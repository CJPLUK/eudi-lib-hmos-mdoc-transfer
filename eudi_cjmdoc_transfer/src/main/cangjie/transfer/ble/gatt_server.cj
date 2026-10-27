/*
 * gatt_server.cj — ISO 18013-5 §8 mdoc holder BLE GATT server.
 *
 * Cangjie translation of Swift MdocGattServer.
 * Source ref:
 *   Sources/MdocDataTransfer18013/BLETransfer/MdocGATTServer.swift
 *
 * Status emission map (delegate.didChangeStatus), in protocol order:
 *   ctor                                         → Initialized
 *   backend.open succeeded (radio accepted us)   → didPoweredOn(true), PoweredOn
 *   advertising running                          → QrEngagementReady
 *   CCCD enabled on BOTH State and Server2Client → didConnected, Connected
 *     (fallback: a START_REQUEST arriving before both CCCD writes were
 *      observed also promotes QrEngagementReady → Connected first)
 *   State write 0x01                             → Started (read buffer reset)
 *   last Client2Server chunk (0x00 prefix)       → RequestReceived, didReceiveRequest
 *   sendData queue fully drained                 → ResponseSent
 *   State write 0x02 / CCCD disabled / link lost → Disconnected
 *   any failure                                  → Error, didFinishedWithError
 *   stop()                                       → Initialized
 *
 * Block size: min(511, ATT_MTU - 3 - 1).  The ATT notification header takes
 * 3 bytes of the MTU (CoreBluetooth's maximumUpdateValueLength already
 * excludes it) and the §8 framing prefix takes one more.  Until the central
 * negotiates, ATT_MTU is 23 → 19-byte payload per chunk.
 *
 * Loopback / testability design:
 *   All radio access goes through GattPeripheralBackend; MdocGattServer
 *   implements GattPeripheralEvents.  Tests construct the server with a
 *   LoopbackPeripheralBackend and call the event methods (or the pure
 *   processWrittenBytes / handleCharacteristicWrite / handleSubscription
 *   seams) directly.
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble

import std.collection.ArrayList
import std.sync.Monitor
import std.time.MonoTime

import kit.PerformanceAnalysisKit.Hilog

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.TransferStatus
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.BleTransferModeConst
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.BleTransferFraming
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ErrorCode
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ServiceCharacteristics

// ---------------------------------------------------------------------------
// BLE frame size constants
// ---------------------------------------------------------------------------

/// Upper bound on the payload bytes per notify chunk (excluding the 1-byte
/// framing prefix).  Mirrors iOS `min(511, maximumUpdateValueLength - 1)`.
let DEFAULT_MAX_BLOCK_SIZE: Int64 = 511

/// ATT_MTU before the central negotiates a larger one (Bluetooth Core 5.x).
let DEFAULT_ATT_MTU: Int32 = 23

/// Bytes of ATT_MTU consumed by the notification header (opcode + handle).
let ATT_NOTIFY_OVERHEAD: Int64 = 3

// ---------------------------------------------------------------------------
// NotifyPacing — serial notify schedule (ConnectivityKit has no "ready to
// update subscribers" callback, so delivery is paced instead of event-driven)
// ---------------------------------------------------------------------------

/**
 * Timing / retry policy for the Server2Client notify queue.
 *
 *   startDelay      — wait before the first chunk (iOS: asyncAfter 0.2 s)
 *   interChunkDelay — gap between consecutive chunks
 *   retryBackoff    — base delay after a failed notify; multiplied by the
 *                     attempt number (linear back-off)
 *   maxAttempts     — attempts per chunk before giving up with an error
 */
public struct NotifyPacing {
    public let startDelay: Duration
    public let interChunkDelay: Duration
    public let retryBackoff: Duration
    public let maxAttempts: Int64

    public init(
        startDelay!: Duration = Duration.millisecond * 200,
        interChunkDelay!: Duration = Duration.millisecond * 10,
        retryBackoff!: Duration = Duration.millisecond * 50,
        maxAttempts!: Int64 = 5
    ) {
        this.startDelay = startDelay
        this.interChunkDelay = interChunkDelay
        this.retryBackoff = retryBackoff
        this.maxAttempts = maxAttempts
    }

