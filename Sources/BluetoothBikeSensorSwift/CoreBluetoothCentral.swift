#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

package actor CoreBluetoothCentral: BluetoothCentral {
    private let queue = DispatchQueue(label: "com.bluetoothbikesensor.central")
    private let centralManager: CBCentralManager
    private let delegateBridge: CentralDelegateBridge

    private var state: BluetoothState = .unknown
    private var pendingConnections: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingDisconnections: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingServiceDiscoveries: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingCharacteristicDiscoveries: [UUID: CheckedContinuation<Void, Error>] = [:]

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>.Box()
    private let discoveryBroadcaster = StreamBroadcaster<DiscoveredPeripheralEvent>.Box()
    private let connectionBroadcaster = StreamBroadcaster<ConnectionEvent>.Box()
    private let gattBroadcaster = StreamBroadcaster<GATTEvent>.Box()

    package init() {
        let bridge = CentralDelegateBridge()
        delegateBridge = bridge
        centralManager = CBCentralManager(delegate: bridge, queue: queue)
        bridge.bind { event in
            Task { await self.handle(event) }
        }
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
        guard state == .poweredOn else { return }
        let cbServiceUUIDs = serviceUUIDs?.map { CBUUIDBridge(uuid: $0).cbUUID }
        centralManager.scanForPeripherals(
            withServices: cbServiceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    package func stopScanning() async {
        centralManager.stopScan()
    }

    package var discoveries: AsyncStream<DiscoveredPeripheralEvent> {
        get async {
            discoveryBroadcaster.makeStream()
        }
    }

    package func connect(id: UUID) async throws {
        guard state == .poweredOn else {
            throw BluetoothCentralError.notPoweredOn
        }
        guard let peripheral = delegateBridge.peripheral(for: id) else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingConnections[id] = continuation
            centralManager.connect(peripheral, options: nil)
        }
    }

    package func disconnect(id: UUID) async throws {
        guard let peripheral = delegateBridge.peripheral(for: id) else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingDisconnections[id] = continuation
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    package var connectionEvents: AsyncStream<ConnectionEvent> {
        get async {
            connectionBroadcaster.makeStream()
        }
    }

    package func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws {
        guard let peripheral = delegateBridge.peripheral(for: id) else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingServiceDiscoveries[id] = continuation
            let cbServiceUUIDs = serviceUUIDs?.map { CBUUIDBridge(uuid: $0).cbUUID }
            peripheral.discoverServices(cbServiceUUIDs)
        }
    }

    package func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?
    ) async throws {
        guard let peripheral = delegateBridge.peripheral(for: id) else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        guard let service = peripheral.services?.first(where: { $0.uuid.asFoundationUUID == serviceUUID }) else {
            throw BluetoothCentralError.serviceNotFound(id, serviceUUID: serviceUUID)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingCharacteristicDiscoveries[id] = continuation
            let cbCharacteristicUUIDs = characteristicUUIDs?.map { CBUUIDBridge(uuid: $0).cbUUID }
            peripheral.discoverCharacteristics(cbCharacteristicUUIDs, for: service)
        }
    }

    package var gattEvents: AsyncStream<GATTEvent> {
        get async {
            gattBroadcaster.makeStream()
        }
    }

    private func handle(_ event: CentralDelegateEvent) {
        switch event {
        case let .stateUpdated(newState):
            state = newState
            stateBroadcaster.yield(newState)

        case let .discovered(discovery):
            discoveryBroadcaster.yield(discovery)

        case let .connected(id):
            connectionBroadcaster.yield(.connected(id: id))
            pendingConnections.removeValue(forKey: id)?.resume()

        case let .failedToConnect(id, reason):
            connectionBroadcaster.yield(.failed(id: id, reason: reason))
            pendingConnections.removeValue(forKey: id)?
                .resume(throwing: BluetoothCentralError.connectionFailed(id, reason: reason))

        case let .disconnected(id, reason):
            connectionBroadcaster.yield(.disconnected(id: id, reason: reason))
            pendingConnections.removeValue(forKey: id)?
                .resume(throwing: BluetoothCentralError.disconnected(id, reason: reason))
            pendingDisconnections.removeValue(forKey: id)?.resume()
            pendingServiceDiscoveries.removeValue(forKey: id)?
                .resume(throwing: BluetoothCentralError.disconnected(id, reason: reason))
            pendingCharacteristicDiscoveries.removeValue(forKey: id)?
                .resume(throwing: BluetoothCentralError.disconnected(id, reason: reason))

        case let .servicesDiscovered(id, serviceUUIDs, errorReason):
            if let errorReason {
                pendingServiceDiscoveries.removeValue(forKey: id)?
                    .resume(throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason))
                return
            }
            gattBroadcaster.yield(.servicesDiscovered(id: id, serviceUUIDs: serviceUUIDs))
            pendingServiceDiscoveries.removeValue(forKey: id)?.resume()

        case let .characteristicsDiscovered(id, serviceUUID, characteristicUUIDs, errorReason):
            if let errorReason {
                pendingCharacteristicDiscoveries.removeValue(forKey: id)?
                    .resume(throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason))
                return
            }
            gattBroadcaster.yield(
                .characteristicsDiscovered(
                    id: id,
                    serviceUUID: serviceUUID,
                    characteristicUUIDs: characteristicUUIDs
                )
            )
            pendingCharacteristicDiscoveries.removeValue(forKey: id)?.resume()
        }
    }
}

