#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

package actor CoreBluetoothCentral: BluetoothCentral {
    private let queue = DispatchQueue(label: "com.bluetoothbikesensor.central")
    private let centralManager: CBCentralManager
    private let delegateBridge: CentralDelegateBridge
    private let delegateEvents: AsyncStream<CentralDelegateEvent>.Continuation

    private var state: BluetoothState = .unknown
    private var pending: [Request: PendingContinuation] = [:]

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let discoveryBroadcaster = StreamBroadcaster<DiscoveredPeripheral>()
    private let eventsBroadcaster = StreamBroadcaster<CentralEvent>()

    package init() {
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
        get async {
            await stateBroadcaster.makeStream()
        }
    }

    package var currentState: BluetoothState {
        get async { state }
    }

    package func startScanning(serviceUUIDs: [UUID]?) async {
        guard state == .poweredOn else { return }
        queue.sync {
            let cbServiceUUIDs = serviceUUIDs?.map(\.cbUUID)
            centralManager.scanForPeripherals(
                withServices: cbServiceUUIDs,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false],
            )
        }
    }

    package func stopScanning() async {
        queue.sync {
            centralManager.stopScan()
        }
    }

    package var discoveries: AsyncStream<DiscoveredPeripheral> {
        get async {
            await discoveryBroadcaster.makeStream()
        }
    }

    package func connect(id: UUID) async throws {
        guard state == .poweredOn else {
            throw BluetoothCentralError.notPoweredOn
        }
        guard delegateBridge.peripheral(for: id) != nil else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let request = Request.connect(id)
                guard storePending(request, continuation: .void(continuation)) else {
                    continuation.resume(
                        throwing: BluetoothCentralError.connectionFailed(
                            id,
                            reason: "Request already in progress",
                        ),
                    )
                    return
                }
                queue.sync {
                    guard let peripheral = delegateBridge.peripheral(for: id) else {
                        resumeVoid(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                        return
                    }
                    centralManager.connect(peripheral, options: nil)
                }
            }
        } onCancel: {
            Task { await self.cancelConnect(id: id) }
        }
    }

    package func disconnect(id: UUID) async throws {
        let peripheralState = queue.sync { () -> CBPeripheralState? in
            guard let peripheral = delegateBridge.peripheral(for: id) else {
                return nil
            }
            return peripheral.state
        }
        guard let peripheralState else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        if peripheralState == .disconnected {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let request = Request.disconnect(id)
            guard storePending(request, continuation: .void(continuation)) else {
                continuation.resume(
                    throwing: BluetoothCentralError.connectionFailed(
                        id,
                        reason: "Request already in progress",
                    ),
                )
                return
            }
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    resumeVoid(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    package var events: AsyncStream<CentralEvent> {
        get async {
            await eventsBroadcaster.makeStream()
        }
    }

    package func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws {
        guard delegateBridge.peripheral(for: id) != nil else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let request = Request.discoverServices(id)
            guard storePending(request, continuation: .void(continuation)) else {
                continuation.resume(
                    throwing: BluetoothCentralError.connectionFailed(
                        id,
                        reason: "Request already in progress",
                    ),
                )
                return
            }
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    resumeVoid(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                let cbServiceUUIDs = serviceUUIDs?.map(\.cbUUID)
                peripheral.discoverServices(cbServiceUUIDs)
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let request = Request.discoverCharacteristics(id)
            guard storePending(request, continuation: .void(continuation)) else {
                continuation.resume(
                    throwing: BluetoothCentralError.connectionFailed(
                        id,
                        reason: "Request already in progress",
                    ),
                )
                return
            }
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    resumeVoid(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard let service = peripheral.services?.first(where: { $0.uuid.foundationUUID == serviceUUID }) else {
                    resumeVoid(request, throwing: BluetoothCentralError.serviceNotFound(id, serviceUUID: serviceUUID))
                    return
                }
                let cbCharacteristicUUIDs = characteristicUUIDs?.map(\.cbUUID)
                peripheral.discoverCharacteristics(cbCharacteristicUUIDs, for: service)
            }
        }

        return queue.sync {
            guard let peripheral = delegateBridge.peripheral(for: id),
                  let service = peripheral.services?.first(where: { $0.uuid.foundationUUID == serviceUUID })
            else {
                return []
            }
            return service.characteristics?.compactMap { $0.uuid.foundationUUID } ?? []
        }
    }

    package func setNotifyValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        enabled: Bool,
    ) async throws {
        let key = GATTRequestKey(
            peripheralID: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let request = Request.setNotify(key)
            guard storePending(request, continuation: .void(continuation)) else {
                continuation.resume(
                    throwing: BluetoothCentralError.connectionFailed(
                        id,
                        reason: "Request already in progress",
                    ),
                )
                return
            }
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    resumeVoid(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard let characteristic = Self.characteristic(
                    on: peripheral,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                ) else {
                    resumeVoid(
                        request,
                        throwing: BluetoothCentralError.characteristicNotFound(
                            id,
                            serviceUUID: serviceUUID,
                            characteristicUUID: characteristicUUID,
                        ),
                    )
                    return
                }
                peripheral.setNotifyValue(enabled, for: characteristic)
            }
        }
    }

    package func readValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) async throws -> Data {
        let key = GATTRequestKey(
            peripheralID: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
        )

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let request = Request.read(key)
            guard storePending(request, continuation: .data(continuation)) else {
                continuation.resume(
                    throwing: BluetoothCentralError.connectionFailed(
                        id,
                        reason: "Request already in progress",
                    ),
                )
                return
            }
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    resumeData(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard let characteristic = Self.characteristic(
                    on: peripheral,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                ) else {
                    resumeData(
                        request,
                        throwing: BluetoothCentralError.characteristicNotFound(
                            id,
                            serviceUUID: serviceUUID,
                            characteristicUUID: characteristicUUID,
                        ),
                    )
                    return
                }
                peripheral.readValue(for: characteristic)
            }
        }
    }

    package func writeValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        value: Data,
    ) async throws {
        let key = GATTRequestKey(
            peripheralID: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let request = Request.write(key)
            guard storePending(request, continuation: .void(continuation)) else {
                continuation.resume(
                    throwing: BluetoothCentralError.connectionFailed(
                        id,
                        reason: "Request already in progress",
                    ),
                )
                return
            }
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    resumeVoid(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard let characteristic = Self.characteristic(
                    on: peripheral,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                ) else {
                    resumeVoid(
                        request,
                        throwing: BluetoothCentralError.characteristicNotFound(
                            id,
                            serviceUUID: serviceUUID,
                            characteristicUUID: characteristicUUID,
                        ),
                    )
                    return
                }
                peripheral.writeValue(value, for: characteristic, type: .withResponse)
            }
        }
    }

    private func cancelConnect(id: UUID) {
        let request = Request.connect(id)
        guard let pendingContinuation = takePending(request) else { return }
        queue.sync {
            guard let peripheral = delegateBridge.peripheral(for: id) else { return }
            centralManager.cancelPeripheralConnection(peripheral)
        }
        switch pendingContinuation {
        case let .void(continuation):
            continuation.resume(throwing: CancellationError())
        case let .data(continuation):
            continuation.resume(throwing: CancellationError())
        }
    }

    private func storePending(_ request: Request, continuation: PendingContinuation) -> Bool {
        if pending[request] != nil {
            return false
        }
        pending[request] = continuation
        return true
    }

    private func takePending(_ request: Request) -> PendingContinuation? {
        pending.removeValue(forKey: request)
    }

    private func resumeVoid(_ request: Request, throwing error: Error) {
        guard let pendingContinuation = takePending(request) else { return }
        switch pendingContinuation {
        case let .void(continuation):
            continuation.resume(throwing: error)
        case let .data(continuation):
            continuation.resume(throwing: error)
        }
    }

    private func resumeVoid(_ request: Request) {
        guard let pendingContinuation = takePending(request) else { return }
        switch pendingContinuation {
        case let .void(continuation):
            continuation.resume()
        case let .data(continuation):
            continuation.resume(throwing: BluetoothCentralError.connectionFailed(
                request.peripheralID,
                reason: "Unexpected pending type",
            ))
        }
    }

    private func resumeData(_ request: Request, returning data: Data) {
        guard let pendingContinuation = takePending(request) else { return }
        switch pendingContinuation {
        case let .data(continuation):
            continuation.resume(returning: data)
        case let .void(continuation):
            continuation.resume(throwing: BluetoothCentralError.connectionFailed(
                request.peripheralID,
                reason: "Unexpected pending type",
            ))
        }
    }

    private func resumeData(_ request: Request, throwing error: Error) {
        resumeVoid(request, throwing: error)
    }

    private func failPendingRequests(for id: UUID, error: Error, resolvingDisconnect: Bool) {
        let keys = pending.keys.filter { $0.peripheralID == id }
        for key in keys {
            if key == .disconnect(id), resolvingDisconnect {
                resumeVoid(key)
            } else {
                resumeVoid(key, throwing: error)
            }
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
            await stateBroadcaster.yield(newState)

        case let .discovered(discovery):
            await discoveryBroadcaster.yield(discovery)

        case let .connected(id):
            resumeVoid(.connect(id))

        case let .failedToConnect(id, reason):
            resumeVoid(
                .connect(id),
                throwing: BluetoothCentralError.connectionFailed(id, reason: reason),
            )

        case let .disconnected(id, reason):
            await eventsBroadcaster.yield(.disconnected(peripheralID: id))
            let disconnectError = BluetoothCentralError.disconnected(id, reason: reason)
            failPendingRequests(for: id, error: disconnectError, resolvingDisconnect: true)

        case let .servicesDiscovered(id, errorReason):
            if let errorReason {
                resumeVoid(
                    .discoverServices(id),
                    throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason),
                )
                return
            }
            resumeVoid(.discoverServices(id))

        case let .characteristicsDiscovered(id, errorReason):
            if let errorReason {
                resumeVoid(
                    .discoverCharacteristics(id),
                    throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason),
                )
                return
            }
            resumeVoid(.discoverCharacteristics(id))

        case let .characteristicValueUpdated(id, serviceUUID, characteristicUUID, value, errorReason):
            let key = GATTRequestKey(
                peripheralID: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
            )
            if let errorReason {
                resumeData(
                    .read(key),
                    throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason),
                )
                return
            }
            await eventsBroadcaster.yield(
                .valueUpdated(
                    peripheralID: id,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    value: value,
                ),
            )
            resumeData(.read(key), returning: value)

        case let .characteristicWriteCompleted(id, serviceUUID, characteristicUUID, errorReason, attCode):
            guard let serviceUUID else {
                let error = BluetoothCentralError.connectionFailed(
                    id,
                    reason: errorReason ?? "Missing service for characteristic",
                )
                let writeKeys = pending.keys.filter {
                    if case let .write(key) = $0 {
                        return key.peripheralID == id && key.characteristicUUID == characteristicUUID
                    }
                    return false
                }
                for key in writeKeys {
                    resumeVoid(key, throwing: error)
                }
                return
            }

            let key = GATTRequestKey(
                peripheralID: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
            )
            let request = Request.write(key)
            if let attCode {
                resumeVoid(request, throwing: BluetoothCentralError.attApplicationError(code: attCode))
                return
            }
            if let errorReason {
                resumeVoid(
                    request,
                    throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason),
                )
                return
            }
            resumeVoid(request)

        case let .notificationStateUpdated(id, serviceUUID, characteristicUUID, _, errorReason):
            let key = GATTRequestKey(
                peripheralID: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
            )
            let request = Request.setNotify(key)
            if let errorReason {
                resumeVoid(
                    request,
                    throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason),
                )
                return
            }
            resumeVoid(request)
        }
    }
}

