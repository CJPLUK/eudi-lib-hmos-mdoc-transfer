/*
 * ISO 18013-5 §8 BLE transfer — value types and enumerations.
 *
 * Source refs:
 *   Sources/MdocDataTransfer18013/Enumerations.swift       (BleTransferMode / TransferStatus / ErrorCode)
 *   Sources/MdocDataTransfer18013/RequestItem.swift        (RequestItem)
 *   Sources/MdocDataTransfer18013/UserRequestInfo.swift    (UserRequestInfo)
 *   Sources/MdocDataTransfer18013/InitializeTransferInfo.swift (InitializeTransferData / InitializeTransferInfo)
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing

// ---------------------------------------------------------------------------
// BleTransferMode — roles and single-byte protocol signals (ISO 18013-5 §8)
// R-102: static constants cannot live inside enum body; extracted to companion.
// ---------------------------------------------------------------------------

/// The two BLE roles defined by ISO 18013-5 §8.
public enum BleTransferMode {
    | Server
    | Client
    | Both
}

/// Single-byte signal constants for the BLE state-machine protocol.
/// START_REQUEST=0x01, END_REQUEST=0x02, START_DATA=0x01, END_DATA=0x00
public class BleTransferModeConst {
    /// 0x01 — mdoc holder sends on State characteristic to signal "ready to receive request"
    public static let START_REQUEST: UInt8 = 0x01
    /// 0x02 — mdoc reader sends on State characteristic to signal "end of session"
    public static let END_REQUEST: UInt8 = 0x02
    /// 0x01 — first byte of every BLE data chunk except the last
    public static let START_DATA: UInt8 = 0x01
    /// 0x00 — first byte of the last BLE data chunk
    public static let END_DATA: UInt8 = 0x00
}

// ---------------------------------------------------------------------------
// TransferStatus — high-level transfer lifecycle states
// ---------------------------------------------------------------------------

/// Transfer status lifecycle, mirroring ISO 18013-5 §8 engagement/transfer phases.
public enum TransferStatus {
    | Initializing
    | Initialized
    | PoweredOn
    | QrEngagementReady
    | Connected
    | Started
    | RequestReceived
    | UserSelected
    | ResponseSent
    | Disconnected
    | Error
}

// ---------------------------------------------------------------------------
// ErrorCode — machine-readable error identifiers
// ---------------------------------------------------------------------------

/// Machine-readable error codes for the BLE transfer layer.
public enum ErrorCode {
    | DocumentsNotProvided
    | InvalidInputDocument
    | InvalidUrl
    | DevicePrivateKeyNotProvided
    | NoDocumentToReturn
    | UserRejected
    | RequestDecodeError
    | BleNotAuthorized
    | BleNotSupported
    | UnexpectedError
    | SessionEncryptionNotInitialized
    | DeviceEngagementMissing
    | ReaderKeyMissing
    | BleInvalidStateLength
    | BleInvalidStateByte
    | BleNoData

    /// Human-readable description matching the Swift source `description` switch.
    public func describe(): String {
        match (this) {
            case DocumentsNotProvided => "DOCUMENTS_NOT_PROVIDED"
            case InvalidInputDocument => "INVALID_INPUT_DOCUMENT"
            case InvalidUrl => "INVALID_URL"
            case DevicePrivateKeyNotProvided => "DEVICE_PRIVATE_KEY_NOT_PROVIDED"
            case NoDocumentToReturn => "NO_DOCUMENT_TO_RETURN"
            case UserRejected => "USER_REJECTED"
            case RequestDecodeError => "REQUEST_DECODE_ERROR"
            case BleNotAuthorized => "BLE_NOT_AUTHORIZED"
            case BleNotSupported => "BLE_NOT_SUPPORTED"
            case UnexpectedError => "GENERIC_ERROR"
            case SessionEncryptionNotInitialized => "SESSION_ENCYPTION_NOT_INITIALIZED"
            case DeviceEngagementMissing => "DEVICE_ENGAGEMENT_MISSING"
            case ReaderKeyMissing => "READER_KEY_MISSING"
            case BleInvalidStateLength => "INVALID_STATE_LENGTH"
            case BleInvalidStateByte => "INVALID_STATE_BYTE"
            case BleNoData => "NO_DATA"
        }
    }
}

// ---------------------------------------------------------------------------
// RequestItem — a single requested data element with optional retention hint
// ---------------------------------------------------------------------------

/// A data-element request item: path components + intent-to-retain + optional flag.
/// Matches Swift RequestItem (elementPath / intentToRetain / isOptional).
public struct RequestItem {
    /// Dot-separated path segments, e.g. ["family_name"] or ["driving_privileges", "0"]
    public let elementPath: Array<String>
    /// Whether the verifier intends to retain the received data element (may be None)
    public let intentToRetain: ?Bool
    /// Whether the element is optional (false / None means required)
    public let isOptional: ?Bool

    public init(elementPath: Array<String>, intentToRetain: ?Bool, isOptional: ?Bool) {
        this.elementPath = elementPath
        this.intentToRetain = intentToRetain
        this.isOptional = isOptional
    }

    /// Convenience: build from dot-joined identifier string, e.g. "family_name".
    public static func fromIdentifier(elementIdentifier: String, intentToRetain: ?Bool, isOptional: ?Bool): RequestItem {
        let parts = elementIdentifier.split(".")
        let pathArr = Array<String>(parts.size, {_ => ""})
        var i: Int64 = 0
        for (p in parts) {
            pathArr[i] = p
            i++
        }
        return RequestItem(pathArr, intentToRetain, isOptional)
    }

    /// The dot-joined string representation of the element path.
    public func elementIdentifier(): String {
        var sb = StringBuilder()
        var first = true
        for (seg in this.elementPath) {
            if (!first) {
                sb.append(".")
            }
            sb.append(seg)
            first = false
        }
        return sb.toString()
    }

    /// Root (first segment) of the element path.
    public func rootIdentifier(): String {
        if (this.elementPath.size > 0) {
            return this.elementPath[0]
        }
        return ""
    }
}

// ---------------------------------------------------------------------------
// UserRequestInfo — aggregate of all per-doctype request data
// ---------------------------------------------------------------------------

/// Aggregates requested items, reader-auth results, and optional supplementary data.
/// Cangjie translation of Swift UserRequestInfo (docDataFormats / itemsRequested /
/// deviceRequestBytes / readerAuthResults).
public struct UserRequestInfo {
    /// Raw CBOR bytes of the DeviceRequest message (may be empty = unset)
    public var deviceRequestBytes: Array<UInt8>
    /// Map: docType → Array<RequestItem> (one entry per requested docType)
    public var itemsRequested: Array<(String, Array<RequestItem>)>
    /// Map: docType → readerAuthValidated (true/false)
    public var readerAuthResults: Array<(String, Bool)>

    public init(
        deviceRequestBytes: Array<UInt8>,
        itemsRequested: Array<(String, Array<RequestItem>)>
    ) {
        this.deviceRequestBytes = deviceRequestBytes
        this.itemsRequested = itemsRequested
        this.readerAuthResults = Array<(String, Bool)>()
    }
}

// ---------------------------------------------------------------------------
// InitializeTransferData / InitializeTransferInfo — transfer initialisation payload
// ---------------------------------------------------------------------------

/// Raw (string-keyed) transfer initialisation data, as received from the application layer.
/// Matches Swift InitializeTransferData fields relevant to the framing/transfer layer.
public struct InitializeTransferData {
    /// doc-id → data format string (e.g. "cbor")
    public let dataFormats: Array<(String, String)>
    /// doc-id → raw document bytes (CBOR-encoded IssuerSigned)
    public let documentData: Array<(String, Array<UInt8>)>
    /// doc-id → document key index
    public let documentKeyIndexes: Array<(String, Int64)>
    /// device auth method string (e.g. "deviceMac" or "deviceSign")
    public let deviceAuthMethod: String
    /// doc-id → doc type string
    public let idsToDocTypes: Array<(String, String)>

    public init(
        dataFormats: Array<(String, String)>,
        documentData: Array<(String, Array<UInt8>)>,
        documentKeyIndexes: Array<(String, Int64)>,
        deviceAuthMethod: String,
        idsToDocTypes: Array<(String, String)>
    ) {
        this.dataFormats = dataFormats
        this.documentData = documentData
        this.documentKeyIndexes = documentKeyIndexes
        this.deviceAuthMethod = deviceAuthMethod
        this.idsToDocTypes = idsToDocTypes
    }
}

/// Resolved transfer initialisation info, after key material has been hydrated.
/// Matches Swift InitializeTransferInfo (resolved DocDataFormat / privateKeyObjects absent —
/// key material lives in mdoc-security layer; this struct carries the transfer-layer view).
public struct InitializeTransferInfo {
    /// doc-id → resolved data format string
    public let dataFormats: Array<(String, String)>
    /// doc-id → raw document bytes
    public let documentObjects: Array<(String, Array<UInt8>)>
    /// device auth method string
    public let deviceAuthMethod: String
    /// doc-id → doc type string
    public let idsToDocTypes: Array<(String, String)>

    public init(
        dataFormats: Array<(String, String)>,
        documentObjects: Array<(String, Array<UInt8>)>,
        deviceAuthMethod: String,
        idsToDocTypes: Array<(String, String)>
    ) {
        this.dataFormats = dataFormats
        this.documentObjects = documentObjects
        this.deviceAuthMethod = deviceAuthMethod
        this.idsToDocTypes = idsToDocTypes
    }
}
