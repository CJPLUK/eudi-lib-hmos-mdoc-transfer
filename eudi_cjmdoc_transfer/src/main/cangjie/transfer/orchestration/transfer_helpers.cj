/*
 * transfer_helpers.cj — ISO 18013-5 §8 BLE transfer orchestration layer.
 *
 * Implements MdocHelpers with three main orchestration functions:
 *   - getSessionDataToSend:      DeviceResponse → encrypted SessionData CBOR bytes
 *   - decodeRequestAndInformUser: encrypted request → decoded DeviceRequest + UserRequestInfo
 *   - getDeviceResponseToSend:   IssuerSigned + selected items → filtered DeviceResponse
 *
 * Consumes upstream delivered packages:
 *   - mdoc-security:    SessionEncryption / SessionEstablishment / MdocReaderAuthentication
 *   - mdoc-data-model:  DeviceRequest / DeviceResponse / ItemsRequest / IssuerSigned / Document / ...
 *
 * Source ref:
 *   Sources/MdocDataTransfer18013/MdocHelpers.swift
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.orchestration

import std.collection.ArrayList
import std.collection.HashMap

import ohos_app_cangjie_eudi_cjmdoc_security.security.session.SessionEncryption
import ohos_app_cangjie_eudi_cjmdoc_security.security.session.SessionEstablishment
import ohos_app_cangjie_eudi_cjmdoc_security.security.session.SessionData

import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.request.DeviceRequest
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.request.ItemsRequest
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.request.DocRequest
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.request.RequestDataElements
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.request.RequestNameSpaces
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.DeviceResponse
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.IssuerSigned
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.IssuerNameSpaces
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.IssuerSignedItem
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.Document
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.DocumentError
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.DeviceSigned
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.response.DeviceAuth
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.core.MdocValidationError

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.TransferStatus
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.RequestItem
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.UserRequestInfo

import ohos_app_cangjie_eudi_cjcbor.cbor.CborValue
import ohos_app_cangjie_eudi_cjcbor.cbor.CborTag

/* ------------------------------------------------------------------ */
/* OrchestratorError — structured error type for this layer            */
/* ------------------------------------------------------------------ */

/**
 * Error type for the orchestration layer.
 * Subtype of Exception so callers can catch generically.
 */
public class OrchestratorError <: Exception {
    public let code: String

    public init(code: String, message: String) {
        super(message)
        this.code = code
    }
}

/* ------------------------------------------------------------------ */
/* DecodeRequestResult — output of decodeRequestAndInformUser           */
/* ------------------------------------------------------------------ */

/**
 * Result returned by MdocHelpers.decodeRequestAndInformUser.
 *
 * Bundles the decoded structures needed by the BLE transport layer to:
 *   1. Present the user with requested data elements (userRequestInfo).
 *   2. Build and encrypt the device response (sessionEncryption + deviceRequest).
 */
public struct DecodeRequestResult {
    /** Active session encryption object (initialised from SessionEstablishment). */
    public let sessionEncryption: SessionEncryption
    /** Decoded DeviceRequest from the reader. */
    public let deviceRequest: DeviceRequest
    /** Aggregated per-doctype request items + reader auth results. */
    public let userRequestInfo: UserRequestInfo
    /** False if the preview device response has no documents (all doc-types unknown). */
    public let isValidRequest: Bool

    public init(
        sessionEncryption: SessionEncryption,
        deviceRequest: DeviceRequest,
        userRequestInfo: UserRequestInfo,
        isValidRequest: Bool
    ) {
        this.sessionEncryption = sessionEncryption
        this.deviceRequest = deviceRequest
        this.userRequestInfo = userRequestInfo
        this.isValidRequest = isValidRequest
    }
}

/* ------------------------------------------------------------------ */
/* MdocHelpers — three main orchestration functions                     */
/* ------------------------------------------------------------------ */

/**
 * Static helper class implementing the ISO 18013-5 §8 BLE transfer
 * orchestration flow.  Mirrors iOS MdocHelpers.
 */
public class MdocHelpers {

    // ----------------------------------------------------------------
    // getSessionDataToSend
    // ----------------------------------------------------------------

