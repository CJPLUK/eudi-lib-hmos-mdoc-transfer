/*
 * ble_transport.cj — ISO 18013-5 §8 BLE transport protocol interface.
 *
 * Cangjie translation of Swift MdocBleTransport protocol.
 * Source ref:
 *   Sources/MdocDataTransfer18013/BLETransfer/MdocBleTransport.swift
 *
 * Both MdocGattServer (holder role) and MdocGattClient (reader role) implement
 * this interface.  The application layer interacts exclusively via this
 * interface and the MdocOfflineDelegate callback.
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble

import ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.framing.TransferStatus

// ---------------------------------------------------------------------------
// MdocBleTransport — unified transport interface (holder + reader)
// ---------------------------------------------------------------------------

/**
 * BLE transport interface for ISO 18013-5 §8 mdoc data transfer.
 *
 * Implementations:
 *   - MdocGattServer  — the mdoc holder (CBPeripheralManager / GATT server)
 *   - MdocGattClient  — the mdoc reader  (CBCentralManager  / GATT client)
 *
 * Lifecycle (holder role):
 *   1. Set delegate before calling any other method.
 *   2. Call startBleAdvertising() after delegate.didPoweredOn(isPeripheralManager: true).
 *   3. Receive data via delegate.didReceiveRequest(data:).
 *   4. Call sendData(data:) to transmit the response.
 *   5. Call stopBleAdvertising() when done; call stop() to clean up.
 *
 * Lifecycle (reader role):
 *   1. Set delegate before calling any other method.
 *   2. Call startBleScanning() after delegate.didPoweredOn(isPeripheralManager: false).
 *   3. Receive the decoded response via delegate.didReceiveRequest(data:).
 *   4. Call sendData(data:) to transmit the request payload.
 *   5. Call stop() when done.
 */
public interface MdocBleTransport {

    // -----------------------------------------------------------------------
    // Delegate — wires the application observer to the transport layer
    // -----------------------------------------------------------------------

    /**
     * Returns the current delegate, or None if not yet set.
     */
    func getDelegate(): ?MdocOfflineDelegate

    /**
     * Sets the delegate that receives transport events.
     *
     * Must be called before startBleAdvertising() or startBleScanning().
     */
    func setDelegate(delegate: MdocOfflineDelegate): Unit

    // -----------------------------------------------------------------------
    // Advertising (holder / GATT server role)
    // -----------------------------------------------------------------------

    /**
     * Start BLE advertising of the GATT service UUID obtained from
     * delegate.deviceEngagement().bleServiceUuid.
     *
     * Initialises and registers the three GATT characteristics (State,
     * Client2Server, Server2Client) before advertising.
     *
     * No-op if BLE is not powered on; the implementation should retry
     * internally once BLE becomes available.
     */
    func startBleAdvertising(): Unit

    /**
     * Stop BLE advertising.
     *
     * Safe to call even if advertising is not currently active.
     */
    func stopBleAdvertising(): Unit

    // -----------------------------------------------------------------------
    // Scanning (reader / GATT client role)
    // -----------------------------------------------------------------------

    /**
     * Start BLE scanning for peripherals advertising the GATT service UUID
     * obtained from delegate.deviceEngagement().bleServiceUuid.
     *
     * Connects automatically when the target peripheral is discovered.
     *
     * No-op if BLE is not powered on.
     */
    func startBleScanning(): Unit

    /**
     * Stop BLE scanning.
     *
     * Safe to call even if scanning is not currently active.
     */
    func stopBleScanning(): Unit

    // -----------------------------------------------------------------------
    // Data transfer
    // -----------------------------------------------------------------------

    /**
     * Send `data` to the remote peer.
     *
     * Holder role:  sends the encrypted DeviceResponse via Server2Client
     *               characteristic notify.
     * Reader role:  sends the encrypted DeviceRequest via Client2Server
     *               characteristic write-without-response.
     *
     * The implementation splits `data` into BLE frames using
     * BleTransferFraming.prepareDataBlocksToSend before transmission.
     *
     * @param data  raw CBOR bytes to transmit.
     */
    func sendData(data: Array<UInt8>): Unit

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /**
     * Returns true when the underlying BLE radio is powered on and ready.
     */
    func isBlePoweredOn(): Bool

    /**
     * Current transfer status.
     */
    func currentStatus(): TransferStatus

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /**
     * Clean up: stop advertising/scanning, disconnect, release resources.
     */
    func stop(): Unit
}