    /** Zero delays, same retry budget — for in-process loopback tests. */
    public static func immediate(): NotifyPacing {
        return NotifyPacing(
            startDelay: Duration.Zero,
            interChunkDelay: Duration.Zero,
            retryBackoff: Duration.Zero,
            maxAttempts: 5
        )
    }
}

// ---------------------------------------------------------------------------
// WriteOutcome — result of a characteristic write for the ATT response
// ---------------------------------------------------------------------------

/**
 * Outcome of handleCharacteristicWrite.
 *   Accepted        — write consumed, respond AttStatus.SUCCESS
 *   Completed(data) — write consumed and it completed a request; `data` is
 *                     the reassembled payload (delegate already notified)
 *   Rejected(att)   — write refused; `att` is the ATT status to respond with
 */
public enum WriteOutcome {
    | Accepted
    | Completed(Array<UInt8>)
    | Rejected(Int32)
}

/// Result of one pass over the Server2Client send queue (block counts carried
/// for logging).
enum DrainOutcome {
    | Drained(Int64)
    | Cancelled(Int64)
    | Failed(String)
}

// ---------------------------------------------------------------------------
// MdocGattServer — holder role GATT server + §8 state machine
// ---------------------------------------------------------------------------

public class MdocGattServer <: MdocBleTransport & GattPeripheralEvents {

    // -----------------------------------------------------------------------
    // Collaborators
    // -----------------------------------------------------------------------

    private let backend: GattPeripheralBackend
    private let pacing: NotifyPacing
    private let monitor: Monitor = Monitor()

    // -----------------------------------------------------------------------
    // State (guarded by monitor unless noted)
    // -----------------------------------------------------------------------

    private var status: TransferStatus = TransferStatus.Initialized
    private var delegate: ?MdocOfflineDelegate = None
    private var serviceUuid: String = ""
    private var identValue: ?Array<UInt8> = None

    private var opened: Bool = false
    private var advertising: Bool = false
    private var radioConfirmed: Bool = false

    private var connectedDeviceId: String = ""
    private var negotiatedMtu: Int32 = DEFAULT_ATT_MTU
    private var stateSubscribed: Bool = false
    private var s2cSubscribed: Bool = false

    // Reassembly accumulator for inbound Client2Server fragments
    private var readBuffer: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()

    // Outbound Server2Client queue
    private var sendQueue: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()
    private var sendGeneration: Int64 = 0
    private var draining: Bool = false
    private var sendCancelled: Bool = false

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    public init() {
        this.backend = ArkTsGattBridge.backendOrDefault()
        this.pacing = NotifyPacing()
    }

    /**
     * Construct with an explicit backend / pacing — the loopback test seam.
     */
    public init(backend!: GattPeripheralBackend, pacing!: NotifyPacing = NotifyPacing()) {
        this.backend = backend
        this.pacing = pacing
    }

    // -----------------------------------------------------------------------
    // MdocBleTransport — delegate accessors
    // -----------------------------------------------------------------------

    public func getDelegate(): ?MdocOfflineDelegate {
        synchronized(this.monitor) {
            return this.delegate
        }
    }

    public func setDelegate(delegate: MdocOfflineDelegate): Unit {
        synchronized(this.monitor) {
            this.delegate = Some(delegate)
        }
    }

    // -----------------------------------------------------------------------
    // Ident characteristic (optional, §8.3.3.1.5)
    // -----------------------------------------------------------------------

    /**
     * Set the value served on the Ident characteristic (…0004).  Must be
     * called before startBleAdvertising(); the kit computes
     * HKDF(EDeviceKey, "BLEIdent").  Passing an empty array disables Ident.
     */
    public func setIdentValue(value: Array<UInt8>): Unit {
        synchronized(this.monitor) {
            if (value.size == 0) {
                this.identValue = None
            } else {
                this.identValue = Some(value.clone())
            }
        }
    }

    // -----------------------------------------------------------------------
    // MdocBleTransport — status
    // -----------------------------------------------------------------------

    public func currentStatus(): TransferStatus {
        synchronized(this.monitor) {
            return this.status
        }
    }

    /**
     * True once the platform accepted GATT server creation and service
     * registration (refused with BleErrorCodes.BLUETOOTH_DISABLED while the
     * radio is off) and until stop() or a radio-off error.
     */
    public func isBlePoweredOn(): Bool {
        synchronized(this.monitor) {
            return this.radioConfirmed
        }
    }