    /**
     * Encode and encrypt a DeviceResponse for transmission to the reader.
     *
     * Flow:
     *   1. Encode DeviceResponse to CBOR bytes via toCbor().encode().
     *   2. Encrypt with SessionEncryption.encrypt().
     *   3. Choose status code: error → 11, normal → 20 (per iOS source).
     *      For error status: cipher data is None; for normal: cipher data = Some(encrypted).
     *   4. Encode SessionData to CBOR and return the bytes.
     *
     * Done-when: "把 DeviceResponse(CBOR)经 SessionEncryption 加密封装成
     * SessionData(status 可选), CBOR 往返无损"
     *
     * @param sessionEncryption  Active session encryption object.
     * @param status             Current transfer status (Error → no data in SessionData).
     * @param docToSend          Device response to send.
     * @return CBOR-encoded bytes of the encrypted SessionData.
     * @throws OrchestratorError if encryption fails.
     */
    public static func getSessionDataToSend(
        sessionEncryption: SessionEncryption,
        status: TransferStatus,
        docToSend: DeviceResponse
    ): Array<UInt8> {
        let isError = match (status) {
            case TransferStatus.Error => true
            case _ => false
        }

        // Step 1: CBOR-encode the DeviceResponse
        let clearBytes: Array<UInt8> = docToSend.toCbor().encode()

        // Step 2 + 3: Encrypt and wrap in SessionData
        let sessionData: SessionData
        if (isError) {
            // Error path: data=None, status=Some(11)
            sessionData = SessionData(None, Some(UInt64(11)))
        } else {
            // Normal path: encrypt first, then wrap
            let cipherData = sessionEncryption.encrypt(clearBytes)
            sessionData = SessionData(Some(cipherData), Some(UInt64(20)))
        }

        // Step 4: Encode SessionData to CBOR bytes
        return sessionData.toCborBytes()
    }

    // ----------------------------------------------------------------
    // decodeRequestAndInformUser
    // ----------------------------------------------------------------

    /**
     * Decrypt and decode a SessionEstablishment/DeviceRequest message from the reader.
     *
     * Flow:
     *   1. Decode raw bytes as SessionEstablishment CBOR.
     *   2. Construct SessionEncryption.forMdoc using the eReader public key and
     *      the device's private key material (via eReaderKeyRawData / devicePrivateKey).
     *   3. Decrypt the SessionEstablishment.data ciphertext.
     *   4. Decode DeviceRequest from the plaintext bytes.
     *   5. For each DocRequest, extract ItemsRequest → RequestItem list.
     *   6. For each DocRequest that has readerAuth, validate with ReaderValidation.
     *   7. Build UserRequestInfo and DecodeRequestResult.
     *
     * Done-when: "解 SessionEstablishment/DeviceRequest(CBOR) → ItemsRequest →
     * RequestItem 列表 + UserRequestInfo; docType/namespace/elementIdentifier 提取正确"
     *
     * @param requestData        Raw bytes received from the reader over BLE.
     * @param sessionEncryption  Pre-initialised SessionEncryption from the engagement phase.
     * @param rootIacaDer        Trusted root IACA DER certificate bytes for reader auth.
     * @param readerCertTrust    When set, reader x5c is checked with this live
     *                           validator (iOS `accessTrustManager`).
     * @return DecodeRequestResult.
     * @throws OrchestratorError on CBOR decode or decryption failure.
     */
    public static func decodeRequestAndInformUser(
        requestData: Array<UInt8>,
        sessionEncryption: SessionEncryption,
        rootIacaDer: Array<Array<UInt8>>,
        readerCertTrust!: ?ReaderCertTrust = None
    ): DecodeRequestResult {
        // Step 1: Decode SessionEstablishment
        let se: SessionEstablishment
        try {
            se = SessionEstablishment.fromCborBytes(requestData)
        } catch (e: MdocValidationError) {
            throw OrchestratorError("REQUEST_DECODE_ERROR", "Failed to decode SessionEstablishment: ${e.message}")
        } catch (e: Exception) {
            throw OrchestratorError("REQUEST_DECODE_ERROR", "Failed to decode SessionEstablishment: ${e.message}")
        }

        // Step 2: Decrypt the ciphertext (SE.data)
        let cipherData = se.data
        let plaintextOpt = sessionEncryption.decrypt(cipherData)
        let plaintext: Array<UInt8> = match (plaintextOpt) {
            case Some(pt) => pt
            case None =>
                throw OrchestratorError("REQUEST_DECODE_ERROR", "Failed to decrypt device request: authentication tag mismatch")
        }

        // Step 3: Decode DeviceRequest
        let deviceRequest: DeviceRequest
        try {
            deviceRequest = DeviceRequest.fromBytes(plaintext)
        } catch (e: MdocValidationError) {
            throw OrchestratorError("REQUEST_DECODE_ERROR", "Failed to decode DeviceRequest: ${e.message}")
        } catch (e: Exception) {
            throw OrchestratorError("REQUEST_DECODE_ERROR", "Failed to decode DeviceRequest: ${e.message}")
        }

        // Step 4: Extract per-doctype requested items
        let itemsRequestedList = ArrayList<(String, Array<RequestItem>)>()
        var hasAnyItems = false

        for (docReq in deviceRequest.docRequests) {
            let itemsReq = docReq.itemsRequest
            let docType = itemsReq.docType
            let nsMap = itemsReq.requestNameSpaces.nameSpaces

            let requestItemsForDoc = ArrayList<RequestItem>()

            // Iterate over all requested namespaces and element identifiers
            for ((ns, rde) in nsMap) {
                let elementsMap = rde.dataElements
                for ((elementId, intentToRetain) in elementsMap) {
                    let ri = RequestItem.fromIdentifier(elementId, Some(intentToRetain), None)
                    requestItemsForDoc.add(ri)
                }
            }

            if (requestItemsForDoc.size > 0) {
                hasAnyItems = true
            }

            itemsRequestedList.add((docType, requestItemsForDoc.toArray()))
        }

        // Step 5: Build UserRequestInfo
        var userInfo = UserRequestInfo(
            plaintext,
            itemsRequestedList.toArray()
        )

        // Step 6: Validate reader authentication for each DocRequest
        let sessionTranscript = sessionEncryption.sessionTranscript()
        let readerAuthResultsList = ArrayList<(String, Bool)>()

        for (docReq in deviceRequest.docRequests) {
            let docType = docReq.itemsRequest.docType
            let authResult = ReaderValidation.validate(
                docReq,
                sessionTranscript,
                rootIacaDer,
                readerCertTrust: readerCertTrust
            )
            readerAuthResultsList.add((docType, authResult.isValidated))
        }

        userInfo.readerAuthResults = readerAuthResultsList.toArray()

        // Step 7: Determine whether the request is valid (any doc matched)
        let isValidRequest = hasAnyItems

        return DecodeRequestResult(
            sessionEncryption,
            deviceRequest,
            userInfo,
            isValidRequest
        )
    }

