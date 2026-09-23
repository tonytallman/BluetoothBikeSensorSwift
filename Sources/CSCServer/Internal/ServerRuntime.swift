#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation
internal import CSCWire

actor ServerRuntime {
    private enum Phase {
        case idle
        case starting
        case running
        case stopping
    }

    fileprivate enum SessionResult: Sendable {
        case stopped
        case cancelled
        case failed(ServerError)
    }

    private enum EndPullAction: Sendable {
        case drop
        case eof
        case fail
        case send(CrankRevolution)
    }

    private enum RearmAction: Sendable {
        case pull
        case stop
    }

    private struct EpisodeCell<T: Sendable> {
        var continuation: CheckedContinuation<T, Error>?
        var cancelled = false
        var resumed = false
    }

    private struct SessionEnded: Sendable {
        enum Reason: Sendable {
            case stopped
            case startCancelled
        }

        let reason: Reason
    }

    private enum PowerWaitResult: Sendable {
        case state(BluetoothState)
        case streamEnded
        case sessionEnded(SessionEnded.Reason)
    }

    private let service: PeripheralService
    private let crankRevolutions: AnyAsyncSequence<CrankRevolution>?

    private var phase: Phase = .idle
    private var sessionID: UInt64 = 0
    private var cleanEOFSessionID: UInt64?
    private var outstandingPull: UInt64?
    private var needsCrankPull = false
    private var teardownStarted = false
    private var recordedFailure: ServerError?
    private var startTaskCancelled = false
    private var stopRequested = false

    private var activeAttempt: UUID?
    private var idleCancelledToken: UUID?

    private var measurementSubscribers: Set<UUID> = []
    private let subscriberBroadcaster = StreamBroadcaster<Set<UUID>>()
    private var notifyReadyBit = false

    #if canImport(CoreBluetooth)
    private var productionPeripheral: CoreBluetoothPeripheral?
    #endif
    private var activePeripheral: (any BluetoothPeripheral)?

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    private var sessionEndCell = EpisodeCell<SessionEnded>()
    private var notifyReadyCell = EpisodeCell<Void>()

    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?
    private var crankTask: Task<Void, Never>?

    init(service: PeripheralService, crankRevolutions: AnyAsyncSequence<CrankRevolution>?) {
        self.service = service
        self.crankRevolutions = crankRevolutions
    }

    func measurementSubscriberUpdates() async -> AsyncStream<Set<UUID>> {
        await subscriberBroadcaster.makeStream()
    }

    func start(
        peripheral: (any BluetoothPeripheral)?,
        poweredOnTimeoutNanoseconds: UInt64,
    ) async throws {
        let token = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    await self.setupStart(
                        token: token,
                        peripheral: peripheral,
                        poweredOnTimeoutNanoseconds: poweredOnTimeoutNanoseconds,
                        continuation: continuation,
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelAttempt(token: token)
            }
        }
        try Task.checkCancellation()
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if phase == .idle {
                continuation.resume()
                return
            }
            stopWaiters.append(continuation)
            stopRequested = true
            beginTeardown()
        }
    }

    // MARK: - Start setup

    private func setupStart(
        token: UUID,
        peripheral: (any BluetoothPeripheral)?,
        poweredOnTimeoutNanoseconds: UInt64,
        continuation: CheckedContinuation<Void, Error>,
    ) {
        if phase != .idle {
            continuation.resume(throwing: ServerError.alreadyStarted)
            return
        }

        activeAttempt = token

        if idleCancelledToken == token || Task.isCancelled {
            idleCancelledToken = nil
            activeAttempt = nil
            continuation.resume(throwing: CancellationError())
            return
        }
        idleCancelledToken = nil

        if isUnsupportedConfiguration {
            activeAttempt = nil
            continuation.resume(throwing: ServerError.unsupportedConfiguration)
            return
        }

        sessionID += 1
        cleanEOFSessionID = nil
        phase = .starting
        startContinuation = continuation

        let resolvedPeripheral: any BluetoothPeripheral
        if let peripheral {
            resolvedPeripheral = peripheral
        } else {
            #if canImport(CoreBluetooth)
            if productionPeripheral == nil {
                productionPeripheral = CoreBluetoothPeripheral()
            }
            resolvedPeripheral = productionPeripheral!
            #else
            activeAttempt = nil
            phase = .idle
            startContinuation = nil
            continuation.resume(throwing: ServerError.bluetoothUnavailable)
            return
            #endif
        }
        activePeripheral = resolvedPeripheral

        let worker = Task {
            let result = await self.runUntilTerminal(
                peripheral: resolvedPeripheral,
                poweredOnTimeoutNanoseconds: poweredOnTimeoutNanoseconds,
            )
            await self.finishTeardown(result: result, peripheral: resolvedPeripheral)
        }
        _ = worker
    }

    private var isUnsupportedConfiguration: Bool {
        service.characteristics.contains { $0.uuid == CSCS.controlPointUUID }
            || crankRevolutions == nil
    }

    private func cancelAttempt(token: UUID) {
        if phase == .idle && (activeAttempt == nil || activeAttempt == token) {
            idleCancelledToken = token
            return
        }
        if activeAttempt != token {
            return
        }
        startTaskCancelled = true
        beginTeardown()
    }

    // MARK: - Worker

    private func runUntilTerminal(
        peripheral: any BluetoothPeripheral,
        poweredOnTimeoutNanoseconds: UInt64,
    ) async -> SessionResult {
        do {
            let powerResult = await waitForPoweredOn(
                peripheral: peripheral,
                timeoutNanoseconds: poweredOnTimeoutNanoseconds,
            )
            if let failure = powerResult {
                return failure
            }

            let readStream = await peripheral.readRequests
            let writeStream = await peripheral.writeTransactions
            let subscriptionStream = await peripheral.subscriptionChanges
            let readyStream = await peripheral.subscriberUpdatesReady

            readTask = spawnReadLoop(peripheral: peripheral, stream: readStream)
            writeTask = spawnWriteLoop(peripheral: peripheral, stream: writeStream)
            subscriptionTask = spawnSubscriptionLoop(stream: subscriptionStream)
            readyTask = spawnReadyLoop(stream: readyStream)

            do {
                try await peripheral.add(service)
            } catch {
                return startupFailureResult(for: error)
            }
            if let flagResult = flagResult() {
                return flagResult
            }

            do {
                try await peripheral.startAdvertising(
                    Advertisement(localName: nil, serviceUUIDs: [service.uuid]),
                )
            } catch {
                return startupFailureResult(for: error)
            }
            if let flagResult = flagResult() {
                return flagResult
            }

            phase = .running
            startCrankTaskIfNeeded()

            return await parkUntilSessionEnd()
        } catch is CancellationError {
            if let flagResult = flagResult() {
                return flagResult
            }
            return await parkUntilSessionEnd()
        } catch {
            if startTaskCancelled {
                return .cancelled
            }
            if let recordedFailure {
                return .failed(recordedFailure)
            }
            return .failed(mapStartupError(error))
        }
    }

    private func flagResult() -> SessionResult? {
        if startTaskCancelled {
            return .cancelled
        }
        if let recordedFailure {
            return .failed(recordedFailure)
        }
        if stopRequested || teardownStarted {
            return .stopped
        }
        return nil
    }

    private func startupFailureResult(for error: Error) -> SessionResult {
        if startTaskCancelled {
            return .cancelled
        }
        if let recordedFailure {
            return .failed(recordedFailure)
        }
        return .failed(mapStartupError(error))
    }

    private func mapStartupError(_ error: Error) -> ServerError {
        if let serverError = error as? ServerError {
            return serverError
        }
        if let peripheralError = error as? BluetoothPeripheralError {
            return mapPeripheralError(peripheralError, fromUpdateValue: false)
        }
        return .publishFailed(reason: String(describing: error))
    }

    private func mapPeripheralError(
        _ error: BluetoothPeripheralError,
        fromUpdateValue: Bool,
    ) -> ServerError {
        switch error {
        case .notPoweredOn:
            return fromUpdateValue ? .publishFailed(reason: String(describing: error)) : .bluetoothUnavailable
        case .peripheralInvalidated:
            return .publishFailed(reason: String(describing: error))
        case .addServiceFailed:
            return .publishFailed(reason: String(describing: error))
        case .advertisingFailed(let reason):
            return .advertisingFailed(reason: reason)
        default:
            return .publishFailed(reason: String(describing: error))
        }
    }

    // MARK: - Power-up

    private func waitForPoweredOn(
        peripheral: any BluetoothPeripheral,
        timeoutNanoseconds: UInt64,
    ) async -> SessionResult? {
        let stateStream = await peripheral.stateUpdates
        let initialState = await peripheral.currentState

        switch initialState {
        case .poweredOn:
            return nil
        case .unsupported, .unauthorized, .poweredOff:
            return .failed(.bluetoothUnavailable)
        case .unknown, .resetting:
            break
        }

        resetEpisodeCell(&sessionEndCell)

        let result = await withTaskGroup(of: PowerWaitResult?.self) { group in
            group.addTask {
                for await state in stateStream {
                    switch state {
                    case .poweredOn:
                        return .state(.poweredOn)
                    case .unsupported, .unauthorized, .poweredOff:
                        return .state(state)
                    case .unknown, .resetting:
                        continue
                    }
                }
                return .streamEnded
            }

            group.addTask {
                if timeoutNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                }
                let state = await peripheral.currentState
                return .state(state)
            }

            group.addTask {
                do {
                    let ended = try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation {
                            (continuation: CheckedContinuation<SessionEnded, Error>) in
                            Task {
                                await self.armPowerWaitContinuation(continuation)
                            }
                        }
                    } onCancel: {
                        Task {
                            await self.cancelPowerWaitContinuation()
                        }
                    }
                    return .sessionEnded(ended.reason)
                } catch is CancellationError {
                    return nil
                } catch {
                    return nil
                }
            }

            var decision: PowerWaitResult?
            while let next = await group.next() {
                if let value = next {
                    decision = value
                    break
                }
            }
            group.cancelAll()
            while await group.next() != nil {}
            return decision
        }

        sessionEndCell = EpisodeCell<SessionEnded>()

        switch result {
        case .state(.poweredOn):
            return nil
        case .state(.unknown), .state(.resetting), .state(.unsupported), .state(.unauthorized), .state(.poweredOff):
            return .failed(.bluetoothUnavailable)
        case .streamEnded, .none:
            if startTaskCancelled {
                return .cancelled
            }
            if stopRequested {
                return .stopped
            }
            return .failed(.bluetoothUnavailable)
        case .sessionEnded(.startCancelled):
            return .cancelled
        case .sessionEnded(.stopped):
            return .stopped
        }
    }

    private func armPowerWaitContinuation(
        _ continuation: CheckedContinuation<SessionEnded, Error>,
    ) {
        if sessionEndCell.cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if startTaskCancelled {
            continuation.resume(returning: SessionEnded(reason: .startCancelled))
            return
        }
        if stopRequested {
            continuation.resume(returning: SessionEnded(reason: .stopped))
            return
        }
        sessionEndCell.continuation = continuation
    }

    private func cancelPowerWaitContinuation() {
        sessionEndCell.cancelled = true
        if let continuation = sessionEndCell.continuation, !sessionEndCell.resumed {
            sessionEndCell.resumed = true
            sessionEndCell.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    private func parkUntilSessionEnd() async -> SessionResult {
        let ended = try! await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SessionEnded, Error>) in
            Task {
                self.armParkCell(continuation: continuation)
            }
        }

        switch ended.reason {
        case .startCancelled:
            return .cancelled
        case .stopped:
            return flagResult() ?? .stopped
        }
    }

    private func armParkCell(continuation: CheckedContinuation<SessionEnded, Error>) {
        if startTaskCancelled {
            continuation.resume(returning: SessionEnded(reason: .startCancelled))
            return
        }
        if stopRequested || teardownStarted {
            continuation.resume(returning: SessionEnded(reason: .stopped))
            return
        }
        sessionEndCell = EpisodeCell()
        sessionEndCell.continuation = continuation
    }

    // MARK: - Teardown

    private func beginTeardown() {
        if phase == .idle {
            return
        }
        if teardownStarted {
            resumeSessionEndCellIfNeeded()
            return
        }
        teardownStarted = true
        resumeSessionEndCellIfNeeded()

        if outstandingPull == nil {
            crankTask?.cancel()
        }
    }

    private func resumeSessionEndCellIfNeeded() {
        guard let continuation = sessionEndCell.continuation, !sessionEndCell.resumed else {
            return
        }
        sessionEndCell.resumed = true
        sessionEndCell.continuation = nil
        if startTaskCancelled {
            continuation.resume(returning: SessionEnded(reason: .startCancelled))
        } else {
            continuation.resume(returning: SessionEnded(reason: .stopped))
        }
    }

    private func finishTeardown(
        result: SessionResult,
        peripheral: any BluetoothPeripheral,
    ) async {
        phase = .stopping

        readTask?.cancel()
        writeTask?.cancel()
        subscriptionTask?.cancel()
        readyTask?.cancel()

        _ = await readTask?.value
        _ = await writeTask?.value
        _ = await subscriptionTask?.value
        _ = await readyTask?.value

        if outstandingPull == nil {
            crankTask?.cancel()
            _ = await crankTask?.value
        }

        await peripheral.stopAdvertising()
        do {
            try await peripheral.removeService(uuid: service.uuid)
        } catch BluetoothPeripheralError.serviceNotFound {
        } catch {
        }

        measurementSubscribers.removeAll()
        await subscriberBroadcaster.yield([])

        let continuation = startContinuation
        let waiters = stopWaiters
        let cancelled = startTaskCancelled
        let failure = recordedFailure
        let sessionResult = result

        startContinuation = nil
        stopWaiters = []
        notifyReadyBit = false
        needsCrankPull = false
        teardownStarted = false
        cleanEOFSessionID = nil
        recordedFailure = nil
        startTaskCancelled = false
        stopRequested = false
        readTask = nil
        writeTask = nil
        subscriptionTask = nil
        readyTask = nil

        resetEpisodeCell(&sessionEndCell)
        resetEpisodeCell(&notifyReadyCell)

        activePeripheral = nil
        activeAttempt = nil
        phase = .idle

        for waiter in waiters {
            waiter.resume()
        }

        if let continuation {
            if cancelled {
                continuation.resume(throwing: CancellationError())
            } else if let failure {
                continuation.resume(throwing: failure)
            } else if case .failed(let error) = sessionResult {
                continuation.resume(throwing: error)
            } else if case .cancelled = sessionResult {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume()
            }
        }
    }

    private func resetEpisodeCell<T>(_ cell: inout EpisodeCell<T>) {
        if let continuation = cell.continuation, !cell.resumed {
            cell.resumed = true
            continuation.resume(throwing: CancellationError())
        }
        cell = EpisodeCell()
    }

    private func recordFailure(_ error: ServerError) {
        if recordedFailure == nil {
            recordedFailure = error
        }
        beginTeardown()
    }

    // MARK: - Event loops

    private func spawnReadLoop(
        peripheral: any BluetoothPeripheral,
        stream: AsyncStream<PeripheralReadRequest>,
    ) -> Task<Void, Never> {
        Task {
            for await request in stream {
                if Task.isCancelled { break }
                await self.handleRead(request, peripheral: peripheral)
            }
        }
    }

    private func spawnWriteLoop(
        peripheral: any BluetoothPeripheral,
        stream: AsyncStream<PeripheralWriteTransaction>,
    ) -> Task<Void, Never> {
        Task {
            for await transaction in stream {
                if Task.isCancelled { break }
                await self.handleWrite(transaction, peripheral: peripheral)
            }
        }
    }

    private func spawnSubscriptionLoop(stream: AsyncStream<SubscriptionChange>) -> Task<Void, Never> {
        Task {
            for await change in stream {
                if Task.isCancelled { break }
                await self.handleSubscription(change)
            }
        }
    }

    private func spawnReadyLoop(stream: AsyncStream<Void>) -> Task<Void, Never> {
        Task {
            for await _ in stream {
                if Task.isCancelled { break }
                await self.handleReady()
            }
        }
    }

    private func handleRead(_ request: PeripheralReadRequest, peripheral: any BluetoothPeripheral) async {
        let response = readResponse(for: request)
        do {
            try await peripheral.respond(
                to: request.id,
                with: response.result,
                value: response.value,
            )
        } catch is CancellationError {
        } catch {
            recordFailure(mapPeripheralError(
                error as? BluetoothPeripheralError ?? .unknownRequest,
                fromUpdateValue: false,
            ))
        }
    }

    private struct ReadResponse {
        let result: ATTResult
        let value: Data?
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

    private func handleWrite(_ transaction: PeripheralWriteTransaction, peripheral: any BluetoothPeripheral) async {
        do {
            try await peripheral.respond(
                to: transaction.id,
                with: .error(code: 0x03),
                value: nil,
            )
        } catch is CancellationError {
        } catch {
            recordFailure(mapPeripheralError(
                error as? BluetoothPeripheralError ?? .unknownRequest,
                fromUpdateValue: false,
            ))
        }
    }

    private func handleSubscription(_ change: SubscriptionChange) async {
        switch change {
        case let .subscribed(centralID, serviceUUID, characteristicUUID):
            guard serviceUUID == service.uuid, characteristicUUID == CSCS.measurementUUID else { return }
            measurementSubscribers.insert(centralID)
        case let .unsubscribed(centralID, serviceUUID, characteristicUUID):
            guard serviceUUID == service.uuid, characteristicUUID == CSCS.measurementUUID else { return }
            measurementSubscribers.remove(centralID)
        }
        await subscriberBroadcaster.yield(measurementSubscribers)
    }

    private func handleReady() {
        if let continuation = notifyReadyCell.continuation, !notifyReadyCell.resumed {
            notifyReadyCell.resumed = true
            notifyReadyCell.continuation = nil
            continuation.resume()
            return
        }
        notifyReadyBit = true
    }

    // MARK: - Crank pull

    private func startCrankTaskIfNeeded() {
        guard phase == .running, !teardownStarted else { return }
        guard cleanEOFSessionID != sessionID else { return }
        guard let crankRevolutions else { return }

        if outstandingPull != nil {
            needsCrankPull = true
            return
        }

        outstandingPull = sessionID
        let sequence = crankRevolutions
        let currentSession = sessionID

        crankTask = Task {
            var iterator = sequence.makeAsyncIterator()
            let session = currentSession
            loop: while !Task.isCancelled {
                let pulled: Result<CrankRevolution?, Error>
                do {
                    let value = try await iterator.next()
                    pulled = .success(value)
                } catch {
                    pulled = .failure(error)
                }

                let action = await self.endPull(
                    session: session,
                    pulled: pulled,
                    taskWasCancelled: Task.isCancelled,
                )

                switch action {
                case .drop:
                    return
                case .eof:
                    return
                case .fail:
                    return
                case let .send(revolution):
                    await self.send(revolution)
                    let rearm = await self.rearmPull(session: session)
                    switch rearm {
                    case .pull:
                        continue loop
                    case .stop:
                        return
                    }
                }
            }
        }
    }

    private func endPull(
        session: UInt64,
        pulled: Result<CrankRevolution?, Error>,
        taskWasCancelled: Bool,
    ) -> EndPullAction {
        outstandingPull = nil

        let isStale = session != sessionID || phase != .running || teardownStarted

        if isStale {
            if needsCrankPull {
                needsCrankPull = false
                startCrankTaskIfNeeded()
            }
            return .drop
        }

        switch pulled {
        case .success(nil):
            if taskWasCancelled {
                return .drop
            }
            cleanEOFSessionID = sessionID
            return .eof
        case .failure(let error):
            if error is CancellationError {
                return .drop
            }
            recordFailure(.revolutionSequenceFailed(reason: error.localizedDescription))
            return .fail
        case .success(let revolution?):
            return .send(revolution)
        }
    }

    private func rearmPull(session: UInt64) -> RearmAction {
        if phase == .running, !teardownStarted, session == sessionID {
            outstandingPull = sessionID
            return .pull
        }
        return .stop
    }

    private func send(_ revolution: CrankRevolution) async {
        if teardownStarted || Task.isCancelled {
            return
        }

        while !Task.isCancelled, !teardownStarted {
            let subscribers = measurementSubscribers
            if subscribers.isEmpty {
                return
            }

            let measurement = CSCMeasurement(
                cumulativeCrankRevolutions: revolution.cumulativeRevolutions,
                lastCrankEventTime: revolution.lastEventTime,
            )
            guard let payload = measurement.encode() else {
                recordFailure(.revolutionSequenceFailed(reason: "encode returned nil"))
                return
            }

            guard let peripheral = activePeripheral else { return }
            let sortedIDs = subscribers.sorted { $0.uuidString < $1.uuidString }

            do {
                let accepted = try await peripheral.updateValue(
                    payload,
                    serviceUUID: service.uuid,
                    characteristicUUID: CSCS.measurementUUID,
                    onSubscribedCentrals: sortedIDs,
                )
                if accepted {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                let peripheralError = error as? BluetoothPeripheralError ?? .unknownRequest
                recordFailure(mapPeripheralError(peripheralError, fromUpdateValue: true))
                return
            }

            do {
                try await waitUntilNotifyReady()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func waitUntilNotifyReady() async throws {
        let cell = EpisodeCell<Void>()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    await self.armNotifyReady(cell: cell, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelNotifyReady(cell: cell)
            }
        }
    }

    private func armNotifyReady(
        cell: EpisodeCell<Void>,
        continuation: CheckedContinuation<Void, Error>,
    ) {
        if cell.cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if startTaskCancelled || stopRequested || teardownStarted {
            continuation.resume(throwing: CancellationError())
            return
        }
        if notifyReadyBit {
            notifyReadyBit = false
            continuation.resume()
            return
        }
        notifyReadyCell = cell
        notifyReadyCell.continuation = continuation
    }

    private func cancelNotifyReady(cell: EpisodeCell<Void>) {
        notifyReadyCell.cancelled = true
        if let continuation = notifyReadyCell.continuation, !notifyReadyCell.resumed {
            notifyReadyCell.resumed = true
            notifyReadyCell.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}
