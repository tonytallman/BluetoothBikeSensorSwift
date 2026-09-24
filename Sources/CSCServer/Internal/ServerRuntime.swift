#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation

actor ServerRuntime {
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
        releaseLease()
    }

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
                service: service,
                wheel: wheel,
                crankRevolutions: crankRevolutions,
                location: location,
                servedSensorLocation: servedSensorLocation,
                peripheral: resolvedPeripheral,
                clock: clock,
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
        } catch {
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

    private func abortStartup() async {
        guard case .starting(let startupTask) = phase else {
            return
        }
        startupTask.cancel()
    }
}
