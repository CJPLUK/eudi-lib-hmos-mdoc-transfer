/*
 * index.cj — HAR root package anchor + in-process loopback demo.
 *
 * Purpose:
 *   1. Provides the root package source file required by cjpm so that child
 *      packages (transfer.framing / transfer.orchestration / transfer.ble) are
 *      discovered correctly (S-003: every directory must have at least one .cj).
 *   2. Exposes `runMdocTransferDemo()` — a pure in-process loopback self-check
 *      that exercises the framing layer (chunk / reassemble round-trip), the
 *      BLE layer pure methods (processWrittenBytes / processReceivedNotify) and,
 *      through LoopbackPeripheralBackend, the complete holder-side ISO 18013-5
 *      §8 status sequence, MTU-driven chunking, malformed-block rejection, the
 *      notify retry policy and the radio-off path — all without BLE hardware.
 *
 * Called from entry/src/main/cangjie/index.cj via:
 *   import ohos_app_cangjie_eudi_cjmdoc_transfer.runMdocTransferDemo
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer

import std.collection.ArrayList

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.BleTransferFraming
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.BleTransferModeConst
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ServiceCharacteristics
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.TransferStatus
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ErrorCode
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.MdocGattServer
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.MdocGattClient
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.MdocOfflineDelegate
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.DeviceEngagementInfo
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.LoopbackPeripheralBackend
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.GattPeripheralEvents
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.GattAttributeRequest
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.NotifyPacing
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.WriteOutcome
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.AttStatus
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.BleErrorCodes
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.CCCD_UUID

/**
 * In-process loopback demo for the mDoc-Transfer HAR.
 *
 * Runs the sub-checks below without real BLE hardware and returns a
 * human-readable result string with PASS / FAIL per sub-check.
 * Never throws — all errors are captured in the returned string.
 *
 *  A) Framing round-trip (chunk 1024 B at 511, reassemble, byte-compare).
 *  B) GattServer ↔ GattClient one-round loopback through the pure methods.
 *  C) Holder status sequence PoweredOn → QrEngagementReady → Connected →
 *     Started → RequestReceived → ResponseSent → Disconnected → Initialized
 *     driven through a LoopbackPeripheralBackend.
 *  D) Chunking at ATT MTU 23 / 185 / 247 / 517 (block = min(511, mtu-4)).
 *  E) Malformed Client2Server prefix rejected with ATT unlikelyError.
 *  F) Notify retry: transient failures are retried, then ResponseSent.
 *  G) Notify give-up: persistent failure ends in Error + didFinishedWithError.
 *  H) Radio off: open refused with BLUETOOTH_DISABLED → error, never ready.
 */
public func runMdocTransferDemo(): String {
    var sb = StringBuilder()
    sb.append("=== mDoc-Transfer HAR loopback demo ===\n")

    sb.append("A) Framing round-trip: ${checkFramingRoundTrip()}\n")
    sb.append("B) BLE loopback (pure methods): ${checkBleLoopback()}\n")
    sb.append("C) Holder status sequence: ${checkHolderStatusSequence()}\n")
    sb.append("D) MTU chunking: ${checkMtuChunking()}\n")
    sb.append("E) Malformed prefix rejection: ${checkMalformedPrefixRejected()}\n")
    sb.append("F) Notify retry: ${checkNotifyRetry()}\n")
    sb.append("G) Notify give-up: ${checkNotifyGiveUp()}\n")
    sb.append("H) Radio off: ${checkRadioOff()}\n")

    return sb.toString()
}

// --------------------------------------------------------------------------
// Shared helpers
// --------------------------------------------------------------------------

let DEMO_SERVICE_UUID: String = "0000A0F1-0000-1000-8000-00805F9B34FB"
let DEMO_READER_ID: String = "11:22:33:AA:BB:FF"

func statusLabel(s: TransferStatus): String {
    match (s) {
        case TransferStatus.Initializing => "Initializing"
        case TransferStatus.Initialized => "Initialized"
        case TransferStatus.PoweredOn => "PoweredOn"
        case TransferStatus.QrEngagementReady => "QrEngagementReady"
        case TransferStatus.Connected => "Connected"
        case TransferStatus.Started => "Started"
        case TransferStatus.RequestReceived => "RequestReceived"
        case TransferStatus.UserSelected => "UserSelected"
        case TransferStatus.ResponseSent => "ResponseSent"
        case TransferStatus.Disconnected => "Disconnected"
        case TransferStatus.Error => "Error"
    }
}

