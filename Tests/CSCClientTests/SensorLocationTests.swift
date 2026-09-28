import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct SensorLocationTests {
    struct AssignedNumberCase: Sendable {
        let value: UInt8
        let kind: SensorLocation.Kind
        let displayName: String
    }

    @Test(arguments: Self.assignedNumberCases())
    func mapsAssignedNumbersToKind(_ entry: AssignedNumberCase) {
        let location = SensorLocation(assignedNumber: entry.value)
        #expect(location.kind == entry.kind)
        #expect(location.displayName == entry.displayName)
    }

    @Test func multipleLocationUpdateSuccess() async throws {
        let fake = FakeBluetoothCentral(
            featureData: CSCFeature([
                .wheelRevolutionData,
                .crankRevolutionData,
                .multipleSensorLocations,
            ]).encode(),
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
        )

        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
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
        let fake = FakeBluetoothCentral(
            featureData: CSCFeature([
                .wheelRevolutionData,
                .crankRevolutionData,
                .multipleSensorLocations,
            ]).encode(),
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
        )

        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        let frontWheel = SensorLocation(assignedNumber: 0x04)
        do {
            try await locations.update(frontWheel)
            Issue.record("Expected update to throw")
        } catch let error as ControlPointError {
            #expect(error == .unsupportedLocation)
        }

        _ = try await connected.disconnect()
    }

    @Test func multipleLocationUpdateWorksAfterConnectedSensorReleased() async throws {
        let fake = FakeBluetoothCentral(
            featureData: CSCFeature([
                .wheelRevolutionData,
                .crankRevolutionData,
                .multipleSensorLocations,
            ]).encode(),
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
        )

        var connected: ConnectedSensor? = try await CSCClientTestSupport.sensor(central: fake).connect()
        guard case let .multiple(locations) = connected?.location else {
            Issue.record("Expected multiple locations")
            return
        }

        let rearDropout = locations.supported.first { $0.kind == .rearDropout }!
        connected = nil

        try await locations.update(rearDropout)
        #expect(locations.current.kind == .rearDropout)
    }

    @Test(arguments: [
        "multipleLocationUpdateMapsOpCodeNotSupported",
        "multipleLocationUpdateMapsInvalidParameter",
        "multipleLocationUpdateMapsOperationFailed",
        "unknownResponseValue",
    ])
    func multipleLocationUpdateMapsResponse(caseName: String) async throws {
        let fake = FakeBluetoothCentral(
            featureData: CSCFeature([
                .wheelRevolutionData,
                .crankRevolutionData,
                .multipleSensorLocations,
            ]).encode(),
            discoveredCharacteristicUUIDs: FakeCharacteristicSets.allCSCCharacteristicUUIDs,
        )
        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        guard case let .multiple(locations) = connected.location else {
            Issue.record("Expected multiple locations")
            return
        }

        switch caseName {
        case "multipleLocationUpdateMapsOpCodeNotSupported":
            await fake.setNextControlPointResponseValue(0x02)
            do {
                try await locations.update(locations.supported[1])
                Issue.record("Expected opCodeNotSupported")
            } catch let error as ControlPointError {
                #expect(error == .opCodeNotSupported)
            }
        case "multipleLocationUpdateMapsInvalidParameter":
            await fake.setNextControlPointResponseValue(0x03)
            do {
                try await locations.update(locations.supported[1])
                Issue.record("Expected invalidParameter")
            } catch let error as ControlPointError {
                #expect(error == .invalidParameter)
            }
        case "multipleLocationUpdateMapsOperationFailed":
            await fake.setNextControlPointResponseValue(0x04)
            do {
                try await locations.update(locations.supported[1])
                Issue.record("Expected operationFailed")
            } catch let error as ControlPointError {
                #expect(error == .operationFailed)
            }
        case "unknownResponseValue":
            await fake.setNextControlPointResponseValue(0x05)
            do {
                try await locations.update(locations.supported[1])
                Issue.record("Expected unknownResponseValue")
            } catch let error as ControlPointError {
                #expect(error == .failed(reason: "Unknown response value 5"))
            }
        default:
            Issue.record("Unknown case")
        }

        _ = try await connected.disconnect()
    }

    private static func assignedNumberCases() -> [AssignedNumberCase] {
        [
            AssignedNumberCase(value: 0, kind: .other, displayName: "Other"),
            AssignedNumberCase(value: 1, kind: .topOfShoe, displayName: "Top of shoe"),
            AssignedNumberCase(value: 2, kind: .inShoe, displayName: "In shoe"),
            AssignedNumberCase(value: 3, kind: .hip, displayName: "Hip"),
            AssignedNumberCase(value: 4, kind: .frontWheel, displayName: "Front Wheel"),
            AssignedNumberCase(value: 5, kind: .leftCrank, displayName: "Left Crank"),
            AssignedNumberCase(value: 6, kind: .rightCrank, displayName: "Right Crank"),
            AssignedNumberCase(value: 7, kind: .leftPedal, displayName: "Left Pedal"),
            AssignedNumberCase(value: 8, kind: .rightPedal, displayName: "Right Pedal"),
            AssignedNumberCase(value: 9, kind: .frontHub, displayName: "Front Hub"),
            AssignedNumberCase(value: 10, kind: .rearDropout, displayName: "Rear Dropout"),
            AssignedNumberCase(value: 11, kind: .chainstay, displayName: "Chainstay"),
            AssignedNumberCase(value: 12, kind: .rearWheel, displayName: "Rear Wheel"),
            AssignedNumberCase(value: 13, kind: .rearHub, displayName: "Rear Hub"),
            AssignedNumberCase(value: 14, kind: .chest, displayName: "Chest"),
            AssignedNumberCase(value: 15, kind: .spider, displayName: "Spider"),
            AssignedNumberCase(value: 16, kind: .chainRing, displayName: "Chain Ring"),
            AssignedNumberCase(value: 0xFF, kind: .reserved(0xFF), displayName: "Unknown (255)"),
        ]
    }
}