    /** Negotiated ATT_MTU for the current link (23 until the central changes it). */
    public func negotiatedMtuSize(): Int32 {
        synchronized(this.monitor) {
            return this.negotiatedMtu
        }
    }

    /** Payload bytes per notify chunk derived from the negotiated MTU. */
    public func currentBlockSize(): Int64 {
        return MdocGattServer.blockSizeFor(this.negotiatedMtuSize())
    }

    /**
     * Block payload for a given ATT_MTU: min(511, mtu - 3 - 1).
     * Values below the Bluetooth minimum (23) are treated as 23.
     */
    public static func blockSizeFor(mtu: Int32): Int64 {
        var effective = Int64(mtu)
        if (effective < Int64(DEFAULT_ATT_MTU)) {
            effective = Int64(DEFAULT_ATT_MTU)
        }
        let usable = effective - ATT_NOTIFY_OVERHEAD - 1
        if (usable > DEFAULT_MAX_BLOCK_SIZE) {
            return DEFAULT_MAX_BLOCK_SIZE
        }
        return usable
    }

    // -----------------------------------------------------------------------
    // Internal helpers — status update + error reporting
    // (delegate callbacks are always invoked outside the monitor)
    // -----------------------------------------------------------------------

    private func setStatus(newStatus: TransferStatus): Unit {
        var d: ?MdocOfflineDelegate = None
        synchronized(this.monitor) {
            this.status = newStatus
            d = this.delegate
        }
        if (let Some(del) <- d) {
            del.didChangeStatus(newStatus)
        }
    }

    private func reportError(code: ErrorCode, message: String): Unit {
        Hilog.error(0, "MdocGattServer", "Error [${code.describe()}]: ${message}")
        this.setStatus(TransferStatus.Error)
        let d = this.getDelegate()
        if (let Some(del) <- d) {
            del.didFinishedWithError(code, message)
        }
    }

    private func reportBackendError(e: BleBackendException, context: String): Unit {
        if (e.code == BleErrorCodes.BLUETOOTH_DISABLED) {
            synchronized(this.monitor) {
                this.radioConfirmed = false
            }
            this.reportError(ErrorCode.BleNotSupported, "Bluetooth is off (${context}: ${e.message})")
        } else if (e.code == BleErrorCodes.PERMISSION_DENIED) {
            this.reportError(ErrorCode.BleNotAuthorized, "${context}: ${e.message}")
        } else if (e.code == BleErrorCodes.CAPABILITY_NOT_SUPPORTED) {
            this.reportError(ErrorCode.BleNotSupported, "${context}: ${e.message}")
        } else {
            this.reportError(ErrorCode.UnexpectedError, "${context}: ${e.message}")
        }
    }

    private func isSessionActive(): Bool {
        synchronized(this.monitor) {
            return match (this.status) {
                case TransferStatus.Connected => true
                case TransferStatus.Started => true
                case TransferStatus.RequestReceived => true
                case TransferStatus.UserSelected => true
                case TransferStatus.ResponseSent => true
                case _ => false
            }
        }
    }

    private func isStatus(expected: TransferStatus): Bool {
        synchronized(this.monitor) {
            return match ((this.status, expected)) {
                case (TransferStatus.Initializing, TransferStatus.Initializing) => true
                case (TransferStatus.Initialized, TransferStatus.Initialized) => true
                case (TransferStatus.PoweredOn, TransferStatus.PoweredOn) => true
                case (TransferStatus.QrEngagementReady, TransferStatus.QrEngagementReady) => true
                case (TransferStatus.Connected, TransferStatus.Connected) => true
                case (TransferStatus.Started, TransferStatus.Started) => true
                case (TransferStatus.RequestReceived, TransferStatus.RequestReceived) => true
                case (TransferStatus.UserSelected, TransferStatus.UserSelected) => true
                case (TransferStatus.ResponseSent, TransferStatus.ResponseSent) => true
                case (TransferStatus.Disconnected, TransferStatus.Disconnected) => true
                case (TransferStatus.Error, TransferStatus.Error) => true
                case _ => false
            }
        }
    }

    private static func sameUuid(a: String, b: String): Bool {
        return a.equalsIgnoreAsciiCase(b)
    }

