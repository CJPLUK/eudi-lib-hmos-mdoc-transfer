/*
 * orchestration_test.cj — offline unit tests for the orchestration / value /
 * delegate layers of mdoc-transfer that do NOT require real BLE hardware.
 *
 * Coverage added by this suite:
 *   - OrchestratorError            (construct + code/message accessors)
 *   - ReaderAuthResult             (init + success/failure constructors + fields)
 *   - DeviceEngagementInfo         (construct + bleServiceUuid field)
 *   - ErrorCode.describe           (all 16 enum cases)
 *   - MdocOfflineDelegate          (concrete impl + deviceEngagement())
 *   - getDelegate / setDelegate    (GattServer & GattClient)
 *   - currentStatus                (GattServer & GattClient initial state)
 *
 * Symbols requiring real Bluetooth peripherals (advertising / scanning / GATT
 * read-write notify) are intentionally NOT exercised here — see the report.
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.TransferStatus
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ErrorCode
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.orchestration.OrchestratorError
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.orchestration.ReaderAuthResult
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.orchestration.ReaderCertTrust
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.orchestration.ReaderValidation
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.DeviceEngagementInfo
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.MdocOfflineDelegate
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.MdocGattServer
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble.MdocGattClient

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Maps a TransferStatus to a stable string so it can be compared with @Expect
/// (the enum has no derived equality).
func statusName(s: TransferStatus): String {
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

/// Minimal concrete MdocOfflineDelegate used to exercise get/setDelegate and the
/// delegate interface itself. Records the last callbacks it received.
class RecordingDelegate <: MdocOfflineDelegate {
    var poweredOnCalls: Int64 = 0
    var lastStatus: ?TransferStatus = None
    var lastErrorCode: ?ErrorCode = None
    var lastReceived: ?Array<UInt8> = None
    var connectedCalls: Int64 = 0
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
        this.lastStatus = Some(newStatus)
    }

    public func didReceiveRequest(data: Array<UInt8>): Unit {
        this.lastReceived = Some(data)
    }

    public func didFinishedWithError(code: ErrorCode, _: String): Unit {
        this.lastErrorCode = Some(code)
    }

    public func deviceEngagement(): ?DeviceEngagementInfo {
        return this.engagement
    }
}

// ============================================================================
// Test class 8: OrchestratorError
// ============================================================================

@Test
class OrchestratorErrorE2EUT {

    @TestCase
    func construct_codeAndMessage(): Unit {
        let err = OrchestratorError("REQUEST_DECODE_ERROR", "bad cbor")
        @Expect(err.code, "REQUEST_DECODE_ERROR")
        @Expect(err.message, "bad cbor")
    }

    @TestCase
    func construct_emptyMessage(): Unit {
        let err = OrchestratorError("GENERIC", "")
        @Expect(err.code, "GENERIC")
        @Expect(err.message, "")
    }

    @TestCase
    func isCatchableAsException(): Unit {
        var caughtCode = ""
        var caughtMsg = ""
        try {
            throw OrchestratorError("DECRYPT_FAIL", "tag mismatch")
        } catch (e: OrchestratorError) {
            caughtCode = e.code
            caughtMsg = e.message
        }
        @Expect(caughtCode, "DECRYPT_FAIL")
        @Expect(caughtMsg, "tag mismatch")
    }

    @TestCase
    func isCatchableAsBaseException(): Unit {
        var caught = false
        try {
            throw OrchestratorError("X", "y")
        } catch (e: Exception) {
            caught = true
        }
        @Expect(caught, true)
    }
}

// ============================================================================
// Test class 9: ReaderAuthResult
// ============================================================================

@Test
class ReaderAuthResultE2EUT {

    @TestCase
    func init_allFields(): Unit {
        let r = ReaderAuthResult(true, Some("CN=Reader"), "ok")
        @Expect(r.isValidated, true)
        @Expect(r.certificateIssuer, Some("CN=Reader"))
        @Expect(r.validationMessage, "ok")
    }

    @TestCase
    func success_setsValidatedTrueAndEmptyMessage(): Unit {
        let r = ReaderAuthResult.success(Some("ACME Reader CA"))
        @Expect(r.isValidated, true)
        @Expect(r.certificateIssuer, Some("ACME Reader CA"))
        @Expect(r.validationMessage, "")
    }

    @TestCase
    func success_withNoneIssuer(): Unit {
        let r = ReaderAuthResult.success(None)
        @Expect(r.isValidated, true)
        @Expect(r.certificateIssuer.isNone(), true)
        @Expect(r.validationMessage, "")
    }

    @TestCase
    func failure_setsValidatedFalseAndNoneIssuer(): Unit {
        let r = ReaderAuthResult.failure("Reader authentication not present in request")
        @Expect(r.isValidated, false)
        @Expect(r.certificateIssuer.isNone(), true)
        @Expect(r.validationMessage, "Reader authentication not present in request")
    }
}

// ============================================================================
// Test class 10: DeviceEngagementInfo
// ============================================================================

@Test
class DeviceEngagementInfoE2EUT {

    @TestCase
    func construct_storesServiceUuid(): Unit {
        let info = DeviceEngagementInfo("00000000-0000-0000-0000-000000000001")
        @Expect(info.bleServiceUuid, "00000000-0000-0000-0000-000000000001")
    }

    @TestCase
    func construct_emptyUuidPreserved(): Unit {
        let info = DeviceEngagementInfo("")
        @Expect(info.bleServiceUuid, "")
    }
}

// ============================================================================
// Test class 11: ErrorCode.describe — all 16 cases
// ============================================================================

@Test
class ErrorCodeDescribeE2EUT {

    @TestCase
    func documentsNotProvided(): Unit {
        @Expect(ErrorCode.DocumentsNotProvided.describe(), "DOCUMENTS_NOT_PROVIDED")
    }

    @TestCase
    func invalidInputDocument(): Unit {
        @Expect(ErrorCode.InvalidInputDocument.describe(), "INVALID_INPUT_DOCUMENT")
    }

    @TestCase
    func invalidUrl(): Unit {
        @Expect(ErrorCode.InvalidUrl.describe(), "INVALID_URL")
    }

    @TestCase
    func devicePrivateKeyNotProvided(): Unit {
        @Expect(ErrorCode.DevicePrivateKeyNotProvided.describe(), "DEVICE_PRIVATE_KEY_NOT_PROVIDED")
    }

    @TestCase
    func noDocumentToReturn(): Unit {
        @Expect(ErrorCode.NoDocumentToReturn.describe(), "NO_DOCUMENT_TO_RETURN")
    }

    @TestCase
    func userRejected(): Unit {
        @Expect(ErrorCode.UserRejected.describe(), "USER_REJECTED")
    }

    @TestCase
    func requestDecodeError(): Unit {
        @Expect(ErrorCode.RequestDecodeError.describe(), "REQUEST_DECODE_ERROR")
    }

    @TestCase
    func bleNotAuthorized(): Unit {
        @Expect(ErrorCode.BleNotAuthorized.describe(), "BLE_NOT_AUTHORIZED")
    }

    @TestCase
    func bleNotSupported(): Unit {
        @Expect(ErrorCode.BleNotSupported.describe(), "BLE_NOT_SUPPORTED")
    }

    @TestCase
    func unexpectedError(): Unit {
        @Expect(ErrorCode.UnexpectedError.describe(), "GENERIC_ERROR")
    }

    @TestCase
    func sessionEncryptionNotInitialized(): Unit {
        @Expect(ErrorCode.SessionEncryptionNotInitialized.describe(), "SESSION_ENCYPTION_NOT_INITIALIZED")
    }

    @TestCase
    func deviceEngagementMissing(): Unit {
        @Expect(ErrorCode.DeviceEngagementMissing.describe(), "DEVICE_ENGAGEMENT_MISSING")
    }

    @TestCase
    func readerKeyMissing(): Unit {
        @Expect(ErrorCode.ReaderKeyMissing.describe(), "READER_KEY_MISSING")
    }

    @TestCase
    func bleInvalidStateLength(): Unit {
        @Expect(ErrorCode.BleInvalidStateLength.describe(), "INVALID_STATE_LENGTH")
    }

    @TestCase
    func bleInvalidStateByte(): Unit {
        @Expect(ErrorCode.BleInvalidStateByte.describe(), "INVALID_STATE_BYTE")
    }

    @TestCase
    func bleNoData(): Unit {
        @Expect(ErrorCode.BleNoData.describe(), "NO_DATA")
    }
}

// ============================================================================
// Test class 12: Delegate wiring + currentStatus (GattServer & GattClient)
// ============================================================================

@Test
class DelegateAndStatusE2EUT {

    @TestCase
    func server_currentStatus_initialIsInitialized(): Unit {
        let server = MdocGattServer()
        @Expect(statusName(server.currentStatus()), "Initialized")
    }

    @TestCase
    func client_currentStatus_initialIsInitializing(): Unit {
        let client = MdocGattClient()
        @Expect(statusName(client.currentStatus()), "Initializing")
    }

    @TestCase
    func server_getDelegate_noneBeforeSet(): Unit {
        let server = MdocGattServer()
        @Expect(server.getDelegate().isNone(), true)
    }

    @TestCase
    func client_getDelegate_noneBeforeSet(): Unit {
        let client = MdocGattClient()
        @Expect(client.getDelegate().isNone(), true)
    }

    @TestCase
    func server_setDelegate_thenGetDelegateSome(): Unit {
        let server = MdocGattServer()
        let del = RecordingDelegate(Some(DeviceEngagementInfo("svc-uuid-1")))
        server.setDelegate(del)
        @Expect(server.getDelegate().isSome(), true)
    }

    @TestCase
    func client_setDelegate_thenGetDelegateSome(): Unit {
        let client = MdocGattClient()
        let del = RecordingDelegate(None)
        client.setDelegate(del)
        @Expect(client.getDelegate().isSome(), true)
    }

    @TestCase
    func server_setDelegate_engagementReadableThroughDelegate(): Unit {
        let server = MdocGattServer()
        let del = RecordingDelegate(Some(DeviceEngagementInfo("00000000-0000-0000-0000-0000000000AB")))
        server.setDelegate(del)
        let got = server.getDelegate()
        match (got) {
            case Some(d) =>
                let eng = d.deviceEngagement()
                match (eng) {
                    case Some(e) => @Expect(e.bleServiceUuid, "00000000-0000-0000-0000-0000000000AB")
                    case None => @Expect(false, true)
                }
            case None => @Expect(false, true)
        }
    }
}

// ============================================================================
// Test class 13: MdocOfflineDelegate concrete-impl callback semantics
// ============================================================================

@Test
class OfflineDelegateImplE2EUT {

    @TestCase
    func deviceEngagement_returnsConfiguredInfo(): Unit {
        let del = RecordingDelegate(Some(DeviceEngagementInfo("svc-9")))
        let eng = del.deviceEngagement()
        match (eng) {
            case Some(e) => @Expect(e.bleServiceUuid, "svc-9")
            case None => @Expect(false, true)
        }
    }

    @TestCase
    func deviceEngagement_noneWhenUnset(): Unit {
        let del = RecordingDelegate(None)
        @Expect(del.deviceEngagement().isNone(), true)
    }

    @TestCase
    func callbacks_recordState(): Unit {
        let del = RecordingDelegate(None)
        del.didPoweredOn(true)
        del.didConnected(true, Some("reader"))
        del.didChangeStatus(TransferStatus.Connected)
        let payload: Array<UInt8> = [0x83u8, 0x01u8]
        del.didReceiveRequest(payload)
        del.didFinishedWithError(ErrorCode.BleNoData, "no data")

        @Expect(del.poweredOnCalls, 1)
        @Expect(del.connectedCalls, 1)
        match (del.lastStatus) {
            case Some(s) => @Expect(statusName(s), "Connected")
            case None => @Expect(false, true)
        }
        match (del.lastReceived) {
            case Some(d) => @Expect(d.size, 2)
            case None => @Expect(false, true)
        }
        match (del.lastErrorCode) {
            case Some(c) => @Expect(c.describe(), "NO_DATA")
            case None => @Expect(false, true)
        }
    }
}

class AcceptAllReaderTrust <: ReaderCertTrust {
    public func validateCertTrustPath(chain: Array<Array<UInt8>>): (Bool, ?String) {
        (chain.size > 0, None)
    }
}

class RejectAllReaderTrust <: ReaderCertTrust {
    public func validateCertTrustPath(_chain: Array<Array<UInt8>>): (Bool, ?String) {
        (false, Some("untrusted test reader"))
    }
}

@Test
class ReaderLiveTrustTests {
    @TestCase
    func liveTrustAcceptsNonEmptyChain(): Unit {
        let trust = AcceptAllReaderTrust()
        let result = ReaderValidation.validateChain([[0x30u8]], Some("CN=Reader"), trust)
        @Expect(result.isValidated, true)
    }

    @TestCase
    func liveTrustRejectsWhenManagerSaysNo(): Unit {
        let trust = RejectAllReaderTrust()
        let result = ReaderValidation.validateChain([[0x30u8]], None, trust)
        @Expect(result.isValidated, false)
        @Expect(result.validationMessage, "untrusted test reader")
    }

    @TestCase
    func liveTrustRejectsEmptyChain(): Unit {
        let trust = AcceptAllReaderTrust()
        let empty = Array<Array<UInt8>>()
        let result = ReaderValidation.validateChain(empty, None, trust)
        @Expect(result.isValidated, false)
    }
}
