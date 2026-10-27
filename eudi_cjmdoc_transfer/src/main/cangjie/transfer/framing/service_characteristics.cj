/*
 * ISO 18013-5 §8 BLE GATT service and characteristic UUID constants.
 *
 * Source ref:
 *   Sources/MdocDataTransfer18013/BLETransfer/ServiceCharacteristics.swift
 *   (MdocGattServer.MdocServiceCharacteristic — mdoc holder / GATT server role)
 *
 * UUID layout (mdoc holder = GATT server):
 *   State          00000001-A123-48CE-896B-4C76973373E6
 *   Client2Server  00000002-A123-48CE-896B-4C76973373E6
 *   Server2Client  00000003-A123-48CE-896B-4C76973373E6
 *
 * The reader (GATT central) uses 00000005–00000008 range; those constants live
 * in mt_ble_transport (reader-side GattClient), not in this framing layer.
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing

/// GATT characteristic identifiers for the mdoc holder role (GATT server).
/// These are the three mandatory characteristics defined in ISO 18013-5 §8.3.3.1.
///
/// Note on BLE service UUID: the GATT service UUID used for advertising and
/// scanning is NOT a static constant here. In the Swift reference implementation
/// (MdocGATTServer.swift line 207), the service UUID is obtained at runtime from
/// DeviceEngagement.ble_uuid (a dynamic value negotiated during device engagement).
/// Callers must obtain the service UUID from DeviceEngagement and pass it at runtime.
public class ServiceCharacteristics {
    // -----------------------------------------------------------------------
    // Characteristic UUIDs — mdoc holder / GATT server role
    // -----------------------------------------------------------------------

    /// State characteristic UUID (holder-side).
    /// Used by the holder to signal START_REQUEST (0x01) and by the reader to
    /// signal END_REQUEST (0x02) during the §8 state machine.
    public static let STATE_UUID: String = "00000001-A123-48CE-896B-4C76973373E6"

    /// Client-to-Server characteristic UUID.
    /// The mdoc reader writes request data chunks (§8 framing) to this characteristic.
    public static let CLIENT_2_SERVER_UUID: String = "00000002-A123-48CE-896B-4C76973373E6"

    /// Server-to-Client characteristic UUID.
    /// The mdoc holder notifies response data chunks (§8 framing) on this characteristic.
    public static let SERVER_2_CLIENT_UUID: String = "00000003-A123-48CE-896B-4C76973373E6"

    /// Ident characteristic UUID (holder-side, optional per ISO 18013-5 §8.3.3.1.5).
    /// Read-only; value = HKDF(EDeviceKey, "BLEIdent") supplied by the wallet kit.
    public static let IDENT_UUID: String = "00000004-A123-48CE-896B-4C76973373E6"

    // -----------------------------------------------------------------------
    // Human-readable names (for logging / diagnostics)
    // -----------------------------------------------------------------------

    /// Returns the human-readable name for a given characteristic UUID string,
    /// or "Unknown" if not recognised.
    public static func descriptionFor(uuid: String): String {
        if (uuid == STATE_UUID) {
            return "State"
        } else if (uuid == CLIENT_2_SERVER_UUID) {
            return "Client to Server"
        } else if (uuid == SERVER_2_CLIENT_UUID) {
            return "Server to Client"
        } else if (uuid == IDENT_UUID) {
            return "Ident"
        } else {
            return "Unknown"
        }
    }
}
