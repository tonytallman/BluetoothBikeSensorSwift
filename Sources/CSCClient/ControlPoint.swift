internal import CSCWire
import Foundation

/// Errors thrown by SC Control Point procedures on a connected sensor.
public enum ControlPointError: Error, Sendable, Equatable {
    case unsupportedLocation
    case controlPointUnavailable
    case procedureInProgress
    case opCodeNotSupported
    case invalidParameter
    case operationFailed
    case cccdImproperlyConfigured
    case timedOut
    case failed(reason: String)
}

package actor ControlPoint {
    private let central: any BluetoothCentral
    private let peripheralID: UUID
    private let timeout: Duration

    private var isBusy = false
    private var procedure: UInt = 0
    private var waiter: CheckedContinuation<Data, Error>?
    private var helpers: [Task<Void, Never>] = []
    private var writeInFlight = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    package init(
        central: any BluetoothCentral,
        peripheralID: UUID,
        timeout: Duration,
    ) {
        self.central = central
        self.peripheralID = peripheralID
        self.timeout = timeout
    }

    func perform(_ request: CSCControlPointRequest) async throws -> CSCControlPointResponse {
        guard !isBusy else {
            throw ControlPointError.procedureInProgress
        }
        isBusy = true
        procedure &+= 1
        let id = procedure

        let events = await central.events
        let requestData = request.encode()
        let expectedOpcode = requestData.first ?? 0

        let indicationData: Data
        do {
            indicationData = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    waiter = continuation
                    start(id: id, requestData: requestData, events: events)
                }
            } onCancel: {
                Task { await self.resolve(id: id, result: .failure(CancellationError())) }
            }
        } catch {
            throw Self.mapError(error)
        }

        return try Self.validateResponse(indicationData, expectedRequestOpcode: expectedOpcode)
    }

    package func waitUntilIdle() async {
        if !isBusy, !writeInFlight {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleWaiters.append(continuation)
            resumeIdleWaitersIfNeeded()
        }
    }

    package func cancel() {
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: ControlPointError.failed(reason: "Cancelled"))
        }
        helpers.forEach { $0.cancel() }
        helpers = []
        isBusy = false
        writeInFlight = false
        resumeIdleWaitersIfNeeded()
    }

    private func start(id: UInt, requestData: Data, events: AsyncStream<CentralEvent>) {
        writeInFlight = true

        let listener = Task {
            for await event in events {
                guard !Task.isCancelled else {
                    return
                }
                switch event {
                case let .valueUpdated(
                    peripheralID,
                    serviceUUID,
                    characteristicUUID,
                    value,
                ):
                    guard peripheralID == self.peripheralID,
                        serviceUUID == CSCS.serviceUUID,
                        characteristicUUID == CSCS.controlPointUUID
                    else {
                        continue
                    }
                    await resolve(id: id, result: .success(value))
                    return
                case let .disconnected(peripheralID):
                    guard peripheralID == self.peripheralID else {
                        continue
                    }
                    await resolve(id: id, result: .failure(ControlPointError.failed(reason: "Disconnected")))
                    return
                }
            }
        }
        helpers.append(listener)

        let timer = Task {
            try? await Task.sleep(for: timeout)
            await resolve(id: id, result: .failure(ControlPointError.timedOut))
        }
        helpers.append(timer)

        Task {
            do {
                try await central.writeValue(
                    id: peripheralID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.controlPointUUID,
                    value: requestData,
                )
            } catch {
                await resolve(id: id, result: .failure(error))
            }
            await writeFinished(procedureID: id)
        }
    }

    private func writeFinished(procedureID: UInt) async {
        writeInFlight = false
        if procedureID == procedure, waiter == nil, isBusy {
            isBusy = false
        }
        resumeIdleWaitersIfNeeded()
    }

    private func resolve(id: UInt, result: Result<Data, Error>) {
        guard id == procedure, let waiter else {
            return
        }
        self.waiter = nil
        helpers.forEach { $0.cancel() }
        helpers = []

        switch result {
        case let .success(data):
            isBusy = false
            waiter.resume(returning: data)
        case let .failure(error):
            if !writeInFlight {
                isBusy = false
            }
            waiter.resume(throwing: Self.mapError(error))
        }
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard !isBusy, !writeInFlight else {
            return
        }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    private static func validateResponse(
        _ indication: Data,
        expectedRequestOpcode: UInt8,
    ) throws -> CSCControlPointResponse {
        guard let response = CSCControlPointResponse.decode(indication) else {
            throw ControlPointError.failed(reason: "Invalid control point response")
        }

        guard response.requestOpcode == expectedRequestOpcode else {
            throw ControlPointError.failed(reason: "Unexpected request opcode in response")
        }

        switch response.value {
        case CSCControlPointResponseValue.success.rawValue:
            return response
        case CSCControlPointResponseValue.opCodeNotSupported.rawValue:
            throw ControlPointError.opCodeNotSupported
        case CSCControlPointResponseValue.invalidParameter.rawValue:
            throw ControlPointError.invalidParameter
        case CSCControlPointResponseValue.operationFailed.rawValue:
            throw ControlPointError.operationFailed
        default:
            throw ControlPointError.failed(reason: "Unknown response value \(response.value)")
        }
    }

    private static func mapError(_ error: Error) -> ControlPointError {
        if let controlPointError = error as? ControlPointError {
            return controlPointError
        }
        if error is CancellationError {
            return .failed(reason: "Cancelled")
        }
        if let centralError = error as? BluetoothCentralError {
            switch centralError {
            case .disconnected:
                return .failed(reason: "Disconnected")
            case let .attApplicationError(code):
                switch CSCATTApplicationError(rawValue: code) {
                case .procedureAlreadyInProgress:
                    return .procedureInProgress
                case .cccdImproperlyConfigured:
                    return .cccdImproperlyConfigured
                case .none:
                    return .failed(reason: "ATT error \(code)")
                }
            default:
                return .failed(reason: String(describing: centralError))
            }
        }
        return .failed(reason: error.localizedDescription)
    }
}

enum CSCControlPointClient {
    static func supportedLocations(from response: CSCControlPointResponse) -> [SensorLocation]? {
        guard response.requestOpcode == CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
              response.value == CSCControlPointResponseValue.success.rawValue
        else {
            return nil
        }

        return response.parameter.map { SensorLocation(assignedNumber: $0) }
    }
}
