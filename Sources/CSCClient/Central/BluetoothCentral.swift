import Foundation

/// Mirrors `CBManagerState` without depending on CoreBluetooth, so this package and its tests
/// share one enum. `.unknown` and `.resetting` are transient. ``Scanner`` waits briefly through
/// them. `.unsupported`, `.unauthorized`, and `.poweredOff` are terminal for that wait.
package enum BluetoothState: Sendable, Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

/// Failures from ``BluetoothCentral`` conformers, before they are mapped to ``ConnectError``,
/// ``DisconnectError``, or ``ControlPointError``.
package enum BluetoothCentralError: Error, Sendable, Equatable {
    case peripheralNotFound(UUID)
    case notPoweredOn
    /// A failure reported as text: CoreBluetooth error text on any operation (including discovery,
    /// notify, read, and write on a connected peripheral), or a rejected duplicate request.
    /// `reason` is diagnostic text. The test double uses this case when a hung write is released.
    case connectionFailed(UUID, reason: String)
    /// The link dropped. `reason` is nil when CoreBluetooth reported no error, which an
    /// intentional disconnect looks like.
    case disconnected(UUID, reason: String?)
    case serviceNotFound(UUID, serviceUUID: UUID)
    case characteristicNotFound(UUID, serviceUUID: UUID, characteristicUUID: UUID)
    /// Raw ATT application error. CSCS uses `0x80` (procedure already in progress) and `0x81`
    /// (CCCD improperly configured); the numeric code is preserved so ``ControlPoint`` can map
    /// those two and leave every other code as diagnostic text.
    case attApplicationError(code: UInt8)
}

/// One discovery callback. `serviceUUIDs` empty means the advertisement omitted the list, which
/// ``Scanner`` still accepts. It does not mean the peripheral has no services.
package struct DiscoveredPeripheral: Sendable, Equatable {
    package let id: UUID
    package let name: String?
    package let manufacturerData: Data?
    package let serviceUUIDs: [UUID]

    package init(
        id: UUID,
        name: String?,
        manufacturerData: Data?,
        serviceUUIDs: [UUID],
    ) {
        self.id = id
        self.name = name
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
    }
}

/// Value updates and disconnects for every peripheral on one central, in callback order.
///
/// Consumers filter by peripheral id. ``valueUpdated`` is both a read response and a
/// notification or indication; a pending read is completed from the same callback that is
/// yielded here.
package enum CentralEvent: Sendable, Equatable {
    case valueUpdated(peripheralID: UUID, serviceUUID: UUID, characteristicUUID: UUID, value: Data)
    case disconnected(peripheralID: UUID)
}

/// Central-role seam. ``CoreBluetoothCentral`` is the production conformer;
/// ``FakeBluetoothCentral`` is the test double.
///
/// ``stateUpdates``, ``discoveries``, and ``events`` do not replay. Subscribe before the call
/// that produces the events you need, or use ``stateSubscriptionSnapshot()`` when the current
/// state and later transitions both matter. ``events`` fans out to every subscriber and is not
/// split per peripheral.
///
/// Scan sessions are ordered `UInt64`s from ``ScanSessionID``. `startScanning` is ignored when
/// `session` is at or below the newest session already stopped. `stopScanning` stops the radio
/// only when `session` is the one that last started it.
package protocol BluetoothCentral: Sendable {
    var stateUpdates: AsyncStream<BluetoothState> { get async }
    var currentState: BluetoothState { get async }

    /// Subscribes to ``stateUpdates`` and returns ``currentState`` without a gap where a
    /// transition can be applied to one and missed by the other.
    func stateSubscriptionSnapshot() async -> (AsyncStream<BluetoothState>, BluetoothState)

    func startScanning(serviceUUIDs: [UUID]?, session: UInt64) async
    func stopScanning(session: UInt64) async

    /// Discovery callbacks in arrival order. Does not replay; subscribe before `startScanning`.
    var discoveries: AsyncStream<DiscoveredPeripheral> { get async }

    func connect(id: UUID) async throws
    func disconnect(id: UUID) async throws

    /// Read responses, notifications, indications, and disconnects in callback order, for every
    /// peripheral. Does not replay.
    var events: AsyncStream<CentralEvent> { get async }

    func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws
    func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?,
    ) async throws -> [UUID]

    func setNotifyValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        enabled: Bool,
    ) async throws

    func readValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) async throws -> Data

    func writeValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        value: Data,
    ) async throws
}
