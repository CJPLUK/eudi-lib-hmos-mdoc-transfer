/*
 * gatt_peripheral_backend.cj — radio-facing seam for the ISO 18013-5 §8 holder.
 *
 * MdocGattServer owns the §8 state machine; everything that touches the
 * Bluetooth stack goes through GattPeripheralBackend.  The production backend
 * (ConnectivityKitPeripheralBackend) wraps ohos.bluetooth.ble.GattServer.  The
 * in-process LoopbackPeripheralBackend (loopback_peripheral.cj) implements the
 * same contract without a radio so the full status sequence, MTU-driven
 * chunking and the notify retry policy can be exercised in unit tests.
 *
 * Platform mapping (ConnectivityKit → CoreBluetooth equivalent):
 *   createGattServer + addService          → CBPeripheralManager.add(service)
 *   startAdvertising(AdvertisingParams)    → CBPeripheralManager.startAdvertising
 *   on(DescriptorWrite) with CCCD 0x2902   → didSubscribeTo / didUnsubscribeFrom
 *   on(ServerBleMtuChange)                 → CBCentral.maximumUpdateValueLength
 *   notifyCharacteristicChanged            → updateValue(_:for:onSubscribedCentrals:)
 *   sendResponse(ServerResponse)           → respond(to:withResult:)
 *
 * Radio state is supplied by the application through ArkTS
 * ohos.bluetooth.access. On current HarmonyOS devices the Cangjie
 * GattServer.addService binding returns 2900099 even though the equivalent
 * ArkTS API succeeds, so production installs an ArkTS-backed implementation
 * while retaining this seam and the Cangjie state machine.
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble

import ohos.callback_invoke.Callback1Argument
import ohos.business_exception.BusinessException
import kit.ConnectivityKit.*
import kit.PerformanceAnalysisKit.Hilog

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ServiceCharacteristics

// ---------------------------------------------------------------------------
// CCCD descriptor UUID (standard BLE Client Characteristic Configuration)
// ---------------------------------------------------------------------------
public let CCCD_UUID: String = "00002902-0000-1000-8000-00805F9B34FB"


// ---------------------------------------------------------------------------
// ATT response status codes used in ServerResponse.status
// (mirrors CBATTError .success / .readNotPermitted / .requestNotSupported /
//  .unlikelyError used by the iOS MdocGattServer)
// ---------------------------------------------------------------------------
public class AttStatus {
    public static let SUCCESS: Int32 = 0x00
    public static let READ_NOT_PERMITTED: Int32 = 0x02
    public static let REQUEST_NOT_SUPPORTED: Int32 = 0x06
    public static let UNLIKELY_ERROR: Int32 = 0x0E
}

// ---------------------------------------------------------------------------
// Platform error codes surfaced by ohos.bluetooth.ble (BusinessException.code)
// ---------------------------------------------------------------------------
public class BleErrorCodes {
    public static let PERMISSION_DENIED: Int32 = 201
    public static let CAPABILITY_NOT_SUPPORTED: Int32 = 801
    public static let SERVICE_STOPPED: Int32 = 2900001
    public static let BLUETOOTH_DISABLED: Int32 = 2900003
    public static let OPERATION_FAILED: Int32 = 2900099
}

/**
 * Thrown by a GattPeripheralBackend when the platform refuses an operation.
 * `code` carries the ohos.bluetooth BusinessException code (see BleErrorCodes)
 * so the transport can distinguish "radio off" from "permission denied".
 */
public class BleBackendException <: Exception {
    public let code: Int32

    public init(code: Int32, message: String) {
        super(message)
        this.code = code
    }
}

// ---------------------------------------------------------------------------
// GattAttributeRequest — a read/write request from the connected central
// ---------------------------------------------------------------------------

/**
 * Backend-neutral view of a GATT read or write request.
 *
 * `descriptorUUID` is None for characteristic-level requests and Some(uuid)
 * for descriptor-level requests (CCCD subscribe / unsubscribe).  `value` is
 * empty for reads.
 */