    // -----------------------------------------------------------------------
    // MdocBleTransport — startBleAdvertising
    // -----------------------------------------------------------------------

    public func startBleAdvertising(): Unit {
        if (this.isStatus(TransferStatus.Error)) {
            Hilog.info(0, "MdocGattServer", "startBleAdvertising ignored: transport is in error state")
            return
        }
        var alreadyAdvertising = false
        synchronized(this.monitor) {
            alreadyAdvertising = this.advertising
        }
        if (alreadyAdvertising) {
            Hilog.info(0, "MdocGattServer", "startBleAdvertising ignored: already advertising")
            return
        }

        // Resolve service UUID from delegate engagement info
        let engagementOpt: ?DeviceEngagementInfo = match (this.getDelegate()) {
            case Some(d) => d.deviceEngagement()
            case None => None
        }
        let engagement = match (engagementOpt) {
            case Some(e) => e
            case None =>
                this.reportError(ErrorCode.DeviceEngagementMissing, "DeviceEngagementInfo not set on delegate")
                return
        }
        var uuid = ""
        var ident: ?Array<UInt8> = None
        synchronized(this.monitor) {
            this.serviceUuid = engagement.bleServiceUuid
            uuid = this.serviceUuid
            ident = this.identValue
        }

        // Bring the GATT server up.  The platform refuses this while the radio
        // is off (BLUETOOTH_DISABLED), so success is the "powered on" signal.
        try {
            this.backend.open(uuid, ident, this)
        } catch (e: BleBackendException) {
            this.reportBackendError(e, "GATT server setup")
            return
        }
        synchronized(this.monitor) {
            this.opened = true
            this.radioConfirmed = true
        }
        if (let Some(d) <- this.getDelegate()) {
            d.didPoweredOn(true)
        }
        this.setStatus(TransferStatus.PoweredOn)

        // Advertise the engagement service UUID
        try {
            this.backend.startAdvertise(uuid)
        } catch (e: BleBackendException) {
            this.reportBackendError(e, "startAdvertising")
            return
        }
        synchronized(this.monitor) {
            this.advertising = true
        }
        this.setStatus(TransferStatus.QrEngagementReady)
        Hilog.info(0, "MdocGattServer", "BLE advertising started with service UUID: ${uuid}")
    }

    // -----------------------------------------------------------------------
    // MdocBleTransport — stopBleAdvertising
    // -----------------------------------------------------------------------

    public func stopBleAdvertising(): Unit {
        var wasAdvertising = false
        synchronized(this.monitor) {
            wasAdvertising = this.advertising
            this.advertising = false
        }
        if (wasAdvertising) {
            this.backend.stopAdvertise()
            Hilog.info(0, "MdocGattServer", "BLE advertising stopped")
        }
    }

    // -----------------------------------------------------------------------
    // MdocBleTransport — startBleScanning / stopBleScanning
    // Not used in the holder role; provided for interface completeness.
    // -----------------------------------------------------------------------

    public func startBleScanning(): Unit {
        // Holder does not scan
    }

    public func stopBleScanning(): Unit {
        // Holder does not scan
    }

    // -----------------------------------------------------------------------
    // GattPeripheralEvents — link and MTU
    // -----------------------------------------------------------------------

    public func onConnectionStateChanged(deviceId: String, connected: Bool): Unit {
        if (connected) {
            synchronized(this.monitor) {
                this.connectedDeviceId = deviceId
                this.negotiatedMtu = DEFAULT_ATT_MTU
                this.stateSubscribed = false
                this.s2cSubscribed = false
            }
            Hilog.info(0, "MdocGattServer", "Central connected: ${deviceId}")
            return
        }
        var isCurrent = false
        synchronized(this.monitor) {
            isCurrent = this.connectedDeviceId == "" || this.connectedDeviceId == deviceId
            if (isCurrent) {
                this.connectedDeviceId = ""
                this.stateSubscribed = false
                this.s2cSubscribed = false
            }
        }
        if (!isCurrent) {
            return
        }
        Hilog.info(0, "MdocGattServer", "Central disconnected: ${deviceId}")
        this.cancelPendingSend()
        if (this.isSessionActive()) {
            this.setStatus(TransferStatus.Disconnected)
        }
    }

