/*
 * gatt_client.cj — ISO 18013-5 §8 mdoc reader BLE GATT client.
 *
 * Cangjie translation of Swift MdocGattCentral.
 * Source ref:
 *   Sources/MdocDataTransfer18013/BLETransfer/MDocGattCentral.swift
 *
 * Platform mapping:
 *   CBCentralManager / scanForPeripherals → startBleScanning / on(BleDeviceFind)
 *   CBCentralManager / connect            → createGattClientDevice / connect
 *   CBPeripheral / discoverServices       → gattClient.getServices
 *   CBPeripheral / writeValue             → gattClient.writeCharacteristicValue
 *   CBPeripheral / setNotifyValue         → gattClient.setCharacteristicChangeNotification
 *   CBPeripheralDelegate / didUpdateValueFor → on(BleCharacteristicChange)
 *
 * Loopback / testability design (critical constraint):
 *   The §8 state-machine logic is extracted into two pure methods:
 *     processReceivedNotify(characteristicUUID, bytes) — drives reassembly
 *     computeSendBlocks(data)                          — splits payload for write
 *   Hardware callbacks call these methods; unit tests can call them directly
 *   without ConnectivityKit, enabling in-process loopback testing.
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble

import std.collection.ArrayList

import ohos.callback_invoke.Callback1Argument
import ohos.business_exception.BusinessException
import kit.ConnectivityKit.*
import kit.PerformanceAnalysisKit.Hilog

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.TransferStatus
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.BleTransferModeConst
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.BleTransferFraming
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ErrorCode
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ServiceCharacteristics

// ---------------------------------------------------------------------------
// ConnectivityKit callback classes for BLE scan / GATT client events
// ---------------------------------------------------------------------------

class ScanResultCb <: Callback1Argument<Array<ScanResult>> {
    let cb: (?BusinessException, Array<ScanResult>) -> Unit
    public init(cb: (?BusinessException, Array<ScanResult>) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, results: Array<ScanResult>): Unit {
        cb(err, results)
    }
}

class GattClientConnStateCb <: Callback1Argument<BleConnectionChangeState> {
    let cb: (?BusinessException, BleConnectionChangeState) -> Unit
    public init(cb: (?BusinessException, BleConnectionChangeState) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, state: BleConnectionChangeState): Unit {
        cb(err, state)
    }
}

class GattClientCharChangeCb <: Callback1Argument<BleCharacteristic> {
    let cb: (?BusinessException, BleCharacteristic) -> Unit
    public init(cb: (?BusinessException, BleCharacteristic) -> Unit) {
        this.cb = cb
    }
    public func invoke(err: ?BusinessException, char: BleCharacteristic): Unit {
        cb(err, char)
    }
}

// ---------------------------------------------------------------------------
// MdocGattClient — reader role GATT client + §8 state machine
// ---------------------------------------------------------------------------

/**
 * BLE GATT client implementation for the ISO 18013-5 §8 mdoc reader role.
 *
 * Wraps ConnectivityKit scan + GattClientDevice.  The §8 reassembly logic is
 * exposed via processReceivedNotify() so that unit tests can exercise the
 * protocol flow in-process (loopback with MdocGattServer.notifyBlocks).
 */
public class MdocGattClient <: MdocBleTransport {

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    private var status: TransferStatus = TransferStatus.Initializing
    private var delegate: ?MdocOfflineDelegate = None
    private var gattClient: ?GattClientDevice = None
    private var scanning: Bool = false
    private var serviceUuid: String = ""

    // Characteristic handles discovered after getServices
    private var stateCharUuid: String = ServiceCharacteristics.STATE_UUID
    private var c2sCharUuid: String = ServiceCharacteristics.CLIENT_2_SERVER_UUID
    private var s2cCharUuid: String = ServiceCharacteristics.SERVER_2_CLIENT_UUID

    // Reassembly accumulator for inbound Server2Client notify fragments
    private var readBuffer: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()

    // Send buffer for request fragments
    private var sendBuffer: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()

