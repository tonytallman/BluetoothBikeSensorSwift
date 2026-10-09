internal import CSCWire
import Foundation

/// Controllable ``BluetoothCentral`` for unit tests. Not intended for production use.
///
/// Scan-session gating matches ``CoreBluetoothCentral``: a stop records its id even when it
/// is not the active scan, and a later start at or below that id does not record
/// `startScanning`. The fake does not otherwise model the radio. `connect` does not consult
/// ``ConnectCancelCoordinator`` or Bluetooth power; cancellation of a hung connect throws
/// `CancellationError` from the sleep. Scripted failures, hangs, and held control-point
/// indications are one-shot unless a count says otherwise.
///
/// ``waitUntil(_:)`` reevaluates every parked predicate after each state-changing call.
/// Predicates run on this actor, so they may read actor-isolated state such as `recordedCalls`
/// directly. Discover, notify, read, and write throw ``BluetoothCentralError/disconnected``
/// when the id is not connected, and they do that before any scripted hang.
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

    /// Same roles as on ``CoreBluetoothCentral``. Kept in lockstep so ``Scanner`` tests exercise
    /// the real session rules against this double.
    private var activeScanSession: UInt64 = 0
    private var highestStoppedScanSession: UInt64 = 0
    private var state: BluetoothState
    private var nextErrors: [Operation: BluetoothCentralError] = [:]
    private var nextControlPointResponseValue: UInt8?
    private var shouldHangNextConnect = false
    private var shouldHoldNextControlPointIndication = false
    private var shouldHangNextWrite = false
    private var hangWriteAfterIndicationCount = 0
    private var shouldHangNextSetNotify = false
    private var hungWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var hungSetNotifyWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectedPeripheralIDs: Set<UUID> = []
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

    /// Counts subscribers from this property and from ``stateSubscriptionSnapshot()``, so a test
    /// can ``waitForStateUpdatesSubscriber()`` before ``setState(_:)``. A state yielded before
    /// anyone is listening is gone; these streams do not replay.
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

    package func stateSubscriptionSnapshot() async -> (AsyncStream<BluetoothState>, BluetoothState) {
        stateUpdatesSubscriberCount += 1
        changed()
        let stream = await stateBroadcaster.makeStream()
        return (stream, state)
    }

    package func startScanning(serviceUUIDs: [UUID]?, session: UInt64) async {
        guard session > highestStoppedScanSession else { return }
        activeScanSession = session
        appendRecordedCall(.startScanning(serviceUUIDs: serviceUUIDs))
    }

    package func stopScanning(session: UInt64) async {
        if session > highestStoppedScanSession {
            highestStoppedScanSession = session
        }
        guard activeScanSession == session else { return }
        activeScanSession = 0
        appendRecordedCall(.stopScanning)
    }

    package var discoveries: AsyncStream<DiscoveredPeripheral> {
        get async {
            await discoveryBroadcaster.makeStream()
        }
    }

    /// Records the call, then either parks until cancelled (`hangNextConnect`), throws a
    /// scripted error, or marks `id` connected. Does not model an already-connected short
    /// circuit or cancel-pending teardown.
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

        connectedPeripheralIDs.insert(id)
    }

    /// Always yields ``CentralEvent/disconnected`` after a successful return, including when
    /// `id` was not connected. Production returns early for an already-disconnected peripheral
    /// and does not yield that event.
    package func disconnect(id: UUID) async throws {
        appendRecordedCall(.disconnect(id: id))

        if let error = nextErrors.removeValue(forKey: .disconnect) {
            throw error
        }

        connectedPeripheralIDs.remove(id)
        await eventsBroadcaster.yield(.disconnected(peripheralID: id))
        changed()
    }

    package var events: AsyncStream<CentralEvent> {
        get async {
            await eventsBroadcaster.makeStream()
        }
    }

    /// Throws ``BluetoothCentralError/disconnected`` when `id` is not in the connected set, so
    /// a GATT call after a link-loss event fails immediately instead of hanging.
    package func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws {
        guard connectedPeripheralIDs.contains(id) else {
            throw BluetoothCentralError.disconnected(id, reason: nil)
        }

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
        guard connectedPeripheralIDs.contains(id) else {
            throw BluetoothCentralError.disconnected(id, reason: nil)
        }

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

    /// When `hangNextSetNotify` is armed, parks after the connected-id check. A peripheral that
    /// is already disconnected throws before that park, which is what
    /// ``ConnectedSensor/disconnect()`` relies on to avoid waiting out a notify teardown.
    package func setNotifyValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        enabled: Bool,
    ) async throws {
        guard connectedPeripheralIDs.contains(id) else {
            throw BluetoothCentralError.disconnected(id, reason: nil)
        }

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

        if shouldHangNextSetNotify {
            shouldHangNextSetNotify = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                hungSetNotifyWaiters.append(continuation)
            }
        }
    }

    package func readValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) async throws -> Data {
        guard connectedPeripheralIDs.contains(id) else {
            throw BluetoothCentralError.disconnected(id, reason: nil)
        }

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

    /// Control-point writes synthesize an indication on ``events`` unless a hold or hang says
    /// otherwise.
    ///
    /// `hangNextWrite` parks before any indication and, when released, throws
    /// ``BluetoothCentralError/connectionFailed``. `hangWriteAfterIndicating` yields the
    /// indication first, then parks, and returns success when released, so the procedure can
    /// finish while this call is still outstanding. `holdNextControlPointIndication` returns
    /// success and keeps the indication until ``releaseHeldControlPointIndication()``.
    package func writeValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        value: Data,
    ) async throws {
        guard connectedPeripheralIDs.contains(id) else {
            throw BluetoothCentralError.disconnected(id, reason: nil)
        }

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

        if hangWriteAfterIndicationCount > 0 {
            hangWriteAfterIndicationCount -= 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                hungWriteWaiters.append(continuation)
            }
        }
    }

    package func setState(_ newState: BluetoothState) async {
        state = newState
        await stateBroadcaster.yield(newState)
        changed()
    }

    package func emitDiscovery(_ event: DiscoveredPeripheral) async {
        await discoveryBroadcaster.yield(event)
        changed()
    }

    /// Yields `event`. ``CentralEvent/disconnected`` also removes that id from the connected
    /// set, so a later GATT call throws ``BluetoothCentralError/disconnected`` immediately.
    package func emit(_ event: CentralEvent) async {
        if case let .disconnected(peripheralID) = event {
            connectedPeripheralIDs.remove(peripheralID)
        }
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

    /// Next ``connect(id:)`` sleeps until cancelled, then throws `CancellationError`.
    package func hangNextConnect() {
        shouldHangNextConnect = true
        changed()
    }

    /// Next ``writeValue(id:serviceUUID:characteristicUUID:value:)`` parks before any indication,
    /// then throws when released. The park is not limited to the control-point characteristic.
    package func hangNextWrite() {
        shouldHangNextWrite = true
        changed()
    }

    /// Next `count` control-point writes yield their indication, then park, then return
    /// success. `count` accumulates across calls.
    package func hangWriteAfterIndicating(count: Int = 1) {
        hangWriteAfterIndicationCount += count
        changed()
    }

    package func hangNextSetNotify() {
        shouldHangNextSetNotify = true
        changed()
    }

    /// Resumes the oldest parked write or post-indication hang. One call releases one waiter.
    /// Shared by ``hangNextWrite()`` and ``hangWriteAfterIndicating(count:)``; which behavior
    /// follows the resume depends on which arm parked the waiter.
    package func releaseHungWrite() async {
        guard !hungWriteWaiters.isEmpty else {
            return
        }
        hungWriteWaiters.removeFirst().resume()
        changed()
    }

    /// Next control-point write succeeds without yielding the indication. The procedure stays
    /// in flight until ``releaseHeldControlPointIndication()``.
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

    /// Parks until `isMet` returns true, reevaluating after every ``changed()``. `isMet` runs
    /// on this actor.
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

    package func waitForStartScanCount(atLeast count: Int) async {
        await waitUntil {
            Self.startScanCount(in: self.recordedCalls) >= count
        }
    }

    private static func startScanCount(in calls: [RecordedCall]) -> Int {
        calls.filter { call in
            if case .startScanning = call { return true }
            return false
        }.count
    }

    package func waitForControlPointWriteCount(above baseline: Int) async {
        await waitUntil {
            Self.controlPointWriteCount(in: self.recordedCalls) > baseline
        }
    }

    package func controlPointWriteCount() -> Int {
        Self.controlPointWriteCount(in: recordedCalls)
    }

    private static func controlPointWriteCount(in calls: [RecordedCall]) -> Int {
        calls.filter { call in
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
        }.count
    }

    package func waitForStateUpdatesSubscriber() async {
        await waitUntil { self.stateUpdatesSubscriberCount > 0 }
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

    /// Builds a CSC Control Point indication for `request`. Request Supported Sensor Locations
    /// on success carries ``supportedSensorLocationBytes``; every other request carries an
    /// empty parameter. The response value defaults to success (`0x01`) unless
    /// ``setNextControlPointResponseValue(_:)`` armed a different byte for this write.
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
