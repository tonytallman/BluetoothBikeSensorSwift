internal import CSCWire
import Foundation

private final class ListenerTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>?) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func get() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

package actor CSCControlPointSession {
    nonisolated(unsafe) package static var procedureTimeoutNanoseconds: UInt64 = 30_000_000_000

    private let central: any BluetoothCentral
    private let peripheralID: UUID
    private let controlPointAvailable: Bool
    private let listenerTaskBox = ListenerTaskBox()
    private var procedureInFlight = false
    private var epoch: UInt = 0
    private var waitingEpoch: UInt?
    private var writeSettled = true
    private var pendingIndication: CheckedContinuation<Data, Error>?
    private var bufferedIndication: Data?
    private var listenerReadyContinuation: CheckedContinuation<Void, Never>?

    init(
        central: any BluetoothCentral,
        peripheralID: UUID,
        controlPointAvailable: Bool,
    ) {
        self.central = central
        self.peripheralID = peripheralID
        self.controlPointAvailable = controlPointAvailable
    }

    deinit {
        listenerTaskBox.cancel()
    }

    package func startListener() async {
        await ensureListening()
    }

    func cancel() {
        listenerTaskBox.cancel()
        listenerReadyContinuation?.resume()
        listenerReadyContinuation = nil
        failIndicationWait(with: CancellationError())
    }

    @discardableResult
    func perform(
        request: Data,
        expectedRequestOpcode: UInt8,
        onSuccess: @Sendable (CSCControlPointResponse) async -> Void = { _ in },
    ) async throws -> CSCControlPointResponse {
        guard controlPointAvailable else {
            throw ControlPointError.controlPointUnavailable
        }

        await ensureListening()

        guard !procedureInFlight else {
            throw ControlPointError.procedureInProgress
        }
        procedureInFlight = true
        bufferedIndication = nil

        let indicationData: Data
        do {
            indicationData = try await waitForIndicationAfterWrite(request: request)
        } catch {
            if writeSettled {
                procedureInFlight = false
            }
            throw error
        }

        procedureInFlight = false
        return try await Self.handleResponse(
            indicationData,
            expectedRequestOpcode: expectedRequestOpcode,
            onSuccess: onSuccess,
        )
    }

    private func waitForIndicationAfterWrite(request: Data) async throws -> Data {
        let timeoutNanoseconds = Self.procedureTimeoutNanoseconds
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            self.failIndicationWait(with: ControlPointError.timedOut)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await waitForIndicationAndWrite(request: request)
        } onCancel: {
            Task { await self.failIndicationWait(with: CancellationError()) }
        }
    }

    private func waitForIndicationAndWrite(request: Data) async throws -> Data {
        let startedEpoch = epoch
        waitingEpoch = startedEpoch
        writeSettled = false

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingIndication = continuation

            Task {
                defer {
                    writeSettled = true
                    if epoch != startedEpoch {
                        procedureInFlight = false
                    }
                }

                do {
                    try await central.writeValue(
                        id: peripheralID,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        value: request,
                    )
                } catch {
                    failIndicationWait(with: error)
                    return
                }
                resumePendingFromBufferIfNeeded()
            }
        }
    }

    private func resumePendingFromBufferIfNeeded() {
        guard waitingEpoch == epoch, let buffered = bufferedIndication, let pending = pendingIndication else {
            return
        }
        bufferedIndication = nil
        pending.resume(returning: buffered)
        pendingIndication = nil
    }

    private func failIndicationWait(with error: Error) {
        epoch &+= 1
        waitingEpoch = nil
        if let pendingIndication {
            pendingIndication.resume(throwing: Self.mapWriteError(error))
            self.pendingIndication = nil
        }
        bufferedIndication = nil
    }

    private func ensureListening() async {
        guard listenerTaskBox.get() == nil else {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listenerReadyContinuation = continuation
            let task = Task {
                await self.runListener()
            }
            listenerTaskBox.set(task)
        }
    }

    private func runListener() async {
        defer {
            listenerTaskBox.set(nil)
            failIndicationWait(with: CancellationError())
        }

        let gattEvents = await central.gattEvents
        listenerReadyContinuation?.resume()
        listenerReadyContinuation = nil

        for await event in gattEvents {
            guard !Task.isCancelled else {
                return
            }

            guard case let .characteristicValue(
                id,
                serviceUUID,
                characteristicUUID,
                value,
            ) = event,
                id == peripheralID,
                serviceUUID == CSCS.serviceUUID,
                characteristicUUID == CSCS.controlPointUUID
            else {
                continue
            }

            deliverIndication(value)
        }
    }

    private func deliverIndication(_ value: Data) {
        guard waitingEpoch == epoch else {
            return
        }

        if let pendingIndication {
            pendingIndication.resume(returning: value)
            self.pendingIndication = nil
        } else {
            bufferedIndication = value
        }
    }

    private static func handleResponse(
        _ indication: Data,
        expectedRequestOpcode: UInt8,
        onSuccess: @Sendable (CSCControlPointResponse) async -> Void,
    ) async throws -> CSCControlPointResponse {
        guard let response = CSCControlPointResponse.decode(indication) else {
            throw ControlPointError.failed(reason: "Invalid control point response")
        }

        guard response.requestOpcode == expectedRequestOpcode else {
            throw ControlPointError.failed(reason: "Unexpected request opcode in response")
        }

        switch response.value {
        case CSCControlPointResponseValue.success.rawValue:
            await onSuccess(response)
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

    private static func mapWriteError(_ error: Error) -> ControlPointError {
        if let controlPointError = error as? ControlPointError {
            return controlPointError
        }
        if error is CancellationError {
            return .failed(reason: "Cancelled")
        }
        if let centralError = error as? BluetoothCentralError {
            switch centralError {
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
