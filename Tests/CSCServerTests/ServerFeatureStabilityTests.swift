import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerFeatureStabilityTests {
    enum Shape: String, CaseIterable, Sendable {
        case crank
        case crankStatic
        case crankMultiple
        case wheel
        case wheelStatic
        case wheelMultiple
        case wheelCrank
        case wheelCrankStatic
        case wheelCrankMultiple
    }

    @Test(arguments: Shape.allCases)
    func featureAndInventoryIdenticalAcrossRestart(shape: Shape) async throws {
        let server = Self.build(shape)
        let fake = FakeBluetoothPeripheral()

        try await server.start(peripheral: fake)
        await server.stop()
        try await server.start(peripheral: fake)

        let added = await fake.recordedCalls.compactMap { call -> PeripheralService? in
            if case let .add(service) = call {
                return service
            }
            return nil
        }
        #expect(added == [server.service, server.service])

        let feature = try #require(server.service.characteristics.first { $0.uuid == CSCS.featureUUID })
        #expect(feature.value == server.feature.encode())
        #expect(feature.properties == [.read])
        #expect(feature.permissions == [.readable])
        #expect(await fake.read(characteristicUUID: CSCS.featureUUID) == server.feature.encode())

        await server.stop()
    }

    @Test func proceduresDoNotChangeFeature() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank, .rightCrank], current: .leftCrank)
        let delegate = ScriptedCumulativeDelegate()
        let server = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)
        let writer = UUID()
        await fake.subscribeControlPoint(server: server, centralID: writer)

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: updateSensorLocationValue(.rightCrank))) == .success)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x03, value: 0x01) },
        )
        await server.waitUntilControlPointProcedureIdle()

        #expect(await fake.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(9))) == .success)
        await fake.waitUntilUpdateValueCount(
            1,
            characteristic: CSCS.controlPointUUID,
            matching: { $0 == controlPointResponse(opcode: 0x01, value: 0x01) },
        )
        await server.waitUntilControlPointProcedureIdle()

        #expect(await fake.read(characteristicUUID: CSCS.featureUUID) == Data([0x05, 0x00]))
        #expect(server.feature.encode() == Data([0x05, 0x00]))
        await server.stop()
    }

    @Test func buildersProduceIndependentServersWithSameFeature() async throws {
        let builder = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: ScriptedCumulativeDelegate())
            .crankRevolutions(NeverYieldingCrankSequence())
        let first = builder.build()
        let second = builder.build()

        #expect(first !== second)
        #expect(first.feature == second.feature)
        #expect(first.service == second.service)

        let firstFake = FakeBluetoothPeripheral()
        let secondFake = FakeBluetoothPeripheral()
        try await first.start(peripheral: firstFake)
        try await second.start(peripheral: secondFake)
        await first.stop()

        #expect(await !firstFake.isAdvertising)
        #expect(await secondFake.isAdvertising)
        #expect(await secondFake.read(characteristicUUID: CSCS.featureUUID) == Data([0x03, 0x00]))
        await second.stop()
    }

    private static func build(_ shape: Shape) -> Server {
        let wheel = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: ScriptedCumulativeDelegate())
        let crank = Server.crankRevolutions(NeverYieldingCrankSequence())
        let locations = ScriptedLocationDelegate(supported: [.leftCrank, .rightCrank], current: .leftCrank)
        switch shape {
        case .crank:
            return crank.build()
        case .crankStatic:
            return crank.staticSensorLocation(.leftCrank).build()
        case .crankMultiple:
            return crank.multipleSensorLocations(locations).build()
        case .wheel:
            return wheel.build()
        case .wheelStatic:
            return wheel.staticSensorLocation(.rearDropout).build()
        case .wheelMultiple:
            return wheel.multipleSensorLocations(locations).build()
        case .wheelCrank:
            return wheel.crankRevolutions(NeverYieldingCrankSequence()).build()
        case .wheelCrankStatic:
            return wheel.crankRevolutions(NeverYieldingCrankSequence()).staticSensorLocation(.rearWheel).build()
        case .wheelCrankMultiple:
            return wheel.crankRevolutions(NeverYieldingCrankSequence()).multipleSensorLocations(locations).build()
        }
    }
}