public struct GattAttributeRequest {
    public let deviceId: String
    public let transId: Int32
    public let offset: Int32
    public let needRsp: Bool
    public let characteristicUUID: String
    public let descriptorUUID: ?String
    public let value: Array<UInt8>

    public init(
        deviceId: String,
        transId: Int32,
        offset: Int32,
        needRsp: Bool,
        characteristicUUID: String,
        descriptorUUID: ?String,
        value: Array<UInt8>
    ) {
        this.deviceId = deviceId
        this.transId = transId
        this.offset = offset
        this.needRsp = needRsp
        this.characteristicUUID = characteristicUUID
        this.descriptorUUID = descriptorUUID
        this.value = value
    }
}

// ---------------------------------------------------------------------------
// GattPeripheralEvents — callbacks from the backend into the state machine
// ---------------------------------------------------------------------------

/**
 * Events a backend delivers to MdocGattServer.  All methods may be invoked on
 * the platform's Bluetooth callback thread.
 */
public interface GattPeripheralEvents {
    /** Link-layer connection established (connected=true) or dropped (false). */
    func onConnectionStateChanged(deviceId: String, connected: Bool): Unit

    /** ATT MTU negotiated for the current link (e.g. 23, 185, 247, 517). */
    func onMtuChanged(mtu: Int32): Unit

    /** Characteristic or descriptor write from the central. */
    func onWriteRequest(request: GattAttributeRequest): Unit

    /** Characteristic or descriptor read from the central. */
    func onReadRequest(request: GattAttributeRequest): Unit
}

// ---------------------------------------------------------------------------
// GattPeripheralBackend — radio-facing operations used by MdocGattServer
// ---------------------------------------------------------------------------

/**
 * Operations MdocGattServer needs from the Bluetooth stack.
 *
 * Every method that talks to the radio throws BleBackendException on refusal.
 * `open` must register the mdoc GATT service (State / Client2Server /
 * Server2Client and, when `identValue` is Some, Ident) and wire the platform
 * callbacks to `events`.
 */
public interface GattPeripheralBackend {
    func open(serviceUuid: String, identValue: ?Array<UInt8>, events: GattPeripheralEvents): Unit
    func startAdvertise(serviceUuid: String): Unit
    func stopAdvertise(): Unit
    func notify(deviceId: String, serviceUuid: String, characteristicUuid: String, value: Array<UInt8>): Unit
    func respond(deviceId: String, transId: Int32, status: Int32, offset: Int32, value: Array<UInt8>): Unit
    func close(serviceUuid: String): Unit
}

/**
 * Operations implemented by the ArkTS BLE API on HarmonyOS devices whose
 * Cangjie `GattServer.addService` binding is an unsupported runtime stub.
 */
public interface ArkTsGattOperations {
    func open(serviceUuid: String, identHex: String): Unit
    func startAdvertise(serviceUuid: String): Unit
    func stopAdvertise(): Unit
    func notify(deviceId: String, serviceUuid: String, characteristicUuid: String, valueHex: String): Unit
    func respond(deviceId: String, transId: Int32, status: Int32, offset: Int32, valueHex: String): Unit
    func close(serviceUuid: String): Unit
}

/** Process-wide ArkTS platform bridge installed by the application entry. */
public class ArkTsGattBridge {
    private static var operations: ?ArkTsGattOperations = None
    private static var events: ?GattPeripheralEvents = None

    public static func install(operations: ArkTsGattOperations): Unit {
        ArkTsGattBridge.operations = Some(operations)
    }

    public static func backendOrDefault(): GattPeripheralBackend {
        return match (ArkTsGattBridge.operations) {
            case Some(ops) => ArkTsGattPeripheralBackend(ops)
            case None => ConnectivityKitPeripheralBackend()
        }
    }

    static func bind(events: GattPeripheralEvents): Unit { ArkTsGattBridge.events = Some(events) }
    static func unbind(): Unit { ArkTsGattBridge.events = None }