    public func onMtuChanged(mtu: Int32): Unit {
        synchronized(this.monitor) {
            if (mtu >= DEFAULT_ATT_MTU) {
                this.negotiatedMtu = mtu
            }
        }
        Hilog.info(0, "MdocGattServer", "ATT MTU changed: ${mtu} → block size ${this.currentBlockSize()}")
    }

    // -----------------------------------------------------------------------
    // GattPeripheralEvents — writes
    // -----------------------------------------------------------------------

    public func onWriteRequest(request: GattAttributeRequest): Unit {
        var attStatus = AttStatus.SUCCESS
        var completed: ?Array<UInt8> = None
        match (request.descriptorUUID) {
            case Some(descUuid) =>
                if (MdocGattServer.sameUuid(descUuid, CCCD_UUID)) {
                    // CCCD bit0 = notifications, bit1 = indications
                    let enabled = request.value.size > 0 && (request.value[0] & 0x03u8) != 0u8
                    this.handleSubscription(request.characteristicUUID, enabled)
                } else {
                    attStatus = AttStatus.REQUEST_NOT_SUPPORTED
                }
            case None =>
                match (this.handleCharacteristicWrite(request.characteristicUUID, request.value)) {
                    case WriteOutcome.Accepted => ()
                    case WriteOutcome.Completed(payload) => completed = Some(payload)
                    case WriteOutcome.Rejected(att) => attStatus = att
                }
        }
        if (request.needRsp) {
            this.backend.respond(request.deviceId, request.transId, attStatus, request.offset, Array<UInt8>())
        }
        if (let Some(payload) <- completed) {
            if (let Some(d) <- this.getDelegate()) {
                d.didReceiveRequest(payload)
            }
        }
    }

    /**
     * Subscription tracking (CBPeripheralManager didSubscribeTo / didUnsubscribeFrom).
     *
     * Connected is emitted once the central has enabled notifications on BOTH
     * State and Server2Client while the holder is QrEngagementReady.  Any
     * unsubscribe during an active session ends it (Disconnected).
     */
    public func handleSubscription(characteristicUUID: String, enabled: Bool): Unit {
        let isState = MdocGattServer.sameUuid(characteristicUUID, ServiceCharacteristics.STATE_UUID)
        let isS2c = MdocGattServer.sameUuid(characteristicUUID, ServiceCharacteristics.SERVER_2_CLIENT_UUID)
        if (!isState && !isS2c) {
            return
        }
        let name = ServiceCharacteristics.descriptionFor(characteristicUUID)
        if (enabled) {
            if (!this.isStatus(TransferStatus.QrEngagementReady)) {
                Hilog.info(0, "MdocGattServer", "Subscribe on ${name} ignored (not engagement-ready)")
                return
            }
            var both = false
            synchronized(this.monitor) {
                if (isState) {
                    this.stateSubscribed = true
                } else {
                    this.s2cSubscribed = true
                }
                both = this.stateSubscribed && this.s2cSubscribed
            }
            Hilog.info(0, "MdocGattServer", "Remote central subscribed to ${name}")
            if (both) {
                this.promoteToConnected()
            }
            return
        }
        var wasActive = false
        synchronized(this.monitor) {
            if (isState) {
                this.stateSubscribed = false
            } else {
                this.s2cSubscribed = false
            }
        }
        wasActive = this.isSessionActive()
        Hilog.info(0, "MdocGattServer", "Remote central unsubscribed from ${name}")
        if (wasActive) {
            this.cancelPendingSend()
            this.setStatus(TransferStatus.Disconnected)
        }
    }

    private func promoteToConnected(): Unit {
        var deviceId = ""
        synchronized(this.monitor) {
            deviceId = this.connectedDeviceId
        }
        if (let Some(d) <- this.getDelegate()) {
            d.didConnected(true, Some(deviceId))
        }
        this.setStatus(TransferStatus.Connected)
    }

    // -----------------------------------------------------------------------
    // §8 State machine — pure logic (testable without hardware)
    // -----------------------------------------------------------------------

    /**
     * Process raw bytes written to a characteristic by the remote reader and
     * return the reassembled request when this write completed it.
     *
     * Thin wrapper over handleCharacteristicWrite kept for the pure loopback
     * tests; the ATT status is discarded.
     */
    public func processWrittenBytes(characteristicUUID: String, bytes: Array<UInt8>): ?Array<UInt8> {
        return match (this.handleCharacteristicWrite(characteristicUUID, bytes)) {
            case WriteOutcome.Completed(payload) => Some(payload)
            case _ => None
        }
    }