/// Delegate that records every callback so the demo can assert on the order.
class DemoDelegate <: MdocOfflineDelegate {
    var poweredOnCalls: Int64 = 0
    var connectedCalls: Int64 = 0
    let statuses: ArrayList<String> = ArrayList<String>()
    var lastReceived: ?Array<UInt8> = None
    var lastErrorCode: ?ErrorCode = None
    var lastErrorMessage: String = ""
    let engagement: ?DeviceEngagementInfo

    init(engagement: ?DeviceEngagementInfo) {
        this.engagement = engagement
    }

    public func didPoweredOn(_: Bool): Unit {
        this.poweredOnCalls += 1
    }

    public func didConnected(_: Bool, _: ?String): Unit {
        this.connectedCalls += 1
    }

    public func didChangeStatus(newStatus: TransferStatus): Unit {
        this.statuses.add(statusLabel(newStatus))
    }

    public func didReceiveRequest(data: Array<UInt8>): Unit {
        this.lastReceived = Some(data)
    }

    public func didFinishedWithError(code: ErrorCode, message: String): Unit {
        this.lastErrorCode = Some(code)
        this.lastErrorMessage = message
    }

    public func deviceEngagement(): ?DeviceEngagementInfo {
        return this.engagement
    }

    func statusTrail(): String {
        var sb = StringBuilder()
        var first = true
        for (s in this.statuses) {
            if (!first) {
                sb.append(",")
            }
            sb.append(s)
            first = false
        }
        return sb.toString()
    }
}

/// Outcome of bringing a loopback holder up to the Started state.
enum RigOutcome {
    | Ready(DemoRig)
    | Failed(String)
}

/// A loopback holder plus the reader-side event sink to drive it.
struct DemoRig {
    let backend: LoopbackPeripheralBackend
    let server: MdocGattServer
    let delegate: DemoDelegate
    let events: GattPeripheralEvents

    init(backend: LoopbackPeripheralBackend, server: MdocGattServer, delegate: DemoDelegate, events: GattPeripheralEvents) {
        this.backend = backend
        this.server = server
        this.delegate = delegate
        this.events = events
    }
}

func cccdRequest(charUuid: String, enable: Bool): GattAttributeRequest {
    let v: Array<UInt8> = if (enable) { [0x01u8, 0x00u8] } else { [0x00u8, 0x00u8] }
    return GattAttributeRequest(DEMO_READER_ID, 1, 0, true, charUuid, Some(CCCD_UUID), v)
}

func charWriteRequest(charUuid: String, value: Array<UInt8>, transId: Int32): GattAttributeRequest {
    return GattAttributeRequest(DEMO_READER_ID, transId, 0, true, charUuid, None, value)
}

/// Advertise, connect, negotiate `mtu`, subscribe both characteristics and
/// send START_REQUEST.  Returns Failed(message) on any deviation.
func bringUpStartedHolder(mtu: Int32): RigOutcome {
    let backend = LoopbackPeripheralBackend()
    let server = MdocGattServer(backend: backend, pacing: NotifyPacing.immediate())
    let delegate = DemoDelegate(Some(DeviceEngagementInfo(DEMO_SERVICE_UUID)))
    server.setDelegate(delegate)

    server.startBleAdvertising()
    let events = match (backend.eventSink()) {
        case Some(e) => e
        case None => return RigOutcome.Failed("backend was not opened by startBleAdvertising")
    }
    if (!backend.isAdvertising()) {
        return RigOutcome.Failed("backend is not advertising after startBleAdvertising")
    }
    if (statusLabel(server.currentStatus()) != "QrEngagementReady") {
        return RigOutcome.Failed("status after advertising is ${statusLabel(server.currentStatus())}, want QrEngagementReady")
    }

    events.onConnectionStateChanged(DEMO_READER_ID, true)
    events.onMtuChanged(mtu)
    events.onWriteRequest(cccdRequest(ServiceCharacteristics.STATE_UUID, true))
    if (statusLabel(server.currentStatus()) != "QrEngagementReady") {
        return RigOutcome.Failed("Connected emitted after a single subscription")
    }
    events.onWriteRequest(cccdRequest(ServiceCharacteristics.SERVER_2_CLIENT_UUID, true))
    if (statusLabel(server.currentStatus()) != "Connected") {
        return RigOutcome.Failed("status after both subscriptions is ${statusLabel(server.currentStatus())}, want Connected")
    }
    events.onWriteRequest(charWriteRequest(ServiceCharacteristics.STATE_UUID, [BleTransferModeConst.START_REQUEST], 2))
    if (statusLabel(server.currentStatus()) != "Started") {
        return RigOutcome.Failed("status after START_REQUEST is ${statusLabel(server.currentStatus())}, want Started")
    }
    return RigOutcome.Ready(DemoRig(backend, server, delegate, events))
}

