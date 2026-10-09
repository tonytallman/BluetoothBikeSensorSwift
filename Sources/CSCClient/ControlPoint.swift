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
    ///
    /// `reason` is diagnostic text, not user-facing copy.
    case failed(reason: String)
}

/// One SC Control Point procedure at a time for one peripheral.
///
/// ``perform(_:)`` writes the request, then waits for the matching indication on
/// ``BluetoothCentral/events`` or for `timeout`. Every helper captures `procedure` at start.
/// A late timeout, indication, or write completion whose id no longer matches is ignored, so
/// it cannot complete or clear the next procedure.
///
/// `isBusy` is the gate callers see (``ControlPointError/procedureInProgress``). A failure
/// leaves it set until `writeInFlight` is also clear, so a timeout that fires while the write
/// is still outstanding keeps rejecting new procedures until that write returns. A successful
/// indication clears `isBusy` immediately, even if the write has not returned; the next
/// procedure may start, and the previous write's completion is ignored because its id no
/// longer matches.
package actor ControlPoint {
    private let central: any BluetoothCentral
    private let peripheralID: UUID
    private let timeout: Duration

    /// Set when ``perform(_:)`` accepts a procedure. Cleared when that procedure's indication
    /// succeeds, or when a failed procedure's write has also finished.
    private var isBusy = false

    /// Bumped with wrapping add on every ``perform(_:)`` so a long-lived connection cannot
    /// trap. Helpers compare against this. A wrapped id could alias a helper that is still
    /// running; that collision is accepted as unreachable.
    private var procedure: UInt = 0

    /// The single waiter for the in-flight indication. Cleared when ``resolve(id:result:)``
    /// resumes it. A second indication, or a late timeout, sees `nil` or a mismatched id and
    /// is dropped.
    private var waiter: CheckedContinuation<Data, Error>?

    /// Listener and timeout tasks for the current procedure. Cancelled when it ends.
    private var helpers: [Task<Void, Never>] = []

    /// True from ``start(id:requestData:events:)`` until ``writeFinished(procedureID:)`` for
    /// that same id. A failed resolve leaves `isBusy` set while this is true.
    private var writeInFlight = false

    /// Parked ``waitUntilIdle()`` callers. Resumed only when `isBusy` and `writeInFlight` are
    /// both false.
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

    /// Writes `request` and waits for its indication.
    ///
    /// Subscribes to ``BluetoothCentral/events`` before the write. The stream does not replay.
    /// The listener, the timeout, and the write all capture the same procedure id. Cancelling
    /// the caller resolves that id with `CancellationError`, which ``mapError(_:)`` turns into
    /// ``ControlPointError/failed(reason:)``.
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

    /// Test hook. Returns immediately when no procedure and no write are outstanding; otherwise
    /// parks until both are clear. Rechecks inside the continuation so a procedure that finished
    /// as the waiter was recorded is not left parked.
    package func waitUntilIdle() async {
        if !isBusy, !writeInFlight {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleWaiters.append(continuation)
            resumeIdleWaitersIfNeeded()
        }
    }

    /// Arms the listener and the timeout, then writes. `writeInFlight` is set before either
    /// task is created so a fast failure cannot observe a procedure that looks idle.
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

    /// Ignores every event that is not this peripheral's SC Control Point indication or its
    /// disconnect. Measurement notifications travel on the same ``BluetoothCentral/events``
    /// stream and are left for the measurement loop.
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

    /// Clears `writeInFlight` only when `procedureID` is still current. An older write returning
    /// after a newer ``perform(_:)`` has started must not clear the new procedure's flag. If the
    /// waiter is already gone and the procedure is still marked busy, this write was the last
    /// thing holding the gate (timeout while the write was stuck) and clearing it opens the gate.
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

    /// Completes the current procedure's waiter when `id` still owns it.
    ///
    /// Success clears `isBusy` even when the write is still in flight. Failure clears `isBusy`
    /// only when the write has already finished; otherwise ``writeFinished(procedureID:)`` clears
    /// it later, and ``perform(_:)`` keeps throwing ``ControlPointError/procedureInProgress`` in
    /// between. Either path cancels the helper tasks. Resuming the waiter does not run the
    /// caller's continuation until this actor turn ends, so ``writeFinished(procedureID:)`` on
    /// the write-failure path still runs before the caller can start another procedure.
    ///
    /// A stale id returns without touching the current waiter. That is what drops an indication
    /// that arrives after ``ControlPointError/timedOut``.
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

    /// Decodes the indication, checks that it answers this request's opcode, and maps the CSCS
    /// response value onto ``ControlPointError``. An unknown response value is
    /// ``ControlPointError/failed(reason:)``.
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

    /// Collapses transport failures into ``ControlPointError``.
    ///
    /// `CancellationError` becomes ``ControlPointError/failed(reason:)`` with reason `"Cancelled"`.
    /// ATT application error `0x80` is ``ControlPointError/procedureInProgress`` and `0x81` is
    /// ``ControlPointError/cccdImproperlyConfigured``; any other ATT code keeps the numeric code
    /// in the diagnostic reason. ``BluetoothCentralError/disconnected`` becomes a failed
    /// procedure with reason `"Disconnected"`; the central error's reason string is not passed
    /// through.
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
