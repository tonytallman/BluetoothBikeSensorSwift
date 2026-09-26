import Foundation
internal import CSCWire

actor ServerSession {
    private enum PublishStage: Sendable {
        case none
        case serviceAdded
        case advertising
    }

    private enum StaleHeadResolution {
        case removed
        case send(QueuedMeasurement)
    }

    private enum RevolutionSample: Sendable {
        case wheel(WheelRevolution)
        case crank(CrankRevolution)
    }

    private struct QueuedMeasurement {
        var payload: Data
        var encodedWheelGeneration: UInt64?
        let sample: RevolutionSample
        var producerContinuation: CheckedContinuation<Void, Never>?
    }

    private struct QueuedIndication {
        let id: UUID
        let payload: Data
        let centralID: UUID
    }

    private enum OutboundItem {
        case measurement(QueuedMeasurement)
        case indication(QueuedIndication)
    }

    private let configuration: ServerConfiguration
    private let peripheral: any BluetoothPeripheral
    private let clock: any ServerClock
    private let onMeasurementSubscriberCountChange: @Sendable (Int) async -> Void

    private var publishStage: PublishStage = .none
    private var closed = false
    private var measurementSubscribers: Set<UUID> = []
    private var controlPointSubscribers: Set<UUID> = []
    private var testWaiters: [(condition: ServerTestCondition, continuation: CheckedContinuation<Void, Never>)] = []

    private var powerLossCountAtStartup = 0
    private var isSuspended = false
    private var suspensionEpoch: UInt64 = 0
    private var lastBluetoothState: BluetoothState = .poweredOn
    private var isPublishingSubscriberCount = false
    private var recoveryInProgress = false

    private var isReadyToUpdate = false
    private var readyToUpdateWaiter: CheckedContinuation<Void, Never>?

    private var isStartupComplete = false
    private var pendingInboundEvents: [PeripheralEvent] = []

    private var wheelCache: WheelRevolution?
    private var crankCache: CrankRevolution?
    private var wheelGeneration: UInt64 = 0

    private var outboundQueue: [OutboundItem] = []
    private var outboundQueueWaiter: CheckedContinuation<Void, Never>?

    private static let procedureTimeout: Duration = .seconds(30)

    private var procedureInProgress = false
    private var procedureIndicationID: UUID?
    private var procedureGeneration: UInt64 = 0
    private var procedureTimedOut = false
    private var procedureTimeoutTask: Task<Void, Never>?

    private var acceptedMeasurementCount = 0

    private let servedSensorLocation: ServedSensorLocationBox?

    private var inboundTask: Task<Void, Never>?
    private var outboundPumpTask: Task<Void, Never>?
    private var wheelTask: Task<Void, Never>?
    private var crankTask: Task<Void, Never>?
    private var procedureTask: Task<Void, Never>?

    private init(
        configuration: ServerConfiguration,
        servedSensorLocation: ServedSensorLocationBox?,
        peripheral: any BluetoothPeripheral,
        clock: any ServerClock,
        onMeasurementSubscriberCountChange: @escaping @Sendable (Int) async -> Void,
    ) {
        self.configuration = configuration
        self.servedSensorLocation = servedSensorLocation
        self.peripheral = peripheral
        self.clock = clock
        self.onMeasurementSubscriberCountChange = onMeasurementSubscriberCountChange
    }

    static func open(
        configuration: ServerConfiguration,
        servedSensorLocation: ServedSensorLocationBox?,
        peripheral: any BluetoothPeripheral,
        clock: any ServerClock,
        onMeasurementSubscriberCountChange: @escaping @Sendable (Int) async -> Void,
    ) async throws -> ServerSession {
        let session = ServerSession(
            configuration: configuration,
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

    // MARK: - Opening and closing

    func waitUntil(_ condition: ServerTestCondition) async {
        guard !isSatisfied(condition) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            testWaiters.append((condition, continuation))
            resumeSatisfiedTestWaiters()
        }
    }

    private func isSatisfied(_ condition: ServerTestCondition) -> Bool {
        (closed && condition.isSatisfiedByClose) || isMet(condition)
    }

    private func isMet(_ condition: ServerTestCondition) -> Bool {
        switch condition {
        case let .measurementSubscribers(ids):
            return !isPublishingSubscriberCount && measurementSubscribers == ids
        case let .controlPointSubscribers(ids):
            return controlPointSubscribers == ids
        case let .acceptedMeasurementCount(atLeast: count):
            return acceptedMeasurementCount >= count
        case let .outboundCount(atLeast: count):
            return outboundQueue.count >= count
        case .readyToUpdateWaiterParked:
            return readyToUpdateWaiter != nil
        case .controlPointProcedureIdle:
            return !procedureInProgress
        case .measurementSubscriberWaiterParked:
            return testWaiters.contains { entry in
                if case .measurementSubscribers = entry.condition {
                    return true
                }
                return false
            }
        case .bluetoothRecoveryIdle:
            return !recoveryInProgress
        }
    }

    private func resumeSatisfiedTestWaiters() {
        var remaining: [(condition: ServerTestCondition, continuation: CheckedContinuation<Void, Never>)] = []
        for entry in testWaiters {
            if case .measurementSubscriberWaiterParked = entry.condition {
                remaining.append(entry)
                continue
            }
            if isSatisfied(entry.condition) {
                entry.continuation.resume()
            } else {
                remaining.append(entry)
            }
        }
        testWaiters = remaining

        var afterSecondPass: [(condition: ServerTestCondition, continuation: CheckedContinuation<Void, Never>)] = []
        for entry in testWaiters {
            if isSatisfied(entry.condition) {
                entry.continuation.resume()
            } else {
                afterSecondPass.append(entry)
            }
        }
        testWaiters = afterSecondPass
    }

    func close() async {
        beginShutdown()
        await stopTasks()
        await tearDown(stoppingAdvertising: true)
    }

    private func beginShutdown() {
        closed = true
        pendingInboundEvents.removeAll()
        resumeReadyToUpdateWaiter()
        resumeOutboundQueueWaiter()
        resumeSatisfiedTestWaiters()
    }

    private func stopTasks() async {
        let timeoutTask = procedureTimeoutTask
        outboundPumpTask?.cancel()
        procedureTask?.cancel()
        timeoutTask?.cancel()
        wheelTask?.cancel()
        crankTask?.cancel()

        _ = await outboundPumpTask?.value
        _ = await procedureTask?.value
        _ = await timeoutTask?.value
        _ = await wheelTask?.value
        _ = await crankTask?.value

        outboundPumpTask = nil
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

    // MARK: - Startup and teardown

    private func startup() async throws {
        try await waitForPoweredOn()
        powerLossCountAtStartup = await peripheral.powerLossCount

        let eventStream = await peripheral.events
        inboundTask = spawnInboundTask(stream: eventStream)

        do {
            try await peripheral.add(configuration.service)
            publishStage = .serviceAdded
        } catch {
            throw serverError(from: error, during: .addService)
        }

        if closed || Task.isCancelled {
            throw CancellationError()
        }

        do {
            try await peripheral.startAdvertising(serviceUUIDs: [configuration.service.uuid])
        } catch {
            throw serverError(from: error, during: .startAdvertising)
        }
        publishStage = .advertising

        if closed || Task.isCancelled {
            throw CancellationError()
        }

        // A loss during startup fails start() even if power came back before the calls finished.
        if await peripheral.powerLossCount != powerLossCountAtStartup {
            throw ServerError.notPoweredOn
        }

        outboundPumpTask = spawnOutboundPumpTask()
        await drainPendingInboundEvents()
        if closed || Task.isCancelled {
            throw CancellationError()
        }
        crankTask = startRevolutionLoop(configuration.crankRevolutions, as: { .crank($0) })
        wheelTask = startRevolutionLoop(configuration.wheel?.revolutions, as: { .wheel($0) })
        isStartupComplete = true
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
        await tearDown(stoppingAdvertising: publishStage == .advertising)
    }

    private func tearDown(stoppingAdvertising: Bool) async {
        if stoppingAdvertising {
            await peripheral.stopAdvertising()
        }

        if publishStage != .none {
            try? await peripheral.removeService(uuid: configuration.service.uuid)
        }
        publishStage = .none

        await stopInboundTask()

        measurementSubscribers.removeAll()
        controlPointSubscribers.removeAll()
        await notifyMeasurementSubscriberCount()
    }

    private func notifyMeasurementSubscriberCount() async {
        isPublishingSubscriberCount = true
        await onMeasurementSubscriberCountChange(measurementSubscribers.count)
        isPublishingSubscriberCount = false
    }

    /// Settles any recovery already in progress before answering.
    func isRadioSuspended() async -> Bool {
        await waitUntil(.bluetoothRecoveryIdle)
        return isSuspended
    }

    // MARK: - Radio recovery

    private func handleBluetoothState(_ state: BluetoothState) async {
        let previous = lastBluetoothState
        lastBluetoothState = state
        guard state == .poweredOn else {
            if !isSuspended {
                await suspendForRadioLoss()
            }
            return
        }
        // Retrying needs a real transition back into .poweredOn, not a duplicate event.
        guard previous != .poweredOn, isSuspended, !closed else {
            return
        }
        recoveryInProgress = true
        await recoverFromRadioLoss()
        recoveryInProgress = false
        resumeSatisfiedTestWaiters()
    }

    private func suspendForRadioLoss() async {
        isSuspended = true
        suspensionEpoch &+= 1
        measurementSubscribers.removeAll()
        controlPointSubscribers.removeAll()
        isReadyToUpdate = false
        resumeReadyToUpdateWaiter()
        await notifyMeasurementSubscriberCount()
        resumeSatisfiedTestWaiters()
    }

    /// Republishes the build-time service. `close()` may run during any await here and owns
    /// teardown; this removes only what it published after `closed` is set.
    private func recoverFromRadioLoss() async {
        await peripheral.stopAdvertising()
        if closed {
            return
        }
        if publishStage != .none {
            try? await peripheral.removeService(uuid: configuration.service.uuid)
            publishStage = .none
        }
        if closed {
            return
        }

        do {
            try await peripheral.add(configuration.service)
        } catch {
            return
        }
        publishStage = .serviceAdded
        if closed {
            try? await peripheral.removeService(uuid: configuration.service.uuid)
            publishStage = .none
            return
        }

        do {
            try await peripheral.startAdvertising(serviceUUIDs: [configuration.service.uuid])
        } catch {
            try? await peripheral.removeService(uuid: configuration.service.uuid)
            publishStage = .none
            return
        }
        if closed {
            await peripheral.stopAdvertising()
            if publishStage != .none {
                try? await peripheral.removeService(uuid: configuration.service.uuid)
                publishStage = .none
            }
            return
        }

        publishStage = .advertising
        isReadyToUpdate = false
        isSuspended = false
    }

    private func isStaleWheelPayload(_ item: QueuedMeasurement) -> Bool {
        guard let stamp = item.encodedWheelGeneration else {
            return false
        }
        return stamp != wheelGeneration
    }

    // MARK: - Outbound pump

    private func spawnOutboundPumpTask() -> Task<Void, Never> {
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
                await processQueuedMeasurement()
            case .indication:
                await processQueuedIndication()
            }
        }
        if closed {
            drainOutboundQueueOnShutdown()
        }
    }

    private func waitForOutboundQueueItem() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closed || !outboundQueue.isEmpty {
                continuation.resume()
            } else {
                outboundQueueWaiter = continuation
            }
        }
    }

    private func resumeOutboundQueueWaiter() {
        if let waiter = outboundQueueWaiter {
            outboundQueueWaiter = nil
            waiter.resume()
        }
    }

    private func resumeReadyToUpdateWaiter() {
        if let waiter = readyToUpdateWaiter {
            readyToUpdateWaiter = nil
            waiter.resume()
        }
    }

    private func resolveStaleHead(_ item: QueuedMeasurement) -> StaleHeadResolution {
        guard isStaleWheelPayload(item) else {
            return .send(item)
        }
        guard case let .crank(crank) = item.sample,
              let payload = CSCMeasurement(
                  cumulativeCrankRevolutions: crank.cumulativeRevolutions,
                  lastCrankEventTime: crank.lastEventTime,
              ).encode()
        else {
            return .removed
        }
        var updated = item
        updated.payload = payload
        updated.encodedWheelGeneration = nil
        outboundQueue[0] = .measurement(updated)
        return .send(updated)
    }

    @discardableResult
    private func prepareHead(_ item: inout QueuedMeasurement) -> Bool {
        if closed {
            finishHeadMeasurement(&item)
            drainOutboundQueueOnShutdown()
            return false
        }
        if measurementSubscribers.isEmpty {
            finishHeadMeasurement(&item)
            return false
        }
        switch resolveStaleHead(item) {
        case .removed:
            finishHeadMeasurement(&item)
            return false
        case .send(let current):
            item = current
            return true
        }
    }

    private func finishHeadMeasurement(_ item: inout QueuedMeasurement) {
        outboundQueue.removeFirst()
        resumeProducer(&item)
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
    private func dropIndicationIfCentralDeparted(_ indication: QueuedIndication) -> Bool {
        guard !controlPointSubscribers.contains(indication.centralID) else {
            return false
        }
        finishHeadIndication(indication.id)
        return true
    }

    private func processQueuedMeasurement() async {
        guard case var .measurement(item) = outboundQueue.first else {
            return
        }

        while !Task.isCancelled {
            guard prepareHead(&item) else {
                return
            }

            isReadyToUpdate = false
            let lossEpoch = suspensionEpoch
            let accepted: Bool
            do {
                accepted = try await peripheral.updateValue(
                    item.payload,
                    serviceUUID: configuration.service.uuid,
                    characteristicUUID: CSCS.measurementUUID,
                    onSubscribedCentrals: nil,
                )
            } catch {
                finishHeadMeasurement(&item)
                return
            }

            if accepted {
                if suspensionEpoch == lossEpoch {
                    recordAcceptedMeasurement(item)
                }
                finishHeadMeasurement(&item)
                return
            }

            if closed {
                drainOutboundQueueOnShutdown()
                return
            }

            await waitForReadyToUpdate()
            if closed {
                drainOutboundQueueOnShutdown()
                return
            }
        }
    }

    private func recordAcceptedMeasurement(_ item: QueuedMeasurement) {
        if isStaleWheelPayload(item) {
            if case let .crank(crank) = item.sample {
                crankCache = crank
            }
            return
        }
        switch item.sample {
        case let .wheel(wheel):
            wheelCache = wheel
        case let .crank(crank):
            crankCache = crank
        }
        acceptedMeasurementCount += 1
        resumeSatisfiedTestWaiters()
    }

    private func processQueuedIndication() async {
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
                finishHeadIndication(indicationID)
                drainOutboundQueueOnShutdown()
                return
            }

            if dropIndicationIfCentralDeparted(indication) {
                return
            }

            isReadyToUpdate = false
            let accepted: Bool
            do {
                accepted = try await peripheral.updateValue(
                    indication.payload,
                    serviceUUID: configuration.service.uuid,
                    characteristicUUID: CSCS.controlPointUUID,
                    onSubscribedCentrals: [indication.centralID],
                )
            } catch {
                finishHeadIndication(indicationID)
                return
            }

            guard isHeadIndication(indicationID) else {
                return
            }

            if accepted {
                finishHeadIndication(indicationID)
                return
            }

            if closed {
                drainOutboundQueueOnShutdown()
                return
            }

            if dropIndicationIfCentralDeparted(indication) {
                return
            }

            await waitForReadyToUpdate()

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

    private func finishHeadIndication(_ id: UUID) {
        if removeHeadIndicationIfOwned(id) {
            endProcedure()
        }
    }

    private func drainOutboundQueueOnShutdown() {
        while !outboundQueue.isEmpty {
            switch outboundQueue.removeFirst() {
            case var .measurement(item):
                resumeProducer(&item)
            case .indication:
                break
            }
        }
        if procedureInProgress {
            endProcedure()
        }
    }

    private func resumeProducer(_ item: inout QueuedMeasurement) {
        if let continuation = item.producerContinuation {
            item.producerContinuation = nil
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
        resumeSatisfiedTestWaiters()
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
            resumeReadyToUpdateWaiter()
        }
        endProcedure()
    }

    private func enqueueMeasurement(_ item: QueuedMeasurement) {
        outboundQueue.append(.measurement(item))
        resumeOutboundQueueWaiter()
        resumeSatisfiedTestWaiters()
    }

    private func enqueueIndication(_ response: CSCControlPointResponse, centralID: UUID) {
        guard !closed, !procedureTimedOut else {
            endProcedure()
            return
        }
        let item = QueuedIndication(
            id: UUID(),
            payload: response.encode(),
            centralID: centralID,
        )
        procedureIndicationID = item.id
        outboundQueue.append(.indication(item))
        resumeOutboundQueueWaiter()
        resumeSatisfiedTestWaiters()
    }

    private func indicate(
        opcode: UInt8,
        value: CSCControlPointResponseValue,
        parameter: Data = Data(),
        to centralID: UUID,
    ) {
        enqueueIndication(
            CSCControlPointResponse(
                requestOpcode: opcode,
                value: value.rawValue,
                parameter: parameter,
            ),
            centralID: centralID,
        )
    }

    private func emit(_ sample: RevolutionSample) async {
        if closed {
            return
        }
        if measurementSubscribers.isEmpty {
            return
        }
        guard let (payload, stamp) = encodeSample(sample) else {
            return
        }

        let item = QueuedMeasurement(
            payload: payload,
            encodedWheelGeneration: stamp,
            sample: sample,
            producerContinuation: nil,
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var queuedItem = item
            queuedItem.producerContinuation = continuation
            enqueueMeasurement(queuedItem)
        }
    }

    private func encodeSample(_ sample: RevolutionSample) -> (Data, UInt64?)? {
        let measurement: CSCMeasurement
        switch sample {
        case let .wheel(wheel):
            measurement = CSCMeasurement(
                cumulativeWheelRevolutions: wheel.cumulativeRevolutions,
                lastWheelEventTime: wheel.lastEventTime,
                cumulativeCrankRevolutions: crankCache?.cumulativeRevolutions,
                lastCrankEventTime: crankCache?.lastEventTime,
            )
        case let .crank(crank):
            measurement = CSCMeasurement(
                cumulativeWheelRevolutions: wheelCache?.cumulativeRevolutions,
                lastWheelEventTime: wheelCache?.lastEventTime,
                cumulativeCrankRevolutions: crank.cumulativeRevolutions,
                lastCrankEventTime: crank.lastEventTime,
            )
        }
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
    // MARK: - Inbound events

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
        guard isStartupComplete else {
            pendingInboundEvents.append(event)
            return
        }
        await handleInbound(event)
    }

    private func handleInbound(_ event: PeripheralEvent) async {
        switch event {
        case let .stateUpdated(state):
            await handleBluetoothState(state)
        case let .read(request):
            await handleRead(request)
        case let .writeTransaction(transaction):
            await handleWrite(transaction)
        case let .subscription(change):
            await handleSubscription(change)
        case .readyToUpdateSubscribers:
            signalReadyToUpdate()
        }
    }

    private func signalReadyToUpdate() {
        if readyToUpdateWaiter != nil {
            resumeReadyToUpdateWaiter()
        } else {
            isReadyToUpdate = true
        }
    }

    private func waitForReadyToUpdate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if closed {
                continuation.resume()
            } else if isReadyToUpdate {
                isReadyToUpdate = false
                continuation.resume()
            } else {
                readyToUpdateWaiter = continuation
                resumeSatisfiedTestWaiters()
            }
        }
    }

    private func handleRead(_ request: PeripheralReadRequest) async {
        let (result, value) = readResponse(for: request)
        try? await peripheral.respond(
            to: request.id,
            with: result,
            value: value,
        )
    }

    private func readResponse(for request: PeripheralReadRequest) -> (ATTResult, Data?) {
        guard request.serviceUUID == configuration.service.uuid else {
            return (.error(code: 0x0A), nil)
        }

        guard let characteristic = configuration.service.characteristics.first(where: {
            $0.uuid == request.characteristicUUID
        }) else {
            return (.error(code: 0x0A), nil)
        }

        if characteristic.uuid == CSCS.sensorLocationUUID,
           case .multiple = configuration.location,
           let servedSensorLocation
        {
            let value = CSCSensorLocation(
                assignedNumber: servedSensorLocation.read().assignedNumber,
            ).encode()
            return offsetSlice(of: value, offset: request.offset)
        }

        guard let value = characteristic.value else {
            return (.error(code: 0x02), nil)
        }

        return offsetSlice(of: value, offset: request.offset)
    }

    private func offsetSlice(of value: Data, offset: Int) -> (ATTResult, Data?) {
        if offset < 0 || offset > value.count {
            return (.error(code: 0x07), nil)
        }
        return (.success, Data(value.dropFirst(offset)))
    }

    // MARK: - Control point

    private func handleWrite(_ transaction: PeripheralWriteTransaction) async {
        guard transaction.requests.count == 1,
              let request = transaction.requests.first,
              request.serviceUUID == configuration.service.uuid,
              configuration.includesControlPoint,
              request.characteristicUUID == CSCS.controlPointUUID
        else {
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
        try? await peripheral.respond(
            to: transactionID,
            with: .error(code: code),
            value: nil,
        )
    }

    private func opcode(of request: CSCControlPointRequest) -> UInt8 {
        switch request {
        case .setCumulativeValue:
            return CSCControlPointOpCode.setCumulativeValue.rawValue
        case .startSensorCalibration:
            return CSCControlPointOpCode.startSensorCalibration.rawValue
        case .updateSensorLocation:
            return CSCControlPointOpCode.updateSensorLocation.rawValue
        case .requestSupportedSensorLocations:
            return CSCControlPointOpCode.requestSupportedSensorLocations.rawValue
        case let .invalidParameter(opcode, _):
            return opcode
        case let .unknown(opcode, _):
            return opcode
        }
    }

    private func supportsProcedure(_ opcode: UInt8) -> Bool {
        switch opcode {
        case CSCControlPointOpCode.setCumulativeValue.rawValue:
            return configuration.wheel != nil
        case CSCControlPointOpCode.updateSensorLocation.rawValue,
             CSCControlPointOpCode.requestSupportedSensorLocations.rawValue:
            return configuration.location.multipleLocations != nil
        default:
            return false
        }
    }

    private func runProcedure(_ request: CSCControlPointRequest, centralID: UUID) async {
        switch (request, configuration.wheel, configuration.location.multipleLocations) {
        case let (.setCumulativeValue(value), wheel?, _):
            do {
                try await wheel.delegate.setCumulativeWheelRevolutions(value)
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
            wheelGeneration &+= 1
            wheelCache = nil
            indicate(
                opcode: CSCControlPointOpCode.setCumulativeValue.rawValue,
                value: .success,
                to: centralID,
            )
            resumeReadyToUpdateWaiter()

        case let (.updateSensorLocation(assignedNumber), _, locations?):
            guard let kind = locations.supported.first(where: { $0.assignedNumber == assignedNumber }) else {
                indicate(
                    opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
                    value: .invalidParameter,
                    to: centralID,
                )
                return
            }
            do {
                try await locations.delegate.update(kind)
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

        case (.requestSupportedSensorLocations, _, let locations?):
            if closed {
                endProcedure()
                return
            }
            indicate(
                opcode: CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
                value: .success,
                parameter: Data(locations.supported.map(\.assignedNumber)),
                to: centralID,
            )

        case let (.invalidParameter(opcode, _), _, _) where supportsProcedure(opcode):
            indicate(opcode: opcode, value: .invalidParameter, to: centralID)

        default:
            indicate(opcode: opcode(of: request), value: .opCodeNotSupported, to: centralID)
        }
    }

    private func handleSubscription(_ change: SubscriptionChange) async {
        switch change {
        case let .subscribed(centralID, serviceUUID, characteristicUUID):
            guard serviceUUID == configuration.service.uuid else {
                return
            }
            switch characteristicUUID {
            case CSCS.measurementUUID:
                let inserted = measurementSubscribers.insert(centralID).inserted
                if inserted {
                    await notifyMeasurementSubscriberCount()
                }
                resumeSatisfiedTestWaiters()
            case CSCS.controlPointUUID:
                controlPointSubscribers.insert(centralID)
                resumeSatisfiedTestWaiters()
            default:
                return
            }
        case let .unsubscribed(centralID, serviceUUID, characteristicUUID):
            guard serviceUUID == configuration.service.uuid else {
                return
            }
            switch characteristicUUID {
            case CSCS.measurementUUID:
                let removed = measurementSubscribers.remove(centralID) != nil
                if removed {
                    await notifyMeasurementSubscriberCount()
                }
                resumeSatisfiedTestWaiters()
            case CSCS.controlPointUUID:
                controlPointSubscribers.remove(centralID)
                resumeSatisfiedTestWaiters()
                dropQueuedIndications(for: centralID)
            default:
                return
            }
        }
    }

    /// At most one control-point indication is queued per central.
    private func dropQueuedIndications(for centralID: UUID) {
        guard let index = outboundQueue.firstIndex(where: { item in
            if case .indication(let indication) = item {
                return indication.centralID == centralID
            }
            return false
        }), case .indication(let indication) = outboundQueue[index] else {
            return
        }
        let isProcedureIndication = indication.id == procedureIndicationID
        let wasHead = index == 0
        outboundQueue.remove(at: index)
        if wasHead {
            endProcedure()
            resumeReadyToUpdateWaiter()
        } else if isProcedureIndication {
            endProcedure()
        }
    }

    // MARK: - Revolution loops

    private func startRevolutionLoop<Element: Sendable>(
        _ sequence: AnyAsyncSequence<Element>?,
        as map: @escaping @Sendable (Element) -> RevolutionSample,
    ) -> Task<Void, Never>? {
        guard let sequence else {
            return nil
        }
        return Task {
            do {
                for try await element in sequence {
                    await self.emit(map(element))
                }
            } catch {
            }
        }
    }

    private enum StartupStage {
        case addService
        case startAdvertising
    }

    private func serverError(from error: Error, during stage: StartupStage) -> ServerError {
        if let serverError = error as? ServerError {
            return serverError
        }
        if let peripheralError = error as? BluetoothPeripheralError {
            switch (peripheralError, stage) {
            case (.notPoweredOn, _):
                return .notPoweredOn
            case let (.advertisingFailed(reason), _):
                return .advertisingFailed(reason: reason)
            case let (.addServiceFailed(_, reason), .addService):
                return .publishFailed(reason: reason)
            case (_, .addService):
                return .publishFailed(reason: String(describing: peripheralError))
            case (_, .startAdvertising):
                return .advertisingFailed(reason: String(describing: peripheralError))
            }
        }
        switch stage {
        case .addService:
            return .publishFailed(reason: String(describing: error))
        case .startAdvertising:
            return .advertisingFailed(reason: String(describing: error))
        }
    }
}
