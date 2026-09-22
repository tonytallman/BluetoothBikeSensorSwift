import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct SensorConnectionTests {
    private func makeSensor(
        fake: FakeBluetoothCentral,
        id: UUID = UUID(),
        name: String = "Test Sensor",
        hasSpeed: Bool = true,
        hasCadence: Bool = true,
    ) -> DiscoveredSensor {
        DiscoveredSensor(
            id: id,
            name: name,
            manufacturer: nil,
            hasSpeed: hasSpeed,
            hasCadence: hasCadence,
            central: fake,
        )
    }

    @Test func connectSuccessDiscoversCSCService() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        let connected = try await sensor.connect()

        let calls = await fake.recordedCalls
        #expect(calls.contains(.connect(id: sensorID)))
        #expect(calls.contains(.discoverServices(id: sensorID, serviceUUIDs: [CSCS.serviceUUID])))
        #expect(calls.contains(
            .discoverCharacteristics(
                id: sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUIDs: ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs,
            ),
        ))
        #expect(calls.contains(
            .readValue(
                id: sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
            ),
        ))
        #expect(calls.contains(
            .setNotifyValue(
                id: sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
                enabled: true,
            ),
        ))

        _ = try await connected.disconnect()
    }

    @Test func disconnectReturnsRediscoverableSensor() async throws {
        let fake = FakeBluetoothCentral()
        let sensor = makeSensor(fake: fake)

        let connected = try await sensor.connect()
        let rediscovered = try await connected.disconnect()
        let reconnected = try await rediscovered.connect()

        _ = reconnected
        let calls = await fake.recordedCalls
        #expect(calls.filter {
            if case .connect = $0 { return true }
            return false
        }.count == 2)
    }

    @Test func connectFailureMapsToConnectError() async {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        await fake.failNextConnect(with: .connectionFailed(sensorID, reason: "Refused"))

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .failed(reason: "Refused"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func connectTimeout() async {
        let fake = FakeBluetoothCentral()
        let sensor = makeSensor(fake: fake)
        let originalTimeout = DiscoveredSensor.connectTimeoutNanoseconds
        DiscoveredSensor.connectTimeoutNanoseconds = 100_000_000
        defer { DiscoveredSensor.connectTimeoutNanoseconds = originalTimeout }

        await fake.hangNextConnect()

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .timeout)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func serviceDiscoveryFailure() async {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        await fake.failNextDiscoverServices(
            with: .serviceNotFound(sensorID, serviceUUID: CSCS.serviceUUID),
        )

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(reason: "Service not found: \(CSCS.serviceUUID)"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let calls = await fake.recordedCalls
        #expect(calls.contains(.disconnect(id: sensorID)))
    }

    @Test func connectFailsWhenNotPoweredOn() async {
        let fake = FakeBluetoothCentral(initialState: .poweredOff)
        let sensor = makeSensor(fake: fake)

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .notPoweredOn)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func multiConnectionAllowed() async throws {
        let fake = FakeBluetoothCentral()
        let first = makeSensor(fake: fake, id: UUID(), name: "First")
        let second = makeSensor(fake: fake, id: UUID(), name: "Second")

        let firstConnected = try await first.connect()
        let secondConnected = try await second.connect()

        let calls = await fake.recordedCalls
        #expect(calls.filter {
            if case .connect = $0 { return true }
            return false
        }.count == 2)

        _ = try await firstConnected.disconnect()
        _ = try await secondConnected.disconnect()
    }

    @Test func disconnectAlreadyDisconnected() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        await fake.failNextDisconnect(with: .peripheralNotFound(sensorID))

        do {
            _ = try await connected.disconnect()
            Issue.record("Expected disconnect to throw")
        } catch let error as DisconnectError {
            #expect(error == .alreadyDisconnected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rapidConnectDisconnectReconnect() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        var current = makeSensor(fake: fake, id: sensorID)

        for _ in 0..<3 {
            let connected = try await current.connect()
            current = try await connected.disconnect()
        }

        _ = try await current.connect()

        let calls = await fake.recordedCalls
        #expect(calls.filter {
            if case .connect = $0 { return true }
            return false
        }.count == 4)
        #expect(calls.filter {
            if case .disconnect = $0 { return true }
            return false
        }.count == 3)
    }

    @Test func connectPeripheralNotFound() async {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        await fake.failNextConnect(with: .peripheralNotFound(sensorID))

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .peripheralNotFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func disconnectFailureMapsToDisconnectError() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        await fake.failNextDisconnect(with: .connectionFailed(sensorID, reason: "Link dropped"))

        do {
            _ = try await connected.disconnect()
            Issue.record("Expected disconnect to throw")
        } catch let error as DisconnectError {
            #expect(error == .failed(reason: "Link dropped"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func characteristicDiscoveryFailure() async {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        await fake.failNextDiscoverCharacteristics(
            with: .characteristicNotFound(
                sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(
                reason: "Characteristic not found: \(CSCS.measurementUUID) on \(CSCS.serviceUUID)",
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let calls = await fake.recordedCalls
        #expect(calls.contains(.disconnect(id: sensorID)))
    }

    @Test func featureReadFailureThrowsConnectError() async {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        await fake.failNextReadValue(
            with: .characteristicNotFound(
                sensorID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.featureUUID,
            ),
        )

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(reason: "CSC Feature read failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func zeroFeatureFlagsThrowConnectError() async {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([]).encode())

        do {
            _ = try await makeSensor(fake: fake).connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(reason: "Sensor supports neither wheel nor crank data"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func advertisementFlagsDoNotOverrideFeatureBits() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.crankRevolutionData]).encode())

        let connected = try await makeSensor(fake: fake, hasSpeed: true, hasCadence: true).connect()

        switch connected.revolutions {
        case .crank:
            break
        default:
            Issue.record("Expected crank-only revolution data")
        }
        switch connected.location {
        case .unavailable:
            break
        default:
            Issue.record("Expected unavailable location")
        }

        _ = try await connected.disconnect()
    }

    @Test func defaultConnectYieldsWheelAndCrankWithUnavailableLocation() async throws {
        let fake = FakeBluetoothCentral()
        let connected = try await makeSensor(fake: fake).connect()

        switch connected.revolutions {
        case .wheelAndCrank:
            break
        default:
            Issue.record("Expected wheelAndCrank revolution data")
        }
        switch connected.location {
        case .unavailable:
            break
        default:
            Issue.record("Expected unavailable location")
        }

        _ = try await connected.disconnect()
    }

    @Test func fixedLocationConnect() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await fake.setSensorLocationData(CSCSensorLocation(assignedNumber: 0x04).encode())

        let connected = try await makeSensor(fake: fake).connect()

        guard case let .fixed(location) = connected.location else {
            Issue.record("Expected fixed location")
            return
        }
        #expect(location.kind == .frontWheel)
        #expect(location.displayName == "Front Wheel")

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationConnect() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await fake.setSensorLocationData(CSCSensorLocation(assignedNumber: 0x05).encode())
        await fake.setSupportedSensorLocationBytes([0x05, 0x06, 0x0A])

        let connected = try await makeSensor(fake: fake).connect()

        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }
        #expect(locations.current.kind == .leftCrank)
        #expect(locations.supported.map(\.kind) == [.leftCrank, .rightCrank, .rearDropout])

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationConnectEnablesControlPointNotifyBeforeWrite() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)

        let connected = try await makeSensor(fake: fake).connect()

        let calls = await fake.recordedCalls
        let notifyIndex = calls.firstIndex { call in
            guard case let .setNotifyValue(
                _,
                serviceUUID,
                characteristicUUID,
                enabled,
            ) = call else {
                return false
            }
            return serviceUUID == CSCS.serviceUUID
                && characteristicUUID == CSCS.controlPointUUID
                && enabled
        }
        let requestLocationsWriteIndex = calls.firstIndex { call in
            guard case let .writeValue(
                _,
                serviceUUID,
                characteristicUUID,
                value,
            ) = call else {
                return false
            }
            return serviceUUID == CSCS.serviceUUID
                && characteristicUUID == CSCS.controlPointUUID
                && value.first == CSCControlPointOpCode.requestSupportedSensorLocations.rawValue
        }

        guard let notifyIndex, let requestLocationsWriteIndex else {
            Issue.record("Expected control point notify and Request Supported Sensor Locations write")
            return
        }
        #expect(notifyIndex < requestLocationsWriteIndex)

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationUpdateWorksAfterConnectedSensorReleased() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await fake.setSensorLocationData(CSCSensorLocation(assignedNumber: 0x05).encode())
        await fake.setSupportedSensorLocationBytes([0x05, 0x06, 0x0A])

        var connected: ConnectedSensor? = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected?.location else {
            Issue.record("Expected multiple locations")
            return
        }

        let rearDropout = locations.supported.first { $0.kind == .rearDropout }!
        connected = nil

        try await locations.update(rearDropout)
        #expect(locations.current.kind == .rearDropout)
    }

    @Test func heldControlPointIndicationTimesOutOnUpdate() async throws {
        let originalTimeout = CSCControlPointSession.procedureTimeoutNanoseconds
        CSCControlPointSession.procedureTimeoutNanoseconds = 100_000_000
        defer { CSCControlPointSession.procedureTimeoutNanoseconds = originalTimeout }

        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)

        let connected = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.holdNextControlPointIndication()

        let start = ContinuousClock.now
        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected timedOut")
        } catch let error as ControlPointError {
            #expect(error == .timedOut)
        }
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .seconds(1))

        await fake.releaseHeldControlPointIndication()
        _ = try await connected.disconnect()
    }

    @Test func heldControlPointIndicationTimesOutOnConnect() async {
        let originalTimeout = CSCControlPointSession.procedureTimeoutNanoseconds
        CSCControlPointSession.procedureTimeoutNanoseconds = 100_000_000
        defer { CSCControlPointSession.procedureTimeoutNanoseconds = originalTimeout }

        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await fake.holdNextControlPointIndication()

        do {
            _ = try await makeSensor(fake: fake).connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(reason: "timedOut"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func heldControlPointIndicationCompletesConnect() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await fake.holdNextControlPointIndication()

        let baseline = await ConnectedSensorTestHelpers.controlPointWriteCount(on: fake)
        async let writeRecorded: Void = ConnectedSensorTestHelpers.waitForControlPointWrite(
            on: fake,
            after: baseline,
        )
        let connectTask = Task {
            try await makeSensor(fake: fake).connect()
        }

        try await writeRecorded
        await fake.releaseHeldControlPointIndication()

        let connected = try await connectTask.value
        guard case .multiple = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        _ = try await connected.disconnect()
    }

    @Test func controlPointWriteFailureDoesNotHangUpdate() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)

        let connected = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.failNextWriteWithATTCode(CSCATTApplicationError.cccdImproperlyConfigured.rawValue)

        let start = ContinuousClock.now
        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected cccdImproperlyConfigured")
        } catch let error as ControlPointError {
            #expect(error == .cccdImproperlyConfigured)
        }
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .seconds(1))

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationUpdateSuccess() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await fake.setSensorLocationData(CSCSensorLocation(assignedNumber: 0x05).encode())
        await fake.setSupportedSensorLocationBytes([0x05, 0x06, 0x0A])

        let connected = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        let rearDropout = locations.supported.first { $0.kind == .rearDropout }!
        try await locations.update(rearDropout)
        #expect(locations.current.kind == .rearDropout)

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationUpdateRejectsUnsupportedToken() async throws {
        let source = FakeBluetoothCentral()
        await source.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await source.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await source.setSensorLocationData(CSCSensorLocation(assignedNumber: 0x04).encode())
        await source.setSupportedSensorLocationBytes([0x04])

        let target = FakeBluetoothCentral()
        await target.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await target.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await target.setSensorLocationData(CSCSensorLocation(assignedNumber: 0x05).encode())
        await target.setSupportedSensorLocationBytes([0x05, 0x06, 0x0A])

        let sourceConnected = try await makeSensor(fake: source).connect()
        let targetConnected = try await makeSensor(fake: target).connect()
        guard case let .multiple(sourceLocations) = sourceConnected.location,
              case let .multiple(locations) = targetConnected.location,
              let frontWheel = sourceLocations.supported.first(where: { $0.kind == .frontWheel })
        else {
            Issue.record("Expected multiple locations")
            return
        }

        do {
            try await locations.update(frontWheel)
            Issue.record("Expected update to throw")
        } catch let error as ControlPointError {
            #expect(error == .unsupportedLocation)
        }

        _ = try await sourceConnected.disconnect()
        _ = try await targetConnected.disconnect()
    }

    @Test func timedOutIndicationIsIgnoredByNextProcedure() async throws {
        let originalTimeout = CSCControlPointSession.procedureTimeoutNanoseconds
        CSCControlPointSession.procedureTimeoutNanoseconds = 100_000_000
        defer { CSCControlPointSession.procedureTimeoutNanoseconds = originalTimeout }

        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)
        await fake.setSensorLocationData(CSCSensorLocation(assignedNumber: 0x05).encode())
        await fake.setSupportedSensorLocationBytes([0x05, 0x06, 0x0A])

        let connected = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        let rightCrank = locations.supported.first { $0.kind == .rightCrank }!
        let rearDropout = locations.supported.first { $0.kind == .rearDropout }!

        await fake.holdNextControlPointIndication()
        do {
            try await locations.update(rightCrank)
            Issue.record("Expected timedOut")
        } catch let error as ControlPointError {
            #expect(error == .timedOut)
        }
        #expect(locations.current.kind == .leftCrank)

        await fake.releaseHeldControlPointIndication()
        #expect(locations.current.kind == .leftCrank)

        try await locations.update(rearDropout)
        #expect(locations.current.kind == .rearDropout)

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationUpdateMapsOpCodeNotSupported() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)

        let connected = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.setNextControlPointResponseValue(0x02)

        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected opCodeNotSupported")
        } catch let error as ControlPointError {
            #expect(error == .opCodeNotSupported)
        }

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationUpdateMapsInvalidParameter() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)

        let connected = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.setNextControlPointResponseValue(0x03)

        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected invalidParameter")
        } catch let error as ControlPointError {
            #expect(error == .invalidParameter)
        }

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationUpdateMapsOperationFailed() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)

        let connected = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.setNextControlPointResponseValue(0x04)

        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected operationFailed")
        } catch let error as ControlPointError {
            #expect(error == .operationFailed)
        }

        _ = try await connected.disconnect()
    }

    @Test func wheelConnectRequiresControlPoint() async {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.crankOnlyCharacteristics())

        do {
            _ = try await makeSensor(fake: fake).connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(
                reason: "SC Control Point characteristic missing for wheel data",
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func wheelAndCrankConnectRequiresControlPoint() async {
        let fake = FakeBluetoothCentral()
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.crankOnlyCharacteristics())

        do {
            _ = try await makeSensor(fake: fake).connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(
                reason: "SC Control Point characteristic missing for wheel data",
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func crankOnlyConnectWithoutControlPointSucceeds() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.crankRevolutionData]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.crankOnlyCharacteristics())

        let connected = try await makeSensor(fake: fake).connect()
        switch connected.revolutions {
        case .crank:
            break
        default:
            Issue.record("Expected crank-only revolution data")
        }

        _ = try await connected.disconnect()
    }

    @Test func setCumulativeRevolutionsSuccess() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.wheelAndControlPointCharacteristics())

        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()
        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }

        let speedStream = await wheel.speed
        let collector = Task {
            await AsyncTestHelpers.collect(from: speedStream, maxCount: 1)
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        try await wheel.setCumulativeRevolutions(0)

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        let speeds = await collector.value
        #expect(speeds.count == 1)

        _ = try await connected.disconnect()
    }

    @Test func setCumulativeRevolutionsClearsBaseline() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.wheelAndControlPointCharacteristics())

        let sensorID = UUID()
        let connected = try await makeSensor(fake: fake, id: sensorID).connect()
        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }

        let speedStream = await wheel.speed
        let collector = Task {
            await AsyncTestHelpers.collect(from: speedStream, maxCount: 1)
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        try await wheel.setCumulativeRevolutions(0)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 101, eventTime: 1_536)
        await emitWheelMeasurement(fake: fake, id: sensorID, revolutions: 103, eventTime: 2_560)

        let speeds = await collector.value
        #expect(speeds.count == 1)

        _ = try await connected.disconnect()
    }

    @Test func setCumulativeRevolutionsMapsOpCodeNotSupported() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.wheelAndControlPointCharacteristics())

        let connected = try await makeSensor(fake: fake).connect()
        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }

        await fake.setNextControlPointResponseValue(0x02)

        do {
            try await wheel.setCumulativeRevolutions(0)
            Issue.record("Expected opCodeNotSupported")
        } catch let error as ControlPointError {
            #expect(error == .opCodeNotSupported)
        }

        _ = try await connected.disconnect()
    }

    @Test func setCumulativeRevolutionsMapsOperationFailed() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.wheelAndControlPointCharacteristics())

        let connected = try await makeSensor(fake: fake).connect()
        guard let wheel = ConnectedSensorTestHelpers.wheel(from: connected) else {
            Issue.record("Expected wheel revolutions")
            return
        }

        await fake.setNextControlPointResponseValue(0x04)

        do {
            try await wheel.setCumulativeRevolutions(0)
            Issue.record("Expected operationFailed")
        } catch let error as ControlPointError {
            #expect(error == .operationFailed)
        }

        _ = try await connected.disconnect()
    }

    @Test func controlPointProcedureInProgressGate() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)

        let connected = try await makeSensor(fake: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.holdNextControlPointIndication()

        let baseline = await ConnectedSensorTestHelpers.controlPointWriteCount(on: fake)
        async let writeRecorded: Void = ConnectedSensorTestHelpers.waitForControlPointWrite(
            on: fake,
            after: baseline,
        )
        let firstUpdate = Task {
            try await locations.update(locations.supported[1])
        }

        try await writeRecorded

        do {
            try await locations.update(locations.supported[2])
            Issue.record("Expected procedureInProgress")
        } catch let error as ControlPointError {
            #expect(error == .procedureInProgress)
        }

        await fake.releaseHeldControlPointIndication()
        _ = try await firstUpdate.value
        _ = try await connected.disconnect()
    }

    @Test func attProcedureAlreadyInProgressMapsToControlPointError() async throws {
        let fake = FakeBluetoothCentral()
        await fake.setFeatureData(CSCFeature([.wheelRevolutionData, .crankRevolutionData, .multipleSensorLocations]).encode())
        await fake.setDiscoveredCharacteristicUUIDs(ConnectedSensorTestHelpers.allCSCCharacteristicUUIDs)

        let connected = try await makeSensor(fake: fake).connect()

        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        await fake.failNextWriteWithATTCode(CSCATTApplicationError.procedureAlreadyInProgress.rawValue)

        do {
            try await locations.update(locations.supported[1])
            Issue.record("Expected procedureInProgress")
        } catch let error as ControlPointError {
            #expect(error == .procedureInProgress)
        }

        _ = try await connected.disconnect()
    }

    private func emitWheelMeasurement(
        fake: FakeBluetoothCentral,
        id: UUID,
        revolutions: UInt32,
        eventTime: UInt16,
    ) async {
        let payload = CSCMeasurementFixtures.wheelMeasurement(
            revolutions: revolutions,
            eventTime: eventTime,
        )
        await fake.emitGATT(
            .characteristicValue(
                id: id,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
                value: payload,
            ),
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}
