#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation

actor ServerLifecycle {
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

    func measurementSubscriberCount() async -> AsyncStream<Int> {
        await measurementSubscriberCountBroadcaster.makeStream()
    }

    private func setMeasurementSubscriberCount(_ count: Int) async {
        sessionSubscriberCount = count
        guard case .running = phase else { return }
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
        await measurementSubscriberCountBroadcaster.yield(0)
    }

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
            await setMeasurementSubscriberCount(sessionSubscriberCount)
        } catch {
            if case .starting(let currentTask) = phase, currentTask == startupTask {
                await beginStopping(Self.teardown(after: startupTask))
            }
            throw error
        }
    }

    private func abortStartup() async {
        guard case .starting(let startupTask) = phase else {
            return
        }
        startupTask.cancel()
    }
}
