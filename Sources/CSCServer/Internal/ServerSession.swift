import Foundation
internal import CSCWire

actor ServerSession {
    private enum PublishStage: Sendable {
        case none
        case serviceAdded
        case advertising
    }

    private struct ReadResponse: Sendable {
        let result: ATTResult
        let value: Data?
    }

    private struct SubscriberWaiter: Sendable {
        let expected: Set<UUID>
        let continuation: CheckedContinuation<Void, Never>
    }

    private let service: PeripheralService
    private let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    private let peripheral: any BluetoothPeripheral

    private var publishStage: PublishStage = .none
    private var measurementSubscribers: Set<UUID> = []
    private var subscriberWaiters: [SubscriberWaiter] = []

    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var crankTask: Task<Void, Never>?

    private init(
        service: PeripheralService,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        peripheral: any BluetoothPeripheral,
    ) {
        self.service = service
        self.crankRevolutions = crankRevolutions
        self.peripheral = peripheral
    }

    static func open(
        service: PeripheralService,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        peripheral: any BluetoothPeripheral,
    ) async throws -> ServerSession {
        let session = ServerSession(
            service: service,
            crankRevolutions: crankRevolutions,
            peripheral: peripheral,
        )
        do {
            try await withTaskCancellationHandler {
                try await session.startup()
            } onCancel: {
                Task {
                    await session.rollbackStartup()
                }
            }
            try Task.checkCancellation()
            return session
        } catch is CancellationError {
            await session.rollbackStartup()
            throw CancellationError()
        }
    }

    func waitForMeasurementSubscribers(_ ids: Set<UUID>) async {
        if measurementSubscribers == ids {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            subscriberWaiters.append(
                SubscriberWaiter(expected: ids, continuation: continuation),
            )
        }
    }

    func close() async {
        crankTask?.cancel()
        _ = await crankTask?.value
        crankTask = nil

        await peripheral.stopAdvertising()

        if publishStage != .none {
            try? await peripheral.removeService(uuid: service.uuid)
        }
        publishStage = .none

        readTask?.cancel()
        writeTask?.cancel()
        subscriptionTask?.cancel()
        _ = await readTask?.value
        _ = await writeTask?.value
        _ = await subscriptionTask?.value
        readTask = nil
        writeTask = nil
        subscriptionTask = nil

        measurementSubscribers.removeAll()
        resumeSubscriberWaiters()
    }

    private func startup() async throws {
        try await waitForPoweredOn()

        let readStream = await peripheral.readRequests
        let writeStream = await peripheral.writeTransactions
        let subscriptionStream = await peripheral.subscriptionChanges

        readTask = spawnReadLoop(stream: readStream)
        writeTask = spawnWriteLoop(stream: writeStream)
        subscriptionTask = spawnSubscriptionLoop(stream: subscriptionStream)

        do {
            try await peripheral.add(service)
            publishStage = .serviceAdded
        } catch {
            throw mapPublishError(error)
        }

        try Task.checkCancellation()

        do {
            try await peripheral.startAdvertising(
                Advertisement(localName: nil, serviceUUIDs: [service.uuid]),
            )
            publishStage = .advertising
        } catch {
            try? await peripheral.removeService(uuid: service.uuid)
            publishStage = .none
            throw mapAdvertisingError(error)
        }

        startCrankLoopIfNeeded()
    }

    private func rollbackStartup() async {
        crankTask?.cancel()
        _ = await crankTask?.value
        crankTask = nil

        if publishStage == .advertising {
            await peripheral.stopAdvertising()
        }

        if publishStage != .none {
            try? await peripheral.removeService(uuid: service.uuid)
        }
        publishStage = .none

        readTask?.cancel()
        writeTask?.cancel()
        subscriptionTask?.cancel()
        _ = await readTask?.value
        _ = await writeTask?.value
        _ = await subscriptionTask?.value
        readTask = nil
        writeTask = nil
        subscriptionTask = nil

        measurementSubscribers.removeAll()
        resumeSubscriberWaiters()
    }

    private func waitForPoweredOn() async throws {
        let stateStream = await peripheral.stateUpdates
        var iterator = stateStream.makeAsyncIterator()
        var state = await peripheral.currentState

        while state == .unknown || state == .resetting {
            try Task.checkCancellation()
            guard let next = await iterator.next() else {
                try Task.checkCancellation()
                throw ServerError.notPoweredOn
            }
            state = next
        }

        try Task.checkCancellation()

        guard state == .poweredOn else {
            throw ServerError.notPoweredOn
        }
    }

    private func spawnReadLoop(stream: AsyncStream<PeripheralReadRequest>) -> Task<Void, Never> {
        Task {
            for await request in stream {
                if Task.isCancelled {
                    break
                }
                await handleRead(request)
            }
        }
    }

    private func spawnWriteLoop(stream: AsyncStream<PeripheralWriteTransaction>) -> Task<Void, Never> {
        Task {
            for await transaction in stream {
                if Task.isCancelled {
                    break
                }
                await handleWrite(transaction)
            }
        }
    }

    private func spawnSubscriptionLoop(stream: AsyncStream<SubscriptionChange>) -> Task<Void, Never> {
        Task {
            for await change in stream {
                if Task.isCancelled {
                    break
                }
                await handleSubscription(change)
            }
        }
    }

    private func handleRead(_ request: PeripheralReadRequest) async {
        let response = readResponse(for: request)
        do {
            try await peripheral.respond(
                to: request.id,
                with: response.result,
                value: response.value,
            )
        } catch is CancellationError {
        } catch {
        }
    }

    private func readResponse(for request: PeripheralReadRequest) -> ReadResponse {
        guard request.serviceUUID == service.uuid else {
            return ReadResponse(result: .error(code: 0x0A), value: nil)
        }
        guard let characteristic = service.characteristics.first(where: { $0.uuid == request.characteristicUUID }) else {
            return ReadResponse(result: .error(code: 0x0A), value: nil)
        }
        guard let value = characteristic.value else {
            return ReadResponse(result: .error(code: 0x02), value: nil)
        }

        let offset = request.offset
        if offset < 0 || offset > value.count {
            return ReadResponse(result: .error(code: 0x07), value: nil)
        }
        if offset == value.count {
            return ReadResponse(result: .success, value: Data())
        }
        return ReadResponse(result: .success, value: Data(value.dropFirst(offset)))
    }

    private func handleWrite(_ transaction: PeripheralWriteTransaction) async {
        do {
            try await peripheral.respond(
                to: transaction.id,
                with: .error(code: 0x03),
                value: nil,
            )
        } catch is CancellationError {
        } catch {
        }
    }

    private func handleSubscription(_ change: SubscriptionChange) async {
        switch change {
        case let .subscribed(centralID, serviceUUID, characteristicUUID):
            guard serviceUUID == service.uuid, characteristicUUID == CSCS.measurementUUID else {
                return
            }
            measurementSubscribers.insert(centralID)
        case let .unsubscribed(centralID, serviceUUID, characteristicUUID):
            guard serviceUUID == service.uuid, characteristicUUID == CSCS.measurementUUID else {
                return
            }
            measurementSubscribers.remove(centralID)
        }
        resumeSubscriberWaiters()
    }

    private func resumeSubscriberWaiters() {
        let pending = subscriberWaiters
        subscriberWaiters.removeAll()
        for waiter in pending {
            if measurementSubscribers == waiter.expected {
                waiter.continuation.resume()
            } else {
                subscriberWaiters.append(waiter)
            }
        }
    }

    private func startCrankLoopIfNeeded() {
        guard let crankRevolutions else {
            return
        }

        let sequence = crankRevolutions
        crankTask = Task {
            let iterator = sequence.makeAsyncIterator()
            while !Task.isCancelled {
                let revolution: CrankRevolution?
                do {
                    revolution = try await iterator.next()
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                guard let revolution else {
                    return
                }

                await send(revolution)
            }
        }
    }

    private func send(_ revolution: CrankRevolution) async {
        guard !measurementSubscribers.isEmpty else {
            return
        }

        let measurement = CSCMeasurement(
            cumulativeCrankRevolutions: revolution.cumulativeRevolutions,
            lastCrankEventTime: revolution.lastEventTime,
        )
        guard let payload = measurement.encode() else {
            return
        }

        while !Task.isCancelled {
            guard !measurementSubscribers.isEmpty else {
                return
            }

            do {
                let accepted = try await peripheral.updateValue(
                    payload,
                    serviceUUID: service.uuid,
                    characteristicUUID: CSCS.measurementUUID,
                    onSubscribedCentrals: nil,
                )
                if accepted {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }

            let readyStream = await peripheral.subscriberUpdatesReady
            var readyIterator = readyStream.makeAsyncIterator()
            guard await readyIterator.next() != nil else {
                return
            }
        }
    }

    private func mapPublishError(_ error: Error) -> ServerError {
        if let serverError = error as? ServerError {
            return serverError
        }
        if let peripheralError = error as? BluetoothPeripheralError {
            switch peripheralError {
            case .notPoweredOn:
                return .notPoweredOn
            case .addServiceFailed(_, let reason):
                return .publishFailed(reason: reason)
            case .advertisingFailed(let reason):
                return .advertisingFailed(reason: reason)
            default:
                return .publishFailed(reason: String(describing: peripheralError))
            }
        }
        return .publishFailed(reason: String(describing: error))
    }

    private func mapAdvertisingError(_ error: Error) -> ServerError {
        if let serverError = error as? ServerError {
            return serverError
        }
        if let peripheralError = error as? BluetoothPeripheralError {
            switch peripheralError {
            case .advertisingFailed(let reason):
                return .advertisingFailed(reason: reason)
            default:
                return .advertisingFailed(reason: String(describing: peripheralError))
            }
        }
        return .advertisingFailed(reason: String(describing: error))
    }
}