    // Flag: START_REQUEST has been sent on the State characteristic
    private var didSendStartRequest: Bool = false

    // ---------------------------------------------------------------------------
    // MdocBleTransport — delegate accessors
    // ---------------------------------------------------------------------------

    public func getDelegate(): ?MdocOfflineDelegate {
        return this.delegate
    }

    public func setDelegate(delegate: MdocOfflineDelegate): Unit {
        this.delegate = Some(delegate)
    }

    // ---------------------------------------------------------------------------
    // MdocBleTransport — status
    // ---------------------------------------------------------------------------

    public func currentStatus(): TransferStatus {
        return this.status
    }

    public func isBlePoweredOn(): Bool {
        return match (this.status) {
            case TransferStatus.PoweredOn => true
            case TransferStatus.QrEngagementReady => true
            case TransferStatus.Connected => true
            case TransferStatus.Started => true
            case TransferStatus.RequestReceived => true
            case TransferStatus.ResponseSent => true
            case _ => false
        }
    }

    // ---------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------

    private func setStatus(newStatus: TransferStatus): Unit {
        this.status = newStatus
        if (let Some(d) <- this.delegate) {
            d.didChangeStatus(newStatus)
        }
    }

    private func reportError(code: ErrorCode, message: String): Unit {
        this.setStatus(TransferStatus.Error)
        if (let Some(d) <- this.delegate) {
            d.didFinishedWithError(code, message)
        }
        Hilog.error(0, "MdocGattClient", "Error [${code.describe()}]: ${message}")
    }

    // ---------------------------------------------------------------------------
    // MdocBleTransport — startBleScanning
    // ---------------------------------------------------------------------------

    public func startBleScanning(): Unit {
        // Resolve service UUID from delegate engagement info
        let engagementOpt: ?DeviceEngagementInfo = match (this.delegate) {
            case Some(d) => d.deviceEngagement()
            case None => None
        }
        let engagement = match (engagementOpt) {
            case Some(e) => e
            case None =>
                this.reportError(ErrorCode.DeviceEngagementMissing, "DeviceEngagementInfo not set on delegate")
                return
        }
        this.serviceUuid = engagement.bleServiceUuid

        // Notify delegate that BLE is ready (reader side)
        if (let Some(d) <- this.delegate) {
            d.didPoweredOn(false)
        }

        // Subscribe to scan results
        let self_ = this
        let scanCb = ScanResultCb() {
            err, results =>
            if (results.size > 0) {
                let deviceId = results[0].deviceId
                Hilog.info(0, "MdocGattClient", "Found peripheral: ${deviceId}")
                self_.connectToDevice(deviceId)
                // Stop scanning after first match
                try {
                    stopBleScanning()
                    self_.scanning = false
                } catch (e: BusinessException) {
                    Hilog.error(0, "MdocGattClient", "stopBleScanning failed: ${e.message}")
                }
            }
        }

        try {
            on(BluetoothBleCallbackType.BleDeviceFind, scanCb)
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "on(BleDeviceFind) failed: ${e.message}")
            return
        }