    public static func connectionChanged(deviceId: String, connected: Bool): Unit {
        if (let Some(e) <- ArkTsGattBridge.events) { e.onConnectionStateChanged(deviceId, connected) }
    }
    public static func mtuChanged(mtu: Int32): Unit {
        if (let Some(e) <- ArkTsGattBridge.events) { e.onMtuChanged(mtu) }
    }
    public static func writeRequest(deviceId: String, transId: Int32, offset: Int32, needRsp: Bool,
        characteristicUuid: String, descriptorUuid: ?String, value: Array<UInt8>): Unit {
        if (let Some(e) <- ArkTsGattBridge.events) {
            e.onWriteRequest(GattAttributeRequest(deviceId, transId, offset, needRsp,
                characteristicUuid, descriptorUuid, value))
        }
    }
    public static func readRequest(deviceId: String, transId: Int32, offset: Int32,
        characteristicUuid: String, descriptorUuid: ?String): Unit {
        if (let Some(e) <- ArkTsGattBridge.events) {
            e.onReadRequest(GattAttributeRequest(deviceId, transId, offset, true,
                characteristicUuid, descriptorUuid, Array<UInt8>()))
        }
    }
}

/** Backend-neutral adapter over the ArkTS operations registered by entry. */
public class ArkTsGattPeripheralBackend <: GattPeripheralBackend {
    private let operations: ArkTsGattOperations
    public init(operations: ArkTsGattOperations) { this.operations = operations }

    public func open(serviceUuid: String, identValue: ?Array<UInt8>, events: GattPeripheralEvents): Unit {
        ArkTsGattBridge.bind(events)
        let identHex = match (identValue) { case Some(v) => bytesToHex(v) case None => "" }
        try { this.operations.open(serviceUuid, identHex) }
        catch (e: Exception) { ArkTsGattBridge.unbind(); throw BleBackendException(BleErrorCodes.OPERATION_FAILED, e.message) }
    }
    public func startAdvertise(serviceUuid: String): Unit { this.operations.startAdvertise(serviceUuid) }
    public func stopAdvertise(): Unit { this.operations.stopAdvertise() }
    public func notify(deviceId: String, serviceUuid: String, characteristicUuid: String, value: Array<UInt8>): Unit {
        this.operations.notify(deviceId, serviceUuid, characteristicUuid, bytesToHex(value))
    }
    public func respond(deviceId: String, transId: Int32, status: Int32, offset: Int32, value: Array<UInt8>): Unit {
        this.operations.respond(deviceId, transId, status, offset, bytesToHex(value))
    }
    public func close(serviceUuid: String): Unit {
        try { this.operations.close(serviceUuid) } catch (_: Exception) {}
        ArkTsGattBridge.unbind()
    }
}

private func bytesToHex(value: Array<UInt8>): String {
    let digits = "0123456789abcdef".toArray()
    let out = Array<UInt8>(value.size * 2, repeat: 0u8)
    var i: Int64 = 0
    while (i < value.size) {
        let b = value[i]
        out[i * 2] = digits[Int64(b >> 4)]
        out[i * 2 + 1] = digits[Int64(b & 0x0fu8)]
        i += 1
    }
    return String.fromUtf8(out)
}

// ---------------------------------------------------------------------------
// ConnectivityKit callback adapters (Callback1Argument<T> → closure)
// ---------------------------------------------------------------------------

class GattServerConnStateChangeCb <: Callback1Argument<BleConnectionChangeState> {
    let cb: (?BusinessException, BleConnectionChangeState) -> Unit
    public init(cb: (?BusinessException, BleConnectionChangeState) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, state: BleConnectionChangeState): Unit {
        cb(err, state)
    }
}

class GattServerCharReadCb <: Callback1Argument<CharacteristicReadRequest> {
    let cb: (?BusinessException, CharacteristicReadRequest) -> Unit
    public init(cb: (?BusinessException, CharacteristicReadRequest) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, req: CharacteristicReadRequest): Unit {
        cb(err, req)
    }
}

class GattServerCharWriteCb <: Callback1Argument<CharacteristicWriteRequest> {
    let cb: (?BusinessException, CharacteristicWriteRequest) -> Unit
    public init(cb: (?BusinessException, CharacteristicWriteRequest) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, req: CharacteristicWriteRequest): Unit {
        cb(err, req)
    }
}

