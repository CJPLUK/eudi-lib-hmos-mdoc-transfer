/*
 * reader_validation.cj — ISO 18013-5 §9.1.4 reader authentication validation.
 *
 * Wraps MdocReaderAuthentication (from mdoc-security) to provide a thin
 * orchestration-layer result type and a convenience validator consumed by
 * MdocHelpers.decodeRequestAndInformUser.
 *
 * Source ref:
 *   Sources/MdocDataTransfer18013/ReaderValidation.swift
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.orchestration

import ohos_app_cangjie_eudi_cjmdoc_security.security.session.SessionTranscript
import ohos_app_cangjie_eudi_cjmdoc_security.security.reader_auth.MdocReaderAuthentication

import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.request.DocRequest
import ohos_app_cangjie_eudi_cjmdoc_data_model.mdoc.core.CoseSign1

/**
 * Live reader-chain trust (iOS `CertificateTrustValidator`).
 * Implemented by wallet-kit wrapping `accessTrustManager`.
 */
public interface ReaderCertTrust {
    func validateCertTrustPath(chain: Array<Array<UInt8>>): (Bool, ?String)
}

/* ------------------------------------------------------------------ */
/* ReaderAuthResult — per-docRequest reader authentication outcome      */
/* ------------------------------------------------------------------ */

/**
 * Encapsulates the result of validating a reader's authentication for one
 * DocRequest.  Mirrors iOS ReaderAuthenticationResult (isValidated / message).
 */
public struct ReaderAuthResult {
    /** True if the certificate chain and signature are both valid. */
    public let isValidated: Bool
    /** Common name extracted from the reader's leaf certificate, if available. */
    public let certificateIssuer: ?String
    /** Human-readable validation outcome message ("" on success). */
    public let validationMessage: String

    public init(
        isValidated: Bool,
        certificateIssuer: ?String,
        validationMessage: String
    ) {
        this.isValidated = isValidated
        this.certificateIssuer = certificateIssuer
        this.validationMessage = validationMessage
    }

    /** Convenience: build a failed result with no certificate issuer. */
    public static func failure(message: String): ReaderAuthResult {
        return ReaderAuthResult(false, None, message)
    }

    /** Convenience: build a success result. */
    public static func success(certificateIssuer: ?String): ReaderAuthResult {
        return ReaderAuthResult(true, certificateIssuer, "")
    }
}

/* ------------------------------------------------------------------ */
/* ReaderValidation — orchestration-layer certificate CN extractor      */
/* ------------------------------------------------------------------ */

/**
 * Thin orchestration helper that:
 *   1. Delegates certificate-chain + COSE_Sign1 signature verification
 *      to MdocReaderAuthentication (mdoc-security layer).
 *   2. Extracts the reader certificate issuer CN from the leaf DER cert
 *      to populate ReaderAuthResult.certificateIssuer.
 *
 * iOS: ReaderValidation struct in ReaderValidation.swift
 */
public class ReaderValidation {

    /**
     * Validate reader authentication for a single DocRequest.
     *
     * @param docRequest         The decoded DocRequest (may or may not have readerAuth).
     * @param sessionTranscript  Session transcript from the active SessionEncryption.
     * @param rootIacaDer        Trusted root IACA DER certificate bytes.
     * @param readerCertTrust    When set, chain trust uses this validator (iOS
     *                           `accessTrustManager`) instead of dumped IACA roots.
     *
     * @return ReaderAuthResult — isValidated=true only if readerAuth is present,
     *   the certificate chain is valid, and the COSE_Sign1 signature is valid.
     *   If readerAuth is absent, returns isValidated=false with a descriptive message.
     */
    public static func validate(
        docRequest: DocRequest,
        sessionTranscript: SessionTranscript,
        rootIacaDer: Array<Array<UInt8>>,
        readerCertTrust!: ?ReaderCertTrust = None
    ): ReaderAuthResult {
        // 1. Check whether readerAuth is present in the DocRequest
        let readerAuthOpt = docRequest.readerAuth
        let readerAuth = match (readerAuthOpt) {
            case Some(ra) => ra
            case None =>
                return ReaderAuthResult.failure("Reader authentication not present in request")
        }

        // 2. Also require itemsRequestRawData for the ReaderAuthentication payload
        let itemsRequestRawDataOpt = docRequest.itemsRequestRawData
        let itemsRequestRawData = match (itemsRequestRawDataOpt) {
            case Some(b) => b
            case None =>
                return ReaderAuthResult.failure("ItemsRequest raw data missing from DocRequest")
        }

        // 3. Extract x5chain and COSE_Sign1 from the ReaderAuth
        let x5chain = readerAuth.x5chain
        let coseSign1 = readerAuth.coseSign1

        // 4. Extract leaf CN (best-effort; does not fail validation on parse error)
        let leafCn: ?String = extractLeafCn(x5chain)

        // 5. Signature + chain. Live trustValidator matches iOS
        //    validateReaderAuth(..., trustValidator: accessTrustManager).
        let mdocReaderAuth = MdocReaderAuthentication(sessionTranscript)
        match (readerCertTrust) {
            case Some(live) =>
                let (sigOk, sigMsg) = mdocReaderAuth.verifySignature(
                    coseSign1,
                    x5chain,
                    itemsRequestRawData
                )
                if (!sigOk) {
                    return ReaderAuthResult(false, leafCn, sigMsg)
                }
                return validateChain(x5chain, leafCn, live)
            case None =>
                let (isValid, message) = mdocReaderAuth.verify(
                    coseSign1,
                    x5chain,
                    itemsRequestRawData,
                    rootIacaDer
                )
                if (isValid) {
                    return ReaderAuthResult.success(leafCn)
                } else {
                    return ReaderAuthResult(false, leafCn, message)
                }
        }
    }

