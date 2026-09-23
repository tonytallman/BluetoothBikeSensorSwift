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
    }

    func start(peripheral: (any BluetoothPeripheral)?) async throws {
        if isUnsupportedConfiguration {
            throw ServerError.unsupportedConfiguration
        }

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

    private var isUnsupportedConfiguration: Bool {
        wheel != nil || crankRevolutions == nil || {
            if case .multiple = location {
                return true
            }
            return false
        }()
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
                crankRevolutions: crankRevolutions,
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
            if case .starting(let currentTask) = phase, currentTask == startupTask {
                phase = .idle
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