func reassembleNotified(backend: LoopbackPeripheralBackend): Array<UInt8> {
    let notified = backend.notified()
    let blocks = Array<Array<UInt8>>(notified.size, {i => notified[i].value})
    return BleTransferFraming.reassemble(blocks)
}

func bytesEqual(a: Array<UInt8>, b: Array<UInt8>): Bool {
    if (a.size != b.size) {
        return false
    }
    var i: Int64 = 0
    while (i < a.size) {
        if (a[i] != b[i]) {
            return false
        }
        i++
    }
    return true
}

// --------------------------------------------------------------------------
// Sub-check A: framing round-trip
// --------------------------------------------------------------------------

func checkFramingRoundTrip(): String {
    let payloadSize: Int64 = 1024
    let payload = Array<UInt8>(payloadSize, {i => UInt8(i % 256)})

    let blocks = BleTransferFraming.prepareDataBlocksToSend(payload, 511)
    if (blocks.size == 0) {
        return "FAIL — prepareDataBlocksToSend returned 0 blocks"
    }

    let reassembled = BleTransferFraming.reassemble(blocks)
    if (reassembled.size != payloadSize) {
        return "FAIL — reassembled size ${reassembled.size} != expected ${payloadSize}"
    }

    var i: Int64 = 0
    while (i < payloadSize) {
        if (reassembled[i] != payload[i]) {
            return "FAIL — mismatch at byte ${i}: got ${reassembled[i]}, want ${payload[i]}"
        }
        i++
    }

    return "PASS (payload=${payloadSize}B, blocks=${blocks.size})"
}

// --------------------------------------------------------------------------
// Sub-check B: GattServer <-> GattClient pure-method loopback
// --------------------------------------------------------------------------