        // Construct scan filter for the MDOC service UUID
        var scanFilter = ScanFilter()
        scanFilter.serviceUUID = this.serviceUuid
        let scanOpts = ScanOptions(
            interval: 0,
            dutyMode: ScanDuty.ScanModeLowPower,
            matchMode: MatchMode.MatchModeAggressive,
            phyType: PhyType.PhyLe1M
        )
        try {
            startBleScanning([scanFilter], options: scanOpts)
            this.scanning = true
            this.setStatus(TransferStatus.QrEngagementReady)
            Hilog.info(0, "MdocGattClient", "BLE scanning started for UUID: ${this.serviceUuid}")
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "startBleScanning failed: ${e.message}")
        }
    }

    // ---------------------------------------------------------------------------
    // MdocBleTransport — stopBleScanning
    // ---------------------------------------------------------------------------

    public func stopBleScanning(): Unit {
        if (this.scanning) {
            try {
                stopBleScanning()
                off(BluetoothBleCallbackType.BleDeviceFind)
                this.scanning = false
            } catch (e: BusinessException) {
                Hilog.error(0, "MdocGattClient", "stopBleScanning failed: ${e.message}")
            }
        }
    }

    // ---------------------------------------------------------------------------
    // MdocBleTransport — startBleAdvertising / stopBleAdvertising
    // Reader does not advertise; provided for interface completeness.
    // ---------------------------------------------------------------------------

    public func startBleAdvertising(): Unit {
        // Reader does not advertise
    }

    public func stopBleAdvertising(): Unit {
        // Reader does not advertise
    }

    // ---------------------------------------------------------------------------
    // Connect → discover → subscribe → send START_REQUEST
    // ---------------------------------------------------------------------------

    private func connectToDevice(deviceId: String): Unit {
        let client: GattClientDevice
        try {
            client = createGattClientDevice(deviceId)
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "createGattClientDevice(${deviceId}) failed: ${e.message}")
            return
        }
        this.gattClient = Some(client)

        // Subscribe to connection state changes
        let self_ = this
        let connCb = GattClientConnStateCb() {
            err, state =>
            if (state.state == ProfileConnectionState.StateConnected) {
                if (let Some(d) <- self_.delegate) {
                    d.didConnected(false, Some(state.deviceId))
                }
                self_.setStatus(TransferStatus.Connected)
                // Discover services after connection
                self_.discoverServices()
            } else if (state.state == ProfileConnectionState.StateDisconnected) {
                self_.setStatus(TransferStatus.Disconnected)
            }
        }
        try {
            client.on(BluetoothBleGattClientDeviceCallbackType.BleConnectionStateChange, connCb)
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "on(BleConnectionStateChange) failed: ${e.message}")
            return
        }

        // Connect
        try {
            client.connect()
            Hilog.info(0, "MdocGattClient", "Connecting to ${deviceId}")
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "connect failed: ${e.message}")
        }
    }

    private func discoverServices(): Unit {
        let client = match (this.gattClient) {
            case Some(c) => c
            case None => return
        }
        let self_ = this
        try {
            client.getServices() {
                err: ?BusinessException, servicesOpt: ?Array<GattService> =>
                if (let Some(e) <- err) {
                    self_.reportError(ErrorCode.BleNotSupported, "getServices callback error: ${e.message}")
                    return
                }
                let services = match (servicesOpt) {
                    case Some(s) => s
                    case None =>
                        self_.reportError(ErrorCode.BleNotSupported, "getServices returned None")
                        return
                }
                self_.onServicesDiscovered(services)
            }
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "getServices failed: ${e.message}")
        }
    }

    private func onServicesDiscovered(services: Array<GattService>): Unit {
        // Verify that the required characteristics are present
        var foundState = false
        var foundC2S = false
        var foundS2C = false

        var i: Int64 = 0
        while (i < services.size) {
            let svc = services[i]
            if (svc.serviceUUID == this.serviceUuid) {
                var j: Int64 = 0
                while (j < svc.characteristics.size) {
                    let char = svc.characteristics[j]
                    if (char.characteristicUUID == ServiceCharacteristics.STATE_UUID) {
                        foundState = true
                    } else if (char.characteristicUUID == ServiceCharacteristics.CLIENT_2_SERVER_UUID) {
                        foundC2S = true
                    } else if (char.characteristicUUID == ServiceCharacteristics.SERVER_2_CLIENT_UUID) {
                        foundS2C = true
                    }
                    j++
                }
            }
            i++
        }

        if (!foundState || !foundC2S || !foundS2C) {
            this.reportError(ErrorCode.BleNotSupported, "Required MDOC characteristics not found on peer")
            return
        }

        Hilog.info(0, "MdocGattClient", "All 3 MDOC characteristics found; subscribing to S2C notify")

        // Subscribe to Server2Client characteristic notifications
        this.subscribeToServer2Client()
    }

    private func subscribeToServer2Client(): Unit {
        let client = match (this.gattClient) {
            case Some(c) => c
            case None => return
        }

        // Subscribe to BleCharacteristicChange events first
        let self_ = this
        let charChangeCb = GattClientCharChangeCb() {
            err, char =>
            if (char.characteristicUUID == self_.s2cCharUuid) {
                let bytes = char.characteristicValue
                let reassembledOpt = self_.processReceivedNotify(char.characteristicUUID, bytes)
                if (let Some(payload) <- reassembledOpt) {
                    if (let Some(d) <- self_.delegate) {
                        d.didReceiveRequest(payload)
                    }
                }
            }
        }
        try {
            client.on(BluetoothBleGattClientDeviceCallbackType.BleCharacteristicChange, charChangeCb)
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "on(BleCharacteristicChange) failed: ${e.message}")
            return
        }

        // Enable Server2Client notifications
        let s2cDescBuf: Array<UInt8> = [0, 0]
        let cccd = BleDescriptor(this.serviceUuid, this.s2cCharUuid, CCCD_UUID, s2cDescBuf)
        let s2cChar = BleCharacteristic(
            this.serviceUuid,
            this.s2cCharUuid,
            Array<UInt8>(),
            [cccd]
        )
        try {
            client.setCharacteristicChangeNotification(s2cChar, true) {
                error: ?BusinessException, c: ?Unit =>
                if (let Some(e) <- error) {
                    self_.reportError(ErrorCode.BleNotSupported, "setCharacteristicChangeNotification failed: ${e.message}")
                    return
                }
                Hilog.info(0, "MdocGattClient", "S2C notification enabled; sending START_REQUEST")
                self_.sendStartRequest()
            }
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "setCharacteristicChangeNotification call failed: ${e.message}")
        }
    }

    private func sendStartRequest(): Unit {
        if (this.didSendStartRequest) {
            return
        }
        let client = match (this.gattClient) {
            case Some(c) => c
            case None => return
        }
        let stateValue: Array<UInt8> = [BleTransferModeConst.START_REQUEST]
        let stateChar = BleCharacteristic(
            this.serviceUuid,
            this.stateCharUuid,
            stateValue,
            Array<BleDescriptor>()
        )
        let self_ = this
        try {
            client.writeCharacteristicValue(stateChar, GattWriteType.WriteNoResponse) {
                error: ?BusinessException, c: ?Unit =>
                if (let Some(e) <- error) {
                    self_.reportError(ErrorCode.BleNotSupported, "writeCharacteristicValue(START_REQUEST) failed: ${e.message}")
                    return
                }
                self_.didSendStartRequest = true
                self_.setStatus(TransferStatus.Started)
                Hilog.info(0, "MdocGattClient", "START_REQUEST sent")
            }
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "writeCharacteristicValue(START_REQUEST) call failed: ${e.message}")
        }
    }

    // ---------------------------------------------------------------------------
    // §8 State machine — pure reassembly logic (testable without hardware)
    // ---------------------------------------------------------------------------

    /**
     * Process bytes received via Server2Client characteristic notify.
     *
     * This is the pure §8 reassembly driver.  It is separated from the
     * ConnectivityKit callback so that unit tests can call it directly
     * (in-process loopback, no real BLE radio needed).
     *
     * @param characteristicUUID  the UUID of the notified characteristic.
     * @param bytes               the raw notify payload (prefix byte + data).
     * @return the fully reassembled response payload when END_DATA is received,
     *         or None if more fragments are expected.
     */
    public func processReceivedNotify(characteristicUUID: String, bytes: Array<UInt8>): ?Array<UInt8> {
        if (characteristicUUID != ServiceCharacteristics.SERVER_2_CLIENT_UUID) {
            return None
        }
        if (bytes.size == 0) {
            return None
        }
        // Accumulate raw block (includes prefix byte) for BleTransferFraming.reassemble
        let blockCopy = Array<UInt8>(bytes.size, {_ => 0u8})
        var i: Int64 = 0
        while (i < bytes.size) {
            blockCopy[i] = bytes[i]
            i++
        }
        this.readBuffer.add(blockCopy)

        let prefix = bytes[0]
        if (prefix == BleTransferModeConst.END_DATA) {
            // Last fragment received — reassemble and return
            let blocks = this.readBuffer.toArray()
            let payload = BleTransferFraming.reassemble(blocks)
            this.readBuffer = ArrayList<Array<UInt8>>()
            this.setStatus(TransferStatus.RequestReceived)
            Hilog.info(0, "MdocGattClient", "Response reassembled: ${payload.size} bytes")
            return Some(payload)
        }
        return None
    }

    // ---------------------------------------------------------------------------
    // MdocBleTransport — sendData (Client2Server write-without-response)
    // ---------------------------------------------------------------------------

    /**
     * Fragment `data` and write each block to the holder via Client2Server
     * characteristic write-without-response.
     */
    public func sendData(data: Array<UInt8>): Unit {
        let client = match (this.gattClient) {
            case Some(c) => c
            case None =>
                this.reportError(ErrorCode.BleNotSupported, "sendData: gattClient not connected")
                return
        }
        let blocks = BleTransferFraming.prepareDataBlocksToSend(data, DEFAULT_MAX_BLOCK_SIZE)
        if (blocks.size == 0) {
            Hilog.info(0, "MdocGattClient", "sendData: nothing to send")
            return
        }

        // Store for sequential write
        this.sendBuffer = ArrayList<Array<UInt8>>()
        var i: Int64 = 0
        while (i < blocks.size) {
            this.sendBuffer.add(blocks[i])
            i++
        }

        this.writeNextBlock(client)
    }

    /**
     * Write the next block from sendBuffer to the Client2Server characteristic.
     *
     * Exposed for loopback test: the test can call this directly to feed
     * blocks into the server's processWrittenBytes without ConnectivityKit.
     */
    public func writeNextBlock(client: GattClientDevice): Unit {
        if (this.sendBuffer.size == 0) {
            this.setStatus(TransferStatus.ResponseSent)
            Hilog.info(0, "MdocGattClient", "All request blocks sent")
            return
        }
        let block = this.sendBuffer[0]
        this.sendBuffer.remove(0..1)

        let c2sChar = BleCharacteristic(
            this.serviceUuid,
            this.c2sCharUuid,
            block,
            Array<BleDescriptor>()
        )
        let self_ = this
        try {
            client.writeCharacteristicValue(c2sChar, GattWriteType.WriteNoResponse) {
                error: ?BusinessException, c: ?Unit =>
                if (let Some(e) <- error) {
                    self_.reportError(ErrorCode.BleNotSupported, "writeCharacteristicValue(C2S) failed: ${e.message}")
                    return
                }
                self_.writeNextBlock(client)
            }
        } catch (e: BusinessException) {
            this.reportError(ErrorCode.BleNotSupported, "writeCharacteristicValue(C2S) call failed: ${e.message}")
        }
    }

    // ---------------------------------------------------------------------------
    // MdocBleTransport — stop
    // ---------------------------------------------------------------------------

    public func stop(): Unit {
        // Send END_REQUEST to the holder
        if (let Some(client) <- this.gattClient) {
            let endValue: Array<UInt8> = [BleTransferModeConst.END_REQUEST]
            let stateChar = BleCharacteristic(
                this.serviceUuid,
                this.stateCharUuid,
                endValue,
                Array<BleDescriptor>()
            )
            try {
                client.writeCharacteristicValue(stateChar, GattWriteType.WriteNoResponse) {
                    error: ?BusinessException, c: ?Unit => ()
                }
            } catch (e: BusinessException) {
                Hilog.error(0, "MdocGattClient", "writeCharacteristicValue(END_REQUEST) failed: ${e.message}")
            }

            // Disconnect
            try {
                client.disconnect()
                client.close()
            } catch (e: BusinessException) {
                Hilog.error(0, "MdocGattClient", "disconnect/close failed: ${e.message}")
            }
        }
        this.gattClient = None
        this.readBuffer = ArrayList<Array<UInt8>>()
        this.sendBuffer = ArrayList<Array<UInt8>>()
        this.didSendStartRequest = false
        this.setStatus(TransferStatus.Disconnected)
    }
}
