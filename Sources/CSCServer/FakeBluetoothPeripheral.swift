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
    package enum UpdateValueCentralFilter: Sendable, Equatable {
        case all
        case only([UUID])
    }

    package enum RecordedCall: Sendable, Equatable {
        case add(PeripheralService)
        case removeService(uuid: UUID)
        case removeAllServices
        case startAdvertising(Advertisement)
        case stopAdvertising
        case updateValue(
            value: Data,
            serviceUUID: UUID,
            characteristicUUID: UUID,
            centralIDs: UpdateValueCentralFilter,
        )
        case respond(id: UUID, result: ATTResult, value: Data?)
    }

    private struct Hold {
        var isHeld = false
        var parked: [CheckedContinuation<Void, Never>] = []
        var parkedWaiters: [CheckedContinuation<Void, Never>] = []

        mutating func park(_ continuation: CheckedContinuation<Void, Never>) {
            parked.append(continuation)
            let waiters = parkedWaiters
            parkedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
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

    private enum HoldKind {
        case add
        case advertise
        case updateValue
    }

    private var state: BluetoothState
    private var advertising = false
    private var lossCount = 0
    private var services: [UUID: PeripheralService] = [:]
    private var outstandingReadRequestIDs: Set<UUID> = []
    private var outstandingWriteTransactionIDs: Set<UUID> = []

    private var shouldFailNextAdd = false
    private var shouldFailNextAdvertise = false
    private var nextUpdateValueAccepted = true
    private var addHold = Hold()
    private var advertiseHold = Hold()
    private var updateValueHold = Hold()

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let eventBroadcaster = StreamBroadcaster<PeripheralEvent>()

    private struct RecordedCallWaiter {
        let predicate: @Sendable (RecordedCall) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct RecordedCallsWaiter {
        let predicate: @Sendable ([RecordedCall]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private var recordedCallWaiters: [RecordedCallWaiter] = []
    private var recordedCallsWaiters: [RecordedCallsWaiter] = []
    private var stateUpdatesSubscriberWaiters: [CheckedContinuation<Void, Never>] = []
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
            resumeStateUpdatesSubscriberWaiters()
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
        try PeripheralServiceValidation.validate(service)
        try requirePoweredOn()

        if addHold.isHeld {
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

    package func removeAllServices() async {
        appendRecordedCall(.removeAllServices)
        services.removeAll()
    }

    package func startAdvertising(_ advertisement: Advertisement) async throws {
        try requirePoweredOn()

        if advertiseHold.isHeld {
            await park(.advertise)
            try requirePoweredOn()
        }

        appendRecordedCall(.startAdvertising(advertisement))

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
        let isRead = outstandingReadRequestIDs.contains(requestID)
        let isWrite = outstandingWriteTransactionIDs.contains(requestID)

        guard isRead || isWrite else {
            throw BluetoothPeripheralError.unknownRequest
        }

        guard state == .poweredOn else {
            outstandingReadRequestIDs.remove(requestID)
            outstandingWriteTransactionIDs.remove(requestID)
            throw BluetoothPeripheralError.notPoweredOn
        }

        if isRead {
            switch result {
            case .success:
                guard let value else {
                    throw BluetoothPeripheralError.missingReadValue
                }
            case .error:
                guard value == nil else {
                    throw BluetoothPeripheralError.unexpectedResponseValue
                }
            }
        } else {
            guard value == nil else {
                throw BluetoothPeripheralError.unexpectedResponseValue
            }
        }

        appendRecordedCall(.respond(id: requestID, result: result, value: value))
        outstandingReadRequestIDs.remove(requestID)
        outstandingWriteTransactionIDs.remove(requestID)
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

        let filter: UpdateValueCentralFilter
        if let centralIDs {
            filter = .only(centralIDs)
        } else {
            filter = .all
        }

        appendRecordedCall(
            .updateValue(
                value: value,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                centralIDs: filter,
            ),
        )

        if updateValueHold.isHeld {
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
        outstandingReadRequestIDs.insert(request.id)
        await eventBroadcaster.yield(.read(request))
    }

    package func emitWriteTransaction(_ transaction: PeripheralWriteTransaction) async {
        outstandingWriteTransactionIDs.insert(transaction.id)
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

    /// Parks every `add` until ``releaseAdd()``.
    package func holdNextAdd() {
        addHold.isHeld = true
    }

    package func releaseAdd() {
        addHold.release()
    }

    package func waitUntilAddHeld() async {
        await waitUntilParked(.add)
    }

    /// Parks every `startAdvertising` until ``releaseAdvertise()``.
    package func holdNextAdvertise() {
        advertiseHold.isHeld = true
    }

    package func releaseAdvertise() {
        advertiseHold.release()
    }

    package func waitUntilAdvertiseHeld() async {
        await waitUntilParked(.advertise)
    }

    /// Parks every `updateValue` after it is recorded, until ``releaseUpdateValue()``.
    package func holdNextUpdateValue() {
        updateValueHold.isHeld = true
    }

    package func releaseUpdateValue() {
        updateValueHold.release()
    }

    package func waitUntilUpdateValueHeld() async {
        await waitUntilParked(.updateValue)
    }

    package func waitUntilEventSubscriberCount(_ count: Int) async {
        await eventBroadcaster.waitUntilSubscriberCount(count)
    }

    package func waitForRecordedCall(
        where predicate: @escaping @Sendable (RecordedCall) -> Bool,
    ) async {
        if recordedCalls.contains(where: predicate) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recordedCallWaiters.append(
                RecordedCallWaiter(predicate: predicate, continuation: continuation),
            )
            resumeRecordedCallWaiters()
        }
    }

    package func waitForStateUpdatesSubscriber() async {
        if stateUpdatesSubscriberCount > 0 {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateUpdatesSubscriberWaiters.append(continuation)
        }
    }

    package func waitUntilRecordedCallsSatisfy(
        _ predicate: @escaping @Sendable ([RecordedCall]) -> Bool,
    ) async {
        if predicate(recordedCalls) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recordedCallsWaiters.append(
                RecordedCallsWaiter(predicate: predicate, continuation: continuation),
            )
            resumeRecordedCallsWaiters()
        }
    }

    private func requirePoweredOn() throws {
        guard state == .poweredOn else {
            throw BluetoothPeripheralError.notPoweredOn
        }
    }

    private func park(_ kind: HoldKind) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            switch kind {
            case .add:
                addHold.park(continuation)
            case .advertise:
                advertiseHold.park(continuation)
            case .updateValue:
                updateValueHold.park(continuation)
            }
        }
    }

    private func waitUntilParked(_ kind: HoldKind) async {
        let isParked: Bool
        switch kind {
        case .add:
            isParked = !addHold.parked.isEmpty
        case .advertise:
            isParked = !advertiseHold.parked.isEmpty
        case .updateValue:
            isParked = !updateValueHold.parked.isEmpty
        }
        if isParked {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            switch kind {
            case .add:
                addHold.parkedWaiters.append(continuation)
            case .advertise:
                advertiseHold.parkedWaiters.append(continuation)
            case .updateValue:
                updateValueHold.parkedWaiters.append(continuation)
            }
        }
    }

    private func resumeRecordedCallWaiters() {
        var remaining: [RecordedCallWaiter] = []
        for waiter in recordedCallWaiters {
            if recordedCalls.contains(where: waiter.predicate) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        recordedCallWaiters = remaining
    }

    private func resumeRecordedCallsWaiters() {
        var remaining: [RecordedCallsWaiter] = []
        for waiter in recordedCallsWaiters {
            if waiter.predicate(recordedCalls) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        recordedCallsWaiters = remaining
    }

    private func resumeStateUpdatesSubscriberWaiters() {
        guard stateUpdatesSubscriberCount > 0 else {
            return
        }
        let waiters = stateUpdatesSubscriberWaiters
        stateUpdatesSubscriberWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func appendRecordedCall(_ call: RecordedCall) {
        recordedCalls.append(call)
        resumeRecordedCallWaiters()
        resumeRecordedCallsWaiters()
    }

    private func hasCharacteristic(serviceUUID: UUID, characteristicUUID: UUID) -> Bool {
        guard let service = services[serviceUUID] else {
            return false
        }
        return service.characteristics.contains { $0.uuid == characteristicUUID }
    }
}
