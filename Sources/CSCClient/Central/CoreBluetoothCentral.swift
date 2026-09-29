#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

actor CoreBluetoothCentral: BluetoothCentral {
    private let queue = DispatchQueue(label: "com.bluetoothbikesensor.central")
    private let centralManager: CBCentralManager
    private let delegateBridge: CentralDelegateBridge
    private let delegateEvents: AsyncStream<CentralDelegateEvent>.Continuation

    private var state: BluetoothState = .unknown
    private var pending: [Request: CheckedContinuation<Data, Error>] = [:]
    private var pendingConnect: Set<UUID> = []
    private var connectCancel = ConnectCancelCoordinator()
    private var activeScanSession: UInt64 = 0
    private var highestStoppedScanSession: UInt64 = 0

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let discoveryBroadcaster = StreamBroadcaster<DiscoveredPeripheral>()
    private let eventsBroadcaster = StreamBroadcaster<CentralEvent>()

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: CentralDelegateEvent.self)
        let bridge = CentralDelegateBridge(events: continuation)
        delegateBridge = bridge
        delegateEvents = continuation
        centralManager = CBCentralManager(delegate: bridge, queue: queue)
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    deinit {
        delegateEvents.finish()
    }

    package var stateUpdates: AsyncStream<BluetoothState> {
        get async { await stateBroadcaster.makeStream() }
    }

    package var currentState: BluetoothState {
        get async { state }
    }

    package func stateSubscriptionSnapshot() async -> (AsyncStream<BluetoothState>, BluetoothState) {
        (await stateBroadcaster.makeStream(), state)
    }

    package func startScanning(serviceUUIDs: [UUID]?, session: UInt64) async {
        guard session > highestStoppedScanSession else { return }
        guard state == .poweredOn else { return }
        activeScanSession = session
        queue.sync {
            centralManager.scanForPeripherals(
                withServices: serviceUUIDs?.map(\.cbUUID),
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false],
            )
        }
    }

    package func stopScanning(session: UInt64) async {
        if session > highestStoppedScanSession {
            highestStoppedScanSession = session
        }
        guard activeScanSession == session else { return }
        activeScanSession = 0
        queue.sync { centralManager.stopScan() }
    }

    package var discoveries: AsyncStream<DiscoveredPeripheral> {
        get async { await discoveryBroadcaster.makeStream() }
    }

    package func connect(id: UUID) async throws {
        guard state == .poweredOn else { throw BluetoothCentralError.notPoweredOn }
        let connectionState = queue.sync { () -> (found: Bool, connected: Bool, cancelPending: Bool) in
            guard let peripheral = delegateBridge.peripheral(for: id) else {
                return (false, false, false)
            }
            let cancelPending = connectCancel.isCancelPending(id)
            return (true, peripheral.state == .connected, cancelPending)
        }
        guard connectionState.found else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        if connectionState.connected, !connectionState.cancelPending {
            return
        }
        try await withTaskCancellationHandler {
            _ = try await enqueue(.connect(id)) {
                queue.sync { connectPeripheral(id: id, request: .connect(id)) }
            }
        } onCancel: {
            Task { await self.cancelConnect(id: id) }
        }
    }

    package func disconnect(id: UUID) async throws {
        let peripheralState = queue.sync { () -> CBPeripheralState? in
            delegateBridge.peripheral(for: id)?.state
        }
        guard let peripheralState else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        if peripheralState == .disconnected { return }

        _ = try await enqueue(.disconnect(id)) {
            queue.sync { disconnectPeripheral(id: id, request: .disconnect(id)) }
        }
    }

    package var events: AsyncStream<CentralEvent> {
        get async { await eventsBroadcaster.makeStream() }
    }

    package func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws {
        guard delegateBridge.peripheral(for: id) != nil else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        let request = Request.discoverServices(id)
        _ = try await enqueue(request) {
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    complete(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard peripheral.state == .connected else {
                    complete(
                        request,
                        throwing: BluetoothCentralError.disconnected(id, reason: nil),
                    )
                    return
                }
                peripheral.discoverServices(serviceUUIDs?.map(\.cbUUID))
            }
        }
    }

    package func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?,
    ) async throws -> [UUID] {
        guard delegateBridge.peripheral(for: id) != nil else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        let request = Request.discoverCharacteristics(id)
        _ = try await enqueue(request) {
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    complete(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard peripheral.state == .connected else {
                    complete(
                        request,
                        throwing: BluetoothCentralError.disconnected(id, reason: nil),
                    )
                    return
                }
                guard let service = peripheral.services?.first(where: { $0.uuid.foundationUUID == serviceUUID }) else {
                    complete(
                        request,
                        throwing: BluetoothCentralError.serviceNotFound(id, serviceUUID: serviceUUID),
                    )
                    return
                }
                peripheral.discoverCharacteristics(characteristicUUIDs?.map(\.cbUUID), for: service)
            }
        }
        return queue.sync {
            guard let peripheral = delegateBridge.peripheral(for: id),
                  let service = peripheral.services?.first(where: { $0.uuid.foundationUUID == serviceUUID })
            else { return [] }
            return service.characteristics?.compactMap { $0.uuid.foundationUUID } ?? []
        }
    }

    package func setNotifyValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        enabled: Bool,
    ) async throws {
        _ = try await performGATT(
            id: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            request: { .setNotify($0, $1, $2) },
        ) { peripheral, characteristic in
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    package func readValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) async throws -> Data {
        try await performGATT(
            id: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            request: { .read($0, $1, $2) },
        ) { peripheral, characteristic in
            peripheral.readValue(for: characteristic)
        }
    }

    package func writeValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        value: Data,
    ) async throws {
        _ = try await performGATT(
            id: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            request: { .write($0, $1, $2) },
        ) { peripheral, characteristic in
            peripheral.writeValue(value, for: characteristic, type: .withResponse)
        }
    }

    private func enqueue(_ request: Request, work: () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            guard pending[request] == nil else {
                continuation.resume(throwing: request.duplicateInProgressError)
                return
            }
            pending[request] = continuation
            work()
        }
    }

    private func complete(_ request: Request, returning data: Data = Data()) {
        guard let continuation = pending.removeValue(forKey: request) else { return }
        continuation.resume(returning: data)
    }

    private func complete(_ request: Request, throwing error: Error) {
        guard let continuation = pending.removeValue(forKey: request) else { return }
        continuation.resume(throwing: error)
    }

    private func complete(_ request: Request, id: UUID, errorReason: String?) {
        if let errorReason {
            complete(request, throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason))
        } else {
            complete(request)
        }
    }

    private func performGATT(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        request: (UUID, UUID, UUID) -> Request,
        perform: (CBPeripheral, CBCharacteristic) -> Void,
    ) async throws -> Data {
        let gattRequest = request(id, serviceUUID, characteristicUUID)
        return try await enqueue(gattRequest) {
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    complete(gattRequest, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard peripheral.state == .connected else {
                    complete(
                        gattRequest,
                        throwing: BluetoothCentralError.disconnected(id, reason: nil),
                    )
                    return
                }
                guard let characteristic = Self.characteristic(
                    on: peripheral,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                ) else {
                    complete(
                        gattRequest,
                        throwing: BluetoothCentralError.characteristicNotFound(
                            id,
                            serviceUUID: serviceUUID,
                            characteristicUUID: characteristicUUID,
                        ),
                    )
                    return
                }
                perform(peripheral, characteristic)
            }
        }
    }

    private func connectPeripheral(id: UUID, request: Request) {
        guard let peripheral = delegateBridge.peripheral(for: id) else {
            complete(request, throwing: BluetoothCentralError.peripheralNotFound(id))
            return
        }
        if connectCancel.isCancelPending(id) {
            return
        }
        if peripheral.state == .connected {
            complete(request)
            return
        }
        pendingConnect.insert(id)
        centralManager.connect(peripheral, options: nil)
    }

    private func disconnectPeripheral(id: UUID, request: Request) {
        guard let peripheral = delegateBridge.peripheral(for: id) else {
            complete(request, throwing: BluetoothCentralError.peripheralNotFound(id))
            return
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func cancelConnect(id: UUID) {
        let request = Request.connect(id)
        guard let continuation = pending.removeValue(forKey: request) else {
            return
        }
        pendingConnect.remove(id)
        queue.sync {
            guard let peripheral = delegateBridge.peripheral(for: id),
                  peripheral.state != .disconnected
            else {
                connectCancel.clearCancelPending(id)
                return
            }
            centralManager.cancelPeripheralConnection(peripheral)
            connectCancel.markCancelPending(id)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelPeripheralConnectionIfKnown(id: UUID) {
        queue.sync {
            guard let peripheral = delegateBridge.peripheral(for: id) else {
                return
            }
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func failPendingRequests(
        for id: UUID,
        error: Error,
        resolvingDisconnect: Bool,
    ) {
        let keys = pending.keys.filter { $0.peripheralID == id }
        for key in keys {
            if key == .disconnect(id), resolvingDisconnect {
                complete(key)
            } else {
                if key == .connect(id) {
                    pendingConnect.remove(id)
                }
                complete(key, throwing: error)
            }
        }
    }

    private func completeConnectIfCurrent(id: UUID) {
        guard pendingConnect.contains(id) else {
            return
        }
        pendingConnect.remove(id)
        complete(.connect(id))
    }

    private func failConnectIfCurrent(id: UUID, reason: String) {
        guard pendingConnect.contains(id) else {
            return
        }
        pendingConnect.remove(id)
        complete(
            .connect(id),
            throwing: BluetoothCentralError.connectionFailed(id, reason: reason),
        )
    }

    private func handleConnectCancelTeardown(
        id: UUID,
        peripheralState: PeripheralConnectionSnapshot,
    ) {
        let snapshot = PeripheralLinkSnapshot(peripheralState)
        switch connectCancel.teardownOutcome(for: id, snapshot: snapshot) {
        case .ignore:
            break
        case .reCancelWhilePending:
            cancelPeripheralConnectionIfKnown(id: id)
        case .clearedRetryConnect:
            issueConnectIfPending(id: id)
        }
    }

    private func issueConnectIfPending(id: UUID) {
        guard pending[.connect(id)] != nil else {
            return
        }
        guard state == .poweredOn else {
            pendingConnect.remove(id)
            complete(.connect(id), throwing: BluetoothCentralError.notPoweredOn)
            return
        }
        queue.sync {
            connectPeripheral(id: id, request: .connect(id))
        }
    }

    private func failPendingConnectsNotPoweredOn() {
        let connectKeys = pending.keys.filter {
            if case .connect = $0 { return true }
            return false
        }
        for key in connectKeys {
            if case let .connect(id) = key {
                pendingConnect.remove(id)
            }
            complete(key, throwing: BluetoothCentralError.notPoweredOn)
        }
    }

    private static func characteristic(
        on peripheral: CBPeripheral,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) -> CBCharacteristic? {
        peripheral.services?
            .first(where: { $0.uuid.foundationUUID == serviceUUID })?
            .characteristics?
            .first(where: { $0.uuid.foundationUUID == characteristicUUID })
    }

    private func handle(_ event: CentralDelegateEvent) async {
        switch event {
        case let .stateUpdated(newState):
            state = newState
            if newState == .poweredOff || newState == .resetting
                || newState == .unauthorized || newState == .unsupported {
                connectCancel.clearAllCancelPending()
                failPendingConnectsNotPoweredOn()
            }
            await stateBroadcaster.yield(newState)

        case let .discovered(discovery):
            await discoveryBroadcaster.yield(discovery)

        case let .connected(id):
            switch connectCancel.connectedOutcome(for: id) {
            case .completeConnect:
                completeConnectIfCurrent(id: id)
            case .reCancelWhilePending:
                cancelPeripheralConnectionIfKnown(id: id)
            }

        case let .failedToConnect(id, reason, peripheralState):
            if connectCancel.isCancelPending(id) {
                handleConnectCancelTeardown(id: id, peripheralState: peripheralState)
                return
            }
            if peripheralState == .connected {
                return
            }
            failConnectIfCurrent(id: id, reason: reason)

        case let .disconnected(id, reason, peripheralState):
            if connectCancel.isCancelPending(id) {
                handleConnectCancelTeardown(id: id, peripheralState: peripheralState)
                return
            }
            if peripheralState == .connected {
                return
            }
            failPendingRequests(
                for: id,
                error: BluetoothCentralError.disconnected(id, reason: reason),
                resolvingDisconnect: true,
            )
            await eventsBroadcaster.yield(.disconnected(peripheralID: id))

        case let .servicesDiscovered(id, errorReason):
            complete(.discoverServices(id), id: id, errorReason: errorReason)

        case let .characteristicsDiscovered(id, errorReason):
            complete(.discoverCharacteristics(id), id: id, errorReason: errorReason)

        case let .characteristicValueUpdated(id, serviceUUID, characteristicUUID, value, errorReason):
            if let serviceUUID {
                let request = Request.read(id, serviceUUID, characteristicUUID)
                if let errorReason {
                    complete(request, id: id, errorReason: errorReason)
                    return
                }
                complete(request, returning: value)
                await eventsBroadcaster.yield(
                    .valueUpdated(
                        peripheralID: id,
                        serviceUUID: serviceUUID,
                        characteristicUUID: characteristicUUID,
                        value: value,
                    ),
                )
            } else {
                let error = BluetoothCentralError.connectionFailed(
                    id,
                    reason: errorReason ?? "Missing service for characteristic",
                )
                let readKeys = pending.keys.filter {
                    guard case let .read(peripheralID, _, cid) = $0 else { return false }
                    return peripheralID == id && cid == characteristicUUID
                }
                for key in readKeys {
                    complete(key, throwing: error)
                }
            }

        case let .characteristicWriteCompleted(id, serviceUUID, characteristicUUID, errorReason, attCode):
            if let serviceUUID {
                let request = Request.write(id, serviceUUID, characteristicUUID)
                if let attCode {
                    complete(request, throwing: BluetoothCentralError.attApplicationError(code: attCode))
                } else if let errorReason {
                    complete(
                        request,
                        throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason),
                    )
                } else {
                    complete(request)
                }
                return
            }

            let error = BluetoothCentralError.connectionFailed(
                id,
                reason: errorReason ?? "Missing service for characteristic",
            )
            let writeKeys = pending.keys.filter {
                guard case let .write(peripheralID, _, cid) = $0 else { return false }
                return peripheralID == id && cid == characteristicUUID
            }
            for key in writeKeys {
                complete(key, throwing: error)
            }

        case let .notificationStateUpdated(id, serviceUUID, characteristicUUID, errorReason):
            if let serviceUUID {
                complete(.setNotify(id, serviceUUID, characteristicUUID), id: id, errorReason: errorReason)
            } else {
                let error = BluetoothCentralError.connectionFailed(
                    id,
                    reason: errorReason ?? "Missing service for characteristic",
                )
                let notifyKeys = pending.keys.filter {
                    guard case let .setNotify(peripheralID, _, cid) = $0 else { return false }
                    return peripheralID == id && cid == characteristicUUID
                }
                for key in notifyKeys {
                    complete(key, throwing: error)
                }
            }
        }
    }
}

private enum Request: Hashable {
    case connect(UUID)
    case disconnect(UUID)
    case discoverServices(UUID)
    case discoverCharacteristics(UUID)
    case read(UUID, UUID, UUID)
    case write(UUID, UUID, UUID)
    case setNotify(UUID, UUID, UUID)

    var peripheralID: UUID {
        switch self {
        case let .connect(id),
             let .disconnect(id),
             let .discoverServices(id),
             let .discoverCharacteristics(id):
            id
        case let .read(id, _, _),
             let .write(id, _, _),
             let .setNotify(id, _, _):
            id
        }
    }

    var duplicateInProgressError: BluetoothCentralError {
        .connectionFailed(peripheralID, reason: "Request already in progress")
    }
}

private extension PeripheralLinkSnapshot {
    init(_ snapshot: PeripheralConnectionSnapshot) {
        switch snapshot {
        case .connected:
            self = .connected
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .disconnecting:
            self = .disconnecting
        }
    }
}

private enum PeripheralConnectionSnapshot: Sendable {
    case connected
    case disconnected
    case connecting
    case disconnecting

    init(_ state: CBPeripheralState) {
        switch state {
        case .connected:
            self = .connected
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .disconnecting:
            self = .disconnecting
        @unknown default:
            self = .disconnected
        }
    }
}

private enum CentralDelegateEvent: Sendable {
    case stateUpdated(BluetoothState)
    case discovered(DiscoveredPeripheral)
    case connected(id: UUID)
    case failedToConnect(id: UUID, reason: String, peripheralState: PeripheralConnectionSnapshot)
    case disconnected(id: UUID, reason: String?, peripheralState: PeripheralConnectionSnapshot)
    case servicesDiscovered(id: UUID, errorReason: String?)
    case characteristicsDiscovered(id: UUID, errorReason: String?)
    case characteristicValueUpdated(
        id: UUID,
        serviceUUID: UUID?,
        characteristicUUID: UUID,
        value: Data,
        errorReason: String?,
    )
    case characteristicWriteCompleted(
        id: UUID,
        serviceUUID: UUID?,
        characteristicUUID: UUID,
        errorReason: String?,
        attCode: UInt8?,
    )
    case notificationStateUpdated(
        id: UUID,
        serviceUUID: UUID?,
        characteristicUUID: UUID,
        errorReason: String?,
    )
}

private final class CentralDelegateBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let lock = NSLock()
    private let events: AsyncStream<CentralDelegateEvent>.Continuation
    private var peripherals: [UUID: CBPeripheral] = [:]

    init(events: AsyncStream<CentralDelegateEvent>.Continuation) {
        self.events = events
    }

    func peripheral(for id: UUID) -> CBPeripheral? {
        lock.lock()
        defer { lock.unlock() }
        return peripherals[id]
    }

    private func emit(_ event: CentralDelegateEvent) {
        events.yield(event)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.stateUpdated(BluetoothState(central.state)))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber,
    ) {
        let id = peripheral.identifier
        lock.lock()
        peripheral.delegate = self
        peripherals[id] = peripheral
        lock.unlock()

        emit(
            .discovered(
                Self.discoveredPeripheral(peripheral: peripheral, advertisementData: advertisementData),
            ),
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.connected(id: peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?,
    ) {
        emit(
            .failedToConnect(
                id: peripheral.identifier,
                reason: error?.localizedDescription ?? "Connection failed",
                peripheralState: PeripheralConnectionSnapshot(peripheral.state),
            ),
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?,
    ) {
        emit(
            .disconnected(
                id: peripheral.identifier,
                reason: error?.localizedDescription,
                peripheralState: PeripheralConnectionSnapshot(peripheral.state),
            ),
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        emit(.servicesDiscovered(id: peripheral.identifier, errorReason: error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        emit(.characteristicsDiscovered(id: peripheral.identifier, errorReason: error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let characteristicUUID = characteristic.uuid.foundationUUID else { return }
        emit(
            .characteristicValueUpdated(
                id: peripheral.identifier,
                serviceUUID: characteristic.service?.uuid.foundationUUID,
                characteristicUUID: characteristicUUID,
                value: characteristic.value ?? Data(),
                errorReason: error?.localizedDescription,
            ),
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let characteristicUUID = characteristic.uuid.foundationUUID else { return }

        var attCode: UInt8?
        var errorReason: String?
        if let error = error as NSError? {
            if error.domain == CBATTErrorDomain {
                let code = error.code
                if code != CBATTError.success.rawValue {
                    if let attCodeValue = UInt8(exactly: code) {
                        attCode = attCodeValue
                    } else {
                        errorReason = error.localizedDescription
                    }
                }
            } else {
                errorReason = error.localizedDescription
            }
        }

        let serviceUUID = characteristic.service?.uuid.foundationUUID
        if serviceUUID == nil, errorReason == nil, attCode == nil {
            errorReason = "Missing service for characteristic"
        }

        emit(
            .characteristicWriteCompleted(
                id: peripheral.identifier,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                errorReason: errorReason,
                attCode: attCode,
            ),
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?,
    ) {
        guard let characteristicUUID = characteristic.uuid.foundationUUID else { return }
        emit(
            .notificationStateUpdated(
                id: peripheral.identifier,
                serviceUUID: characteristic.service?.uuid.foundationUUID,
                characteristicUUID: characteristicUUID,
                errorReason: error?.localizedDescription,
            ),
        )
    }

    private static func discoveredPeripheral(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
    ) -> DiscoveredPeripheral {
        DiscoveredPeripheral(
            id: peripheral.identifier,
            name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .compactMap(\.foundationUUID) ?? [],
        )
    }
}

private extension BluetoothState {
    init(_ state: CBManagerState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}

private extension UUID {
    var cbUUID: CBUUID { CBUUID(nsuuid: self) }
}

private extension CBUUID {
    var foundationUUID: UUID? {
        let uuidString = uuidString
        if uuidString.count == 4 {
            return UUID(uuidString: "0000\(uuidString)-0000-1000-8000-00805F9B34FB")
        }
        if uuidString.count == 8 {
            return UUID(uuidString: "\(uuidString)-0000-1000-8000-00805F9B34FB")
        }
        return UUID(uuidString: uuidString)
    }
}
#endif
