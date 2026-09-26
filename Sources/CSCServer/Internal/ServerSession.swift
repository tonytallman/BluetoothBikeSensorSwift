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

    private struct MeasurementItem {
        var payload: Data
        var encodedWheelGeneration: UInt64?
        let producedWheel: WheelRevolution?
        let producedCrank: CrankRevolution?
        var emitContinuation: CheckedContinuation<Void, Never>?
    }

    private struct IndicationItem {
        let id: UUID
        let payload: Data
        let centralID: UUID
    }

    private enum OutboundItem {
        case measurement(MeasurementItem)
        case indication(IndicationItem)
    }

    private let service: PeripheralService
    private let wheel: WheelConfiguration?
    private let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    private let peripheral: any BluetoothPeripheral
    private let clock: any ServerClock
    private let onMeasurementSubscriberCountChange: (@Sendable (Int) async -> Void)?

    private var publishStage: PublishStage = .none
    private var closed = false
    private var measurementSubscribers: Set<UUID> = []
    private var controlPointSubscribers: Set<UUID> = []
    private var measurementSubscriberWaiters: [SubscriberWaiter] = []
    private var controlPointSubscriberWaiters: [SubscriberWaiter] = []
    private var measurementSubscriberWaiterParkedWaiters: [CheckedContinuation<Void, Never>] = []

    private var startLossCount = 0
    private var radioLost = false
    private var radioLossEpoch: UInt64 = 0
    private var lastRadioState: BluetoothState = .poweredOn
    private var recoveryInProgress = false
    private var recoveryIdleWaiters: [CheckedContinuation<Void, Never>] = []

    private var notifyReady = false
    private var notifyReadyWaiter: CheckedContinuation<Void, Never>?
    private var notifyReadyWaiterParkedWaiters: [CheckedContinuation<Void, Never>] = []

    private var startupGateOpen = false
    private var pendingInboundEvents: [PeripheralEvent] = []

    private var wheelCache: WheelRevolution?
    private var crankCache: CrankRevolution?
    private var wheelGeneration: UInt64 = 0

    private var outboundQueue: [OutboundItem] = []
    private var outboundQueueWaiter: CheckedContinuation<Void, Never>?

    private static let procedureTimeout: Duration = .seconds(30)

    private var procedureInProgress = false
    private var procedureIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var procedureIndicationID: UUID?
    private var procedureGeneration: UInt64 = 0
    private var procedureTimedOut = false
    private var procedureTimeoutTask: Task<Void, Never>?

    private var acceptedMeasurementCount = 0
    private var acceptedMeasurementCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    private var outboundCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    private let location: ServerLocationConfiguration
    private let servedSensorLocation: ServedSensorLocationBox?

    private var inboundTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private var wheelTask: Task<Void, Never>?
    private var crankTask: Task<Void, Never>?
    private var procedureTask: Task<Void, Never>?

    private init(
        service: PeripheralService,
        wheel: WheelConfiguration?,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        location: ServerLocationConfiguration,
        servedSensorLocation: ServedSensorLocationBox?,
        peripheral: any BluetoothPeripheral,
        clock: any ServerClock,
        onMeasurementSubscriberCountChange: (@Sendable (Int) async -> Void)? = nil,
    ) {
        self.service = service
        self.wheel = wheel
        self.crankRevolutions = crankRevolutions
        self.location = location
        self.servedSensorLocation = servedSensorLocation
        self.peripheral = peripheral
        self.clock = clock
        self.onMeasurementSubscriberCountChange = onMeasurementSubscriberCountChange
    }

    static func open(
        service: PeripheralService,
        wheel: WheelConfiguration?,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        location: ServerLocationConfiguration,
        servedSensorLocation: ServedSensorLocationBox?,
        peripheral: any BluetoothPeripheral,
        clock: any ServerClock,
        onMeasurementSubscriberCountChange: (@Sendable (Int) async -> Void)? = nil,
    ) async throws -> ServerSession {
        let session = ServerSession(
            service: service,
            wheel: wheel,
            crankRevolutions: crankRevolutions,
            location: location,
            servedSensorLocation: servedSensorLocation,
            peripheral: peripheral,
            clock: clock,
            onMeasurementSubscriberCountChange: onMeasurementSubscriberCountChange,
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
        } catch {
            await session.rollbackStartup()
            throw error
        }
    }

    func waitForMeasurementSubscribers(_ ids: Set<UUID>) async {
        if closed || measurementSubscribers == ids {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            measurementSubscriberWaiters.append(
                SubscriberWaiter(expected: ids, continuation: continuation),
            )
            resumeMeasurementSubscriberWaiterParkedWaiters()
        }
    }

    func waitUntilMeasurementSubscriberWaiterParked() async {
        if !measurementSubscriberWaiters.isEmpty {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            measurementSubscriberWaiterParkedWaiters.append(continuation)
            resumeMeasurementSubscriberWaiterParkedWaiters()
        }
    }

    func waitForControlPointSubscribers(_ ids: Set<UUID>) async {
        if closed || controlPointSubscribers == ids {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlPointSubscriberWaiters.append(
                SubscriberWaiter(expected: ids, continuation: continuation),
            )
        }
    }

    func waitUntilControlPointProcedureIdle() async {
        if closed || !procedureInProgress {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closed || !procedureInProgress {
                continuation.resume()
                return
            }
            procedureIdleWaiters.append(continuation)
        }
    }

    func waitUntilAcceptedMeasurementCount(_ count: Int) async {
        if closed || acceptedMeasurementCount >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closed || acceptedMeasurementCount >= count {
                continuation.resume()
                return
            }
            acceptedMeasurementCountWaiters.append((count, continuation))
        }
    }

    func waitUntilOutboundCount(atLeast count: Int) async {
        if closed || outboundQueue.count >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closed || outboundQueue.count >= count {
                continuation.resume()
                return
            }
            outboundCountWaiters.append((count, continuation))
        }
    }

    func close() async {
        beginShutdown()
        await stopTasks()

        await peripheral.stopAdvertising()

        if publishStage != .none {
            try? await peripheral.removeService(uuid: service.uuid)
        }
        publishStage = .none

        await stopInboundTask()

        measurementSubscribers.removeAll()
        controlPointSubscribers.removeAll()
        await notifyMeasurementSubscriberCount()
    }

    private func beginShutdown() {
        closed = true
        pendingInboundEvents.removeAll()
        wakeReadyWaiterWithoutLatch()
        resumeNotifyReadyWaiterParkedWaiters()
        resumeOutboundQueueWaiter()
        resumeAllMeasurementSubscriberWaiters()
        resumeAllControlPointSubscriberWaiters()
        resumeMeasurementSubscriberWaiterParkedWaiters()
        resumeAllAcceptedMeasurementCountWaiters()
        resumeAllOutboundCountWaiters()
    }

    private func stopTasks() async {
        let timeoutTask = procedureTimeoutTask
        senderTask?.cancel()
        procedureTask?.cancel()
        timeoutTask?.cancel()
        wheelTask?.cancel()
        crankTask?.cancel()

        _ = await senderTask?.value
        _ = await procedureTask?.value
        _ = await timeoutTask?.value
        _ = await wheelTask?.value
        _ = await crankTask?.value

        senderTask = nil
        procedureTask = nil
        procedureTimeoutTask = nil
        wheelTask = nil
        crankTask = nil
    }

    private func stopInboundTask() async {
        inboundTask?.cancel()
        _ = await inboundTask?.value
        inboundTask = nil
        pendingInboundEvents.removeAll()
    }

    private func startup() async throws {
        try await waitForPoweredOn()
        startLossCount = await peripheral.powerLossCount

        let eventStream = await peripheral.events
        inboundTask = spawnInboundTask(stream: eventStream)

        do {
            try await peripheral.add(service)
            publishStage = .serviceAdded
        } catch {
            throw mapPublishError(error)
        }

        if closed || Task.isCancelled {
            throw CancellationError()
        }

        do {
            try await peripheral.startAdvertising(advertisement)
        } catch {
            try? await peripheral.removeService(uuid: service.uuid)
            publishStage = .none
            throw mapAdvertisingError(error)
        }

        if closed || Task.isCancelled {
            await peripheral.stopAdvertising()
            throw CancellationError()
        }
        publishStage = .advertising

        // A loss during startup fails start() even if power came back before the calls finished.
        if await peripheral.powerLossCount != startLossCount {
            throw ServerError.notPoweredOn
        }

        senderTask = spawnSenderTask()
        await drainPendingInboundEvents()
        if closed || Task.isCancelled {
            throw CancellationError()
        }
        startCrankLoopIfNeeded()
        startWheelLoopIfNeeded()
        startupGateOpen = true
        await notifyMeasurementSubscriberCount()
    }

    /// Handles events buffered during startup, in arrival order, before the startup gate
    /// opens. Returns with the buffer empty; the caller opens the gate synchronously after
    /// this returns, with no `await` in between.
    private func drainPendingInboundEvents() async {
        while !closed, !pendingInboundEvents.isEmpty {
            let event = pendingInboundEvents.removeFirst()
            await handleInbound(event)
        }
    }

    private func rollbackStartup() async {
        beginShutdown()
        await stopTasks()

        if publishStage == .advertising {
            await peripheral.stopAdvertising()
        }

        if publishStage != .none {
            try? await peripheral.removeService(uuid: service.uuid)
        }
        publishStage = .none

        await stopInboundTask()

        measurementSubscribers.removeAll()
        controlPointSubscribers.removeAll()
        await notifyMeasurementSubscriberCount()
    }

    private func notifyMeasurementSubscriberCount() async {
        await onMeasurementSubscriberCountChange?(measurementSubscribers.count)
    }

    private var advertisement: Advertisement {
        Advertisement(localName: nil, serviceUUIDs: [service.uuid])
    }

    /// Settles any recovery already in progress before answering.
    func isRadioSuspended() async -> Bool {
        if recoveryInProgress {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !recoveryInProgress {
                    continuation.resume()
                    return
                }
                recoveryIdleWaiters.append(continuation)
            }
        }
        return radioLost
    }

    private func handleRadioState(_ state: BluetoothState) async {
        let previous = lastRadioState
        lastRadioState = state
        guard state == .poweredOn else {
            if !radioLost {
                await suspendForRadioLoss()
            }
            return
        }
        // Retrying needs a real transition back into .poweredOn, not a duplicate event.
        guard previous != .poweredOn, radioLost, !closed else {
            return
        }
        recoveryInProgress = true
        await recoverFromRadioLoss()
        recoveryInProgress = false
        let waiters = recoveryIdleWaiters
        recoveryIdleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func suspendForRadioLoss() async {
        radioLost = true
        radioLossEpoch &+= 1
        measurementSubscribers.removeAll()
        controlPointSubscribers.removeAll()
        notifyReady = false
        wakeReadyWaiterWithoutLatch()
        await notifyMeasurementSubscriberCount()
        resumeMeasurementSubscriberWaiters()
        resumeControlPointSubscriberWaiters()
    }

    /// Republishes the build-time service. `close()` may run during any await here and owns
    /// teardown; this removes only what it published after `closed` is set.
    private func recoverFromRadioLoss() async {
        await peripheral.stopAdvertising()
        if closed {
            return
        }
        if publishStage != .none {
            try? await peripheral.removeService(uuid: service.uuid)
            publishStage = .none
        }
        if closed {
            return
        }

        do {
            try await peripheral.add(service)
        } catch {
            return
        }
        publishStage = .serviceAdded
        if closed {
            try? await peripheral.removeService(uuid: service.uuid)
            publishStage = .none
            return
        }

        do {
            try await peripheral.startAdvertising(advertisement)
        } catch {
            try? await peripheral.removeService(uuid: service.uuid)
            publishStage = .none
            return
        }
        if closed {
            await peripheral.stopAdvertising()
            if publishStage != .none {
                try? await peripheral.removeService(uuid: service.uuid)
                publishStage = .none
            }
            return
        }

        publishStage = .advertising
        notifyReady = false
        radioLost = false
    }

    private var hasControlPointCharacteristic: Bool {
        service.characteristics.contains { $0.uuid == CSCS.controlPointUUID }
    }

    private func isStaleWheelPayload(_ item: MeasurementItem) -> Bool {
        guard let stamp = item.encodedWheelGeneration else {
            return false
        }
        return stamp != wheelGeneration
    }

    private func spawnSenderTask() -> Task<Void, Never> {
        Task {
            await self.runOutboundPump()
        }
    }

    private func runOutboundPump() async {
        while !Task.isCancelled {
            if closed {
                drainOutboundQueueOnShutdown()
                return
            }

            if outboundQueue.isEmpty {
                await waitForOutboundQueueItem()
                if closed {
                    drainOutboundQueueOnShutdown()
                    return
                }
                continue
            }

            switch outboundQueue[0] {
            case .measurement:
                await processMeasurementItem()
            case .indication:
                await processIndicationItem()
            }
        }
        if closed {
            drainOutboundQueueOnShutdown()
        }
    }

    private func waitForOutboundQueueItem() async {
        if closed {
            return
        }
        if !outboundQueue.isEmpty {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closed {
                continuation.resume()
                return
            }
            if !outboundQueue.isEmpty {
                continuation.resume()
                return
            }
            outboundQueueWaiter = continuation
        }
    }

    private func resumeOutboundQueueWaiter() {
        if let waiter = outboundQueueWaiter {
            outboundQueueWaiter = nil
            waiter.resume()
        }
    }

    private func wakeReadyWaiterWithoutLatch() {
        if let waiter = notifyReadyWaiter {
            notifyReadyWaiter = nil
            waiter.resume()
        }
    }

    /// Returns `true` when the head was removed and the pump should return.
    private func resolveStaleWheelHead(_ item: inout MeasurementItem) -> Bool {
        guard isStaleWheelPayload(item) else {
            return false
        }
        if item.producedWheel != nil {
            outboundQueue.removeFirst()
            completeEmit(&item)
            return true
        }
        guard let crank = item.producedCrank,
              let payload = CSCMeasurement(
                  cumulativeCrankRevolutions: crank.cumulativeRevolutions,
                  lastCrankEventTime: crank.lastEventTime,
              ).encode()
        else {
            outboundQueue.removeFirst()
            completeEmit(&item)
            return true
        }
        item.payload = payload
        item.encodedWheelGeneration = nil
        outboundQueue[0] = .measurement(item)
        return false
    }

    private func isHeadIndication(_ id: UUID) -> Bool {
        guard case .indication(let head) = outboundQueue.first else {
            return false
        }
        return head.id == id
    }

    private func removeHeadIndicationIfOwned(_ id: UUID) -> Bool {
        guard isHeadIndication(id) else {
            return false
        }
        outboundQueue.removeFirst()
        return true
    }

    /// Removes the queued indication with `id` wherever it sits. Returns whether it was the head,
    /// or `nil` when no such indication is queued.
    private func removeIndication(id: UUID) -> Bool? {
        let index = outboundQueue.firstIndex { item in
            if case .indication(let indication) = item {
                return indication.id == id
            }
            return false
        }
        guard let index, case .indication = outboundQueue.remove(at: index) else {
            return nil
        }
        return index == 0
    }

    /// Returns `true` when the pump should stop processing this indication item.
    private func dropIndicationIfCentralDeparted(_ indication: IndicationItem) -> Bool {
        guard !controlPointSubscribers.contains(indication.centralID) else {
            return false
        }
        if removeHeadIndicationIfOwned(indication.id) {
            endProcedure()
        }
        return true
    }

    private func processMeasurementItem() async {
        guard case var .measurement(item) = outboundQueue.first else {
            return
        }

        while !Task.isCancelled {
            if closed {
                outboundQueue.removeFirst()
                completeEmit(&item)
                drainOutboundQueueOnShutdown()
                return
            }

            if measurementSubscribers.isEmpty {
                outboundQueue.removeFirst()
                completeEmit(&item)
                return
            }

            if resolveStaleWheelHead(&item) {
                return
            }

            notifyReady = false
            let lossEpoch = radioLossEpoch
            let accepted: Bool
            do {
                accepted = try await peripheral.updateValue(
                    item.payload,
                    serviceUUID: service.uuid,
                    characteristicUUID: CSCS.measurementUUID,
                    onSubscribedCentrals: nil,
                )
            } catch {
                outboundQueue.removeFirst()
                completeEmit(&item)
                return
            }

            if accepted {
                // A send that overlapped a radio loss reached no current subscriber.
                if radioLossEpoch == lossEpoch {
                    recordAcceptedMeasurement(item)
                }
                outboundQueue.removeFirst()
                completeEmit(&item)
                return
            }

            if closed {
                outboundQueue.removeFirst()
                completeEmit(&item)
                drainOutboundQueueOnShutdown()
                return
            }

            if measurementSubscribers.isEmpty {
                outboundQueue.removeFirst()
                completeEmit(&item)
                return
            }

            if resolveStaleWheelHead(&item) {
                return
            }

            await waitForNotifyReady()
            if closed {
                drainOutboundQueueOnShutdown()
                return
            }
        }
    }

    private func recordAcceptedMeasurement(_ item: MeasurementItem) {
        if isStaleWheelPayload(item) {
            if item.producedWheel == nil, let crank = item.producedCrank {
                crankCache = crank
            }
            return
        }
        if let wheel = item.producedWheel {
            wheelCache = wheel
        }
        if let crank = item.producedCrank {
            crankCache = crank
        }
        acceptedMeasurementCount += 1
        resumeAcceptedMeasurementCountWaiters(for: acceptedMeasurementCount)
    }

    private func processIndicationItem() async {
        guard case .indication(let indication) = outboundQueue.first else {
            return
        }

        let indicationID = indication.id

        while !Task.isCancelled {
            // A timeout, unsubscribe, or radio loss may have removed this item and ended its
            // procedure while the pump was suspended; it must not be sent or ended again.
            guard isHeadIndication(indicationID) else {
                return
            }

            if closed {
                if removeHeadIndicationIfOwned(indicationID) {
                    endProcedure()
                }
                drainOutboundQueueOnShutdown()
                return
            }

            if dropIndicationIfCentralDeparted(indication) {
                return
            }

            notifyReady = false
            let accepted: Bool
            do {
                accepted = try await peripheral.updateValue(
                    indication.payload,
                    serviceUUID: service.uuid,
                    characteristicUUID: CSCS.controlPointUUID,
                    onSubscribedCentrals: [indication.centralID],
                )
            } catch {
                if removeHeadIndicationIfOwned(indicationID) {
                    endProcedure()
                }
                return
            }

            guard isHeadIndication(indicationID) else {
                return
            }

            if accepted {
                if removeHeadIndicationIfOwned(indicationID) {
                    endProcedure()
                }
                return
            }

            if closed {
                drainOutboundQueueOnShutdown()
                return
            }

            if dropIndicationIfCentralDeparted(indication) {
                return
            }

            await waitForNotifyReady()

            if closed {
                drainOutboundQueueOnShutdown()
                return
            }

            guard isHeadIndication(indicationID) else {
                return
            }

            if dropIndicationIfCentralDeparted(indication) {
                return
            }
        }
    }

    private func drainOutboundQueueOnShutdown() {
        while !outboundQueue.isEmpty {
            switch outboundQueue.removeFirst() {
            case var .measurement(item):
                completeEmit(&item)
            case .indication:
                break
            }
        }
        if procedureInProgress {
            endProcedure()
        }
    }

    private func completeEmit(_ item: inout MeasurementItem) {
        if let continuation = item.emitContinuation {
            item.emitContinuation = nil
            continuation.resume()
        }
    }

    private func endProcedure() {
        guard procedureInProgress else {
            return
        }
        procedureInProgress = false
        procedureIndicationID = nil
        procedureTimeoutTask?.cancel()
        procedureTimeoutTask = nil
        procedureGeneration &+= 1
        resumeProcedureIdleWaiters()
    }

    private func armProcedureTimeout() {
        procedureGeneration &+= 1
        procedureTimedOut = false
        procedureIndicationID = nil
        let generation = procedureGeneration
        let clock = clock
        procedureTimeoutTask = Task {
            do {
                try await clock.sleep(for: Self.procedureTimeout)
            } catch {
                return
            }
            await self.procedureTimeoutElapsed(generation)
        }
    }

    /// Ends the procedure without an indication. A delegate call still running is cancelled and
    /// the procedure ends when it returns, so delegate calls never overlap.
    private func procedureTimeoutElapsed(_ generation: UInt64) async {
        guard generation == procedureGeneration, procedureInProgress, !closed else {
            return
        }
        procedureTimedOut = true
        guard let indicationID = procedureIndicationID else {
            procedureTask?.cancel()
            return
        }
        if removeIndication(id: indicationID) == true {
            wakeReadyWaiterWithoutLatch()
        }
        endProcedure()
    }

    private func resumeProcedureIdleWaiters() {
        let waiters = procedureIdleWaiters
        procedureIdleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeAllAcceptedMeasurementCountWaiters() {
        let waiters = acceptedMeasurementCountWaiters
        acceptedMeasurementCountWaiters.removeAll()
        for (_, continuation) in waiters {
            continuation.resume()
        }
    }

    private func resumeAcceptedMeasurementCountWaiters(for count: Int) {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in acceptedMeasurementCountWaiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        acceptedMeasurementCountWaiters = remaining
    }

    private func enqueueMeasurement(_ item: MeasurementItem) {
        outboundQueue.append(.measurement(item))
        resumeOutboundQueueWaiter()
        resumeOutboundCountWaiters()
    }

    private func enqueueIndication(_ response: CSCControlPointResponse, centralID: UUID) {
        guard !closed, !procedureTimedOut else {
            endProcedure()
            return
        }
        let item = IndicationItem(
            id: UUID(),
            payload: response.encode(),
            centralID: centralID,
        )
        procedureIndicationID = item.id
        outboundQueue.append(.indication(item))
        resumeOutboundQueueWaiter()
        resumeOutboundCountWaiters()
    }

    private func resumeOutboundCountWaiters() {
        let count = outboundQueue.count
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in outboundCountWaiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        outboundCountWaiters = remaining
    }

    private func resumeAllOutboundCountWaiters() {
        let waiters = outboundCountWaiters
        outboundCountWaiters.removeAll()
        for (_, continuation) in waiters {
            continuation.resume()
        }
    }

    private func indicate(
        opcode: UInt8,
        value: CSCControlPointResponseValue,
        to centralID: UUID,
    ) {
        enqueueIndication(
            CSCControlPointResponse(
                requestOpcode: opcode,
                value: value.rawValue,
                parameter: Data(),
            ),
            centralID: centralID,
        )
    }

    private func emitWheel(_ sample: WheelRevolution) async {
        if closed {
            return
        }
        if measurementSubscribers.isEmpty {
            return
        }
        guard let (payload, stamp) = encodeWheelSample(sample) else {
            return
        }

        let item = MeasurementItem(
            payload: payload,
            encodedWheelGeneration: stamp,
            producedWheel: sample,
            producedCrank: nil,
            emitContinuation: nil,
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var queuedItem = item
            queuedItem.emitContinuation = continuation
            enqueueMeasurement(queuedItem)
        }
    }

    private func emitCrank(_ sample: CrankRevolution) async {
        if closed {
            return
        }
        if measurementSubscribers.isEmpty {
            return
        }
        guard let (payload, stamp) = encodeCrankSample(sample) else {
            return
        }

        let item = MeasurementItem(
            payload: payload,
            encodedWheelGeneration: stamp,
            producedWheel: nil,
            producedCrank: sample,
            emitContinuation: nil,
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var queuedItem = item
            queuedItem.emitContinuation = continuation
            enqueueMeasurement(queuedItem)
        }
    }

    private func encodeWheelSample(_ sample: WheelRevolution) -> (Data, UInt64?)? {
        let measurement = CSCMeasurement(
            cumulativeWheelRevolutions: sample.cumulativeRevolutions,
            lastWheelEventTime: sample.lastEventTime,
            cumulativeCrankRevolutions: crankCache?.cumulativeRevolutions,
            lastCrankEventTime: crankCache?.lastEventTime,
        )
        guard let payload = measurement.encode() else {
            return nil
        }
        let stamp: UInt64? = measurement.cumulativeWheelRevolutions != nil ? wheelGeneration : nil
        return (payload, stamp)
    }

    private func encodeCrankSample(_ sample: CrankRevolution) -> (Data, UInt64?)? {
        let measurement = CSCMeasurement(
            cumulativeWheelRevolutions: wheelCache?.cumulativeRevolutions,
            lastWheelEventTime: wheelCache?.lastEventTime,
            cumulativeCrankRevolutions: sample.cumulativeRevolutions,
            lastCrankEventTime: sample.lastEventTime,
        )
        guard let payload = measurement.encode() else {
            return nil
        }
        let stamp: UInt64? = measurement.cumulativeWheelRevolutions != nil ? wheelGeneration : nil
        return (payload, stamp)
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

    /// The only consumer of `peripheral.events`. Handlers run one at a time in arrival order.
    private func spawnInboundTask(stream: AsyncStream<PeripheralEvent>) -> Task<Void, Never> {
        Task {
            for await event in stream {
                if Task.isCancelled {
                    break
                }
                await self.receiveInbound(event)
            }
        }
    }

    private func receiveInbound(_ event: PeripheralEvent) async {
        if closed {
            return
        }
        guard startupGateOpen else {
            pendingInboundEvents.append(event)
            return
        }
        await handleInbound(event)
    }

    private func handleInbound(_ event: PeripheralEvent) async {
        switch event {
        case let .stateUpdated(state):
            await handleRadioState(state)
        case let .read(request):
            await handleRead(request)
        case let .writeTransaction(transaction):
            await handleWrite(transaction)
        case let .subscription(change):
            await handleSubscription(change)
        case .readyToUpdateSubscribers:
            signalNotifyReady()
        }
    }

    func waitUntilNotifyReadyWaiterParked() async {
        if closed || notifyReadyWaiter != nil {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closed || notifyReadyWaiter != nil {
                continuation.resume()
                return
            }
            notifyReadyWaiterParkedWaiters.append(continuation)
        }
    }

    private func resumeNotifyReadyWaiterParkedWaiters() {
        let waiters = notifyReadyWaiterParkedWaiters
        notifyReadyWaiterParkedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func signalNotifyReady() {
        if let waiter = notifyReadyWaiter {
            notifyReadyWaiter = nil
            waiter.resume()
        } else {
            notifyReady = true
        }
    }

    private func waitForNotifyReady() async {
        if closed {
            return
        }
        if notifyReady {
            notifyReady = false
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closed {
                continuation.resume()
                return
            }
            if notifyReady {
                notifyReady = false
                continuation.resume()
                return
            }
            notifyReadyWaiter = continuation
            resumeNotifyReadyWaiterParkedWaiters()
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

        if request.characteristicUUID == CSCS.sensorLocationUUID,
           case .multiple = location,
           let servedSensorLocation
        {
            let value = CSCSensorLocation(
                assignedNumber: servedSensorLocation.read().assignedNumber,
            ).encode()
            let offset = request.offset
            if offset < 0 || offset > value.count {
                return ReadResponse(result: .error(code: 0x07), value: nil)
            }
            if offset == value.count {
                return ReadResponse(result: .success, value: Data())
            }
            return ReadResponse(result: .success, value: Data(value.dropFirst(offset)))
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
        guard transaction.requests.count == 1,
              transaction.requests[0].serviceUUID == service.uuid
        else {
            await respondWriteError(transaction.id, code: 0x03)
            return
        }

        let request = transaction.requests[0]

        guard hasControlPointCharacteristic else {
            await respondWriteError(transaction.id, code: 0x03)
            return
        }

        guard request.characteristicUUID == CSCS.controlPointUUID else {
            await respondWriteError(transaction.id, code: 0x03)
            return
        }

        guard request.offset == 0 else {
            await respondWriteError(transaction.id, code: 0x07)
            return
        }

        guard !request.value.isEmpty,
              let decoded = CSCControlPointRequest.decode(request.value)
        else {
            await respondWriteError(transaction.id, code: 0x0D)
            return
        }

        guard controlPointSubscribers.contains(request.centralID) else {
            await respondWriteError(
                transaction.id,
                code: CSCATTApplicationError.cccdImproperlyConfigured.rawValue,
            )
            return
        }

        guard !procedureInProgress else {
            await respondWriteError(
                transaction.id,
                code: CSCATTApplicationError.procedureAlreadyInProgress.rawValue,
            )
            return
        }

        procedureInProgress = true
        do {
            try await peripheral.respond(to: transaction.id, with: .success, value: nil)
        } catch {
            endProcedure()
            return
        }

        if closed {
            endProcedure()
            return
        }

        armProcedureTimeout()
        let centralID = request.centralID
        let decodedRequest = decoded
        procedureTask = Task {
            await self.runProcedure(decodedRequest, centralID: centralID)
        }
    }

    private func respondWriteError(_ transactionID: UUID, code: UInt8) async {
        do {
            try await peripheral.respond(
                to: transactionID,
                with: .error(code: code),
                value: nil,
            )
        } catch is CancellationError {
        } catch {
        }
    }

    private func runProcedure(_ request: CSCControlPointRequest, centralID: UUID) async {
        switch request {
        case let .setCumulativeValue(value):
            await runSetCumulativeProcedure(value: value, centralID: centralID)
        case let .invalidParameter(opcode, _) where opcode == CSCControlPointOpCode.setCumulativeValue.rawValue:
            if wheel == nil {
                indicate(
                    opcode: CSCControlPointOpCode.setCumulativeValue.rawValue,
                    value: .opCodeNotSupported,
                    to: centralID,
                )
            } else {
                indicate(
                    opcode: CSCControlPointOpCode.setCumulativeValue.rawValue,
                    value: .invalidParameter,
                    to: centralID,
                )
            }
        case .startSensorCalibration:
            indicate(
                opcode: CSCControlPointOpCode.startSensorCalibration.rawValue,
                value: .opCodeNotSupported,
                to: centralID,
            )
        case let .invalidParameter(opcode, _)
            where opcode == CSCControlPointOpCode.updateSensorLocation.rawValue:
            if isMultipleSensorLocations {
                indicate(
                    opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
                    value: .invalidParameter,
                    to: centralID,
                )
            } else {
                indicate(
                    opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
                    value: .opCodeNotSupported,
                    to: centralID,
                )
            }
        case let .invalidParameter(opcode, _)
            where opcode == CSCControlPointOpCode.requestSupportedSensorLocations.rawValue:
            if isMultipleSensorLocations {
                indicate(
                    opcode: CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
                    value: .invalidParameter,
                    to: centralID,
                )
            } else {
                indicate(
                    opcode: CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
                    value: .opCodeNotSupported,
                    to: centralID,
                )
            }
        case let .updateSensorLocation(assignedNumber):
            if isMultipleSensorLocations {
                await runUpdateSensorLocationProcedure(
                    assignedNumber: assignedNumber,
                    centralID: centralID,
                )
            } else {
                indicate(
                    opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
                    value: .opCodeNotSupported,
                    to: centralID,
                )
            }
        case .requestSupportedSensorLocations:
            if isMultipleSensorLocations {
                await runRequestSupportedSensorLocationsProcedure(centralID: centralID)
            } else {
                indicate(
                    opcode: CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
                    value: .opCodeNotSupported,
                    to: centralID,
                )
            }
        case let .invalidParameter(opcode, _):
            indicate(opcode: opcode, value: .opCodeNotSupported, to: centralID)
        case let .unknown(opcode, _):
            indicate(opcode: opcode, value: .opCodeNotSupported, to: centralID)
        }
    }

    private func runSetCumulativeProcedure(value: UInt32, centralID: UUID) async {
        guard let wheel else {
            indicate(
                opcode: CSCControlPointOpCode.setCumulativeValue.rawValue,
                value: .opCodeNotSupported,
                to: centralID,
            )
            return
        }

        let delegate = wheel.delegate
        do {
            try await delegate.setCumulativeWheelRevolutions(value)
        } catch {
            if closed {
                endProcedure()
                return
            }
            indicate(
                opcode: CSCControlPointOpCode.setCumulativeValue.rawValue,
                value: .operationFailed,
                to: centralID,
            )
            return
        }

        if closed {
            endProcedure()
            return
        }

        // wheelGeneration wraps after UInt64.max; a stamp of 0 can match again.
        wheelGeneration &+= 1
        wheelCache = nil
        indicate(
            opcode: CSCControlPointOpCode.setCumulativeValue.rawValue,
            value: .success,
            to: centralID,
        )
        wakeReadyWaiterWithoutLatch()
    }

    private var isMultipleSensorLocations: Bool {
        if case .multiple = location {
            return true
        }
        return false
    }

    private var multipleSensorLocationsConfiguration: MultipleSensorLocationsConfiguration? {
        if case .multiple(let configuration) = location {
            return configuration
        }
        return nil
    }

    private func runUpdateSensorLocationProcedure(assignedNumber: UInt8, centralID: UUID) async {
        guard let configuration = multipleSensorLocationsConfiguration else {
            endProcedure()
            return
        }

        guard let kind = configuration.supported.first(where: { $0.assignedNumber == assignedNumber }) else {
            indicate(
                opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
                value: .invalidParameter,
                to: centralID,
            )
            return
        }

        let delegate = configuration.delegate
        do {
            try await delegate.update(kind)
        } catch {
            if closed {
                endProcedure()
                return
            }
            indicate(
                opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
                value: .operationFailed,
                to: centralID,
            )
            return
        }

        servedSensorLocation?.store(kind)

        if closed {
            endProcedure()
            return
        }

        indicate(
            opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
            value: .success,
            to: centralID,
        )
    }

    private func runRequestSupportedSensorLocationsProcedure(centralID: UUID) async {
        guard let configuration = multipleSensorLocationsConfiguration else {
            endProcedure()
            return
        }

        if closed {
            endProcedure()
            return
        }

        enqueueIndication(
            CSCControlPointResponse(
                requestOpcode: CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
                value: CSCControlPointResponseValue.success.rawValue,
                parameter: Data(configuration.supported.map(\.assignedNumber)),
            ),
            centralID: centralID,
        )
    }

    private func handleSubscription(_ change: SubscriptionChange) async {
        switch change {
        case let .subscribed(centralID, serviceUUID, characteristicUUID):
            guard serviceUUID == service.uuid else {
                return
            }
            switch characteristicUUID {
            case CSCS.measurementUUID:
                let inserted = measurementSubscribers.insert(centralID).inserted
                if inserted {
                    await notifyMeasurementSubscriberCount()
                }
                resumeMeasurementSubscriberWaiters()
            case CSCS.controlPointUUID:
                controlPointSubscribers.insert(centralID)
                resumeControlPointSubscriberWaiters()
            default:
                return
            }
        case let .unsubscribed(centralID, serviceUUID, characteristicUUID):
            guard serviceUUID == service.uuid else {
                return
            }
            switch characteristicUUID {
            case CSCS.measurementUUID:
                let removed = measurementSubscribers.remove(centralID) != nil
                if removed {
                    await notifyMeasurementSubscriberCount()
                }
                resumeMeasurementSubscriberWaiters()
            case CSCS.controlPointUUID:
                controlPointSubscribers.remove(centralID)
                resumeControlPointSubscriberWaiters()
                dropQueuedIndications(for: centralID)
            default:
                return
            }
        }
    }

    private func dropQueuedIndications(for centralID: UUID) {
        let ids = outboundQueue.compactMap { item -> UUID? in
            if case .indication(let indication) = item, indication.centralID == centralID {
                return indication.id
            }
            return nil
        }
        for id in ids {
            let isProcedureIndication = id == procedureIndicationID
            guard let wasHead = removeIndication(id: id) else {
                continue
            }
            if wasHead {
                endProcedure()
                wakeReadyWaiterWithoutLatch()
            } else if isProcedureIndication {
                endProcedure()
            }
        }
    }

    private func resumeMeasurementSubscriberWaiters() {
        let pending = measurementSubscriberWaiters
        measurementSubscriberWaiters.removeAll()
        for waiter in pending {
            if measurementSubscribers == waiter.expected {
                waiter.continuation.resume()
            } else {
                measurementSubscriberWaiters.append(waiter)
            }
        }
        resumeMeasurementSubscriberWaiterParkedWaiters()
    }

    private func resumeControlPointSubscriberWaiters() {
        let pending = controlPointSubscriberWaiters
        controlPointSubscriberWaiters.removeAll()
        for waiter in pending {
            if controlPointSubscribers == waiter.expected {
                waiter.continuation.resume()
            } else {
                controlPointSubscriberWaiters.append(waiter)
            }
        }
    }

    private func resumeAllMeasurementSubscriberWaiters() {
        let pending = measurementSubscriberWaiters
        measurementSubscriberWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume()
        }
    }

    private func resumeAllControlPointSubscriberWaiters() {
        let pending = controlPointSubscriberWaiters
        controlPointSubscriberWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume()
        }
    }

    private func resumeMeasurementSubscriberWaiterParkedWaiters() {
        guard !measurementSubscriberWaiters.isEmpty else {
            return
        }
        let waiters = measurementSubscriberWaiterParkedWaiters
        measurementSubscriberWaiterParkedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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

                await self.emitCrank(revolution)
            }
        }
    }

    private func startWheelLoopIfNeeded() {
        guard let wheel else {
            return
        }

        let sequence = wheel.revolutions
        wheelTask = Task {
            let iterator = sequence.makeAsyncIterator()
            while !Task.isCancelled {
                let revolution: WheelRevolution?
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

                await self.emitWheel(revolution)
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
            case .notPoweredOn:
                return .notPoweredOn
            case .advertisingFailed(let reason):
                return .advertisingFailed(reason: reason)
            default:
                return .advertisingFailed(reason: String(describing: peripheralError))
            }
        }
        return .advertisingFailed(reason: String(describing: error))
    }
}
