import Foundation

/// Controllable `BluetoothPeripheral` for unit tests. Not intended for production use.
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

    private var state: BluetoothState
    private var advertising = false
    private var services: [UUID: PeripheralService] = [:]
    private var outstandingReadRequestIDs: Set<UUID> = []
    private var outstandingWriteTransactionIDs: Set<UUID> = []

    private var shouldFailNextAdd = false
    private var shouldFailNextAdvertise = false
    private var nextUpdateValueAccepted = true
    private var isAdvertiseHeld = false
    private var advertiseWaiters: [CheckedContinuation<Void, Never>] = []
    private var advertiseHeldWaiters: [CheckedContinuation<Void, Never>] = []

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let readBroadcaster = StreamBroadcaster<PeripheralReadRequest>()
    private let writeBroadcaster = StreamBroadcaster<PeripheralWriteTransaction>()
    private let subscriptionBroadcaster = StreamBroadcaster<SubscriptionChange>()
    private let readyBroadcaster = StreamBroadcaster<Void>()

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

    package var isAdvertising: Bool {
        get async { advertising }
    }

    package func add(_ service: PeripheralService) async throws {
        try PeripheralServiceValidation.validate(service)

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
        if isAdvertiseHeld {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                advertiseWaiters.append(continuation)
                resumeAdvertiseHeldWaiters()
            }
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

    package var readRequests: AsyncStream<PeripheralReadRequest> {
        get async {
            await readBroadcaster.makeStream()
        }
    }

    package var writeTransactions: AsyncStream<PeripheralWriteTransaction> {
        get async {
            await writeBroadcaster.makeStream()
        }
    }

    package var subscriptionChanges: AsyncStream<SubscriptionChange> {
        get async {
            await subscriptionBroadcaster.makeStream()
        }
    }

    package var subscriberUpdatesReady: AsyncStream<Void> {
        get async {
            await readyBroadcaster.makeStream()
        }
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
        return nextUpdateValueAccepted
    }

    package func setState(_ newState: BluetoothState) async {
        state = newState
        await stateBroadcaster.yield(newState)
    }

    package func emitRead(_ request: PeripheralReadRequest) async {
        outstandingReadRequestIDs.insert(request.id)
        await readBroadcaster.yield(request)
    }

    package func emitWriteTransaction(_ transaction: PeripheralWriteTransaction) async {
        outstandingWriteTransactionIDs.insert(transaction.id)
        await writeBroadcaster.yield(transaction)
    }

    package func emitSubscription(_ change: SubscriptionChange) async {
        await subscriptionBroadcaster.yield(change)
    }

    package func emitReadyToUpdateSubscribers() async {
        await readyBroadcaster.yield(())
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

    package func holdNextAdvertise() {
        isAdvertiseHeld = true
    }

    package func releaseAdvertise() {
        isAdvertiseHeld = false
        let waiters = advertiseWaiters
        advertiseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    package func waitUntilAdvertiseHeld() async {
        if !advertiseWaiters.isEmpty {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            advertiseHeldWaiters.append(continuation)
            resumeAdvertiseHeldWaiters()
        }
    }

    package func waitUntilReadRequestSubscriberCount(_ count: Int) async {
        await readBroadcaster.waitUntilSubscriberCount(count)
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

    private func resumeAdvertiseHeldWaiters() {
        guard !advertiseWaiters.isEmpty else {
            return
        }
        let waiters = advertiseHeldWaiters
        advertiseHeldWaiters.removeAll()
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