    /**
     * Drive the §8 state machine with a characteristic write and compute the
     * ATT status to answer with.
     *
     * Characteristic routing:
     *   State          → 0x01 START_REQUEST → Started (read buffer reset)
     *                    0x02 END_REQUEST   → Disconnected
     *                    anything else      → Rejected(UNLIKELY_ERROR)
     *   Client2Server  → 0x01 START_DATA / 0x00 END_DATA fragments;
     *                    other prefix       → Rejected(UNLIKELY_ERROR)
     *   other UUID     → Rejected(REQUEST_NOT_SUPPORTED)
     */
    public func handleCharacteristicWrite(characteristicUUID: String, bytes: Array<UInt8>): WriteOutcome {
        if (MdocGattServer.sameUuid(characteristicUUID, ServiceCharacteristics.STATE_UUID)) {
            return this.handleStateWrite(bytes)
        }
        if (MdocGattServer.sameUuid(characteristicUUID, ServiceCharacteristics.CLIENT_2_SERVER_UUID)) {
            return this.handleClient2ServerWrite(bytes)
        }
        Hilog.error(0, "MdocGattServer", "Write to unsupported characteristic ${characteristicUUID}")
        return WriteOutcome.Rejected(AttStatus.REQUEST_NOT_SUPPORTED)
    }

    private func handleStateWrite(bytes: Array<UInt8>): WriteOutcome {
        if (bytes.size == 0) {
            Hilog.error(0, "MdocGattServer", "Empty State write rejected")
            return WriteOutcome.Rejected(AttStatus.REQUEST_NOT_SUPPORTED)
        }
        let b = bytes[0]
        if (b == BleTransferModeConst.START_REQUEST) {
            // A compliant reader subscribes before START; if the CCCD writes
            // were not surfaced by the stack, treat START as proof of both.
            if (this.isStatus(TransferStatus.QrEngagementReady)) {
                synchronized(this.monitor) {
                    this.stateSubscribed = true
                    this.s2cSubscribed = true
                }
                this.promoteToConnected()
            }
            synchronized(this.monitor) {
                this.readBuffer = ArrayList<Array<UInt8>>()
            }
            this.setStatus(TransferStatus.Started)
            Hilog.info(0, "MdocGattServer", "START_REQUEST received — session started")
            return WriteOutcome.Accepted
        }
        if (b == BleTransferModeConst.END_REQUEST) {
            Hilog.info(0, "MdocGattServer", "END_REQUEST received — session ended")
            this.cancelPendingSend()
            if (!this.isStatus(TransferStatus.Disconnected)) {
                this.setStatus(TransferStatus.Disconnected)
            }
            return WriteOutcome.Accepted
        }
        Hilog.error(0, "MdocGattServer", "Invalid State byte ${b} rejected")
        return WriteOutcome.Rejected(AttStatus.UNLIKELY_ERROR)
    }

    private func handleClient2ServerWrite(bytes: Array<UInt8>): WriteOutcome {
        if (bytes.size == 0) {
            Hilog.error(0, "MdocGattServer", "Empty Client2Server block rejected")
            return WriteOutcome.Rejected(AttStatus.UNLIKELY_ERROR)
        }
        let prefix = bytes[0]
        let isStartBlock = prefix == BleTransferModeConst.START_DATA
        let isEndBlock = prefix == BleTransferModeConst.END_DATA
        if (!isStartBlock && !isEndBlock) {
            Hilog.error(0, "MdocGattServer", "Not a valid request block (prefix ${prefix}) — rejected")
            return WriteOutcome.Rejected(AttStatus.UNLIKELY_ERROR)
        }
        var payload: ?Array<UInt8> = None
        synchronized(this.monitor) {
            if (bytes.size > 1) {
                this.readBuffer.add(bytes.clone())
            }
            if (isEndBlock) {
                let blocks = this.readBuffer.toArray()
                payload = Some(BleTransferFraming.reassemble(blocks))
                this.readBuffer = ArrayList<Array<UInt8>>()
            }
        }
        match (payload) {
            case Some(p) =>
                this.setStatus(TransferStatus.RequestReceived)
                Hilog.info(0, "MdocGattServer", "Request reassembled: ${p.size} bytes")
                return WriteOutcome.Completed(p)
            case None => return WriteOutcome.Accepted
        }
    }

