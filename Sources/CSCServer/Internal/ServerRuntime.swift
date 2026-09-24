#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation

actor ServerRuntime {
    private enum Phase {
        case idle
        case starting(Task<ServerSession, Error>)
        case running(ServerSession)
    }

    private let service: PeripheralService
    private let wheel: WheelConfiguration?
    private let crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    private let location: ServerLocationConfiguration
    private let servedSensorLocation: ServedSensorLocationBox?

    private var phase: Phase = .idle

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

    func start(peripheral: (any BluetoothPeripheral)?) async throws {
        guard case .idle = phase else {
            throw ServerError.alreadyStarted
        }

        try await withTaskCancellationHandler {
            try await performStart(peripheral: peripheral)
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
        case .starting(let startupTask):
            phase = .idle
            startupTask.cancel()
            do {
                let session = try await startupTask.value
                await session.close()
            } catch {
            }
        case .running(let session):
            phase = .idle
            await session.close()
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

    private func performStart(peripheral: (any BluetoothPeripheral)?) async throws {
        let startupTask = Task {
            let resolvedPeripheral = try self.resolvePeripheral(peripheral)
            return try await ServerSession.open(
                service: service,
                wheel: wheel,
                crankRevolutions: crankRevolutions,
                location: location,
                servedSensorLocation: servedSensorLocation,
                peripheral: resolvedPeripheral,
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
                phase = .idle
                if let session = try? await startupTask.value {
                    await session.close()
                }
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
