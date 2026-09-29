internal import CSCWire
import Foundation

/// Errors thrown by SC Control Point procedures on a connected sensor.
public enum ControlPointError: Error, Sendable, Equatable {
    /// The requested sensor location is not in this sensor's supported list.
    case unsupportedLocation
    /// The sensor has no SC Control Point characteristic.
    ///
    /// Wheel and wheel-and-crank connect can succeed when SC Control Point (`0x2A55`) was not
    /// discovered. Set Cumulative Value, and any other control-point procedure, throws this case
    /// when the characteristic was not discovered.
    case controlPointUnavailable
    /// Another control-point procedure is already in flight.
    case procedureInProgress
    /// The server indicated Op Code Not Supported.
    case opCodeNotSupported
    /// The server indicated Invalid Parameter.
    case invalidParameter
    /// The server indicated Operation Failed.
    case operationFailed
    /// The control-point CCCD is not configured for indications.
    case cccdImproperlyConfigured
    /// The procedure did not complete before the CSCS timeout elapsed.
    case timedOut
    /// The procedure failed for another reason.
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

    init(
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

    private func start(id: UInt, requestData: Data, events: AsyncStream<CentralEvent>) {
        writeInFlight = true

        let listener = Task {
            await self.listenForControlPointEvents(procedureID: id, events: events)
        }
        helpers.append(listener)

        let timer = Task {
            await self.waitForControlPointTimeout(procedureID: id)
        }
        helpers.append(timer)

        Task {
            await self.sendControlPointWrite(procedureID: id, requestData: requestData)
        }
    }

    private func listenForControlPointEvents(
        procedureID: UInt,
        events: AsyncStream<CentralEvent>,
    ) async {
        for await event in events {
            guard !Task.isCancelled else {
                return
            }
            handleControlPointEvent(procedureID: procedureID, event: event)
        }
    }

    private func waitForControlPointTimeout(procedureID: UInt) async {
        do {
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        guard !Task.isCancelled else {
            return
        }
        timeoutProcedure(procedureID: procedureID)
    }

    private func handleControlPointEvent(procedureID: UInt, event: CentralEvent) {
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
                return
            }
            resolve(id: procedureID, result: .success(value))
        case let .disconnected(peripheralID):
            guard peripheralID == self.peripheralID else {
                return
            }
            resolve(
                id: procedureID,
                result: .failure(ControlPointError.failed(reason: "Disconnected")),
            )
        }
    }

    private func timeoutProcedure(procedureID: UInt) {
        resolve(id: procedureID, result: .failure(ControlPointError.timedOut))
    }

    private func sendControlPointWrite(procedureID: UInt, requestData: Data) async {
        do {
            try await central.writeValue(
                id: peripheralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
                value: requestData,
            )
        } catch {
            resolve(id: procedureID, result: .failure(error))
        }
        writeFinished(procedureID: procedureID)
    }

    private func writeFinished(procedureID: UInt) {
        guard procedureID == procedure else {
            return
        }
        writeInFlight = false
        if waiter == nil, isBusy {
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
        return .failed(reason: "\(error)")
    }
}
