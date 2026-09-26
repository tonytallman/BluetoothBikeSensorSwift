#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation

/// Owns one `Server`'s start/stop state machine.
///
/// One `ServerLifecycle` per `Server`; `phase` tracks it independently of every other `Server`
/// instance — there is no process-wide limit on how many may run concurrently. Actual GATT/session
/// work is delegated to ``ServerSession``; this type only sequences start/stop and republishes the
/// measurement subscriber count while a session is not otherwise reachable (starting/stopping).
actor ServerLifecycle {
    /// | Phase | Meaning |
    /// |---|---|
    /// | `.idle` | No session. |
    /// | `.starting` | `performStart` is running; the associated task produces the session. |
    /// | `.running` | Startup succeeded; the session is live. |
    /// | `.stopping` | Teardown task is running; the same task services concurrent `stop()` calls. |
    private enum Phase {
        case idle
        case starting(Task<ServerSession, Error>)
        case running(ServerSession)
        case stopping(Task<Void, Never>)
    }

    private let configuration: ServerConfiguration
    private let servedSensorLocation: ServedSensorLocationBox?

    private var phase: Phase = .idle
    private var finishStoppingEntryCount = 0
    private var finishStoppingEntryCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private let measurementSubscriberCountBroadcaster = StreamBroadcaster<Int>(
        replaysLatest: true,
        initialLatest: 0,
    )
    private var sessionSubscriberCount = 0
    private var publishedSubscriberCount: Int?

    func measurementSubscriberCount() async -> AsyncStream<Int> {
        await measurementSubscriberCountBroadcaster.makeStream()
    }

    /// Called by ``ServerSession`` on every subscriber-set change. Always records the latest
    /// count so it can be republished later, but only broadcasts (and dedupes against the last
    /// broadcast value) while `.running` — while starting or stopping the public stream must
    /// show `0`, not the session's live count.
    private func setMeasurementSubscriberCount(_ count: Int) async {
        sessionSubscriberCount = count
        guard case .running = phase else { return }
        guard publishedSubscriberCount != count else { return }
        publishedSubscriberCount = count
        await measurementSubscriberCountBroadcaster.yield(count)
    }

    init(configuration: ServerConfiguration) {
        self.configuration = configuration
        switch configuration.location {
        case .multiple(let configuration):
            servedSensorLocation = ServedSensorLocationBox(initial: configuration.current)
        case .none, .staticLocation:
            servedSensorLocation = nil
        }
    }

    func start(
        peripheral: (any BluetoothPeripheral)?,
        clock: any ServerClock,
    ) async throws {
        guard case .idle = phase else {
            throw ServerError.alreadyStarted
        }

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

    /// Waits for `task`, then returns to idle, whichever caller resumes first.
    private func finishStopping(_ task: Task<Void, Never>) async {
        finishStoppingEntryCount += 1
        resumeFinishStoppingEntryCountWaiters()
        await task.value
        guard case .stopping(let current) = phase, current == task else {
            return
        }
        phase = .idle
        sessionSubscriberCount = 0
        publishedSubscriberCount = nil
        await measurementSubscriberCountBroadcaster.yield(0)
    }

    /// Test hook: blocks until `count` callers (across possibly-concurrent `stop()` calls) have
    /// entered ``finishStopping(_:)``, to observe the "second `stop()` joins the same teardown
    /// task" behavior deterministically.
    func waitUntilFinishStoppingEntryCount(_ count: Int) async {
        if finishStoppingEntryCount >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishStoppingEntryCountWaiters.append((count, continuation))
            resumeFinishStoppingEntryCountWaiters()
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

    /// No-op (returns immediately, not an indefinite wait) unless `.running` — callers are
    /// expected to have already awaited `start()`.
    func waitUntil(_ condition: ServerTestCondition) async {
        if case .running(let session) = phase {
            await session.waitUntil(condition)
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
                configuration: configuration,
                servedSensorLocation: servedSensorLocation,
                peripheral: resolvedPeripheral,
                clock: clock,
                onMeasurementSubscriberCountChange: { count in
                    await self.setMeasurementSubscriberCount(count)
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
            publishedSubscriberCount = nil
            await setMeasurementSubscriberCount(sessionSubscriberCount)
        } catch {
            // Only tear down if this task still owns startup; a concurrent `stop()` may already
            // have moved `phase` to `.stopping` and started its own teardown of this same task.
            if case .starting(let currentTask) = phase, currentTask == startupTask {
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