private enum CentralDelegateEvent: Sendable {
    case stateUpdated(BluetoothState)
    case discovered(DiscoveredPeripheralEvent)
    case connected(id: UUID)
    case failedToConnect(id: UUID, reason: String)
    case disconnected(id: UUID, reason: String?)
    case servicesDiscovered(id: UUID, serviceUUIDs: [UUID], errorReason: String?)
    case characteristicsDiscovered(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID],
        errorReason: String?
    )
}

private final class CentralDelegateBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let lock = NSLock()
    private var handler: (@Sendable (CentralDelegateEvent) -> Void)?
    private var peripherals: [UUID: CBPeripheral] = [:]

    func bind(handler: @escaping @Sendable (CentralDelegateEvent) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func peripheral(for id: UUID) -> CBPeripheral? {
        lock.lock()
        defer { lock.unlock() }
        return peripherals[id]
    }

    private func emit(_ event: CentralDelegateEvent) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(event)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.stateUpdated(BluetoothState(central.state)))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        lock.lock()
        peripheral.delegate = self
        peripherals[id] = peripheral
        lock.unlock()

        emit(
            .discovered(
                DiscoveredPeripheralEvent(
                    id: id,
                    name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                    manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                    serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                        .map(\.asFoundationUUID) ?? [],
                    rssi: RSSI.intValue
                )
            )
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.connected(id: peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        emit(
            .failedToConnect(
                id: peripheral.identifier,
                reason: error?.localizedDescription ?? "Connection failed"
            )
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        emit(.disconnected(id: peripheral.identifier, reason: error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let serviceUUIDs = peripheral.services?.map { $0.uuid.asFoundationUUID } ?? []
        emit(
            .servicesDiscovered(
                id: peripheral.identifier,
                serviceUUIDs: serviceUUIDs,
                errorReason: error?.localizedDescription
            )
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristicUUIDs = service.characteristics?.map { $0.uuid.asFoundationUUID } ?? []
        emit(
            .characteristicsDiscovered(
                id: peripheral.identifier,
                serviceUUID: service.uuid.asFoundationUUID,
                characteristicUUIDs: characteristicUUIDs,
                errorReason: error?.localizedDescription
            )
        )
    }
}

private extension BluetoothState {
    init(_ state: CBManagerState) {
        switch state {
        case .unknown:
            self = .unknown
        case .resetting:
            self = .resetting
        case .unsupported:
            self = .unsupported
        case .unauthorized:
            self = .unauthorized
        case .poweredOff:
            self = .poweredOff
        case .poweredOn:
            self = .poweredOn
        @unknown default:
            self = .unknown
        }
    }
}

private extension CBUUID {
    var asFoundationUUID: UUID {
        if uuidString.count == 4 {
            return UUID(uuidString: "0000\(uuidString)-0000-1000-8000-00805F9B34FB")!
        }
        return UUID(uuidString: uuidString) ?? UUID()
    }
}
#endif