func checkBleLoopback(): String {
    let server = MdocGattServer()
    let client = MdocGattClient()

    // ---- Step 1: Client → Server: START_REQUEST on STATE_UUID ----
    let startReq: Array<UInt8> = [0x01u8]
    let startResult = server.processWrittenBytes(
        ServiceCharacteristics.STATE_UUID,
        startReq
    )
    // START_REQUEST returns None (not end of data, just control signal)
    match (startResult) {
        case Some(_) => return "FAIL — START_REQUEST should return None from server"
        case None => ()
    }

    // ---- Step 2: Client → Server: send a 200-byte request in fragments ----
    let requestPayload = Array<UInt8>(200, {i => UInt8((i + 7) % 256)})
    let requestBlocks = BleTransferFraming.prepareDataBlocksToSend(requestPayload, 64)
    if (requestBlocks.size == 0) {
        return "FAIL — request fragmentation produced 0 blocks"
    }

    var serverReassembled: ?Array<UInt8> = None
    var bi: Int64 = 0
    while (bi < requestBlocks.size) {
        let block = requestBlocks[bi]
        let result = server.processWrittenBytes(
            ServiceCharacteristics.CLIENT_2_SERVER_UUID,
            block
        )
        match (result) {
            case Some(payload) => serverReassembled = Some(payload)
            case None => ()
        }
        bi++
    }

    let serverPayload: Array<UInt8> = match (serverReassembled) {
        case Some(p) => p
        case None => return "FAIL — server did not reassemble request after all blocks"
    }

    if (serverPayload.size != requestPayload.size) {
        return "FAIL — server reassembled ${serverPayload.size}B, want ${requestPayload.size}B"
    }

    // ---- Step 3: Server → Client: send a 300-byte response in fragments ----
    let responsePayload = Array<UInt8>(300, {i => UInt8((i + 13) % 256)})
    let responseBlocks = BleTransferFraming.prepareDataBlocksToSend(responsePayload, 64)
    if (responseBlocks.size == 0) {
        return "FAIL — response fragmentation produced 0 blocks"
    }

    var clientReassembled: ?Array<UInt8> = None
    var ri: Int64 = 0
    while (ri < responseBlocks.size) {
        let block = responseBlocks[ri]
        let result = client.processReceivedNotify(
            ServiceCharacteristics.SERVER_2_CLIENT_UUID,
            block
        )
        match (result) {
            case Some(payload) => clientReassembled = Some(payload)
            case None => ()
        }
        ri++
    }

    let clientPayload: Array<UInt8> = match (clientReassembled) {
        case Some(p) => p
        case None => return "FAIL — client did not reassemble response after all blocks"
    }

    if (clientPayload.size != responsePayload.size) {
        return "FAIL — client reassembled ${clientPayload.size}B, want ${responsePayload.size}B"
    }

    var ci: Int64 = 0
    while (ci < responsePayload.size) {
        if (clientPayload[ci] != responsePayload[ci]) {
            return "FAIL — client response mismatch at byte ${ci}"
        }
        ci++
    }

    return "PASS (req=200B blocks=${requestBlocks.size}, resp=300B blocks=${responseBlocks.size})"
}

// --------------------------------------------------------------------------
// Sub-check C: holder status sequence through the loopback backend
// --------------------------------------------------------------------------

func checkHolderStatusSequence(): String {
    let rig = match (bringUpStartedHolder(185)) {
        case RigOutcome.Ready(r) => r
        case RigOutcome.Failed(msg) => return "FAIL — ${msg}"
    }
    if (rig.delegate.poweredOnCalls != 1) {
        return "FAIL — didPoweredOn called ${rig.delegate.poweredOnCalls} times, want 1"
    }
    if (rig.delegate.connectedCalls != 1) {
        return "FAIL — didConnected called ${rig.delegate.connectedCalls} times, want 1"
    }
    if (!rig.server.isBlePoweredOn()) {
        return "FAIL — isBlePoweredOn false after the platform accepted the server"
    }

    // Reader writes a 300-byte request in 64-byte fragments
    let requestPayload = Array<UInt8>(300, {i => UInt8((i + 7) % 256)})
    let requestBlocks = BleTransferFraming.prepareDataBlocksToSend(requestPayload, 64)
    var bi: Int64 = 0
    while (bi < requestBlocks.size) {
        rig.events.onWriteRequest(charWriteRequest(ServiceCharacteristics.CLIENT_2_SERVER_UUID, requestBlocks[bi], Int32(10 + bi)))
        bi++
    }
    if (statusLabel(rig.server.currentStatus()) != "RequestReceived") {
        return "FAIL — status after last request block is ${statusLabel(rig.server.currentStatus())}, want RequestReceived"
    }
    let received = match (rig.delegate.lastReceived) {
        case Some(r) => r
        case None => return "FAIL — didReceiveRequest was not called"
    }
    if (!bytesEqual(received, requestPayload)) {
        return "FAIL — didReceiveRequest payload differs from the written request"
    }

    // Holder answers with a 600-byte response
    let responsePayload = Array<UInt8>(600, {i => UInt8((i + 13) % 256)})
    rig.server.sendData(responsePayload)
    if (!rig.server.awaitSendCompletion(Duration.second * 5)) {
        return "FAIL — send queue did not drain within 5 s"
    }
    if (statusLabel(rig.server.currentStatus()) != "ResponseSent") {
        return "FAIL — status after drain is ${statusLabel(rig.server.currentStatus())}, want ResponseSent"
    }
    let expectedBlock = MdocGattServer.blockSizeFor(185)
    let notified = rig.backend.notified()
    var ni: Int64 = 0
    while (ni < notified.size) {
        if (notified[ni].value.size > expectedBlock + 1) {
            return "FAIL — notification ${ni} is ${notified[ni].value.size}B, exceeds block ${expectedBlock}+1"
        }
        if (notified[ni].deviceId != DEMO_READER_ID) {
            return "FAIL — notification ${ni} targeted ${notified[ni].deviceId}"
        }
        ni++
    }
    if (!bytesEqual(reassembleNotified(rig.backend), responsePayload)) {
        return "FAIL — notified blocks do not reassemble to the response"
    }

    // Reader ends the session with END_REQUEST, then the kit stops the transport
    rig.events.onWriteRequest(charWriteRequest(ServiceCharacteristics.STATE_UUID, [BleTransferModeConst.END_REQUEST], 99))
    if (statusLabel(rig.server.currentStatus()) != "Disconnected") {
        return "FAIL — status after END_REQUEST is ${statusLabel(rig.server.currentStatus())}, want Disconnected"
    }
    rig.server.stop()
    rig.server.stop()
    if (statusLabel(rig.server.currentStatus()) != "Initialized") {
        return "FAIL — status after stop is ${statusLabel(rig.server.currentStatus())}, want Initialized"
    }
    if (rig.backend.isOpen() || rig.backend.isAdvertising()) {
        return "FAIL — backend still open/advertising after stop"
    }
    if (rig.server.isBlePoweredOn()) {
        return "FAIL — isBlePoweredOn still true after stop"
    }

    let trail = rig.delegate.statusTrail()
    let want = "PoweredOn,QrEngagementReady,Connected,Started,RequestReceived,ResponseSent,Disconnected,Initialized"
    if (trail != want) {
        return "FAIL — status trail ${trail}, want ${want}"
    }
    return "PASS (${trail}; ${notified.size} notify blocks)"
}

