import Foundation

/// Controllable `BluetoothPeripheral` for unit tests. Not intended for production use.
///
/// Inbound events are yielded on one ``events`` stream in call order. When the state is not
/// `.poweredOn`, `add`, `startAdvertising`, `updateValue`, and `respond` throw
/// `BluetoothPeripheralError.notPoweredOn` and record nothing. Leaving `.poweredOn` stops
/// advertising and increments ``powerLossCount`` but keeps added services.
///
/// A held `add` or `startAdvertising` re-checks the state when released: if the state is no
/// longer `.poweredOn`, the call throws `.notPoweredOn` and records nothing. A held
/// `updateValue` records its attempt before parking and returns the accepted value read at
/// release time.
package actor FakeBluetoothPeripheral: BluetoothPeripheral {
    package enum RecordedCall: Sendable, Equatable {
        case add(PeripheralService)
        case removeService(uuid: UUID)
        case startAdvertising(serviceUUIDs: [UUID])
        case stopAdvertising
        case updateValue(
            value: Data,
            serviceUUID: UUID,
            characteristicUUID: UUID,
            onSubscribedCentrals: [UUID]?,
        )
        case respond(id: UUID, result: ATTResult, value: Data?)
    }

    private struct Hold {
        var isHeld = false
        var parked: [CheckedContinuation<Void, Never>] = []

        mutating func park(_ continuation: CheckedContinuation<Void, Never>) {
            parked.append(continuation)
        }

        mutating func release() {
            isHeld = false
            let continuations = parked
            parked.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
        }
    }

    package enum HeldCall: Sendable {
        case add
        case advertise
        case updateValue
        case respond
    }

    private var state: BluetoothState
    private var advertising = false
    private var lossCount = 0
    private var services: [UUID: PeripheralService] = [:]
    private var outstandingRequestIDs: Set<UUID> = []

    private var shouldFailNextAdd = false
    private var shouldFailNextAdvertise = false
    private var nextUpdateValueAccepted = true
    private var holds: [HeldCall: Hold] = [
        .add: Hold(),
        .advertise: Hold(),
        .updateValue: Hold(),
        .respond: Hold(),
    ]

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let eventBroadcaster = StreamBroadcaster<PeripheralEvent>()

    private var conditionWaiters: [(isMet: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    private var stateUpdatesSubscriberCount = 0

    package private(set) var recordedCalls: [RecordedCall] = []

    package init(initialState: BluetoothState = .poweredOn) {
        state = initialState
    }

    package var currentState: BluetoothState {
        get async { state }
    }

    package var stateUpdates: AsyncStream<BluetoothState> {
        get async {
            stateUpdatesSubscriberCount += 1
            let stream = await stateBroadcaster.makeStream()
            resumeConditionWaiters()
            return stream
        }
    }

    /// Number of transitions to a state other than `.poweredOn`.
    package var powerLossCount: Int {
        get async { lossCount }
    }

    package var isAdvertising: Bool {
        get async { advertising }
    }

    package var events: AsyncStream<PeripheralEvent> {
        get async {
            await eventBroadcaster.makeStream()
        }
    }

    package func add(_ service: PeripheralService) async throws {
        try requirePoweredOn()

        if holdState(.add).isHeld {
            await park(.add)
            try requirePoweredOn()
        }

        if shouldFailNextAdd {
            shouldFailNextAdd = false
            appendRecordedCall(.add(service))
            throw BluetoothPeripheralError.addServiceFailed(
                serviceUUID: service.uuid,
                reason: "Test failure",
            )
        }

        appendRecordedCall(.add(service))
        services[service.uuid] = service
    }

    package func removeService(uuid: UUID) async throws {
        guard services[uuid] != nil else {
            throw BluetoothPeripheralError.serviceNotFound
        }

        appendRecordedCall(.removeService(uuid: uuid))
        services.removeValue(forKey: uuid)
    }

    package func startAdvertising(serviceUUIDs: [UUID]) async throws {
        try requirePoweredOn()

        if holdState(.advertise).isHeld {
            await park(.advertise)
            try requirePoweredOn()
        }

        appendRecordedCall(.startAdvertising(serviceUUIDs: serviceUUIDs))

        if shouldFailNextAdvertise {
            shouldFailNextAdvertise = false
            throw BluetoothPeripheralError.advertisingFailed(reason: "Test failure")
        }

        advertising = true
    }

    package func stopAdvertising() async {
        appendRecordedCall(.stopAdvertising)
        advertising = false
    }

    package func respond(
        to requestID: UUID,
        with result: ATTResult,
        value: Data?,
    ) async throws {
        guard outstandingRequestIDs.contains(requestID) else {
            throw BluetoothPeripheralError.unknownRequest
        }

        guard state == .poweredOn else {
            outstandingRequestIDs.remove(requestID)
            throw BluetoothPeripheralError.notPoweredOn
        }

        if holdState(.respond).isHeld {
            await park(.respond)
            try requirePoweredOn()
        }

        appendRecordedCall(.respond(id: requestID, result: result, value: value))
        outstandingRequestIDs.remove(requestID)
    }

    package func updateValue(
        _ value: Data,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        onSubscribedCentrals centralIDs: [UUID]?,
    ) async throws -> Bool {
        try requirePoweredOn()
        guard hasCharacteristic(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID) else {
            throw BluetoothPeripheralError.characteristicNotFound
        }

        appendRecordedCall(
            .updateValue(
                value: value,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                onSubscribedCentrals: centralIDs,
            ),
        )

        if holdState(.updateValue).isHeld {
            await park(.updateValue)
        }
        return nextUpdateValueAccepted
    }

    /// Sets the state and yields `.stateUpdated` on ``events`` and on ``stateUpdates``.
    ///
    /// Leaving `.poweredOn` stops advertising and increments ``powerLossCount``. Added services
    /// and held calls are left alone.
    package func setState(_ newState: BluetoothState) async {
        state = newState
        if newState != .poweredOn {
            advertising = false
            lossCount += 1
        }
        await eventBroadcaster.yield(.stateUpdated(newState))
        await stateBroadcaster.yield(newState)
    }

    package func emitRead(_ request: PeripheralReadRequest) async {
        outstandingRequestIDs.insert(request.id)
        await eventBroadcaster.yield(.read(request))
    }

    package func emitWriteTransaction(_ transaction: PeripheralWriteTransaction) async {
        outstandingRequestIDs.insert(transaction.id)
        await eventBroadcaster.yield(.writeTransaction(transaction))
    }

    package func emitSubscription(_ change: SubscriptionChange) async {
        await eventBroadcaster.yield(.subscription(change))
    }

    package func emitReadyToUpdateSubscribers() async {
        await eventBroadcaster.yield(.readyToUpdateSubscribers)
    }

    package func failNextAdd() {
        shouldFailNextAdd = true
    }

    package func failNextAdvertise() {
        shouldFailNextAdvertise = true
    }

    package func setNextUpdateValueAccepted(_ accepted: Bool) {
        nextUpdateValueAccepted = accepted
    }

    package func hold(_ call: HeldCall) {
        mutateHold(call) { $0.isHeld = true }
    }

    package func release(_ call: HeldCall) {
        mutateHold(call) { $0.release() }
    }

    package func waitUntil(_ isMet: @escaping () -> Bool) async {
        if isMet() {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conditionWaiters.append((isMet, continuation))
            resumeConditionWaiters()
        }
    }

    package func waitUntilHeld(_ call: HeldCall) async {
        await waitUntil { !self.holdState(call).parked.isEmpty }
    }

    package func waitUntilEventSubscriberCount(_ count: Int) async {
        await eventBroadcaster.waitUntilSubscriberCount(count)
    }

    package func waitForRecordedCall(
        where predicate: @escaping @Sendable (RecordedCall) -> Bool,
    ) async {
        await waitUntil { self.recordedCalls.contains(where: predicate) }
    }

    package func waitForStateUpdatesSubscriber() async {
        await waitUntil { self.stateUpdatesSubscriberCount > 0 }
    }

    package func waitUntilRecordedCallsSatisfy(
        _ predicate: @escaping @Sendable ([RecordedCall]) -> Bool,
    ) async {
        await waitUntil { predicate(self.recordedCalls) }
    }

    private func requirePoweredOn() throws {
        guard state == .poweredOn else {
            throw BluetoothPeripheralError.notPoweredOn
        }
    }

    private func holdState(_ call: HeldCall) -> Hold {
        holds[call]!
    }

    private func mutateHold(_ call: HeldCall, _ mutate: (inout Hold) -> Void) {
        var hold = holds[call]!
        mutate(&hold)
        holds[call] = hold
        resumeConditionWaiters()
    }

    private func park(_ call: HeldCall) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            mutateHold(call) { $0.park(continuation) }
        }
    }

    private func resumeConditionWaiters() {
        var remaining: [(isMet: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in conditionWaiters {
            if waiter.isMet() {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        conditionWaiters = remaining
    }

    private func appendRecordedCall(_ call: RecordedCall) {
        recordedCalls.append(call)
        resumeConditionWaiters()
    }

    private func hasCharacteristic(serviceUUID: UUID, characteristicUUID: UUID) -> Bool {
        guard let service = services[serviceUUID] else {
            return false
        }
        return service.characteristics.contains { $0.uuid == characteristicUUID }
    }
}
