import Foundation

/// Controllable `BluetoothCentral` for unit tests. Not intended for production use.
package actor FakeBluetoothCentral: BluetoothCentral {
    package enum RecordedCall: Sendable, Equatable {
        case startScanning(serviceUUIDs: [UUID]?)
        case stopScanning
        case connect(id: UUID)
        case disconnect(id: UUID)
        case discoverServices(id: UUID, serviceUUIDs: [UUID]?)
        case discoverCharacteristics(id: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID]?)
    }

    private var state: BluetoothState
    private var nextConnectError: BluetoothCentralError?
    private var nextDiscoverServicesError: BluetoothCentralError?
    private var nextDisconnectError: BluetoothCentralError?
    private var shouldHangNextConnect = false

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>.Box()
    private let discoveryBroadcaster = StreamBroadcaster<DiscoveredPeripheralEvent>.Box()
    private let connectionBroadcaster = StreamBroadcaster<ConnectionEvent>.Box()
    private let gattBroadcaster = StreamBroadcaster<GATTEvent>.Box()

    package private(set) var recordedCalls: [RecordedCall] = []

    package init(initialState: BluetoothState = .poweredOn) {
        state = initialState
    }

    package var stateUpdates: AsyncStream<BluetoothState> {
        get async {
            stateBroadcaster.makeStream()
        }
    }

    package var currentState: BluetoothState {
        get async { state }
    }

    package func startScanning(serviceUUIDs: [UUID]?) async {
        recordedCalls.append(.startScanning(serviceUUIDs: serviceUUIDs))
    }

    package func stopScanning() async {
        recordedCalls.append(.stopScanning)
    }

    package var discoveries: AsyncStream<DiscoveredPeripheralEvent> {
        get async {
            discoveryBroadcaster.makeStream()
        }
    }

    package func connect(id: UUID) async throws {
        recordedCalls.append(.connect(id: id))

        if shouldHangNextConnect {
            shouldHangNextConnect = false
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }

        if let nextConnectError {
            self.nextConnectError = nil
            connectionBroadcaster.yield(.failed(id: id, reason: String(describing: nextConnectError)))
            throw nextConnectError
        }
        connectionBroadcaster.yield(.connected(id: id))
    }

    package func disconnect(id: UUID) async throws {
        recordedCalls.append(.disconnect(id: id))

        if let nextDisconnectError {
            self.nextDisconnectError = nil
            connectionBroadcaster.yield(.disconnected(id: id, reason: String(describing: nextDisconnectError)))
            throw nextDisconnectError
        }

        connectionBroadcaster.yield(.disconnected(id: id, reason: nil))
    }

    package var connectionEvents: AsyncStream<ConnectionEvent> {
        get async {
            connectionBroadcaster.makeStream()
        }
    }

    package func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws {
        recordedCalls.append(.discoverServices(id: id, serviceUUIDs: serviceUUIDs))

        if let nextDiscoverServicesError {
            self.nextDiscoverServicesError = nil
            throw nextDiscoverServicesError
        }
    }

    package func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?,
    ) async throws {
        recordedCalls.append(
            .discoverCharacteristics(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUIDs: characteristicUUIDs,
            ),
        )
    }

    package var gattEvents: AsyncStream<GATTEvent> {
        get async {
            gattBroadcaster.makeStream()
        }
    }

    package func setState(_ newState: BluetoothState) {
        state = newState
        stateBroadcaster.yield(newState)
    }

    package func emitDiscovery(_ event: DiscoveredPeripheralEvent) {
        discoveryBroadcaster.yield(event)
    }

    package func emitConnection(_ event: ConnectionEvent) {
        connectionBroadcaster.yield(event)
    }

    package func emitGATT(_ event: GATTEvent) {
        gattBroadcaster.yield(event)
    }

    package func failNextConnect(with error: BluetoothCentralError) {
        nextConnectError = error
    }

    package func failNextDiscoverServices(with error: BluetoothCentralError) {
        nextDiscoverServicesError = error
    }

    package func failNextDisconnect(with error: BluetoothCentralError) {
        nextDisconnectError = error
    }

    package func hangNextConnect() {
        shouldHangNextConnect = true
    }
}