// --------------------------------------------------------------------------
// Sub-check D: chunking follows the negotiated MTU
// --------------------------------------------------------------------------

func checkMtuChunking(): String {
    let mtus: Array<Int32> = [23, 185, 247, 517]
    let wantBlock: Array<Int64> = [19, 181, 243, 511]
    let payload = Array<UInt8>(1000, {i => UInt8((i * 7 + 3) % 256)})
    var summary = StringBuilder()
    var k: Int64 = 0
    while (k < mtus.size) {
        let mtu = mtus[k]
        let expectedBlock = wantBlock[k]
        if (MdocGattServer.blockSizeFor(mtu) != expectedBlock) {
            return "FAIL — blockSizeFor(${mtu}) = ${MdocGattServer.blockSizeFor(mtu)}, want ${expectedBlock}"
        }
        let rig = match (bringUpStartedHolder(mtu)) {
            case RigOutcome.Ready(r) => r
            case RigOutcome.Failed(msg) => return "FAIL — mtu ${mtu}: ${msg}"
        }
        if (rig.server.currentBlockSize() != expectedBlock) {
            return "FAIL — mtu ${mtu}: currentBlockSize ${rig.server.currentBlockSize()}, want ${expectedBlock}"
        }
        rig.server.sendData(payload)
        if (!rig.server.awaitSendCompletion(Duration.second * 5)) {
            return "FAIL — mtu ${mtu}: send queue did not drain"
        }
        let notified = rig.backend.notified()
        let wantBlocks = BleTransferFraming.countNumBlocks(payload.size, expectedBlock)
        if (notified.size != wantBlocks) {
            return "FAIL — mtu ${mtu}: ${notified.size} notifications, want ${wantBlocks}"
        }
        var maxLen: Int64 = 0
        var ni: Int64 = 0
        while (ni < notified.size) {
            let len = notified[ni].value.size
            if (len > maxLen) {
                maxLen = len
            }
            let prefix = notified[ni].value[0]
            let wantPrefix = if (ni == notified.size - 1) { BleTransferModeConst.END_DATA } else { BleTransferModeConst.START_DATA }
            if (prefix != wantPrefix) {
                return "FAIL — mtu ${mtu}: block ${ni} prefix ${prefix}, want ${wantPrefix}"
            }
            ni++
        }
        if (maxLen != expectedBlock + 1) {
            return "FAIL — mtu ${mtu}: largest notification ${maxLen}B, want ${expectedBlock + 1}B"
        }
        if (!bytesEqual(reassembleNotified(rig.backend), payload)) {
            return "FAIL — mtu ${mtu}: reassembled response differs"
        }
        rig.server.stop()
        if (k > 0) {
            summary.append(" ")
        }
        summary.append("mtu${mtu}→${expectedBlock}B×${notified.size}")
        k++
    }
    return "PASS (${summary.toString()})"
}

