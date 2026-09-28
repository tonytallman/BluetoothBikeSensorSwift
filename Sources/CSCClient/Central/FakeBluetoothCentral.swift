internal import CSCWire
import Foundation

/// Controllable `BluetoothCentral` for unit tests. Not intended for production use.
package actor FakeBluetoothCentral: BluetoothCentral {
    package enum Operation: Hashable, Sendable {
        case connect
        case disconnect
        case discoverServices
        case discoverCharacteristics
        case readValue
        case setNotifyValue
        case writeValue
    }

    package enum RecordedCall: Sendable, Equatable {
        case startScanning(serviceUUIDs: [UUID]?)
        case stopScanning
        case connect(id: UUID)
        case disconnect(id: UUID)
        case discoverServices(id: UUID, serviceUUIDs: [UUID]?)
        case discoverCharacteristics(id: UUID, serviceUUID: UUID, characteristicUUIDs: [UUID]?)
        case setNotifyValue(
            id: UUID,
            serviceUUID: UUID,
            characteristicUUID: UUID,
            enabled: Bool,
        )
        case readValue(id: UUID, serviceUUID: UUID, characteristicUUID: UUID)
        case writeValue(
            id: UUID,
            serviceUUID: UUID,
            characteristicUUID: UUID,
            value: Data,
        )
    }

    private var state: BluetoothState
    private var nextErrors: [Operation: BluetoothCentralError] = [:]
    private var nextControlPointResponseValue: UInt8?
    private var shouldHangNextConnect = false
    private var shouldHoldNextControlPointIndication = false
    private var shouldHangNextWrite = false
    private var hungWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldControlPointIndication: CentralEvent?
    private var featureData: Data
    private var discoveredCharacteristicUUIDs: [UUID]
    private var sensorLocationData: Data
    private var supportedSensorLocationBytes: [UInt8]

    private var conditionWaiters: [(isMet: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    private var stateUpdatesSubscriberCount = 0

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let discoveryBroadcaster = StreamBroadcaster<DiscoveredPeripheral>()
    private let eventsBroadcaster = StreamBroadcaster<CentralEvent>()

    package private(set) var recordedCalls: [RecordedCall] = []

    package init(
        initialState: BluetoothState = .poweredOn,
        featureData: Data = CSCFeature([.wheelRevolutionData, .crankRevolutionData]).encode(),
        discoveredCharacteristicUUIDs: [UUID] = [
            CSCS.measurementUUID,
            CSCS.featureUUID,
            CSCS.controlPointUUID,
        ],
        sensorLocationData: Data = CSCSensorLocation(assignedNumber: 0x05).encode(),
        supportedSensorLocationBytes: [UInt8] = [0x05, 0x06, 0x0A],
    ) {
        state = initialState
        self.featureData = featureData
        self.discoveredCharacteristicUUIDs = discoveredCharacteristicUUIDs
        self.sensorLocationData = sensorLocationData
        self.supportedSensorLocationBytes = supportedSensorLocationBytes
    }

    package var stateUpdates: AsyncStream<BluetoothState> {
        get async {
            stateUpdatesSubscriberCount += 1
            changed()
            return await stateBroadcaster.makeStream()
        }
    }

    package var currentState: BluetoothState {
        get async { state }
    }

    package func startScanning(serviceUUIDs: [UUID]?) async {
        appendRecordedCall(.startScanning(serviceUUIDs: serviceUUIDs))
    }

    package func stopScanning() async {
        appendRecordedCall(.stopScanning)
    }

    package var discoveries: AsyncStream<DiscoveredPeripheral> {
        get async {
            await discoveryBroadcaster.makeStream()
        }
    }

    package func connect(id: UUID) async throws {
        appendRecordedCall(.connect(id: id))

        if shouldHangNextConnect {
            shouldHangNextConnect = false
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                throw CancellationError()
            }
        }

        if let error = nextErrors.removeValue(forKey: .connect) {
            throw error
        }
    }

    package func disconnect(id: UUID) async throws {
        appendRecordedCall(.disconnect(id: id))

        if let error = nextErrors.removeValue(forKey: .disconnect) {
            throw error
        }

        await eventsBroadcaster.yield(.disconnected(peripheralID: id))
        changed()
    }

    package var events: AsyncStream<CentralEvent> {
        get async {
            await eventsBroadcaster.makeStream()
        }
    }

    package func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws {
        appendRecordedCall(.discoverServices(id: id, serviceUUIDs: serviceUUIDs))

        if let error = nextErrors.removeValue(forKey: .discoverServices) {
            throw error
        }
    }

    package func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?,
    ) async throws -> [UUID] {
        appendRecordedCall(
            .discoverCharacteristics(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUIDs: characteristicUUIDs,
            ),
        )

        if let error = nextErrors.removeValue(forKey: .discoverCharacteristics) {
            throw error
        }

        return discoveredCharacteristicUUIDs
    }

    package func setNotifyValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        enabled: Bool,
    ) async throws {
        appendRecordedCall(
            .setNotifyValue(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                enabled: enabled,
            ),
        )

        if let error = nextErrors.removeValue(forKey: .setNotifyValue) {
            throw error
        }
    }

    package func readValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) async throws -> Data {
        appendRecordedCall(
            .readValue(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
            ),
        )

        if let error = nextErrors.removeValue(forKey: .readValue) {
            throw error
        }

        if characteristicUUID == CSCS.featureUUID {
            return featureData
        }

        if characteristicUUID == CSCS.sensorLocationUUID {
            return sensorLocationData
        }

        return Data()
    }

    package func writeValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        value: Data,
    ) async throws {
        appendRecordedCall(
            .writeValue(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                value: value,
            ),
        )

        if let error = nextErrors.removeValue(forKey: .writeValue) {
            throw error
        }

        if shouldHangNextWrite {
            shouldHangNextWrite = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                hungWriteWaiters.append(continuation)
            }
            throw BluetoothCentralError.connectionFailed(id, reason: "Hung write released")
        }

        guard characteristicUUID == CSCS.controlPointUUID else {
            return
        }

        let responseValue = nextControlPointResponseValue ?? 0x01
        nextControlPointResponseValue = nil

        let indication = Self.controlPointIndication(
            for: value,
            responseValue: responseValue,
            supportedLocationBytes: supportedSensorLocationBytes,
        )

        let event = CentralEvent.valueUpdated(
            peripheralID: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            value: indication,
        )

        if shouldHoldNextControlPointIndication {
            shouldHoldNextControlPointIndication = false
            heldControlPointIndication = event
            return
        }

        await eventsBroadcaster.yield(event)
        changed()
    }

    package func setState(_ newState: BluetoothState) async {
        state = newState
        await stateBroadcaster.yield(newState)
        changed()
    }

    package func setSupportedSensorLocationBytes(_ bytes: [UInt8]) {
        supportedSensorLocationBytes = bytes
        changed()
    }

    package func emitDiscovery(_ event: DiscoveredPeripheral) async {
        await discoveryBroadcaster.yield(event)
        changed()
    }

    package func emit(_ event: CentralEvent) async {
        await eventsBroadcaster.yield(event)
        changed()
    }

    package func failNext(_ operation: Operation, with error: BluetoothCentralError) {
        nextErrors[operation] = error
        changed()
    }

    package func setNextControlPointResponseValue(_ value: UInt8) {
        nextControlPointResponseValue = value
        changed()
    }

    package func hangNextConnect() {
        shouldHangNextConnect = true
        changed()
    }

    package func hangNextWrite() {
        shouldHangNextWrite = true
        changed()
    }

    package func releaseHungWrite() async {
        let waiters = hungWriteWaiters
        hungWriteWaiters = []
        waiters.forEach { $0.resume() }
        changed()
    }

    package func holdNextControlPointIndication() {
        shouldHoldNextControlPointIndication = true
        changed()
    }

    package func releaseHeldControlPointIndication() async {
        guard let event = heldControlPointIndication else {
            return
        }
        heldControlPointIndication = nil
        await eventsBroadcaster.yield(event)
        changed()
    }

    package func waitUntil(_ isMet: @escaping () -> Bool) async {
        if isMet() {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conditionWaiters.append((isMet, continuation))
            resumeConditionWaiters()
        }
    }

    package func waitForRecordedCall(
        where predicate: @escaping @Sendable (RecordedCall) -> Bool,
    ) async {
        await waitUntil { self.recordedCalls.contains(where: predicate) }
    }

    package func waitForStateUpdatesSubscriber() async {
        await waitUntil { self.stateUpdatesSubscriberCount > 0 }
    }

    package func waitForControlPointWriteCount(greaterThan baseline: Int) async {
        await waitUntil {
            self.recordedCalls.filter { call in
                guard case let .writeValue(
                    _,
                    serviceUUID,
                    characteristicUUID,
                    _,
                ) = call else {
                    return false
                }
                return serviceUUID == CSCS.serviceUUID
                    && characteristicUUID == CSCS.controlPointUUID
            }.count > baseline
        }
    }

    private func appendRecordedCall(_ call: RecordedCall) {
        recordedCalls.append(call)
        changed()
    }

    private func changed() {
        resumeConditionWaiters()
    }

    private func resumeConditionWaiters() {
        var remaining: [(isMet: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in conditionWaiters {
            if waiter.isMet() {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        conditionWaiters = remaining
    }

    private static func controlPointIndication(
        for request: Data,
        responseValue: UInt8,
        supportedLocationBytes: [UInt8],
    ) -> Data {
        let requestOpcode = request.first ?? 0x00
        let parameter: Data =
            requestOpcode == CSCControlPointOpCode.requestSupportedSensorLocations.rawValue
            && responseValue == CSCControlPointResponseValue.success.rawValue
            ? Data(supportedLocationBytes)
            : Data()
        return CSCControlPointResponse(
            requestOpcode: requestOpcode,
            value: responseValue,
            parameter: parameter,
        ).encode()
    }
}