    // ----------------------------------------------------------------
    // getDeviceResponseToSend
    // ----------------------------------------------------------------

    /**
     * Build a DeviceResponse filtered to only the user-authorised elements.
     *
     * Flow:
     *   1. Iterate over selectedItems (docType → Array<RequestItem>).
     *   2. For each docType, find the matching IssuerSigned in issuerSignedMap.
     *   3. Filter IssuerNameSpaces: keep only items whose elementIdentifier is
     *      in the user's authorised set for that namespace.
     *   4. Validate reader authentication if requested (consumes ReaderValidation).
     *   5. Assemble Document objects and return DeviceResponse.
     *
     * Done-when: "按用户授权项裁剪 IssuerSigned/构建 DeviceResponse;
     * ReaderValidation 校验 reader 证书链"
     *
     * Note: In a full implementation the device signing (DeviceAuth / COSE_Sign1)
     * requires the holder's private key material and an MdocAuthentication call
     * that belongs to the mdoc-security layer. This layer builds the
     * issuerSigned-only Document and produces a DeviceResponse.  DeviceAuth
     * is carried over from a pre-computed DeviceSigned produced by
     * the security layer (passed in via existingDeviceSigned).
     *
     * @param deviceRequest        The decoded DeviceRequest from the reader.
     * @param issuerSignedMap      docId → IssuerSigned (raw issuer-signed documents).
     * @param selectedItems        docType → Array<RequestItem> (user-authorised elements).
     * @param sessionEncryption    Active session encryption (for reader auth transcript).
     * @param rootIacaDer          Trusted root IACA DER certificate bytes for reader auth.
     * @param existingDeviceSigned docType → DeviceSigned (pre-computed by security layer).
     * @param readerCertTrust      When set, live access-manager chain check.
     * @return DeviceResponse with only authorised documents.
     */
    public static func getDeviceResponseToSend(
        deviceRequest: DeviceRequest,
        issuerSignedMap: Array<(String, IssuerSigned)>,
        selectedItems: Array<(String, Array<RequestItem>)>,
        sessionEncryption: SessionEncryption,
        rootIacaDer: Array<Array<UInt8>>,
        existingDeviceSigned: Array<(String, DeviceSigned)>,
        readerCertTrust!: ?ReaderCertTrust = None
    ): DeviceResponse {
        let filteredDocs = ArrayList<Document>()
        let docErrors = ArrayList<DocumentError>()
        let sessionTranscript = sessionEncryption.sessionTranscript()

        // Validate reader auth per DocRequest (for diagnostics / policy)
        for (docReq in deviceRequest.docRequests) {
            ReaderValidation.validate(
                docReq,
                sessionTranscript,
                rootIacaDer,
                readerCertTrust: readerCertTrust
            )
        }

        // Build a lookup from docType → IssuerSigned (O(1) per doc)
        let issuerSignedByDocType = HashMap<String, IssuerSigned>()
        for ((_, is_) in issuerSignedMap) {
            let docType = is_.issuerAuth.mso.docType
            issuerSignedByDocType[docType] = is_
        }

        // Build a lookup from docType → DeviceSigned
        let deviceSignedByDocType = HashMap<String, DeviceSigned>()
        for ((docType, ds) in existingDeviceSigned) {
            deviceSignedByDocType[docType] = ds
        }

        for ((docType, authorisedItems) in selectedItems) {
            // Look up the IssuerSigned for this docType
            let issuerSignedOpt = issuerSignedByDocType.get(docType)
            let issuerSigned: IssuerSigned = match (issuerSignedOpt) {
                case Some(is_) => is_
                case None =>
                    // DocType not available → record error
                    let errMap = HashMap<String, UInt64>()
                    errMap[docType] = UInt64(0)
                    docErrors.add(DocumentError(errMap))
                    continue
            }

            // Look up the DeviceSigned for this docType
            let deviceSignedOpt = deviceSignedByDocType.get(docType)
            let deviceSigned: DeviceSigned = match (deviceSignedOpt) {
                case Some(ds) => ds
                case None =>
                    // No device signed available → skip document
                    let errMap = HashMap<String, UInt64>()
                    errMap[docType] = UInt64(0)
                    docErrors.add(DocumentError(errMap))
                    continue
            }

            // Build authorised element identifier set for fast lookup
            let authorisedIds = HashMap<String, Bool>()
            for (ri in authorisedItems) {
                authorisedIds[ri.elementIdentifier()] = true
            }

            // Filter IssuerNameSpaces
            let issuerNsOpt = issuerSigned.issuerNameSpaces
            match (issuerNsOpt) {
                case None =>
                    // No namespace data — cannot include this document
                    let errMap = HashMap<String, UInt64>()
                    errMap[docType] = UInt64(0)
                    docErrors.add(DocumentError(errMap))
                case Some(issuerNs) =>
                    let filteredNsMap = HashMap<String, ArrayList<IssuerSignedItem>>()
                    var hasAnyItem = false

                    for ((ns, items) in issuerNs.nameSpaces) {
                        let filteredItems = ArrayList<IssuerSignedItem>()
                        for (item in items) {
                            if (authorisedIds.contains(item.elementIdentifier)) {
                                filteredItems.add(item)
                                hasAnyItem = true
                            }
                        }
                        if (filteredItems.size > 0) {
                            filteredNsMap[ns] = filteredItems
                        }
                    }

                    if (hasAnyItem) {
                        let filteredIssuerNs = IssuerNameSpaces(filteredNsMap)
                        let filteredIssuerSigned = IssuerSigned(Some(filteredIssuerNs), issuerSigned.issuerAuth)
                        let doc = Document(docType, filteredIssuerSigned, deviceSigned, None)
                        filteredDocs.add(doc)
                    } else {
                        // All requested items absent — record error
                        let errMap = HashMap<String, UInt64>()
                        errMap[docType] = UInt64(0)
                        docErrors.add(DocumentError(errMap))
                    }
            }
        }

        let docsOpt: ?ArrayList<Document> = if (filteredDocs.size > 0) {
            Some(filteredDocs)
        } else {
            None
        }

        let errOpt: ?ArrayList<DocumentError> = if (docErrors.size > 0) {
            Some(docErrors)
        } else {
            None
        }

        return DeviceResponse(DeviceResponse.DEFAULT_VERSION, docsOpt, errOpt, UInt64(0))
    }
}