class GattServerDescReadCb <: Callback1Argument<DescriptorReadRequest> {
    let cb: (?BusinessException, DescriptorReadRequest) -> Unit
    public init(cb: (?BusinessException, DescriptorReadRequest) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, req: DescriptorReadRequest): Unit {
        cb(err, req)
    }
}

class GattServerDescWriteCb <: Callback1Argument<DescriptorWriteRequest> {
    let cb: (?BusinessException, DescriptorWriteRequest) -> Unit
    public init(cb: (?BusinessException, DescriptorWriteRequest) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, req: DescriptorWriteRequest): Unit {
        cb(err, req)
    }
}

class GattServerMtuChangeCb <: Callback1Argument<Int32> {
    let cb: (?BusinessException, Int32) -> Unit
    public init(cb: (?BusinessException, Int32) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, mtu: Int32): Unit {
        cb(err, mtu)
    }
}

// ---------------------------------------------------------------------------
// ConnectivityKitPeripheralBackend — production backend over GattServer
// ---------------------------------------------------------------------------

/**
 * GattPeripheralBackend backed by ohos.bluetooth.ble.GattServer.
 *
 * Holds the GattServer instance and the advertising handle returned by
 * startAdvertising(AdvertisingParams) so that stopAdvertise / close can tear
 * down exactly what was started.
 */
public class ConnectivityKitPeripheralBackend <: GattPeripheralBackend {

    private var gattServer: ?GattServer = None
    private var advertisingId: ?UInt32 = None

    public init() {}

    // -----------------------------------------------------------------------
    // GATT service construction
    // -----------------------------------------------------------------------

    /** Builds the §8 attribute table (State, Client2Server, Server2Client, Ident). */
    private func buildGattService(serviceUuid: String, identValue: ?Array<UInt8>): GattService {
        let writeOnlyPerms = GattPermissions(read: false, write: true)

        // State: writeNoResponse + notify, CCCD so the reader can subscribe
        let stateCccd = BleDescriptor(serviceUuid, ServiceCharacteristics.STATE_UUID, CCCD_UUID, [0u8, 0u8])
        let stateChar = BleCharacteristic(
            serviceUuid,
            ServiceCharacteristics.STATE_UUID,
            Array<UInt8>(),
            [stateCccd],
            properties: GattProperties(write: true, writeNoResponse: true, read: false, notify: true, indicate: false),
            permissions: writeOnlyPerms
        )

        // Client2Server: writeNoResponse (reader writes request fragments)
        let c2sChar = BleCharacteristic(
            serviceUuid,
            ServiceCharacteristics.CLIENT_2_SERVER_UUID,
            Array<UInt8>(),
            Array<BleDescriptor>(),
            properties: GattProperties(write: true, writeNoResponse: true, read: false, notify: false, indicate: false),
            permissions: writeOnlyPerms
        )

        // Server2Client: notify (holder pushes response fragments), CCCD required
        let s2cCccd = BleDescriptor(serviceUuid, ServiceCharacteristics.SERVER_2_CLIENT_UUID, CCCD_UUID, [0u8, 0u8])
        let s2cChar = BleCharacteristic(
            serviceUuid,
            ServiceCharacteristics.SERVER_2_CLIENT_UUID,
            Array<UInt8>(),
            [s2cCccd],
            properties: GattProperties(write: false, writeNoResponse: false, read: false, notify: true, indicate: false),
            permissions: GattPermissions(read: true, write: false)
        )

        let chars: Array<BleCharacteristic> = match (identValue) {
            case Some(ident) =>
                // Ident: read-only, value = HKDF(EDeviceKey, "BLEIdent") from the kit
                let identChar = BleCharacteristic(
                    serviceUuid,
                    ServiceCharacteristics.IDENT_UUID,
                    ident.clone(),
                    Array<BleDescriptor>(),
                    properties: GattProperties(write: false, writeNoResponse: false, read: true, notify: false, indicate: false),
                    permissions: GattPermissions(read: true, write: false)
                )
                [stateChar, c2sChar, s2cChar, identChar]
            case None => [stateChar, c2sChar, s2cChar]
        }
        return GattService(serviceUuid, true, chars)
    }