private enum Request: Hashable {
    case connect(UUID)
    case disconnect(UUID)
    case discoverServices(UUID)
    case discoverCharacteristics(UUID)
    case read(GATTRequestKey)
    case write(GATTRequestKey)
    case setNotify(GATTRequestKey)

    var peripheralID: UUID {
        switch self {
        case let .connect(id), let .disconnect(id), let .discoverServices(id), let .discoverCharacteristics(id):
            id
        case let .read(key), let .write(key), let .setNotify(key):
            key.peripheralID
        }
    }
}

private enum PendingContinuation {
    case void(CheckedContinuation<Void, Error>)
    case data(CheckedContinuation<Data, Error>)
}

private struct GATTRequestKey: Hashable, Sendable {
    let peripheralID: UUID
    let serviceUUID: UUID
    let characteristicUUID: UUID
}

private enum CentralDelegateEvent: Sendable {
    case stateUpdated(BluetoothState)
    case discovered(DiscoveredPeripheral)
    case connected(id: UUID)
    case failedToConnect(id: UUID, reason: String)
    case disconnected(id: UUID, reason: String?)
    case servicesDiscovered(id: UUID, errorReason: String?)
    case characteristicsDiscovered(id: UUID, errorReason: String?)
    case characteristicValueUpdated(
        id: UUID,
        serviceUUID: UUID,
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
        serviceUUID: UUID,
        characteristicUUID: UUID,
        isNotifying: Bool,
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
                DiscoveredPeripheral(
                    id: id,
                    name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                    manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                    serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                        .compactMap(\.foundationUUID) ?? [],
                ),
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
            ),
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?,
    ) {
        emit(.disconnected(id: peripheral.identifier, reason: error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        emit(
            .servicesDiscovered(
                id: peripheral.identifier,
                errorReason: error?.localizedDescription,
            ),
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        emit(
            .characteristicsDiscovered(
                id: peripheral.identifier,
                errorReason: error?.localizedDescription,
            ),
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let serviceUUID = characteristic.service?.uuid.foundationUUID,
              let characteristicUUID = characteristic.uuid.foundationUUID
        else {
            return
        }
        emit(
            .characteristicValueUpdated(
                id: peripheral.identifier,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                value: characteristic.value ?? Data(),
                errorReason: error?.localizedDescription,
            ),
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
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
                characteristicUUID: characteristic.uuid.foundationUUID ?? UUID(),
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
        guard let serviceUUID = characteristic.service?.uuid.foundationUUID,
              let characteristicUUID = characteristic.uuid.foundationUUID
        else {
            return
        }
        emit(
            .notificationStateUpdated(
                id: peripheral.identifier,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                isNotifying: characteristic.isNotifying,
                errorReason: error?.localizedDescription,
            ),
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

private extension UUID {
    var cbUUID: CBUUID {
        CBUUID(nsuuid: self)
    }
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
