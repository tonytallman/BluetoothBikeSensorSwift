import Foundation
internal import CSCWire

/// Owns one start-to-stop lifetime of a published CSC GATT service: the inbound event loop, the
/// outbound notify/indicate pump, SC Control Point procedures, and Bluetooth suspend/recovery.
///
/// A `Server` creates a new `ServerSession` on every `start()`; `stop()` (or a startup failure)
/// discards it — there is no reuse. All mutable state below is actor-isolated; the only code that
/// runs outside actor isolation is the delegate/fake peripheral on the other side of the
/// `BluetoothPeripheral` seam.
actor ServerSession {
    /// Tracks how much of the build-time service is currently published, so `close()`,
    /// `rollbackStartup()`, and radio recovery each undo only what they actually published.
    private enum PublishStage: Sendable {
        case none
        case serviceAdded
        case advertising
    }

    /// Result of re-checking the outbound queue head for staleness immediately before sending.
    private enum StaleHeadResolution {
        /// The head was removed (and its producer resumed) without being sent.
        case removed
        /// The head is safe to send, possibly re-encoded as `QueuedMeasurement` in the crank-only
        /// fallback case.
        case send(QueuedMeasurement)
    }

    /// Identifies which source produced a queued measurement, so an accepted send updates the
    /// right cache (``wheelCache``/``crankCache``) and a stale wheel payload can be re-encoded
    /// crank-only.
    private enum RevolutionSample: Sendable {
        case wheel(WheelRevolution)
        case crank(CrankRevolution)
    }

    /// One queued measurement send. `encodedWheelGeneration` is the ``wheelGeneration`` this
    /// payload's wheel half was encoded against, or `nil` if it has no wheel half; a mismatch
    /// against the current generation marks it stale (see ``isStaleWheelPayload(_:)``).
    /// `producerContinuation` resumes the emitting loop once the item leaves the queue, whether
    /// sent, dropped, or discarded at shutdown.
    private struct QueuedMeasurement {
        var payload: Data
        var encodedWheelGeneration: UInt64?
        let sample: RevolutionSample
        var producerContinuation: CheckedContinuation<Void, Never>?
    }

    /// One queued SC Control Point indication. `id` is stable identity used to find this item
    /// again after the pump suspends mid-send (via ``waitForReadyToUpdate()``), since something
    /// else (unsubscribe, timeout) may have removed it from the queue while suspended.
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

    /// `powerLossCount` captured right after the startup power wait; if it has changed by the
    /// time `startAdvertising` succeeds, Bluetooth was lost and regained mid-startup and startup
    /// rolls back and throws `.notPoweredOn` even though the calls themselves succeeded.
    private var powerLossCountAtStartup = 0
    private var isSuspended = false
    /// Bumped on every suspension. A measurement send whose `updateValue` await straddles a
    /// suspension is not recorded as accepted, even if it returns `true`, because it reached no
    /// current subscriber (see ``processQueuedMeasurement()``).
    private var suspensionEpoch: UInt64 = 0
    /// Last state seen by `handleBluetoothState`, used to require a genuine transition into
    /// `.poweredOn` (not a duplicate `.poweredOn` event) before attempting recovery.
    private var lastBluetoothState: BluetoothState = .poweredOn
    /// Set for the duration of `onMeasurementSubscriberCountChange`'s await. While set, a
    /// `.measurementSubscribers` test condition is never considered met, so a test cannot observe
    /// the subscriber set change before the published count has actually propagated.
    private var isPublishingSubscriberCount = false
    private var recoveryInProgress = false

    /// Ready-to-update latch for CoreBluetooth backpressure. The inbound loop sets it when the
    /// pump is not parked; the pump clears it immediately before every `updateValue` call and
    /// parks `readyToUpdateWaiter` only when it must wait. At most one waiter exists at a time,
    /// because the pump is the only consumer. `resumeReadyToUpdateWaiter()` wakes a parked waiter
    /// without setting the latch — used by wakeups that are not a real CoreBluetooth ready signal
    /// (a successful Set Cumulative Value, a dropped queue head).
    private var isReadyToUpdate = false
    private var readyToUpdateWaiter: CheckedContinuation<Void, Never>?

    /// Buffers inbound events that arrive before startup finishes, so `add`/`startAdvertising`
    /// races with an eager central do not lose events. Drained, and the gate flipped, with no
    /// `await` in between (see ``drainPendingInboundEvents()``).
    private var isStartupComplete = false
    private var pendingInboundEvents: [PeripheralEvent] = []

    /// Last accepted half of a combined CSC Measurement from each source, used to fill in the
    /// other half when only one source produces a new sample.
    private var wheelCache: WheelRevolution?
    private var crankCache: CrankRevolution?
    /// Bumped on every successful Set Cumulative Value. Stamps queued wheel-bearing payloads so
    /// one still queued when the value changes can be recognized as stale and dropped or
    /// recomputed. Wraps after `UInt64.max`; a stamp of `0` can then match again, which is
    /// accepted as harmless.
    private var wheelGeneration: UInt64 = 0

    /// The single outbound FIFO. Only ``runOutboundPump()`` removes the head; everything else
    /// (unsubscribe, timeout, radio loss) removes queued indications by id instead, since the
    /// pump may already be mid-send on the head.
    private var outboundQueue: [OutboundItem] = []
    private var outboundQueueWaiter: CheckedContinuation<Void, Never>?

    /// CSCS §3.4.4: CoreBluetooth never reports the ATT confirmation for an indication, so the
    /// server bounds what it controls with its own budget from the accepted write to the
    /// indication being handed to `updateValue`.
    private static let procedureTimeout: Duration = .seconds(30)

    private var procedureInProgress = false
    /// The queued indication that owns the current procedure, or `nil` while its delegate call
    /// is still running (before the indication exists).
    private var procedureIndicationID: UUID?
    /// Bumped on every new procedure so a timeout task armed for an earlier procedure recognizes
    /// it is stale and no-ops instead of ending a procedure it no longer owns.
    private var procedureGeneration: UInt64 = 0
    /// Set when the 30 s budget elapses. Blocks a delegate call that returns successfully after
    /// the deadline from being indicated, even though its side effect (stored value, generation
    /// bump) is already applied.
    private var procedureTimedOut = false
    private var procedureTimeoutTask: Task<Void, Never>?

    private var acceptedMeasurementCount = 0

    private let servedSensorLocation: ServedSensorLocationBox?

    // MARK: - State

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

    /// Creates and starts up a session. Guarantees `rollbackStartup()` runs on any failure path,
    /// including cancellation of the awaiting task during `startup()` — the cancellation handler
    /// and the `catch` both call it, but ``rollbackStartup()`` is safe to invoke more than once.
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

    // MARK: - Lifecycle

    /// Teardown for a session that reached `.running`, so advertising is stopped
    /// unconditionally (unlike ``rollbackStartup()``, which must check `publishStage` because
    /// startup may have failed before advertising began).
    func close() async {
        beginShutdown()
        await stopTasks()
        await tearDown(stoppingAdvertising: true)
    }

    /// Flips `closed` and wakes every parked waiter so nothing blocks forever once shutdown
    /// starts. Does not itself cancel tasks or touch the peripheral — ``stopTasks()`` and the
    /// caller (``close()``/``rollbackStartup()``) do that afterward.
    private func beginShutdown() {
        closed = true
        pendingInboundEvents.removeAll()
        resumeReadyToUpdateWaiter()
        resumeOutboundQueueWaiter()
        resumeSatisfiedTestWaiters()
    }

    /// Cancels and awaits every long-running task together, so none keeps running on state the
    /// others are about to tear down.
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

    /// Subscribes to `events` before `add`/`startAdvertising` (the stream does not replay), then
    /// publishes the service, advertises, and only then drains buffered events and starts the
    /// revolution loops. Checks `closed`/cancellation after every await so a `stop()` or
    /// cancellation racing startup is caught as early as possible and rolled back by the caller.
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

    /// Teardown for a startup that failed or was cancelled before reaching `.running`; mirrors
    /// ``close()`` but must check `publishStage` since advertising may never have started.
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

    // MARK: - Bluetooth loss and recovery

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

    /// Drops subscriptions and lets the pump discard queued sends, but leaves `publishStage`
    /// unchanged — the service stays exactly as CoreBluetooth left it until recovery runs.
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

    /// The sole `updateValue` caller and the sole consumer of the outbound queue. Loops between
    /// waiting for work and processing the head item until cancelled or closed.
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

    /// If the head's wheel half is stale, either re-encodes it crank-only (writing the result
    /// back into the queue so a subsequent re-check sees the same payload) or reports it should
    /// be removed. Pure with respect to `item`'s caller-visible state — does not remove from the
    /// queue or resume the producer; ``prepareHead(_:)`` does that.
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

    /// Re-checks all three reasons the head measurement might not be sendable — shutdown, no
    /// subscribers, staleness — and removes it if so. Called both before the first send attempt
    /// and again after a `false` return and before parking on ``waitForReadyToUpdate()``, since
    /// any of the three can become true while the pump was awaiting `updateValue` or the ready
    /// signal.
    ///
    /// - Returns: `true` when `item` is safe to send now; `false` when the head was removed and
    ///   the caller should return without sending.
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

    /// Re-checked after every suspension point in ``processQueuedIndication()``, since something
    /// else may have removed this exact indication (by id, possibly not from the head) while the
    /// pump was awaiting.
    private func isHeadIndication(_ id: UUID) -> Bool {
        guard case .indication(let head) = outboundQueue.first else {
            return false
        }
        return head.id == id
    }

    /// Only removes the item if it is still the head with this id — a no-op if something else
    /// already removed or replaced it while the pump was suspended.
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

    /// Sends the head measurement, retrying the same payload after `updateValue` returns `false`
    /// (CoreBluetooth backpressure) until it is accepted or ``prepareHead(_:)`` removes it
    /// (shutdown, no subscribers, staleness).
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

            guard prepareHead(&item) else {
                return
            }

            await waitForReadyToUpdate()
            if closed {
                drainOutboundQueueOnShutdown()
                return
            }
        }
    }

    /// Called only when `updateValue` returned `true` for a payload that overlapped no radio
    /// loss. `wheelGeneration` can still have bumped while `updateValue` was suspended (a Set
    /// Cumulative Value procedure runs on the same actor and can interleave during that await);
    /// re-checking staleness here catches that case. A stale wheel-bearing payload still caches
    /// its crank half (still current) but does not cache the wheel half or count toward
    /// ``acceptedMeasurementCount``.
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

    /// Sends the head indication, retrying after `updateValue` returns `false`, exactly like
    /// ``processQueuedMeasurement()`` — but must additionally re-validate that this item is
    /// still the head by id after every suspension, since a timeout, unsubscribe, or radio loss
    /// can remove or end the owning procedure for this exact item while the pump is parked.
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

    /// Discards every remaining queued item without sending, resuming each producer's continuation.
    /// Also ends an in-progress procedure, since its indication (if queued) was just discarded
    /// here rather than through the normal accept/timeout/unsubscribe path.
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

    // MARK: - Procedure timeout

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

    /// Called when a procedure's delegate call finishes successfully. If the 30 s budget already
    /// elapsed, the side effect already applied but this drops the indication and ends the
    /// procedure instead of sending it late.
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

    /// Enqueues one revolution sample and awaits until it leaves the outbound queue (sent,
    /// dropped, or discarded), which throttles ``startRevolutionLoop(_:as:)`` to the pump's pace
    /// rather than letting a source race ahead of what CoreBluetooth can actually send.
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

    /// Combines the new sample with the last-accepted half from the other source (if any) into
    /// one CSC Measurement payload. The generation stamp is non-nil exactly when the payload
    /// carries a wheel half, so a crank-only encoding is never mistaken for stale wheel data.
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

    /// Startup-only power gate: waits through `.unknown`/`.resetting` (e.g. while the Bluetooth
    /// permission prompt is pending) but fails fast for any other non-`.poweredOn` state. Once
    /// running, ``handleBluetoothState(_:)`` takes over via `events` instead of this stream.
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

    // MARK: - Inbound events

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

    /// Buffers events until startup opens the gate; after `closed`, events are dropped rather
    /// than buffered, since there is no future gate opening that would drain them.
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

    /// The real CoreBluetooth ready-to-update callback. Unlike calling
    /// ``resumeReadyToUpdateWaiter()`` directly, this sets ``isReadyToUpdate`` when nobody is
    /// parked, so the next ``waitForReadyToUpdate()`` call does not have to wait for a signal
    /// that already arrived.
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

    // MARK: - Reads

    private func handleRead(_ request: PeripheralReadRequest) async {
        let (result, value) = readResponse(for: request)
        try? await peripheral.respond(
            to: request.id,
            with: result,
            value: value,
        )
    }

    /// ATT error codes: `0x0A` unknown characteristic, `0x02` read not permitted (the
    /// notify-only Measurement characteristic has no readable value), `0x07` invalid offset
    /// (from ``offsetSlice(of:offset:)``). Multiple-location Sensor Location is read from
    /// `ServedSensorLocationBox` (the byte Update Sensor Location last stored) rather than from
    /// `characteristic.value`, which is `nil` for that configuration.
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

    /// `offset == value.count` succeeds with an empty slice (a valid "read past the end" ATT
    /// response); only `offset > value.count` is the `0x07` error.
    private func offsetSlice(of value: Data, offset: Int) -> (ATTResult, Data?) {
        if offset < 0 || offset > value.count {
            return (.error(code: 0x07), nil)
        }
        return (.success, Data(value.dropFirst(offset)))
    }

    // MARK: - Control-point writes and procedures

    /// SC Control Point write gate, checked in order: the combined characteristic/service gate
    /// (`0x03`, so a service that lacks `0x2A55` or a write to any other characteristic never
    /// leaks a more specific error), non-zero offset (`0x07`), undecodable value (`0x0D`), CCCD
    /// not subscribed (`0x81`), and a procedure already running (`0x80`).
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

    /// Recovers the opcode from a request that ``runProcedure(_:centralID:)`` did not match to a
    /// concrete case, so the `default` branch there can still indicate against the right opcode.
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

    /// Whether this build serves the procedure for `opcode`, independent of whether a request
    /// for it actually decoded successfully — used to choose `invalidParameter` vs
    /// `opCodeNotSupported` for a malformed request in ``runProcedure(_:centralID:)``.
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

    /// Dispatches one decoded SC Control Point request to its procedure by matching
    /// `(request, wheel configuration, multiple-location configuration)` together: a case only
    /// fires when both the request shape and the matching configuration are present, so a
    /// request this build does not serve (e.g. Update Sensor Location without multiple
    /// locations) falls through to the generic `invalidParameter`/`default` cases at the bottom
    /// instead of running the procedure. Runs on ``procedureTask``, started once per accepted
    /// write by ``handleWrite(_:)``.
    private func runProcedure(_ request: CSCControlPointRequest, centralID: UUID) async {
        switch (request, configuration.wheel, configuration.location.multipleLocations) {
        case let (.setCumulativeValue(value), wheel?, _):
            // Calls the delegate, then bumps `wheelGeneration` and clears `wheelCache` on success
            // so any still-queued wheel-bearing payload is recognized as stale. Wakes a parked
            // pump without setting the ready latch, so it re-checks staleness immediately instead
            // of waiting for an unrelated CoreBluetooth ready signal that may not come soon.
            do {
                try await wheel.delegate.setCumulativeWheelRevolutions(value)
            } catch {
                indicate(
                    opcode: CSCControlPointOpCode.setCumulativeValue.rawValue,
                    value: .operationFailed,
                    to: centralID,
                )
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
                indicate(
                    opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
                    value: .operationFailed,
                    to: centralID,
                )
                return
            }
            // Stores the new location before indicating, so the byte served on `0x2A5D` updates
            // immediately even if the success indication that follows is dropped by
            // `enqueueIndication`'s own `closed`/`procedureTimedOut` guard. No separate `closed`
            // check is needed here — indicating into a closed session already ends the procedure.
            servedSensorLocation?.store(kind)
            indicate(
                opcode: CSCControlPointOpCode.updateSensorLocation.rawValue,
                value: .success,
                to: centralID,
            )

        case (.requestSupportedSensorLocations, _, let locations?):
            // Answers from the `build()`-time snapshot (builder order, no length prefix) — never
            // re-reads the delegate's `supported`, which is why the list cannot change after
            // `build()`.
            indicate(
                opcode: CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
                value: .success,
                parameter: Data(locations.supported.map(\.assignedNumber)),
                to: centralID,
            )

        case let (.invalidParameter(opcode, _), _, _) where supportsProcedure(opcode):
            indicate(opcode: opcode, value: .invalidParameter, to: centralID)

        // Covers: a decodable request this build does not serve (wrong opcode/configuration
        // combination), Start Sensor Calibration (never served), an undecodable request for an
        // unserved opcode, and any unknown opcode.
        default:
            indicate(opcode: opcode(of: request), value: .opCodeNotSupported, to: centralID)
        }
    }

    // MARK: - Subscriptions

    /// CCCD enable/disable. `inserted`/`removed` guard the subscriber-count notification against
    /// a duplicate event for a central already in the expected state. Control-point unsubscribe
    /// also drops that central's queued indication, since it can no longer accept it.
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

    /// At most one indication is queued, because `procedureInProgress` stays set until that indication is removed.
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

    // MARK: - Measurement sources

    /// Iterates one revolution source from exactly one task for its whole lifetime, per the
    /// single-task-per-box contract in `AnyAsyncSequence`. Shared by both the wheel and crank
    /// loops via `map`, which tags each element with which source produced it. Any iterator
    /// failure, or the sequence ending naturally, silently stops this loop only — reads and
    /// advertising continue, and a single-pass source (e.g. `AsyncStream`) cannot be restarted
    /// by a later `start()`.
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

    // MARK: - Test hooks

    func waitUntil(_ condition: ServerTestCondition) async {
        guard !isSatisfied(condition) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            testWaiters.append((condition, continuation))
            resumeSatisfiedTestWaiters()
        }
    }

    /// A closed session satisfies `condition.isSatisfiedByClose` conditions unconditionally, so
    /// a test racing shutdown does not park forever on a value `close()`/`rollbackStartup()`
    /// settle only later (e.g. subscriber sets clear in `tearDown`, after `beginShutdown` already
    /// resumed waiters).
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

    /// Two passes so `.measurementSubscriberWaiterParked` is evaluated against the *post-pass-1*
    /// state of `testWaiters`, not a stale snapshot from the middle of pass 1: pass 1 resolves
    /// every other condition (in particular, any `.measurementSubscribers` entry that just
    /// became satisfied) while leaving `.measurementSubscriberWaiterParked` entries untouched;
    /// pass 2 then checks whether a `.measurementSubscribers` entry is still parked in the
    /// pass-1 leftovers before resolving those.
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


    private enum StartupStage {
        case addService
        case startAdvertising
    }

    /// Maps a startup failure to ``ServerError``. The same underlying `BluetoothPeripheralError`
    /// maps to `.publishFailed` when it came from `add` but `.advertisingFailed` when it came
    /// from `startAdvertising`, so `stage` disambiguates which call actually failed.
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