// --------------------------------------------------------------------------
// Sub-check E: malformed Client2Server prefix is rejected
// --------------------------------------------------------------------------

func checkMalformedPrefixRejected(): String {
    let rig = match (bringUpStartedHolder(247)) {
        case RigOutcome.Ready(r) => r
        case RigOutcome.Failed(msg) => return "FAIL — ${msg}"
    }
    // Pure seam: bad prefix → Rejected(UNLIKELY_ERROR), buffer untouched
    let bad: Array<UInt8> = [0x07u8, 0xAAu8, 0xBBu8]
    match (rig.server.handleCharacteristicWrite(ServiceCharacteristics.CLIENT_2_SERVER_UUID, bad)) {
        case WriteOutcome.Rejected(att) =>
            if (att != AttStatus.UNLIKELY_ERROR) {
                return "FAIL — malformed prefix rejected with ATT ${att}, want ${AttStatus.UNLIKELY_ERROR}"
            }
        case _ => return "FAIL — malformed prefix was not rejected"
    }
    if (statusLabel(rig.server.currentStatus()) != "Started") {
        return "FAIL — status changed to ${statusLabel(rig.server.currentStatus())} on a rejected block"
    }
    // Hardware path: the ATT response carries the error status
    rig.events.onWriteRequest(charWriteRequest(ServiceCharacteristics.CLIENT_2_SERVER_UUID, bad, 42))
    let responses = rig.backend.responded()
    if (responses.size == 0) {
        return "FAIL — no ATT response was sent for the rejected block"
    }
    let last = responses[responses.size - 1]
    if (last.transId != 42 || last.status != AttStatus.UNLIKELY_ERROR) {
        return "FAIL — ATT response transId ${last.transId} status ${last.status}, want 42/${AttStatus.UNLIKELY_ERROR}"
    }
    // A well-formed request afterwards reassembles only its own bytes
    let good: Array<UInt8> = [BleTransferModeConst.END_DATA, 0x01u8, 0x02u8]
    let payload = match (rig.server.processWrittenBytes(ServiceCharacteristics.CLIENT_2_SERVER_UUID, good)) {
        case Some(p) => p
        case None => return "FAIL — valid END block after rejection did not complete a request"
    }
    if (payload.size != 2 || payload[0] != 0x01u8 || payload[1] != 0x02u8) {
        return "FAIL — rejected block leaked into the read buffer (got ${payload.size}B)"
    }
    // Writes to an unknown characteristic are answered requestNotSupported
    match (rig.server.handleCharacteristicWrite("00000099-FFFF-FFFF-FFFF-FFFFFFFFFFFF", good)) {
        case WriteOutcome.Rejected(att) =>
            if (att != AttStatus.REQUEST_NOT_SUPPORTED) {
                return "FAIL — unknown characteristic rejected with ATT ${att}"
            }
        case _ => return "FAIL — write to unknown characteristic was accepted"
    }
    rig.server.stop()
    return "PASS (unlikelyError=0x0E, requestNotSupported=0x06)"
}

// --------------------------------------------------------------------------
// Sub-check F: transient notify failures are retried
// --------------------------------------------------------------------------

