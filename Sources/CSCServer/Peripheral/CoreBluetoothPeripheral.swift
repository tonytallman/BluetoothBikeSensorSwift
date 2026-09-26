#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Production `BluetoothPeripheral` backed by `CBPeripheralManager`.
///
/// Delegate callbacks reach the actor through one FIFO channel, so ``events`` preserves
/// callback order. Leaving `.poweredOn` fails an in-flight `add` or `startAdvertising` with
/// `.notPoweredOn` and drops stored centrals and ATT requests. While not powered on, manager
/// calls are skipped: `stopAdvertising` does nothing, service removal updates bookkeeping only,
/// and `respond` drops the request and throws.
///
/// Queue crossing and actor isolation are documented in `project.md` (CSC Server).
/// Manager queue: `com.bluetoothbikesensor.peripheral`.
package actor CoreBluetoothPeripheral: BluetoothPeripheral {
    private let queue = DispatchQueue(label: "com.bluetoothbikesensor.peripheral")
    private let peripheralManager: CBPeripheralManager
    private let delegateBridge: PeripheralDelegateBridge
    private let inFlightBox: InFlightContinuationBox
    private let delegateEvents: AsyncStream<PeripheralDelegateEvent>.Continuation

    private var state: BluetoothState = .unknown
    private var lossCount = 0

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let eventBroadcaster = StreamBroadcaster<PeripheralEvent>()

    package init() {
        let bridge = PeripheralDelegateBridge()
        let box = InFlightContinuationBox()
        let (stream, continuation) = AsyncStream.makeStream(of: PeripheralDelegateEvent.self)
        delegateBridge = bridge
        inFlightBox = box
        delegateEvents = continuation
        let manager = CBPeripheralManager(delegate: bridge, queue: queue)
        peripheralManager = manager
        bridge.bind { event in
            continuation.yield(event)
        }
        bridge.replayCurrentState(from: manager, on: queue)
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    deinit {
        delegateBridge.clearHandler()
        delegateEvents.finish()
        inFlightBox.failAll(with: BluetoothPeripheralError.peripheralInvalidated)
    }

    package var currentState: BluetoothState {
        get async { state }
    }

    package var stateUpdates: AsyncStream<BluetoothState> {
        get async {
            await stateBroadcaster.makeStream()
        }
    }

    package var powerLossCount: Int {
        get async { lossCount }
    }

    package var isAdvertising: Bool {
        get async {
            queue.sync {
                peripheralManager.isAdvertising
            }
        }
    }

    package func add(_ service: PeripheralService) async throws {
        try PeripheralServiceValidation.validate(service)

        guard state == .poweredOn else {
            throw BluetoothPeripheralError.notPoweredOn
        }
        guard !inFlightBox.hasAddInProgress else {
            throw BluetoothPeripheralError.addInProgress
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            inFlightBox.setAddContinuation(continuation)
            queue.sync {
                let (cbService, characteristicPairs) = Self.makeCBService(from: service)
                delegateBridge.store(service: cbService, for: service.uuid)
                for pair in characteristicPairs {
                    delegateBridge.store(
                        characteristic: pair.characteristic,
                        serviceUUID: service.uuid,
                        characteristicUUID: pair.uuid,
                    )
                }
                peripheralManager.add(cbService)
            }
        }
    }

    package func removeService(uuid: UUID) async throws {
        let callsManager = state == .poweredOn
        try queue.sync {
            guard let cbService = delegateBridge.removeService(for: uuid) else {
                throw BluetoothPeripheralError.serviceNotFound
            }
            if callsManager {
                peripheralManager.remove(cbService)
            }
        }
    }

    package func startAdvertising(_ advertisement: Advertisement) async throws {
        guard state == .poweredOn else {
            throw BluetoothPeripheralError.notPoweredOn
        }
        guard !inFlightBox.hasAdvertisingInProgress else {
            throw BluetoothPeripheralError.advertisingInProgress
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            inFlightBox.setAdvertisingContinuation(continuation)
            queue.sync {
                var advertisementData: [String: Any] = [:]
                if let localName = advertisement.localName {
                    advertisementData[CBAdvertisementDataLocalNameKey] = localName
                }
                if !advertisement.serviceUUIDs.isEmpty {
                    advertisementData[CBAdvertisementDataServiceUUIDsKey] = advertisement.serviceUUIDs.map {
                        $0.cbUUID
                    }
                }
                peripheralManager.startAdvertising(advertisementData)
            }
        }
    }

    package func stopAdvertising() async {
        guard state == .poweredOn else {
            return
        }
        queue.sync {
            peripheralManager.stopAdvertising()
        }
    }

    package var events: AsyncStream<PeripheralEvent> {
        get async {
            await eventBroadcaster.makeStream()
        }
    }

    package func respond(
        to requestID: UUID,
        with result: ATTResult,
        value: Data?,
    ) async throws {
        guard let requestKind = delegateBridge.requestKind(for: requestID) else {
            throw BluetoothPeripheralError.unknownRequest
        }

        guard state == .poweredOn else {
            delegateBridge.removeRequest(for: requestID)
            throw BluetoothPeripheralError.notPoweredOn
        }

        try RespondPayloadValidation.validate(
            requestKind: requestKind == .read ? .read : .write,
            result: result,
            value: value,
        )

        try queue.sync {
            guard let request = delegateBridge.removeRequest(for: requestID) else {
                throw BluetoothPeripheralError.unknownRequest
            }

            let cbResult: CBATTError.Code
            switch result {
            case .success:
                cbResult = .success
                if case .read = requestKind {
                    request.value = value
                }
            case let .error(code):
                cbResult = CBATTError.Code(rawValue: Int(code))!
            }

            peripheralManager.respond(to: request, withResult: cbResult)
        }
    }

    package func updateValue(
        _ value: Data,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        onSubscribedCentrals centralIDs: [UUID]?,
    ) async throws -> Bool {
        guard state == .poweredOn else {
            throw BluetoothPeripheralError.notPoweredOn
        }

        return try queue.sync {
            guard let characteristic = delegateBridge.characteristic(
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
            ) else {
                throw BluetoothPeripheralError.characteristicNotFound
            }

            let centrals: [CBCentral]?
            if let centralIDs {
                centrals = centralIDs.compactMap { delegateBridge.central(for: $0) }
            } else {
                centrals = nil
            }

            return peripheralManager.updateValue(
                value,
                for: characteristic,
                onSubscribedCentrals: centrals,
            )
        }
    }

    private func handle(_ event: PeripheralDelegateEvent) async {
        switch event {
        case let .stateUpdated(newState):
            state = newState
            if newState != .poweredOn {
                lossCount += 1
                inFlightBox.failAll(with: BluetoothPeripheralError.notPoweredOn)
                delegateBridge.removeCentralsAndRequests()
            }
            await eventBroadcaster.yield(.stateUpdated(newState))
            await stateBroadcaster.yield(newState)

        case let .serviceAdded(serviceUUID, errorReason):
            let continuation = inFlightBox.takeAddContinuation()
            if let errorReason {
                delegateBridge.removeService(for: serviceUUID)
                continuation?.resume(
                    throwing: BluetoothPeripheralError.addServiceFailed(
                        serviceUUID: serviceUUID,
                        reason: errorReason,
                    ),
                )
            } else {
                continuation?.resume()
            }

        case let .advertisingStarted(errorReason):
            let continuation = inFlightBox.takeAdvertisingContinuation()
            if let errorReason {
                continuation?.resume(
                    throwing: BluetoothPeripheralError.advertisingFailed(reason: errorReason),
                )
            } else {
                continuation?.resume()
            }

        case let .read(request):
            await eventBroadcaster.yield(.read(request))

        case let .writeTransaction(transaction):
            await eventBroadcaster.yield(.writeTransaction(transaction))

        case let .subscription(change):
            await eventBroadcaster.yield(.subscription(change))

        case .readyToUpdateSubscribers:
            await eventBroadcaster.yield(.readyToUpdateSubscribers)
        }
    }

    private static func makeCBService(
        from service: PeripheralService,
    ) -> (CBMutableService, [(uuid: UUID, characteristic: CBMutableCharacteristic)]) {
        let cbService = CBMutableService(
            type: service.uuid.cbUUID,
            primary: service.isPrimary,
        )
        let characteristicPairs = service.characteristics.map { characteristic in
            let cbCharacteristic = makeCBCharacteristic(from: characteristic)
            return (uuid: characteristic.uuid, characteristic: cbCharacteristic)
        }
        cbService.characteristics = characteristicPairs.map(\.characteristic)
        return (cbService, characteristicPairs)
    }

    private static func makeCBCharacteristic(from characteristic: PeripheralCharacteristic) -> CBMutableCharacteristic {
        CBMutableCharacteristic(
            type: characteristic.uuid.cbUUID,
            properties: cbProperties(from: characteristic.properties),
            value: characteristic.value,
            permissions: cbPermissions(from: characteristic.permissions),
        )
    }

    private static func cbProperties(from properties: CharacteristicProperties) -> CBCharacteristicProperties {
        var result: CBCharacteristicProperties = []
        if properties.contains(.read) {
            result.insert(.read)
        }
        if properties.contains(.write) {
            result.insert(.write)
        }
        if properties.contains(.writeWithoutResponse) {
            result.insert(.writeWithoutResponse)
        }
        if properties.contains(.notify) {
            result.insert(.notify)
        }
        if properties.contains(.indicate) {
            result.insert(.indicate)
        }
        return result
    }

    private static func cbPermissions(from permissions: CharacteristicPermissions) -> CBAttributePermissions {
        var result: CBAttributePermissions = []
        if permissions.contains(.readable) {
            result.insert(.readable)
        }
        if permissions.contains(.writeable) {
            result.insert(.writeable)
        }
        return result
    }
}

private enum StoredRequestKind: Sendable {
    case read
    case write
}

private enum PeripheralDelegateEvent: Sendable {
    case stateUpdated(BluetoothState)
    case serviceAdded(serviceUUID: UUID, errorReason: String?)
    case advertisingStarted(errorReason: String?)
    case read(PeripheralReadRequest)
    case writeTransaction(PeripheralWriteTransaction)
    case subscription(SubscriptionChange)
    case readyToUpdateSubscribers
}

private final class InFlightContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var addContinuation: CheckedContinuation<Void, Error>?
    private var advertisingContinuation: CheckedContinuation<Void, Error>?

    var hasAddInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return addContinuation != nil
    }

    var hasAdvertisingInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return advertisingContinuation != nil
    }

    func setAddContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        addContinuation = continuation
        lock.unlock()
    }

    func setAdvertisingContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        advertisingContinuation = continuation
        lock.unlock()
    }

    func takeAddContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = addContinuation
        addContinuation = nil
        return continuation
    }

    func takeAdvertisingContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = advertisingContinuation
        advertisingContinuation = nil
        return continuation
    }

    func failAll(with error: Error) {
        lock.lock()
        let add = addContinuation
        let advertising = advertisingContinuation
        addContinuation = nil
        advertisingContinuation = nil
        lock.unlock()

        add?.resume(throwing: error)
        advertising?.resume(throwing: error)
    }
}