    // -----------------------------------------------------------------------
    // Callback wiring
    // -----------------------------------------------------------------------

    private func registerCallbacks(server: GattServer, events: GattPeripheralEvents): Unit {
        // Connection state, characteristic write and characteristic read carry
        // the §8 session, so a rejection there is fatal.  MTU change and the
        // descriptor callbacks are advisory: without them the transport falls
        // back to the default MTU and to promoting Connected on START_REQUEST.
        let connCb = GattServerConnStateChangeCb() {
            err, state =>
            if (state.state == ProfileConnectionState.StateConnected) {
                events.onConnectionStateChanged(state.deviceId, true)
            } else if (state.state == ProfileConnectionState.StateDisconnected) {
                events.onConnectionStateChanged(state.deviceId, false)
            }
        }
        try {
            server.on(BluetoothBleGattServerCallbackType.ConnectionStateChange, connCb)
        } catch (e: BusinessException) {
            Hilog.error(0, "MdocGattServer",
                "on(ConnectionStateChange) rejected code=${e.code} message=${e.message}")
            throw e
        }

        let writeCb = GattServerCharWriteCb() {
            err, req =>
            events.onWriteRequest(GattAttributeRequest(
                req.deviceId, req.transId, req.offset, req.needRsp,
                req.characteristicUUID, None, req.value
            ))
        }
        try {
            server.on(BluetoothBleGattServerCallbackType.CharacteristicWrite, writeCb)
        } catch (e: BusinessException) {
            Hilog.error(0, "MdocGattServer",
                "on(CharacteristicWrite) rejected code=${e.code} message=${e.message}")
            throw e
        }

        let readCb = GattServerCharReadCb() {
            err, req =>
            events.onReadRequest(GattAttributeRequest(
                req.deviceId, req.transId, req.offset, true,
                req.characteristicUUID, None, Array<UInt8>()
            ))
        }
        try {
            server.on(BluetoothBleGattServerCallbackType.CharacteristicRead, readCb)
        } catch (e: BusinessException) {
            Hilog.error(0, "MdocGattServer",
                "on(CharacteristicRead) rejected code=${e.code} message=${e.message}")
            throw e
        }

        let mtuCb = GattServerMtuChangeCb() {
            err, mtu =>
            events.onMtuChanged(mtu)
        }
        try {
            server.on(BluetoothBleGattServerCallbackType.ServerBleMtuChange, mtuCb)
        } catch (e: BusinessException) {
            Hilog.warn(0, "MdocGattServer",
                "on(ServerBleMtuChange) rejected code=${e.code} message=${e.message}; keeping the default MTU")
        }

        let descWriteCb = GattServerDescWriteCb() {
            err, req =>
            events.onWriteRequest(GattAttributeRequest(
                req.deviceId, req.transId, req.offset, req.needRsp,
                req.characteristicUUID, Some(req.descriptorUUID), req.value
            ))
        }
        try {
            server.on(BluetoothBleGattServerCallbackType.DescriptorWrite, descWriteCb)
        } catch (e: BusinessException) {
            Hilog.warn(0, "MdocGattServer",
                "on(DescriptorWrite) rejected code=${e.code} message=${e.message}; subscription tracking is degraded")
        }

        let descReadCb = GattServerDescReadCb() {
            err, req =>
            events.onReadRequest(GattAttributeRequest(
                req.deviceId, req.transId, req.offset, true,
                req.characteristicUUID, Some(req.descriptorUUID), Array<UInt8>()
            ))
        }
        try {
            server.on(BluetoothBleGattServerCallbackType.DescriptorRead, descReadCb)
        } catch (e: BusinessException) {
            Hilog.warn(0, "MdocGattServer",
                "on(DescriptorRead) rejected code=${e.code} message=${e.message}; CCCD reads are unanswered")
        }
    }