    // -----------------------------------------------------------------------
    // GattPeripheralEvents — reads (Ident value, CCCD state)
    // -----------------------------------------------------------------------

    public func onReadRequest(request: GattAttributeRequest): Unit {
        var value: Array<UInt8> = Array<UInt8>()
        var attStatus = AttStatus.READ_NOT_PERMITTED
        match (request.descriptorUUID) {
            case Some(descUuid) =>
                if (MdocGattServer.sameUuid(descUuid, CCCD_UUID)) {
                    var subscribed = false
                    synchronized(this.monitor) {
                        if (MdocGattServer.sameUuid(request.characteristicUUID, ServiceCharacteristics.STATE_UUID)) {
                            subscribed = this.stateSubscribed
                        } else if (MdocGattServer.sameUuid(request.characteristicUUID, ServiceCharacteristics.SERVER_2_CLIENT_UUID)) {
                            subscribed = this.s2cSubscribed
                        }
                    }
                    value = if (subscribed) { [0x01u8, 0x00u8] } else { [0x00u8, 0x00u8] }
                    attStatus = AttStatus.SUCCESS
                }
            case None =>
                if (MdocGattServer.sameUuid(request.characteristicUUID, ServiceCharacteristics.IDENT_UUID)) {
                    var ident: ?Array<UInt8> = None
                    synchronized(this.monitor) {
                        ident = this.identValue
                    }
                    if (let Some(full) <- ident) {
                        let offset = Int64(request.offset)
                        if (offset >= 0 && offset <= full.size) {
                            value = full[offset..full.size]
                            attStatus = AttStatus.SUCCESS
                        }
                    }
                }
        }
        this.backend.respond(request.deviceId, request.transId, attStatus, request.offset, value)
    }

    // -----------------------------------------------------------------------
    // MdocBleTransport — sendData (Server2Client notify, serial + paced)
    // -----------------------------------------------------------------------

    /**
     * Fragment `data` with the negotiated block size and deliver the chunks
     * on Server2Client strictly one at a time from a background thread.
     * ResponseSent is emitted when the queue drains; a chunk that still fails
     * after NotifyPacing.maxAttempts aborts the send with an error.
     */
    public func sendData(data: Array<UInt8>): Unit {
        let blockSize = this.currentBlockSize()
        let blocks = BleTransferFraming.prepareDataBlocksToSend(data, blockSize)
        if (blocks.size == 0) {
            Hilog.info(0, "MdocGattServer", "sendData: nothing to send")
            this.setStatus(TransferStatus.ResponseSent)
            return
        }
        var startDrain = false
        synchronized(this.monitor) {
            this.sendQueue = ArrayList<Array<UInt8>>()
            var i: Int64 = 0
            while (i < blocks.size) {
                this.sendQueue.add(blocks[i])
                i++
            }
            this.sendGeneration++
            this.sendCancelled = false
            startDrain = !this.draining
            this.draining = true
        }
        Hilog.info(0, "MdocGattServer", "sendData: ${data.size} bytes → ${blocks.size} blocks of ≤${blockSize}B")
        if (startDrain) {
            let self_ = this
            spawn {
                => self_.drainSendQueue()
            }
        }
    }

    /**
     * Block until the current sendData queue has drained (ResponseSent) or
     * was aborted, or until `timeout` elapses.  Returns true when no send is
     * pending any more.
     */
    public func awaitSendCompletion(timeout: Duration): Bool {
        let deadline = MonoTime.now() + timeout
        synchronized(this.monitor) {
            while (this.draining) {
                let remaining = deadline - MonoTime.now()
                if (remaining <= Duration.Zero) {
                    return false
                }
                this.monitor.wait(timeout: remaining)
            }
            return true
        }
    }

    private func cancelPendingSend(): Unit {
        synchronized(this.monitor) {
            this.sendCancelled = true
            this.sendQueue = ArrayList<Array<UInt8>>()
        }
    }

