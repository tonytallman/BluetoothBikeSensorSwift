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

    private struct RecordedCallWaiter {
        let id: UUID
        let predicate: @Sendable ([RecordedCall]) -> Bool
        let continuation: CheckedContinuation<Void, Error>
        var cancelled = false
        var resumed = false
    }

    private struct CurrentStateReadWaiter {
        let id: UUID
        let atLeast: Int
        let continuation: CheckedContinuation<Void, Error>
        var cancelled = false
        var resumed = false
    }

    private var state: BluetoothState
    private var advertising = false
    private var services: [UUID: PeripheralService] = [:]
    private var outstandingReadRequestIDs: Set<UUID> = []
    private var outstandingWriteTransactionIDs: Set<UUID> = []

    private var shouldFailNextAdd = false
    private var shouldFailNextAdvertise = false
    private var shouldFailNextUpdateValue = false
    private var nextUpdateValueAccepted = true

    private var currentStateReadCount = 0
    private var recordedCallWaiters: [RecordedCallWaiter] = []
    private var currentStateReadWaiters: [CurrentStateReadWaiter] = []

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let readBroadcaster = StreamBroadcaster<PeripheralReadRequest>()
    private let writeBroadcaster = StreamBroadcaster<PeripheralWriteTransaction>()
    private let subscriptionBroadcaster = StreamBroadcaster<SubscriptionChange>()
    private let readyBroadcaster = StreamBroadcaster<Void>()

    package private(set) var recordedCalls: [RecordedCall] = []

    package init(initialState: BluetoothState = .poweredOn) {
        state = initialState
    }

    package var currentState: BluetoothState {
        get async {
            currentStateReadCount += 1
            resumeCurrentStateReadWaiters()
            return state
        }
    }

    package var stateUpdates: AsyncStream<BluetoothState> {
        get async {
            await stateBroadcaster.makeStream()
        }
    }

    package var isAdvertising: Bool {
        get async { advertising }
    }

    package func add(_ service: PeripheralService) async throws {
        try PeripheralServiceValidation.validate(service)

        if shouldFailNextAdd {
            shouldFailNextAdd = false
            record(.add(service))
            throw BluetoothPeripheralError.addServiceFailed(
                serviceUUID: service.uuid,
                reason: "Test failure",
            )
        }

        record(.add(service))
        services[service.uuid] = service
    }

    package func removeService(uuid: UUID) async throws {
        guard services[uuid] != nil else {
            throw BluetoothPeripheralError.serviceNotFound
        }

        record(.removeService(uuid: uuid))
        services.removeValue(forKey: uuid)
    }

    package func removeAllServices() async {
        record(.removeAllServices)
        services.removeAll()
    }

    package func startAdvertising(_ advertisement: Advertisement) async throws {
        record(.startAdvertising(advertisement))

        if shouldFailNextAdvertise {
            shouldFailNextAdvertise = false
            throw BluetoothPeripheralError.advertisingFailed(reason: "Test failure")
        }

        advertising = true
    }

    package func stopAdvertising() async {
        record(.stopAdvertising)
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

        record(.respond(id: requestID, result: result, value: value))
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

        if shouldFailNextUpdateValue {
            shouldFailNextUpdateValue = false
            record(
                .updateValue(
                    value: value,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    centralIDs: filter,
                ),
            )
            throw BluetoothPeripheralError.peripheralInvalidated
        }

        record(
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

    package func failNextUpdateValue() {
        shouldFailNextUpdateValue = true
    }

    package func setNextUpdateValueAccepted(_ accepted: Bool) {
        nextUpdateValueAccepted = accepted
    }

    package func waitUntilRecordedCallsSatisfy(
        _ predicate: @Sendable @escaping ([RecordedCall]) -> Bool,
    ) async throws {
        if predicate(recordedCalls) {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = RecordedCallWaiter(
                    id: waiterID,
                    predicate: predicate,
                    continuation: continuation,
                )
                recordedCallWaiters.append(waiter)
                resumeRecordedCallWaiters()
            }
        } onCancel: {
            Task {
                await self.cancelRecordedCallWaiter(id: waiterID)
            }
        }
    }

    package func waitUntilCurrentStateReadCount(atLeast count: Int) async throws {
        if currentStateReadCount >= count {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = CurrentStateReadWaiter(
                    id: waiterID,
                    atLeast: count,
                    continuation: continuation,
                )
                currentStateReadWaiters.append(waiter)
                resumeCurrentStateReadWaiters()
            }
        } onCancel: {
            Task {
                await self.cancelCurrentStateReadWaiter(id: waiterID)
            }
        }
    }

    private func record(_ call: RecordedCall) {
        recordedCalls.append(call)
        resumeRecordedCallWaiters()
    }

    private func resumeRecordedCallWaiters() {
        var remaining: [RecordedCallWaiter] = []
        for index in recordedCallWaiters.indices {
            var waiter = recordedCallWaiters[index]
            if waiter.cancelled {
                if !waiter.resumed {
                    waiter.resumed = true
                    waiter.continuation.resume(throwing: CancellationError())
                }
                continue
            }
            if waiter.predicate(recordedCalls) {
                if !waiter.resumed {
                    waiter.resumed = true
                    waiter.continuation.resume()
                }
            } else {
                remaining.append(waiter)
            }
        }
        recordedCallWaiters = remaining
    }

    private func cancelRecordedCallWaiter(id: UUID) {
        for index in recordedCallWaiters.indices {
            if recordedCallWaiters[index].id == id {
                recordedCallWaiters[index].cancelled = true
                if !recordedCallWaiters[index].resumed {
                    recordedCallWaiters[index].resumed = true
                    recordedCallWaiters[index].continuation.resume(throwing: CancellationError())
                }
                recordedCallWaiters.remove(at: index)
                return
            }
        }
    }

    private func resumeCurrentStateReadWaiters() {
        var remaining: [CurrentStateReadWaiter] = []
        for index in currentStateReadWaiters.indices {
            var waiter = currentStateReadWaiters[index]
            if waiter.cancelled {
                if !waiter.resumed {
                    waiter.resumed = true
                    waiter.continuation.resume(throwing: CancellationError())
                }
                continue
            }
            if currentStateReadCount >= waiter.atLeast {
                if !waiter.resumed {
                    waiter.resumed = true
                    waiter.continuation.resume()
                }
            } else {
                remaining.append(waiter)
            }
        }
        currentStateReadWaiters = remaining
    }

    private func cancelCurrentStateReadWaiter(id: UUID) {
        for index in currentStateReadWaiters.indices {
            if currentStateReadWaiters[index].id == id {
                currentStateReadWaiters[index].cancelled = true
                if !currentStateReadWaiters[index].resumed {
                    currentStateReadWaiters[index].resumed = true
                    currentStateReadWaiters[index].continuation.resume(throwing: CancellationError())
                }
                currentStateReadWaiters.remove(at: index)
                return
            }
        }
    }

    private func hasCharacteristic(serviceUUID: UUID, characteristicUUID: UUID) -> Bool {
        guard let service = services[serviceUUID] else {
            return false
        }
        return service.characteristics.contains { $0.uuid == characteristicUUID }
    }
}