    // -----------------------------------------------------------------------
    // GattPeripheralBackend
    // -----------------------------------------------------------------------

    private func createServer(): GattServer {
        try {
            return createGattServer()
        } catch (e: BusinessException) {
            throw BleBackendException(e.code, "createGattServer failed: ${e.message}")
        }
    }

    public func open(serviceUuid: String, identValue: ?Array<UInt8>, events: GattPeripheralEvents): Unit {
        if (this.gattServer.isSome()) {
            return
        }
        let server = this.createServer()

        // ConnectivityKit expects listeners to be installed before the
        // attribute table is registered. HarmonyOS 6.1.1 may otherwise reject
        // addService() with 2900099 even though createGattServer() succeeded.
        try {
            this.registerCallbacks(server, events)
        } catch (e: BusinessException) {
            this.closeQuietly(server)
            throw BleBackendException(e.code,
                "GATT callback registration failed (code=${e.code}): ${e.message}")
        }

        try {
            server.addService(this.buildGattService(serviceUuid, identValue))
        } catch (e: BusinessException) {
            this.closeQuietly(server)
            throw BleBackendException(e.code,
                "GATT service registration failed (code=${e.code}): ${e.message}")
        }
        Hilog.info(0, "MdocGattServer", "GATT service registered: ${serviceUuid}")

        this.gattServer = Some(server)
    }

    private func closeQuietly(server: GattServer): Unit {
        try {
            server.close()
        } catch (e: BusinessException) {
            Hilog.error(0, "MdocGattServer", "close after failed open: ${e.message}")
        }
    }

    public func startAdvertise(serviceUuid: String): Unit {
        if (this.advertisingId.isSome()) {
            return
        }
        let advSetting = AdvertiseSetting(interval: 160, txPower: 0, connectable: true)
        let advData = AdvertiseData([serviceUuid], Array<ManufactureData>(), Array<ServiceData>())
        let advParams = AdvertisingParams(advSetting, advData, duration: 0)
        try {
            let id = startAdvertising(advParams)
            this.advertisingId = Some(id)
        } catch (e: BusinessException) {
            throw BleBackendException(e.code, "startAdvertising failed: ${e.message}")
        }
    }

    public func stopAdvertise(): Unit {
        if (let Some(id) <- this.advertisingId) {
            try {
                stopAdvertising(id)
            } catch (e: BusinessException) {
                Hilog.error(0, "MdocGattServer", "stopAdvertising failed: ${e.message}")
            }
            this.advertisingId = None
        }
    }

    public func notify(deviceId: String, serviceUuid: String, characteristicUuid: String, value: Array<UInt8>): Unit {
        let server = match (this.gattServer) {
            case Some(s) => s
            case None => throw BleBackendException(BleErrorCodes.SERVICE_STOPPED, "GATT server not open")
        }
        let notifyChar = NotifyCharacteristic(serviceUuid, characteristicUuid, value, false)
        try {
            server.notifyCharacteristicChanged(deviceId, notifyChar)
        } catch (e: BusinessException) {
            throw BleBackendException(e.code, "notifyCharacteristicChanged failed: ${e.message}")
        }
    }

    public func respond(deviceId: String, transId: Int32, status: Int32, offset: Int32, value: Array<UInt8>): Unit {
        if (let Some(server) <- this.gattServer) {
            try {
                server.sendResponse(ServerResponse(deviceId, transId, status, offset, value))
            } catch (e: BusinessException) {
                Hilog.error(0, "MdocGattServer", "sendResponse failed: ${e.message}")
            }
        }
    }

    public func close(serviceUuid: String): Unit {
        this.stopAdvertise()
        if (let Some(server) <- this.gattServer) {
            try {
                server.removeService(serviceUuid)
            } catch (e: BusinessException) {
                Hilog.error(0, "MdocGattServer", "removeService failed: ${e.message}")
            }
            try {
                server.close()
            } catch (e: BusinessException) {
                Hilog.error(0, "MdocGattServer", "close failed: ${e.message}")
            }
        }
        this.gattServer = None
    }
}