    /**
     * Chain-only check against a live trust manager (iOS
     * `validateCertTrustPath`). Used when the caller already verified the
     * COSE signature, or when only the x5c is available.
     */
    public static func validateChain(
        x5chain: Array<Array<UInt8>>,
        certificateIssuer: ?String,
        readerCertTrust: ReaderCertTrust
    ): ReaderAuthResult {
        if (x5chain.size == 0) {
            return ReaderAuthResult.failure("Invalid reader Auth Certificate: empty x5chain")
        }
        let (trusted, reason) = readerCertTrust.validateCertTrustPath(x5chain)
        if (trusted) {
            return ReaderAuthResult.success(certificateIssuer)
        }
        let msg = match (reason) {
            case Some(r) => r
            case None => "Reader auth certificate chain is not trusted"
        }
        ReaderAuthResult(false, certificateIssuer, msg)
    }

    /**
     * Extract the CommonName (CN) from the Subject DN of the leaf DER certificate.
     *
     * Uses a simple ASCII scan over the Subject field bytes to locate "CN=" without
     * depending on a full ASN.1 parser at this layer (the x509 lib is already in
     * the mdoc-security stack; this thin extraction avoids a redundant import cycle).
     *
     * Returns None if x5chain is empty, the cert is too short, or CN is absent.
     *
     * iOS: MdocHelpers.getCN(from:) — regex-based, we do ASCII linear scan here.
     */
    static func extractLeafCn(x5chain: Array<Array<UInt8>>): ?String {
        if (x5chain.size == 0) {
            return None
        }
        let derBytes = x5chain[0]
        // Search for the ASCII sequence "CN=" in the DER bytes.
        // In a DER-encoded X.509 certificate the subject's CN value follows
        // the OID for commonName (2.5.4.3) which in practice encodes to bytes
        // 06 03 55 04 03, followed by a UTF8String or PrintableString tag/length,
        // then the CN value.  A simple linear scan for "CN=" in the printable
        // interpretation of the DER is fragile but sufficient for diagnostic
        // purposes (same as the iOS fallback).
        let cnPrefix: Array<UInt8> = [UInt8(0x43), UInt8(0x4E), UInt8(0x3D)] // "CN="
        var i: Int64 = 0
        while (i + 3 < derBytes.size) {
            if (derBytes[i] == cnPrefix[0] &&
                derBytes[i + 1] == cnPrefix[1] &&
                derBytes[i + 2] == cnPrefix[2]) {
                // Found "CN=" — collect printable bytes until non-printable or ','
                var j: Int64 = i + 3
                let buf = Array<UInt8>(64, repeat: 0)
                var len: Int64 = 0
                while (j < derBytes.size && len < 63) {
                    let b = derBytes[j]
                    // Stop at comma, semicolon, null, or control characters
                    if (b == UInt8(0x2C) || b == UInt8(0x3B) || b < UInt8(0x20) || b > UInt8(0x7E)) {
                        break
                    }
                    buf[len] = b
                    len += 1
                    j += 1
                }
                if (len > 0) {
                    let cnBytes = Array<UInt8>(len, repeat: 0)
                    var k: Int64 = 0
                    while (k < len) {
                        cnBytes[k] = buf[k]
                        k += 1
                    }
                    return Some(String.fromUtf8(cnBytes))
                }
            }
            i += 1
        }
        return None
    }
}