func checkNotifyRetry(): String {
    let rig = match (bringUpStartedHolder(517)) {
        case RigOutcome.Ready(r) => r
        case RigOutcome.Failed(msg) => return "FAIL — ${msg}"
    }
    rig.backend.failNextNotifies(2)
    let payload = Array<UInt8>(50, {i => UInt8(i % 256)})
    rig.server.sendData(payload)
    if (!rig.server.awaitSendCompletion(Duration.second * 5)) {
        return "FAIL — send queue did not drain"
    }
    if (statusLabel(rig.server.currentStatus()) != "ResponseSent") {
        return "FAIL — status ${statusLabel(rig.server.currentStatus())} after retried send, want ResponseSent"
    }
    if (rig.backend.notifyAttemptCount() != 3) {
        return "FAIL — ${rig.backend.notifyAttemptCount()} notify attempts, want 3 (2 failures + 1 success)"
    }
    let notified = rig.backend.notified()
    if (notified.size != 1) {
        return "FAIL — ${notified.size} notifications delivered, want 1"
    }
    if (!bytesEqual(reassembleNotified(rig.backend), payload)) {
        return "FAIL — delivered block differs from the payload"
    }
    rig.server.stop()
    return "PASS (attempts=3, delivered=1)"
}

// --------------------------------------------------------------------------
// Sub-check G: persistent notify failure ends in Error
// --------------------------------------------------------------------------

func checkNotifyGiveUp(): String {
    let rig = match (bringUpStartedHolder(517)) {
        case RigOutcome.Ready(r) => r
        case RigOutcome.Failed(msg) => return "FAIL — ${msg}"
    }
    rig.backend.failNextNotifies(100)
    rig.server.sendData(Array<UInt8>(50, {i => UInt8(i % 256)}))
    if (!rig.server.awaitSendCompletion(Duration.second * 5)) {
        return "FAIL — send did not settle"
    }
    if (statusLabel(rig.server.currentStatus()) != "Error") {
        return "FAIL — status ${statusLabel(rig.server.currentStatus())} after give-up, want Error"
    }
    let code = match (rig.delegate.lastErrorCode) {
        case Some(c) => c
        case None => return "FAIL — didFinishedWithError was not called"
    }
    if (code.describe() != ErrorCode.UnexpectedError.describe()) {
        return "FAIL — error code ${code.describe()}, want ${ErrorCode.UnexpectedError.describe()}"
    }
    if (rig.backend.notifyAttemptCount() != 5) {
        return "FAIL — ${rig.backend.notifyAttemptCount()} notify attempts before give-up, want 5"
    }
    if (rig.backend.notified().size != 0) {
        return "FAIL — blocks were delivered despite persistent failure"
    }
    rig.server.stop()
    return "PASS (attempts=5, error=${code.describe()})"
}

// --------------------------------------------------------------------------
// Sub-check H: radio off is reported before any engagement
// --------------------------------------------------------------------------

func checkRadioOff(): String {
    let backend = LoopbackPeripheralBackend()
    backend.refuseOpen(BleErrorCodes.BLUETOOTH_DISABLED)
    let server = MdocGattServer(backend: backend, pacing: NotifyPacing.immediate())
    let delegate = DemoDelegate(Some(DeviceEngagementInfo(DEMO_SERVICE_UUID)))
    server.setDelegate(delegate)
    server.startBleAdvertising()

    if (statusLabel(server.currentStatus()) != "Error") {
        return "FAIL — status ${statusLabel(server.currentStatus())} with the radio off, want Error"
    }
    let code = match (delegate.lastErrorCode) {
        case Some(c) => c
        case None => return "FAIL — didFinishedWithError was not called"
    }
    if (code.describe() != ErrorCode.BleNotSupported.describe()) {
        return "FAIL — error code ${code.describe()}, want BLE_NOT_SUPPORTED"
    }
    if (!delegate.lastErrorMessage.contains("Bluetooth is off")) {
        return "FAIL — error message '${delegate.lastErrorMessage}' does not say Bluetooth is off"
    }
    if (delegate.poweredOnCalls != 0) {
        return "FAIL — didPoweredOn called with the radio off"
    }
    if (delegate.statusTrail().contains("QrEngagementReady") || delegate.statusTrail().contains("PoweredOn")) {
        return "FAIL — engagement statuses emitted with the radio off: ${delegate.statusTrail()}"
    }
    if (server.isBlePoweredOn() || backend.isAdvertising()) {
        return "FAIL — transport claims powered on / advertising with the radio off"
    }
    return "PASS (trail=${delegate.statusTrail()})"
}
