package import CSCWire
import Foundation

/// Controllable `BluetoothCentral` for unit tests. Not intended for production use.
package actor FakeBluetoothCentral: BluetoothCentral {
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
    private var nextConnectError: BluetoothCentralError?
    private var nextDiscoverServicesError: BluetoothCentralError?
    private var nextDiscoverCharacteristicsError: BluetoothCentralError?
    private var nextDisconnectError: BluetoothCentralError?
    private var nextReadValueError: BluetoothCentralError?
    private var nextSetNotifyError: BluetoothCentralError?
    private var nextWriteValueError: BluetoothCentralError?
    private var nextWriteATTCode: UInt8?
    private var nextControlPointResponseValue: UInt8?
    private var shouldHangNextConnect = false
    private var shouldHoldNextControlPointIndication = false
    private var heldControlPointIndication: GATTEvent?
    private var featureData = CSCFeature([.wheelRevolutionData, .crankRevolutionData]).encode()
    private var discoveredCharacteristicUUIDs: [UUID] = [
        CSCS.measurementUUID,
        CSCS.featureUUID,
        CSCS.controlPointUUID,
    ]
    private var sensorLocationData = CSCSensorLocation(assignedNumber: 0x05).encode()
    private var supportedSensorLocationBytes: [UInt8] = [0x05, 0x06, 0x0A]

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let discoveryBroadcaster = StreamBroadcaster<DiscoveredPeripheralEvent>()
    private let connectionBroadcaster = StreamBroadcaster<ConnectionEvent>()
    private let gattBroadcaster = StreamBroadcaster<GATTEvent>()

    package private(set) var recordedCalls: [RecordedCall] = []

    package init(initialState: BluetoothState = .poweredOn) {
        state = initialState
    }

    package var stateUpdates: AsyncStream<BluetoothState> {
        get async {
            await stateBroadcaster.makeStream()
        }
    }

    package var currentState: BluetoothState {
        get async { state }
    }

    package func startScanning(serviceUUIDs: [UUID]?) async {
        recordedCalls.append(.startScanning(serviceUUIDs: serviceUUIDs))
    }

    package func stopScanning() async {
        recordedCalls.append(.stopScanning)
    }

    package var discoveries: AsyncStream<DiscoveredPeripheralEvent> {
        get async {
            await discoveryBroadcaster.makeStream()
        }
    }

    package func connect(id: UUID) async throws {
        recordedCalls.append(.connect(id: id))

        if shouldHangNextConnect {
            shouldHangNextConnect = false
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }

        if let nextConnectError {
            self.nextConnectError = nil
            await connectionBroadcaster.yield(.failed(id: id, reason: String(describing: nextConnectError)))
            throw nextConnectError
        }
        await connectionBroadcaster.yield(.connected(id: id))
    }

    package func disconnect(id: UUID) async throws {
        recordedCalls.append(.disconnect(id: id))

        if let nextDisconnectError {
            self.nextDisconnectError = nil
            await connectionBroadcaster.yield(.disconnected(id: id, reason: String(describing: nextDisconnectError)))
            throw nextDisconnectError
        }

        await connectionBroadcaster.yield(.disconnected(id: id, reason: nil))
    }

    package var connectionEvents: AsyncStream<ConnectionEvent> {
        get async {
            await connectionBroadcaster.makeStream()
        }
    }

    package func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws {
        recordedCalls.append(.discoverServices(id: id, serviceUUIDs: serviceUUIDs))

        if let nextDiscoverServicesError {
            self.nextDiscoverServicesError = nil
            throw nextDiscoverServicesError
        }
    }

    package func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?,
    ) async throws -> [UUID] {
        recordedCalls.append(
            .discoverCharacteristics(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUIDs: characteristicUUIDs,
            ),
        )

        if let nextDiscoverCharacteristicsError {
            self.nextDiscoverCharacteristicsError = nil
            throw nextDiscoverCharacteristicsError
        }

        return discoveredCharacteristicUUIDs
    }

    package var gattEvents: AsyncStream<GATTEvent> {
        get async {
            await gattBroadcaster.makeStream()
        }
    }

    package func setNotifyValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        enabled: Bool,
    ) async throws {
        recordedCalls.append(
            .setNotifyValue(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                enabled: enabled,
            ),
        )

        if let nextSetNotifyError {
            self.nextSetNotifyError = nil
            throw nextSetNotifyError
        }

        await gattBroadcaster.yield(
            .notificationStateChanged(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                isNotifying: enabled,
            ),
        )
    }

    package func readValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) async throws -> Data {
        recordedCalls.append(
            .readValue(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
            ),
        )

        if let nextReadValueError {
            self.nextReadValueError = nil
            throw nextReadValueError
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
        recordedCalls.append(
            .writeValue(
                id: id,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                value: value,
            ),
        )

        if let nextWriteATTCode {
            let code = nextWriteATTCode
            self.nextWriteATTCode = nil
            throw BluetoothCentralError.attApplicationError(code: code)
        }

        if let nextWriteValueError {
            self.nextWriteValueError = nil
            throw nextWriteValueError
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

        let event = GATTEvent.characteristicValue(
            id: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            value: indication,
        )

        if shouldHoldNextControlPointIndication {
            shouldHoldNextControlPointIndication = false
            heldControlPointIndication = event
            return
        }

        await gattBroadcaster.yield(event)
    }

    package func setState(_ newState: BluetoothState) async {
        state = newState
        await stateBroadcaster.yield(newState)
    }

    package func setFeatureData(_ data: Data) {
        featureData = data
    }

    package func setDiscoveredCharacteristicUUIDs(_ uuids: [UUID]) {
        discoveredCharacteristicUUIDs = uuids
    }

    package func setSensorLocationData(_ data: Data) {
        sensorLocationData = data
    }

    package func setSupportedSensorLocationBytes(_ bytes: [UInt8]) {
        supportedSensorLocationBytes = bytes
    }

    package func emitDiscovery(_ event: DiscoveredPeripheralEvent) async {
        await discoveryBroadcaster.yield(event)
    }

    package func emitConnection(_ event: ConnectionEvent) async {
        await connectionBroadcaster.yield(event)
    }

    package func emitGATT(_ event: GATTEvent) async {
        await gattBroadcaster.yield(event)
    }

    package func failNextConnect(with error: BluetoothCentralError) {
        nextConnectError = error
    }

    package func failNextDiscoverServices(with error: BluetoothCentralError) {
        nextDiscoverServicesError = error
    }

    package func failNextDiscoverCharacteristics(with error: BluetoothCentralError) {
        nextDiscoverCharacteristicsError = error
    }

    package func failNextDisconnect(with error: BluetoothCentralError) {
        nextDisconnectError = error
    }

    package func failNextReadValue(with error: BluetoothCentralError) {
        nextReadValueError = error
    }

    package func failNextSetNotify(with error: BluetoothCentralError) {
        nextSetNotifyError = error
    }

    package func failNextWriteValue(with error: BluetoothCentralError) {
        nextWriteValueError = error
    }

    package func failNextWriteWithATTCode(_ code: UInt8) {
        nextWriteATTCode = code
    }

    package func setNextControlPointResponseValue(_ value: UInt8) {
        nextControlPointResponseValue = value
    }

    package func hangNextConnect() {
        shouldHangNextConnect = true
    }

    package func holdNextControlPointIndication() {
        shouldHoldNextControlPointIndication = true
    }

    package func releaseHeldControlPointIndication() async {
        guard let event = heldControlPointIndication else {
            return
        }
        heldControlPointIndication = nil
        await gattBroadcaster.yield(event)
    }

    private static func controlPointIndication(
        for request: Data,
        responseValue: UInt8,
        supportedLocationBytes: [UInt8],
    ) -> Data {
        guard let requestOpcode = request.first else {
            return CSCControlPointResponse(
                requestOpcode: 0x00,
                value: responseValue,
                parameter: Data(),
            ).encode()
        }

        switch requestOpcode {
        case CSCControlPointOpCode.requestSupportedSensorLocations.rawValue:
            if responseValue == CSCControlPointResponseValue.success.rawValue {
                return CSCControlPointResponse(
                    requestOpcode: requestOpcode,
                    value: responseValue,
                    parameter: Data(supportedLocationBytes),
                ).encode()
            }
            return CSCControlPointResponse(
                requestOpcode: requestOpcode,
                value: responseValue,
                parameter: Data(),
            ).encode()
        default:
            return CSCControlPointResponse(
                requestOpcode: requestOpcode,
                value: responseValue,
                parameter: Data(),
            ).encode()
        }
    }
}
