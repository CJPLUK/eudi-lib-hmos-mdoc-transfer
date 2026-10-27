/*
 * loopback_peripheral.cj — in-process GattPeripheralBackend without a radio.
 *
 * Used by runMdocTransferDemo() and the entry unit tests to drive
 * MdocGattServer through the complete ISO 18013-5 §8 holder sequence:
 * the test plays the reader by calling the captured GattPeripheralEvents
 * (connection, MTU, CCCD writes, State / Client2Server writes) and inspects
 * the Server2Client notifications the server produced.
 *
 * Failure injection:
 *   refuseOpen(code)      — next open() throws BleBackendException(code)
 *                           (BleErrorCodes.BLUETOOTH_DISABLED simulates radio off)
 *   failNextNotifies(n)   — the next n notify() calls throw
 */
package ohos_app_cangjie_eudi_cjmdoc_transfer.transfer.ble

import std.collection.ArrayList
import std.sync.Monitor

/// One Server2Client notification captured by the loopback backend.
public struct LoopbackNotification {
    public let deviceId: String
    public let characteristicUuid: String
    public let value: Array<UInt8>

    public init(deviceId: String, characteristicUuid: String, value: Array<UInt8>) {
        this.deviceId = deviceId
        this.characteristicUuid = characteristicUuid
        this.value = value
    }
}

/// One ATT response captured by the loopback backend.
public struct LoopbackResponse {
    public let deviceId: String
    public let transId: Int32
    public let status: Int32
    public let value: Array<UInt8>

    public init(deviceId: String, transId: Int32, status: Int32, value: Array<UInt8>) {
        this.deviceId = deviceId
        this.transId = transId
        this.status = status
        this.value = value
    }
}

public class LoopbackPeripheralBackend <: GattPeripheralBackend {

    private let monitor: Monitor = Monitor()
    private var events: ?GattPeripheralEvents = None
    private var openedServiceUuid: String = ""
    private var openedIdent: ?Array<UInt8> = None
    private var advertisingUuid: ?String = None
    private var closed: Bool = false
    private var refuseOpenCode: ?Int32 = None
    private var notifyFailuresRemaining: Int64 = 0
    private var notifyAttempts: Int64 = 0
    private let notifications: ArrayList<LoopbackNotification> = ArrayList<LoopbackNotification>()
    private let responses: ArrayList<LoopbackResponse> = ArrayList<LoopbackResponse>()

    public init() {}

    // -----------------------------------------------------------------------
    // Test controls
    // -----------------------------------------------------------------------

    /** Make the next open() fail with the given platform code. */
    public func refuseOpen(code: Int32): Unit {
        synchronized(this.monitor) {
            this.refuseOpenCode = Some(code)
        }
    }

    /** Make the next `count` notify() calls throw. */
    public func failNextNotifies(count: Int64): Unit {
        synchronized(this.monitor) {
            this.notifyFailuresRemaining = count
        }
    }

    /** The GattPeripheralEvents sink registered by open(), if any. */
    public func eventSink(): ?GattPeripheralEvents {
        synchronized(this.monitor) {
            return this.events
        }
    }

    public func isOpen(): Bool {
        synchronized(this.monitor) {
            return this.events.isSome() && !this.closed
        }
    }

    public func isAdvertising(): Bool {
        synchronized(this.monitor) {
            return this.advertisingUuid.isSome()
        }
    }

    public func advertisedServiceUuid(): ?String {
        synchronized(this.monitor) {
            return this.advertisingUuid
        }
    }

    public func registeredIdentValue(): ?Array<UInt8> {
        synchronized(this.monitor) {
            return this.openedIdent
        }
    }

    /** Snapshot of every notification delivered so far, in order. */
    public func notified(): Array<LoopbackNotification> {
        synchronized(this.monitor) {
            return this.notifications.toArray()
        }
    }

    /** Snapshot of every ATT response sent so far, in order. */
    public func responded(): Array<LoopbackResponse> {
        synchronized(this.monitor) {
            return this.responses.toArray()
        }
    }

    /** Total notify() invocations including the ones that were made to fail. */
    public func notifyAttemptCount(): Int64 {
        synchronized(this.monitor) {
            return this.notifyAttempts
        }
    }

    public func clearNotifications(): Unit {
        synchronized(this.monitor) {
            this.notifications.clear()
            this.notifyAttempts = 0
        }
    }

    // -----------------------------------------------------------------------
    // GattPeripheralBackend
    // -----------------------------------------------------------------------

    public func open(serviceUuid: String, identValue: ?Array<UInt8>, events: GattPeripheralEvents): Unit {
        synchronized(this.monitor) {
            if (let Some(code) <- this.refuseOpenCode) {
                this.refuseOpenCode = None
                throw BleBackendException(code, "loopback open refused (code ${code})")
            }
            this.events = Some(events)
            this.openedServiceUuid = serviceUuid
            this.openedIdent = identValue
            this.closed = false
        }
    }

    public func startAdvertise(serviceUuid: String): Unit {
        synchronized(this.monitor) {
            if (this.events.isNone() || this.closed) {
                throw BleBackendException(BleErrorCodes.SERVICE_STOPPED, "loopback: advertise before open")
            }
            this.advertisingUuid = Some(serviceUuid)
        }
    }

    public func stopAdvertise(): Unit {
        synchronized(this.monitor) {
            this.advertisingUuid = None
        }
    }

    public func notify(deviceId: String, serviceUuid: String, characteristicUuid: String, value: Array<UInt8>): Unit {
        synchronized(this.monitor) {
            this.notifyAttempts++
            if (this.closed) {
                throw BleBackendException(BleErrorCodes.SERVICE_STOPPED, "loopback: notify after close")
            }
            if (this.notifyFailuresRemaining > 0) {
                this.notifyFailuresRemaining--
                throw BleBackendException(BleErrorCodes.OPERATION_FAILED, "loopback: injected notify failure")
            }
            this.notifications.add(LoopbackNotification(deviceId, characteristicUuid, value.clone()))
        }
    }

    public func respond(deviceId: String, transId: Int32, status: Int32, offset: Int32, value: Array<UInt8>): Unit {
        synchronized(this.monitor) {
            this.responses.add(LoopbackResponse(deviceId, transId, status, value.clone()))
        }
    }

    public func close(serviceUuid: String): Unit {
        synchronized(this.monitor) {
            this.advertisingUuid = None
            this.closed = true
            this.events = None
        }
    }
}
