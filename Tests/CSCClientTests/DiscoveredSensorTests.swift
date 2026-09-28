import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct DiscoveredSensorTests {
    enum ConnectSequenceVariant: String, CaseIterable {
        case `default`
        case multipleLocations
    }

    enum FeatureBitsCase: String, CaseIterable {
        case advertisementFlagsDoNotOverrideFeatureBits
        case defaultConnectYieldsWheelAndCrankWithUnavailableLocation
        case speedOnlySensorHasNoCrankStreams
        case wheelConnectSucceedsWithoutControlPoint
        case wheelAndCrankConnectSucceedsWithoutControlPoint
        case crankOnlyConnectWithoutControlPointSucceeds
    }

    struct ConnectFailureCase: Sendable {
        let name: String
        let timeouts: Timeouts
        let makeFake: @Sendable () async -> FakeBluetoothCentral
        let configure: @Sendable (FakeBluetoothCentral, UUID) async -> Void
        let expected: ConnectError
        let expectsDisconnect: Bool
    }

    @Test(arguments: ConnectSequenceVariant.allCases)
    func connectSuccessDiscoversCSCService(variant: ConnectSequenceVariant) async throws {
        let fake: FakeBluetoothCentral
        let sensorID = UUID()
        switch variant {
        case .default:
            fake = FakeBluetoothCentral()
        case .multipleLocations:
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([
                    .wheelRevolutionData,
                    .crankRevolutionData,
                    .multipleSensorLocations,
                ]).encode(),
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
            )
        }

        let connected = try await CSCClientTestSupport.sensor(
            id: sensorID,
            central: fake,
        ).connect()

        let calls = await fake.recordedCalls
        let expected: [FakeBluetoothCentral.RecordedCall]
        switch variant {
        case .default:
            expected = [
                .connect(id: sensorID),
                .discoverServices(id: sensorID, serviceUUIDs: [CSCS.serviceUUID]),
                .discoverCharacteristics(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
                ),
                .readValue(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.featureUUID,
                ),
                .setNotifyValue(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.controlPointUUID,
                    enabled: true,
                ),
                .setNotifyValue(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.measurementUUID,
                    enabled: true,
                ),
            ]
        case .multipleLocations:
            expected = [
                .connect(id: sensorID),
                .discoverServices(id: sensorID, serviceUUIDs: [CSCS.serviceUUID]),
                .discoverCharacteristics(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
                ),
                .readValue(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.featureUUID,
                ),
                .setNotifyValue(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.controlPointUUID,
                    enabled: true,
                ),
                .readValue(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.sensorLocationUUID,
                ),
                .writeValue(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.controlPointUUID,
                    value: Data([CSCControlPointOpCode.requestSupportedSensorLocations.rawValue]),
                ),
                .setNotifyValue(
                    id: sensorID,
                    serviceUUID: CSCS.serviceUUID,
                    characteristicUUID: CSCS.measurementUUID,
                    enabled: true,
                ),
            ]
        }
        #expect(calls == expected)

        _ = try await connected.disconnect()
    }

    @Test func connectFailsWhenNotPoweredOn() async {
        let fake = FakeBluetoothCentral(initialState: .poweredOff)
        do {
            _ = try await CSCClientTestSupport.sensor(central: fake).connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .notPoweredOn)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func connectTimeout() async {
        let fake = FakeBluetoothCentral()
        let sensor = CSCClientTestSupport.sensor(
            central: fake,
            timeouts: Timeouts(connect: .milliseconds(100)),
        )

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

    @Test func heldControlPointIndicationCompletesConnect() async throws {
        let fake = FakeBluetoothCentral(
            featureData: CSCFeature([
                .wheelRevolutionData,
                .crankRevolutionData,
                .multipleSensorLocations,
            ]).encode(),
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
        )
        await fake.holdNextControlPointIndication()

        let baseline = await CSCClientTestSupport.controlPointWrites(on: fake)
        async let writeRecorded: Void = CSCClientTestSupport.waitForControlPointWrite(
            on: fake,
            after: baseline,
        )
        let connectTask = Task {
            try await CSCClientTestSupport.sensor(central: fake).connect()
        }

        await writeRecorded
        await fake.releaseHeldControlPointIndication()

        let connected = try await connectTask.value
        guard case .multiple = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        _ = try await connected.disconnect()
    }

    @Test func multiConnectionAllowed() async throws {
        let fake = FakeBluetoothCentral()
        let first = CSCClientTestSupport.sensor(id: UUID(), name: "First", central: fake)
        let second = CSCClientTestSupport.sensor(id: UUID(), name: "Second", central: fake)

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

    @Test(arguments: Self.connectFailureCases())
    func connectFailureMapsToConnectError(_ failureCase: ConnectFailureCase) async {
        let sensorID = UUID()
        let fake = await failureCase.makeFake()
        await failureCase.configure(fake, sensorID)

        do {
            _ = try await CSCClientTestSupport.sensor(
                id: sensorID,
                central: fake,
                timeouts: failureCase.timeouts,
            ).connect()
            Issue.record("Expected connect to throw for \(failureCase.name)")
        } catch let error as ConnectError {
            #expect(error == failureCase.expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let calls = await fake.recordedCalls
        if failureCase.expectsDisconnect {
            #expect(calls.contains(.disconnect(id: sensorID)))
        } else {
            #expect(!calls.contains(.disconnect(id: sensorID)))
        }
    }

    @Test(arguments: FeatureBitsCase.allCases)
    func revolutionsFollowFeatureBits(_ featureCase: FeatureBitsCase) async throws {
        let fake: FakeBluetoothCentral
        let sensorID = UUID()
        switch featureCase {
        case .advertisementFlagsDoNotOverrideFeatureBits:
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([.crankRevolutionData]).encode(),
            )
        case .defaultConnectYieldsWheelAndCrankWithUnavailableLocation:
            fake = FakeBluetoothCentral()
        case .speedOnlySensorHasNoCrankStreams:
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([.wheelRevolutionData]).encode(),
            )
        case .wheelConnectSucceedsWithoutControlPoint:
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([.wheelRevolutionData]).encode(),
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.crankOnlyCharacteristics(),
            )
        case .wheelAndCrankConnectSucceedsWithoutControlPoint:
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([.wheelRevolutionData, .crankRevolutionData]).encode(),
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.crankOnlyCharacteristics(),
            )
        case .crankOnlyConnectWithoutControlPointSucceeds:
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([.crankRevolutionData]).encode(),
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.crankOnlyCharacteristics(),
            )
        }

        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let calls = await fake.recordedCalls

        switch featureCase {
        case .advertisementFlagsDoNotOverrideFeatureBits:
            #expect(connected.revolutions.crank != nil)
            #expect(connected.revolutions.wheel == nil)
            guard case .unavailable = connected.location else {
                Issue.record("Expected unavailable location")
                return
            }
            #expect(CSCClientTestSupport.hasControlPointNotifyEnabled(in: calls, sensorID: sensorID))
            #expect(CSCClientTestSupport.hasMeasurementNotifyEnabled(in: calls, sensorID: sensorID))
        case .defaultConnectYieldsWheelAndCrankWithUnavailableLocation:
            #expect(connected.revolutions.wheel != nil)
            #expect(connected.revolutions.crank != nil)
            guard case .unavailable = connected.location else {
                Issue.record("Expected unavailable location")
                return
            }
            #expect(CSCClientTestSupport.hasControlPointNotifyEnabled(in: calls, sensorID: sensorID))
            #expect(CSCClientTestSupport.hasMeasurementNotifyEnabled(in: calls, sensorID: sensorID))
        case .speedOnlySensorHasNoCrankStreams:
            #expect(connected.revolutions.wheel != nil)
            #expect(connected.revolutions.crank == nil)
            guard case .unavailable = connected.location else {
                Issue.record("Expected unavailable location")
                return
            }
            #expect(CSCClientTestSupport.hasControlPointNotifyEnabled(in: calls, sensorID: sensorID))
            #expect(CSCClientTestSupport.hasMeasurementNotifyEnabled(in: calls, sensorID: sensorID))
        case .wheelConnectSucceedsWithoutControlPoint:
            #expect(connected.revolutions.wheel != nil)
            #expect(connected.revolutions.crank == nil)
            guard case .unavailable = connected.location else {
                Issue.record("Expected unavailable location")
                return
            }
            #expect(!CSCClientTestSupport.hasControlPointNotifyEnabled(in: calls, sensorID: sensorID))
            #expect(CSCClientTestSupport.hasMeasurementNotifyEnabled(in: calls, sensorID: sensorID))
        case .wheelAndCrankConnectSucceedsWithoutControlPoint:
            #expect(connected.revolutions.wheel != nil)
            #expect(connected.revolutions.crank != nil)
            #expect(!CSCClientTestSupport.hasControlPointNotifyEnabled(in: calls, sensorID: sensorID))
            #expect(CSCClientTestSupport.hasMeasurementNotifyEnabled(in: calls, sensorID: sensorID))
        case .crankOnlyConnectWithoutControlPointSucceeds:
            #expect(connected.revolutions.crank != nil)
            #expect(connected.revolutions.wheel == nil)
            guard case .unavailable = connected.location else {
                Issue.record("Expected unavailable location")
                return
            }
            #expect(!CSCClientTestSupport.hasControlPointNotifyEnabled(in: calls, sensorID: sensorID))
            #expect(CSCClientTestSupport.hasMeasurementNotifyEnabled(in: calls, sensorID: sensorID))
        }

        _ = try await connected.disconnect()
    }

    enum LocationConnectCase: String, CaseIterable {
        case fixedLocationConnect
        case fixedLocationConnectSucceedsWithoutControlPoint
        case multipleLocationConnect
    }

    @Test(arguments: LocationConnectCase.allCases)
    func locationFollowsCharacteristics(_ locationCase: LocationConnectCase) async throws {
        let fake: FakeBluetoothCentral
        switch locationCase {
        case .fixedLocationConnect:
            fake = FakeBluetoothCentral(
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
                sensorLocationData: CSCSensorLocation(assignedNumber: 0x04).encode(),
            )
        case .fixedLocationConnectSucceedsWithoutControlPoint:
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([.wheelRevolutionData]).encode(),
                discoveredCharacteristicUUIDs: [
                    CSCS.measurementUUID,
                    CSCS.featureUUID,
                    CSCS.sensorLocationUUID,
                ],
                sensorLocationData: CSCSensorLocation(assignedNumber: 0x04).encode(),
            )
        case .multipleLocationConnect:
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([
                    .wheelRevolutionData,
                    .crankRevolutionData,
                    .multipleSensorLocations,
                ]).encode(),
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
                sensorLocationData: CSCSensorLocation(assignedNumber: 0x05).encode(),
                supportedSensorLocationBytes: [0x05, 0x06, 0x0A],
            )
        }

        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()

        switch locationCase {
        case .fixedLocationConnect, .fixedLocationConnectSucceedsWithoutControlPoint:
            guard case let .fixed(location) = connected.location else {
                Issue.record("Expected fixed location")
                return
            }
            #expect(location.kind == .frontWheel)
            #expect(location.displayName == "Front Wheel")
        case .multipleLocationConnect:
            guard case let .multiple(locations) = connected.location else {
                Issue.record("Expected multiple locations")
                return
            }
            #expect(locations.current.kind == .leftCrank)
            #expect(locations.supported.map(\.kind) == [.leftCrank, .rightCrank, .rearDropout])
        }

        _ = try await connected.disconnect()
    }

    private static func connectFailureCases() -> [ConnectFailureCase] {
        let multipleLocationFake: @Sendable () async -> FakeBluetoothCentral = {
            FakeBluetoothCentral(
                featureData: CSCFeature([
                    .wheelRevolutionData,
                    .crankRevolutionData,
                    .multipleSensorLocations,
                ]).encode(),
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
            )
        }

        return [
            ConnectFailureCase(
                name: "Refused",
                timeouts: Timeouts(),
                makeFake: { FakeBluetoothCentral() },
                configure: { fake, id in
                    await fake.failNext(.connect, with: .connectionFailed(id, reason: "Refused"))
                },
                expected: .failed(reason: "Refused"),
                expectsDisconnect: false,
            ),
            ConnectFailureCase(
                name: "peripheralNotFound",
                timeouts: Timeouts(),
                makeFake: { FakeBluetoothCentral() },
                configure: { fake, id in
                    await fake.failNext(.connect, with: .peripheralNotFound(id))
                },
                expected: .peripheralNotFound,
                expectsDisconnect: false,
            ),
            ConnectFailureCase(
                name: "disconnectedDuringConnect",
                timeouts: Timeouts(),
                makeFake: { FakeBluetoothCentral() },
                configure: { fake, id in
                    await fake.failNext(.connect, with: .disconnected(id, reason: nil))
                },
                expected: .failed(reason: "Disconnected during connect"),
                expectsDisconnect: false,
            ),
            ConnectFailureCase(
                name: "serviceDiscoveryFailure",
                timeouts: Timeouts(),
                makeFake: { FakeBluetoothCentral() },
                configure: { fake, id in
                    await fake.failNext(
                        .discoverServices,
                        with: .serviceNotFound(id, serviceUUID: CSCS.serviceUUID),
                    )
                },
                expected: .serviceDiscoveryFailed(reason: "Service not found: \(CSCS.serviceUUID)"),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "characteristicDiscoveryFailure",
                timeouts: Timeouts(),
                makeFake: { FakeBluetoothCentral() },
                configure: { fake, id in
                    await fake.failNext(
                        .discoverCharacteristics,
                        with: .characteristicNotFound(
                            id,
                            serviceUUID: CSCS.serviceUUID,
                            characteristicUUID: CSCS.measurementUUID,
                        ),
                    )
                },
                expected: .serviceDiscoveryFailed(
                    reason: "Characteristic not found: \(CSCS.measurementUUID) on \(CSCS.serviceUUID)",
                ),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "featureReadFailureThrowsConnectError",
                timeouts: Timeouts(),
                makeFake: { FakeBluetoothCentral() },
                configure: { fake, id in
                    await fake.failNext(
                        .readValue,
                        with: .characteristicNotFound(
                            id,
                            serviceUUID: CSCS.serviceUUID,
                            characteristicUUID: CSCS.featureUUID,
                        ),
                    )
                },
                expected: .serviceDiscoveryFailed(reason: "CSC Feature read failed"),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "notifyFailureMapsToConnectError",
                timeouts: Timeouts(),
                makeFake: { FakeBluetoothCentral() },
                configure: { fake, id in
                    await fake.failNext(
                        .setNotifyValue,
                        with: .characteristicNotFound(
                            id,
                            serviceUUID: CSCS.serviceUUID,
                            characteristicUUID: CSCS.measurementUUID,
                        ),
                    )
                },
                expected: .serviceDiscoveryFailed(
                    reason: "Characteristic not found: \(CSCS.measurementUUID) on \(CSCS.serviceUUID)",
                ),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "zeroFeatureFlagsThrowConnectError",
                timeouts: Timeouts(),
                makeFake: {
                    FakeBluetoothCentral(featureData: CSCFeature([]).encode())
                },
                configure: { _, _ in },
                expected: .serviceDiscoveryFailed(
                    reason: "Sensor supports neither wheel nor crank data",
                ),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "multipleLocationsConnectStillRequiresControlPoint",
                timeouts: Timeouts(),
                makeFake: {
                    FakeBluetoothCentral(
                        featureData: CSCFeature([
                            .wheelRevolutionData,
                            .multipleSensorLocations,
                        ]).encode(),
                        discoveredCharacteristicUUIDs: [
                            CSCS.measurementUUID,
                            CSCS.featureUUID,
                            CSCS.sensorLocationUUID,
                        ],
                        sensorLocationData: CSCSensorLocation(assignedNumber: 0x04).encode(),
                    )
                },
                configure: { _, _ in },
                expected: .serviceDiscoveryFailed(reason: "SC Control Point characteristic missing"),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "heldControlPointIndicationTimesOutOnConnect",
                timeouts: Timeouts(controlPointProcedure: .milliseconds(100)),
                makeFake: multipleLocationFake,
                configure: { fake, _ in
                    await fake.holdNextControlPointIndication()
                },
                expected: .serviceDiscoveryFailed(reason: "timedOut"),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "invalidFeatureValue",
                timeouts: Timeouts(),
                makeFake: {
                    FakeBluetoothCentral(featureData: Data([0xFF]))
                },
                configure: { _, _ in },
                expected: .serviceDiscoveryFailed(reason: "Invalid CSC Feature value"),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "sensorLocationCharacteristicMissing",
                timeouts: Timeouts(),
                makeFake: {
                    FakeBluetoothCentral(
                        featureData: CSCFeature([
                            .wheelRevolutionData,
                            .multipleSensorLocations,
                        ]).encode(),
                        discoveredCharacteristicUUIDs: FakeCharacteristicSets.crankOnlyCharacteristics(),
                    )
                },
                configure: { _, _ in },
                expected: .serviceDiscoveryFailed(reason: "Sensor Location characteristic missing"),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "invalidSensorLocationValue",
                timeouts: Timeouts(),
                makeFake: {
                    FakeBluetoothCentral(
                        featureData: CSCFeature([.wheelRevolutionData]).encode(),
                        discoveredCharacteristicUUIDs: [
                            CSCS.measurementUUID,
                            CSCS.featureUUID,
                            CSCS.sensorLocationUUID,
                        ],
                        sensorLocationData: Data(),
                    )
                },
                configure: { _, _ in },
                expected: .serviceDiscoveryFailed(reason: "Invalid Sensor Location value"),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "currentLocationNotSupported",
                timeouts: Timeouts(),
                makeFake: {
                    FakeBluetoothCentral(
                        featureData: CSCFeature([
                            .wheelRevolutionData,
                            .crankRevolutionData,
                            .multipleSensorLocations,
                        ]).encode(),
                        discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
                        sensorLocationData: CSCSensorLocation(assignedNumber: 0x04).encode(),
                    )
                },
                configure: { fake, _ in
                },
                expected: .serviceDiscoveryFailed(reason: "Current sensor location is not supported"),
                expectsDisconnect: true,
            ),
            ConnectFailureCase(
                name: "supportedLocationsRequestRejected",
                timeouts: Timeouts(),
                makeFake: multipleLocationFake,
                configure: { fake, _ in
                    await fake.setNextControlPointResponseValue(0x02)
                },
                expected: .serviceDiscoveryFailed(reason: "opCodeNotSupported"),
                expectsDisconnect: true,
            ),
        ]
    }
}