    /**
     * Background drain loop.  Terminal emissions (ResponseSent / Error) are
     * made while `draining` is still set so awaitSendCompletion() returns only
     * after the delegate saw them; if a delegate callback queued more data in
     * the meantime the same thread keeps going.
     */
    private func drainSendQueue(): Unit {
        if (this.pacing.startDelay > Duration.Zero) {
            sleep(this.pacing.startDelay)
        }
        while (true) {
            match (this.deliverQueuedBlocks()) {
                case DrainOutcome.Drained(count) =>
                    Hilog.info(0, "MdocGattServer", "Finished sending BLE data (${count} blocks)")
                    this.setStatus(TransferStatus.ResponseSent)
                case DrainOutcome.Cancelled(count) =>
                    Hilog.info(0, "MdocGattServer", "Send cancelled after ${count} blocks")
                case DrainOutcome.Failed(message) =>
                    this.cancelPendingSend()
                    this.reportError(ErrorCode.UnexpectedError, message)
            }
            var again = false
            synchronized(this.monitor) {
                again = !this.sendCancelled && this.sendQueue.size > 0
                if (!again) {
                    this.draining = false
                    this.monitor.notifyAll()
                }
            }
            if (!again) {
                break
            }
        }
    }

    /**
     * Deliver queued blocks strictly one at a time with bounded retry.
     */
    private func deliverQueuedBlocks(): DrainOutcome {
        var sentBlocks: Int64 = 0
        while (true) {
            var next: ?Array<UInt8> = None
            var cancelled = false
            var generation: Int64 = 0
            var deviceId = ""
            var uuid = ""
            synchronized(this.monitor) {
                cancelled = this.sendCancelled
                if (!cancelled && this.sendQueue.size > 0) {
                    next = Some(this.sendQueue[0])
                }
                generation = this.sendGeneration
                deviceId = this.connectedDeviceId
                uuid = this.serviceUuid
            }
            if (cancelled) {
                return DrainOutcome.Cancelled(sentBlocks)
            }
            let block = match (next) {
                case Some(b) => b
                case None => return DrainOutcome.Drained(sentBlocks)
            }

            var attempt: Int64 = 0
            var delivered = false
            var lastError = ""
            while (!delivered && attempt < this.pacing.maxAttempts) {
                try {
                    this.backend.notify(deviceId, uuid, ServiceCharacteristics.SERVER_2_CLIENT_UUID, block)
                    delivered = true
                } catch (e: BleBackendException) {
                    attempt++
                    lastError = e.message
                    Hilog.error(0, "MdocGattServer", "notify block ${sentBlocks} attempt ${attempt} failed: ${e.message}")
                    if (attempt < this.pacing.maxAttempts && this.pacing.retryBackoff > Duration.Zero) {
                        sleep(this.pacing.retryBackoff * attempt)
                    }
                }
            }
            if (!delivered) {
                return DrainOutcome.Failed(
                    "Server2Client notify failed after ${this.pacing.maxAttempts} attempts (block ${sentBlocks}): ${lastError}"
                )
            }

            synchronized(this.monitor) {
                // Only pop if sendData did not replace the queue meanwhile
                if (this.sendGeneration == generation && this.sendQueue.size > 0) {
                    this.sendQueue.remove(at: 0)
                }
            }
            sentBlocks++
            if (this.pacing.interChunkDelay > Duration.Zero) {
                sleep(this.pacing.interChunkDelay)
            }
        }
        return DrainOutcome.Drained(sentBlocks)
    }

    // -----------------------------------------------------------------------
    // MdocBleTransport — stop (idempotent)
    // -----------------------------------------------------------------------

    public func stop(): Unit {
        this.cancelPendingSend()
        this.stopBleAdvertising()
        var wasOpened = false
        var uuid = ""
        synchronized(this.monitor) {
            wasOpened = this.opened
            uuid = this.serviceUuid
            this.opened = false
            this.radioConfirmed = false
            this.connectedDeviceId = ""
            this.negotiatedMtu = DEFAULT_ATT_MTU
            this.stateSubscribed = false
            this.s2cSubscribed = false
            this.readBuffer = ArrayList<Array<UInt8>>()
        }
        if (wasOpened) {
            this.backend.close(uuid)
            Hilog.info(0, "MdocGattServer", "GATT server closed")
        }
        if (!this.isStatus(TransferStatus.Initialized)) {
            this.setStatus(TransferStatus.Initialized)
        }
    }
}
