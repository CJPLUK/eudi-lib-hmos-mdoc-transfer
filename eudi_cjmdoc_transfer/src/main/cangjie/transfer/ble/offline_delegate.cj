/*
 * offline_delegate.cj — ISO 18013-5 §8 BLE transfer callback interface.
 *
 * Cangjie translation of Swift MdocOfflineDelegate protocol.
 * Source ref:
 *   Sources/MdocDataTransfer18013/BLETransfer/MdocOfflineDelegate.swift
 *
 * Design note:
 *   MdocOfflineDelegate is the observer/callback interface that connects the
 *   BLE transport layer (MdocGattServer / MdocGattClient) to the application
 *   layer.  All four callback methods are called by the transport layer; the
 *   application layer provides an implementation.
 *
 *   The `deviceEngagement` property carries the runtime BLE service UUID
 *   (DeviceEngagement.ble_uuid) used by both roles to advertise / scan.
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.TransferStatus
import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.ErrorCode

// ---------------------------------------------------------------------------
// DeviceEngagementInfo — minimal engagement data needed by BLE transport
// ---------------------------------------------------------------------------

/**
 * Carries the BLE-specific device engagement parameters.
 *
 * In the iOS reference, DeviceEngagement is a richer structure from the
 * mdoc-data-model layer.  The BLE transport layer only needs the service UUID
 * for advertising/scanning.  We define a minimal struct here to decouple the
 * transport layer from the full DeviceEngagement type.
 */
public struct DeviceEngagementInfo {
    /// The BLE GATT service UUID obtained from the QR-code / NFC engagement.
    /// Example: "00000000-0000-0000-0000-000000000001"
    public let bleServiceUuid: String

    public init(bleServiceUuid: String) {
        this.bleServiceUuid = bleServiceUuid
    }
}

// ---------------------------------------------------------------------------
// MdocOfflineDelegate — observer interface for the BLE transport layer
// ---------------------------------------------------------------------------

/**
 * Callback interface that the application layer must implement to receive
 * events from MdocGattServer (holder) or MdocGattClient (reader).
 *
 * All callbacks are invoked by the BLE transport layer on the thread that the
 * ConnectivityKit delivers hardware events (may not be the main thread).
 * Implementations that touch UI must dispatch to the UI thread (S-001).
 */
public interface MdocOfflineDelegate {

    /**
     * Called when the BLE subsystem has powered on and is ready.
     *
     * @param isPeripheralManager true = called from the server (peripheral) role;
     *                            false = called from the client (central) role.
     */
    func didPoweredOn(isPeripheralManager: Bool): Unit

    /**
     * Called when a BLE connection is established.
     *
     * @param isPeripheral true = this device is acting as peripheral (holder/server);
     *                     false = this device is acting as central (reader/client).
     * @param deviceName   Optional identifier of the remote device.
     */
    func didConnected(isPeripheral: Bool, deviceName: ?String): Unit

    /**
     * Called when the transfer status changes.
     *
     * @param newStatus the new TransferStatus value.
     */
    func didChangeStatus(newStatus: TransferStatus): Unit

    /**
     * Called when the transport layer has fully reassembled an inbound request
     * (holder role) or response (reader role) from received BLE data fragments.
     *
     * @param data the raw CBOR bytes of the complete message.
     */
    func didReceiveRequest(data: Array<UInt8>): Unit

    /**
     * Called when a non-recoverable error occurs in the transport layer.
     *
     * @param code     the machine-readable error code.
     * @param message  a human-readable error description.
     */
    func didFinishedWithError(code: ErrorCode, message: String): Unit

    /**
     * Provides access to the current device engagement info.
     *
     * The BLE transport reads `deviceEngagement.bleServiceUuid` to obtain the
     * runtime GATT service UUID for advertising (holder) or scanning (reader).
     *
     * Returns None until the application layer sets engagement data.
     */
    func deviceEngagement(): ?DeviceEngagementInfo
}