private final class PeripheralDelegateBridge: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (PeripheralDelegateEvent) -> Void)?
    private var services: [UUID: CBMutableService] = [:]
    private var characteristics: [CharacteristicKey: CBMutableCharacteristic] = [:]
    private var centrals: [UUID: CBCentral] = [:]
    private var attRequests: [UUID: CBATTRequest] = [:]
    private var attRequestKinds: [UUID: StoredRequestKind] = [:]

    func bind(handler: @escaping @Sendable (PeripheralDelegateEvent) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func replayCurrentState(from peripheral: CBPeripheralManager, on queue: DispatchQueue) {
        let state = queue.sync {
            BluetoothState(peripheral.state)
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.emit(.stateUpdated(state))
        }
    }

    func clearHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func store(service: CBMutableService, for uuid: UUID) {
        lock.lock()
        services[uuid] = service
        lock.unlock()
    }

    @discardableResult
    func removeService(for uuid: UUID) -> CBMutableService? {
        lock.lock()
        defer { lock.unlock() }
        characteristics = characteristics.filter { $0.key.serviceUUID != uuid }
        return services.removeValue(forKey: uuid)
    }

    func removeAllServices() {
        lock.lock()
        services.removeAll()
        characteristics.removeAll()
        lock.unlock()
    }

    func store(
        characteristic: CBMutableCharacteristic,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) {
        lock.lock()
        characteristics[CharacteristicKey(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)] =
            characteristic
        lock.unlock()
    }

    func characteristic(serviceUUID: UUID, characteristicUUID: UUID) -> CBMutableCharacteristic? {
        lock.lock()
        defer { lock.unlock() }
        return characteristics[CharacteristicKey(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)]
    }

    func central(for id: UUID) -> CBCentral? {
        lock.lock()
        defer { lock.unlock() }
        return centrals[id]
    }

    func requestKind(for id: UUID) -> StoredRequestKind? {
        lock.lock()
        defer { lock.unlock() }
        return attRequestKinds[id]
    }

    func removeCentralsAndRequests() {
        lock.lock()
        centrals.removeAll()
        attRequests.removeAll()
        attRequestKinds.removeAll()
        lock.unlock()
    }

    @discardableResult
    func removeRequest(for id: UUID) -> CBATTRequest? {
        lock.lock()
        defer { lock.unlock() }
        attRequestKinds.removeValue(forKey: id)
        return attRequests.removeValue(forKey: id)
    }

    private func storeReadRequest(_ request: CBATTRequest, id: UUID) {
        lock.lock()
        attRequests[id] = request
        attRequestKinds[id] = .read
        lock.unlock()
    }

    private func storeWriteRequest(_ request: CBATTRequest, id: UUID) {
        lock.lock()
        attRequests[id] = request
        attRequestKinds[id] = .write
        lock.unlock()
    }

    private func emit(_ event: PeripheralDelegateEvent) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(event)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        emit(.stateUpdated(BluetoothState(peripheral.state)))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard let serviceUUID = service.uuid.foundationUUID else {
            return
        }
        emit(.serviceAdded(serviceUUID: serviceUUID, errorReason: error?.localizedDescription))
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        emit(.advertisingStarted(errorReason: error?.localizedDescription))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        lock.lock()
        centrals[request.central.identifier] = request.central
        lock.unlock()

        let characteristic = request.characteristic
        guard
            let service = characteristic.service,
            let serviceUUID = service.uuid.foundationUUID,
            let characteristicUUID = characteristic.uuid.foundationUUID
        else {
            peripheral.respond(to: request, withResult: .invalidHandle)
            return
        }

        let requestID = UUID()
        storeReadRequest(request, id: requestID)
        emit(
            .read(
                PeripheralReadRequest(
                    id: requestID,
                    centralID: request.central.identifier,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    offset: request.offset,
                ),
            ),
        )
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let firstRequest = requests.first else {
            return
        }

        lock.lock()
        for request in requests {
            centrals[request.central.identifier] = request.central
        }
        lock.unlock()

        var writeRequests: [PeripheralWriteRequest] = []
        for request in requests {
            let characteristic = request.characteristic
            guard
                let service = characteristic.service,
                let serviceUUID = service.uuid.foundationUUID,
                let characteristicUUID = characteristic.uuid.foundationUUID
            else {
                peripheral.respond(to: firstRequest, withResult: .invalidHandle)
                return
            }

            writeRequests.append(
                PeripheralWriteRequest(
                    centralID: request.central.identifier,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    offset: request.offset,
                    value: request.value ?? Data(),
                ),
            )
        }

        let transactionID = UUID()
        storeWriteRequest(firstRequest, id: transactionID)
        emit(
            .writeTransaction(
                PeripheralWriteTransaction(
                    id: transactionID,
                    requests: writeRequests,
                ),
            ),
        )
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic,
    ) {
        emitSubscriptionChange(central: central, characteristic: characteristic, subscribed: true)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic,
    ) {
        emitSubscriptionChange(central: central, characteristic: characteristic, subscribed: false)
    }

    private func emitSubscriptionChange(
        central: CBCentral,
        characteristic: CBCharacteristic,
        subscribed: Bool,
    ) {
        lock.lock()
        centrals[central.identifier] = central
        lock.unlock()

        guard let identity = characteristicIdentity(characteristic) else {
            return
        }

        let change: SubscriptionChange = subscribed
            ? .subscribed(
                centralID: central.identifier,
                serviceUUID: identity.serviceUUID,
                characteristicUUID: identity.characteristicUUID,
            )
            : .unsubscribed(
                centralID: central.identifier,
                serviceUUID: identity.serviceUUID,
                characteristicUUID: identity.characteristicUUID,
            )
        emit(.subscription(change))
    }

    private func characteristicIdentity(
        _ characteristic: CBCharacteristic,
    ) -> (serviceUUID: UUID, characteristicUUID: UUID)? {
        guard
            let service = characteristic.service,
            let serviceUUID = service.uuid.foundationUUID,
            let characteristicUUID = characteristic.uuid.foundationUUID
        else {
            return nil
        }
        return (serviceUUID, characteristicUUID)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        emit(.readyToUpdateSubscribers)
    }
}

private struct CharacteristicKey: Hashable, Sendable {
    let serviceUUID: UUID
    let characteristicUUID: UUID
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
