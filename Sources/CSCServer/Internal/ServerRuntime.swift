#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation

/// Owns the `Server` lifecycle state machine and the one-live-server-per-process lease.
///
/// One `ServerRuntime` per `Server`, but only one runtime process-wide may hold the
/// ``LiveServerRegistry`` lease at a time. `phase` and `lease` are always updated together:
/// the lease is claimed before ``performStart(peripheral:clock:)`` starts and released only
/// once teardown (``finishStopping(_:)``) completes. Actual GATT/session work is delegated to
/// ``ServerSession``; this type only sequences start/stop and republishes the measurement
/// subscriber count while ``ServerSession`` is not otherwise reachable (starting/stopping).
actor ServerRuntime {
    /// | Phase | Meaning |
    /// |---|---|
    /// | `.idle` | No session; the lease (if any) is not held. |
    /// | `.starting` | `performStart` is running; the associated task produces the session. |
    /// | `.running` | Startup succeeded; the session is live. |
    /// | `.stopping` | Teardown task is running; the same task services concurrent `stop()` calls. |
    private enum Phase {
        case idle
        case starting(Task<ServerSession, Error>)
        case running(ServerSession)
        case stopping(Task<Void, Never>)
    }

    private let service: PeripheralService
    private let wheel: WheelConfiguration?
    private let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    private let location: ServerLocationConfiguration
    private let servedSensorLocation: ServedSensorLocationBox?

    private var phase: Phase = .idle
    private var lease: (registry: LiveServerRegistry, token: UUID)?
    private var finishStoppingEntryCount = 0
    private var finishStoppingEntryCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private let measurementSubscriberCountBroadcaster = StreamBroadcaster<Int>(
        replaysLatest: true,
        initialLatest: 0,
    )
    private var measurementSubscriberCountLatest = 0
    private var measurementSubscriberCountPublished: Int?

    func measurementSubscriberCount() async -> AsyncStream<Int> {
        await measurementSubscriberCountBroadcaster.makeStream()
    }

    /// Called by ``ServerSession`` on every subscriber-set change. Always records the latest
    /// count so it can be republished later, but only broadcasts while `.running` — while
    /// starting or stopping the public stream must show `0`, not the session's live count.
    private func publishMeasurementSubscriberCount(_ count: Int) async {
        measurementSubscriberCountLatest = count
        guard case .running = phase else { return }
        await publishMeasurementSubscriberCountIfChanged(count)
    }

    /// Dedupes against the last broadcast value so repeated equal counts do not re-yield.
    private func publishMeasurementSubscriberCountIfChanged(_ count: Int) async {
        if measurementSubscriberCountPublished == count { return }
        measurementSubscriberCountPublished = count
        await measurementSubscriberCountBroadcaster.yield(count)
    }

    /// Forces a re-check of the latest count against the dedupe guard. Called right after the
    /// transition to `.running`, after resetting `measurementSubscriberCountPublished` to `nil`,
    /// so the transition always yields even if the count happens to still be the last-broadcast
    /// value (which was `0` while starting).
    private func syncMeasurementSubscriberCountPublication() async {
        await publishMeasurementSubscriberCountIfChanged(measurementSubscriberCountLatest)
    }

    init(
        service: PeripheralService,
        wheel: WheelConfiguration?,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>?,
        location: ServerLocationConfiguration,
    ) {
        self.service = service
        self.wheel = wheel
        self.crankRevolutions = crankRevolutions
        self.location = location
        switch location {
        case .multiple(let configuration):
            servedSensorLocation = ServedSensorLocationBox(initial: configuration.current)
        case .none, .staticLocation:
            servedSensorLocation = nil
        }
    }

    /// Claims the live-server lease before doing anything else, so a losing racer touches no
    /// peripheral at all. The lease is claimed synchronously (no `await` between the phase
    /// guard and `liveServers.claim()`), so two concurrent `start()` calls on different
    /// `ServerRuntime`s cannot both win.
    func start(
        peripheral: (any BluetoothPeripheral)?,
        clock: any ServerClock,
        liveServers: LiveServerRegistry,
    ) async throws {
        guard case .idle = phase, lease == nil else {
            throw ServerError.alreadyStarted
        }
        guard let token = liveServers.claim() else {
            throw ServerError.alreadyStarted
        }
        lease = (registry: liveServers, token: token)

        try await withTaskCancellationHandler {
            try await performStart(peripheral: peripheral, clock: clock)
        } onCancel: {
            Task {
                await self.abortStartup()
            }
        }
    }

    /// Dispatches on `phase`: no-op when idle, joins the in-progress teardown when already
    /// stopping, or starts one — cancelling and rolling back an in-progress `start()`, or
    /// closing a running session.
    func stop() async {
        switch phase {
        case .idle:
            return
        case .stopping(let task):
            await finishStopping(task)
        case .starting(let startupTask):
            await beginStopping(Self.teardown(after: startupTask))
        case .running(let session):
            await beginStopping(Task { await session.close() })
        }
    }

    /// Cancels the startup task and, if it still produced a session before observing the
    /// cancellation, closes that session too — startup can succeed and be torn down in the same
    /// `stop()` call.
    private static func teardown(after startupTask: Task<ServerSession, Error>) -> Task<Void, Never> {
        Task {
            startupTask.cancel()
            if let session = try? await startupTask.value {
                await session.close()
            }
        }
    }

    private func beginStopping(_ task: Task<Void, Never>) async {
        phase = .stopping(task)
        await finishStopping(task)
    }

    /// Waits for `task`, then returns to idle and releases the live-server slot once, whichever
    /// caller resumes first.
    private func finishStopping(_ task: Task<Void, Never>) async {
        finishStoppingEntryCount += 1
        resumeFinishStoppingEntryCountWaiters()
        await task.value
        guard case .stopping(let current) = phase, current == task else {
            return
        }
        phase = .idle
        measurementSubscriberCountLatest = 0
        measurementSubscriberCountPublished = nil
        await publishMeasurementSubscriberCountIfChanged(0)
        releaseLease()
    }

    /// Test hook: blocks until `count` callers (across possibly-concurrent `stop()` calls) have
    /// entered ``finishStopping(_:)``, to observe the "second `stop()` joins the same teardown
    /// task" behavior deterministically.
    func waitUntilFinishStoppingEntryCount(_ count: Int) async {
        if finishStoppingEntryCount >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if finishStoppingEntryCount >= count {
                continuation.resume()
                return
            }
            finishStoppingEntryCountWaiters.append((count, continuation))
        }
    }

    private func resumeFinishStoppingEntryCountWaiters() {
        let count = finishStoppingEntryCount
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in finishStoppingEntryCountWaiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        finishStoppingEntryCountWaiters = remaining
    }

    private func releaseLease() {
        if let lease {
            lease.registry.release(lease.token)
            self.lease = nil
        }
    }

    // The test hooks below forward to the running `ServerSession` and are no-ops (return
    // immediately, not an indefinite wait) whenever `phase` is not `.running` — callers are
    // expected to have already awaited `start()`.

    func waitForMeasurementSubscribers(_ ids: Set<UUID>) async {
        if case .running(let session) = phase {
            await session.waitForMeasurementSubscribers(ids)
        }
    }

    func waitUntilMeasurementSubscriberWaiterParked() async {
        if case .running(let session) = phase {
            await session.waitUntilMeasurementSubscriberWaiterParked()
        }
    }

    func waitForControlPointSubscribers(_ ids: Set<UUID>) async {
        if case .running(let session) = phase {
            await session.waitForControlPointSubscribers(ids)
        }
    }

    func waitUntilControlPointProcedureIdle() async {
        if case .running(let session) = phase {
            await session.waitUntilControlPointProcedureIdle()
        }
    }

    func waitUntilAcceptedMeasurementCount(_ count: Int) async {
        if case .running(let session) = phase {
            await session.waitUntilAcceptedMeasurementCount(count)
        }
    }

    func waitUntilOutboundCount(atLeast count: Int) async {
        if case .running(let session) = phase {
            await session.waitUntilOutboundCount(atLeast: count)
        }
    }

    func waitUntilNotifyReadyWaiterParked() async {
        if case .running(let session) = phase {
            await session.waitUntilNotifyReadyWaiterParked()
        }
    }

    var isRadioSuspended: Bool {
        get async {
            guard case .running(let session) = phase else {
                return false
            }
            return await session.isRadioSuspended()
        }
    }

    /// On platforms without CoreBluetooth, the public `Server.start()` (which passes `nil`) can
    /// never succeed; only the `package` overload with an injected peripheral works there.
    private func resolvePeripheral(_ peripheral: (any BluetoothPeripheral)?) throws -> any BluetoothPeripheral {
        if let peripheral {
            return peripheral
        }
        #if canImport(CoreBluetooth)
        return CoreBluetoothPeripheral()
        #else
        throw ServerError.notPoweredOn
        #endif
    }

    /// Runs `ServerSession.open` in a child task so `stop()` (or cancellation) can race it: after
    /// the task finishes, this re-checks that `phase` still names this exact task before
    /// committing to `.running`, in case a concurrent `stop()` already began tearing down.
    private func performStart(peripheral: (any BluetoothPeripheral)?, clock: any ServerClock) async throws {
        let startupTask = Task {
            let resolvedPeripheral = try self.resolvePeripheral(peripheral)
            return try await ServerSession.open(
                service: service,
                wheel: wheel,
                crankRevolutions: crankRevolutions,
                location: location,
                servedSensorLocation: servedSensorLocation,
                peripheral: resolvedPeripheral,
                clock: clock,
                onMeasurementSubscriberCountChange: { count in
                    await self.publishMeasurementSubscriberCount(count)
                },
            )
        }
        phase = .starting(startupTask)

        do {
            let session = try await startupTask.value
            try Task.checkCancellation()
            guard case .starting(let currentTask) = phase, currentTask == startupTask else {
                throw CancellationError()
            }
            phase = .running(session)
            // Force a re-publish on entering `.running`, even if the count is unchanged from the
            // `0` shown while starting.
            measurementSubscriberCountPublished = nil
            await syncMeasurementSubscriberCountPublication()
        } catch {
            // Only tear down if this task still owns startup; a concurrent `stop()` may already
            // have moved `phase` to `.stopping` and started its own teardown of this same task.
            let stillOwnsStartup = {
                if case .starting(let currentTask) = phase, currentTask == startupTask {
                    return true
                }
                return false
            }()
            if stillOwnsStartup {
                await beginStopping(Self.teardown(after: startupTask))
            }
            throw error
        }
    }

    /// Runs from the cancellation handler around `start()`, potentially from a different task;
    /// only cancels the startup task this runtime still recognizes as current.
    private func abortStartup() async {
        guard case .starting(let startupTask) = phase else {
            return
        }
        startupTask.cancel()
    }
}
