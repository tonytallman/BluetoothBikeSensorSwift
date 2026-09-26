// Unrepresentable — leave commented. These must not type-check:
// ServerBuilder<ServerWheel.Unselected, ServerCrank.Unselected, ServerLocation.Unselected>().build()
// Server.wheelRevolutions(wheel).build()
// Server.crankRevolutions(crank).setCumulativeWheelRevolutions(cumulative)
// Server.crankRevolutions(crank).startSensorCalibration()
// Server.crankRevolutions(crank).controlPoint()
// Server.crankRevolutions(crank).staticSensorLocation(.leftCrank).multipleSensorLocations(locations)
// Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: cumulative)
//     .wheelRevolutions(wheel, setCumulativeWheelRevolutions: cumulative)
// Server.crankRevolutions(crank).crankRevolutions(crank)

import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerBuilderTests {
    @Test func crankOnly() {
        let server = Server.crankRevolutions(crankStream).build()

        #expect(server.configuration.feature.encode() == Data([0x02, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x02, 0x00],
            sensorLocation: .none,
            includesControlPoint: false,
        ))
        #expect(server.configuration.wheel == nil)
        #expect(isLocationNone(server))
        #expect(!hasControlPoint(server))
    }

    @Test func crankPlusStaticLocation() {
        let server = Server.crankRevolutions(crankStream)
            .staticSensorLocation(.leftCrank)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x02, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x02, 0x00],
            sensorLocation: .cached(.leftCrank),
            includesControlPoint: false,
        ))
        #expect(server.configuration.wheel == nil)
        #expect(!hasControlPoint(server))
    }

    @Test func wheelOnly() {
        let cumulative = CumulativeSpy()
        let server = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x01, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x01, 0x00],
            sensorLocation: .none,
            includesControlPoint: true,
        ))
        #expect(delegateIdentity(server.configuration.wheel?.delegate) == delegateIdentity(cumulative))
        #expect(isLocationNone(server))
        #expect(hasControlPoint(server))
    }

    @Test func wheelPlusStaticLocation() {
        let cumulative = CumulativeSpy()
        let server = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .staticSensorLocation(.rearDropout)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x01, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x01, 0x00],
            sensorLocation: .cached(.rearDropout),
            includesControlPoint: true,
        ))
        #expect(delegateIdentity(server.configuration.wheel?.delegate) == delegateIdentity(cumulative))
        #expect(hasControlPoint(server))
    }

    @Test func wheelPlusCrank() {
        let cumulative = CumulativeSpy()
        let server = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .crankRevolutions(crankStream)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x03, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x03, 0x00],
            sensorLocation: .none,
            includesControlPoint: true,
        ))
        #expect(delegateIdentity(server.configuration.wheel?.delegate) == delegateIdentity(cumulative))
        #expect(isLocationNone(server))
        #expect(hasControlPoint(server))
    }

    @Test func wheelPlusCrankPlusStaticLocation() {
        let cumulative = CumulativeSpy()
        let server = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .crankRevolutions(crankStream)
            .staticSensorLocation(.rearWheel)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x03, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x03, 0x00],
            sensorLocation: .cached(.rearWheel),
            includesControlPoint: true,
        ))
        #expect(delegateIdentity(server.configuration.wheel?.delegate) == delegateIdentity(cumulative))
        #expect(hasControlPoint(server))
    }

    @Test func crankPlusMultipleLocations() {
        let locations = LocationsSpy(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(crankStream)
            .multipleSensorLocations(locations)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x06, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x06, 0x00],
            sensorLocation: .multiple,
            includesControlPoint: true,
        ))
        #expect(server.configuration.wheel == nil)
        #expect(multipleConfiguration(server)?.supported == [.leftCrank, .rightCrank])
        #expect(multipleConfiguration(server)?.current == .leftCrank)
        #expect(sensorLocationValue(server) == nil)
        #expect(hasControlPoint(server))
    }

    @Test func wheelPlusMultipleLocations() {
        let cumulative = CumulativeSpy()
        let locations = LocationsSpy(
            supported: [.rearDropout, .rearWheel],
            current: .rearWheel,
        )
        let server = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .multipleSensorLocations(locations)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x05, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x05, 0x00],
            sensorLocation: .multiple,
            includesControlPoint: true,
        ))
        #expect(delegateIdentity(server.configuration.wheel?.delegate) == delegateIdentity(cumulative))
        #expect(multipleConfiguration(server)?.supported == [.rearDropout, .rearWheel])
        #expect(multipleConfiguration(server)?.current == .rearWheel)
        #expect(sensorLocationValue(server) == nil)
        #expect(hasControlPoint(server))
    }

    @Test func wheelPlusCrankPlusMultipleLocations() {
        let cumulative = CumulativeSpy()
        let locations = LocationsSpy(
            supported: [.leftCrank, .rightCrank],
            current: .rightCrank,
        )
        let server = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .crankRevolutions(crankStream)
            .multipleSensorLocations(locations)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x07, 0x00]))
        #expect(server.configuration.service == expectedService(
            featureBytes: [0x07, 0x00],
            sensorLocation: .multiple,
            includesControlPoint: true,
        ))
        #expect(delegateIdentity(server.configuration.wheel?.delegate) == delegateIdentity(cumulative))
        #expect(multipleConfiguration(server)?.supported == [.leftCrank, .rightCrank])
        #expect(multipleConfiguration(server)?.current == .rightCrank)
        #expect(sensorLocationValue(server) == nil)
        #expect(hasControlPoint(server))
    }

    @Test func multipleLocationsSnapshotIsImmutable() {
        let locations = LocationsSpy(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(crankStream)
            .multipleSensorLocations(locations)
            .build()

        locations.supported = [.frontWheel]
        #expect(multipleConfiguration(server)?.supported == [.leftCrank, .rightCrank])
        #expect(locations.updateCount == 0)

        let cumulative = CumulativeSpy()
        let wheelServer = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .build()
        #expect(cumulative.setCount == 0)
        _ = wheelServer
    }

    @Test func reversedChainMatchesForwardChain() {
        let cumulative = CumulativeSpy()
        let forward = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .crankRevolutions(crankStream)
            .staticSensorLocation(.rearWheel)
            .build()
        let reversed = Server.crankRevolutions(crankStream)
            .staticSensorLocation(.rearWheel)
            .wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .build()

        #expect(reversed.configuration.feature.encode() == forward.configuration.feature.encode())
        #expect(reversed.configuration.service == forward.configuration.service)
    }

    @Test func multipleThenWheelChain() {
        let cumulative = CumulativeSpy()
        let locations = LocationsSpy(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(crankStream)
            .multipleSensorLocations(locations)
            .wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x07, 0x00]))
        #expect(sensorLocationValue(server) == nil)
        #expect(hasControlPoint(server))
        #expect(server.configuration.wheel != nil)
        #expect(server.configuration.crankRevolutions != nil)
    }

    @Test func unreadSequencesRemainAfterBuild() async throws {
        let wheelValue = WheelRevolution(cumulativeRevolutions: 42, lastEventTime: 100)
        let crankValue = CrankRevolution(cumulativeRevolutions: 7, lastEventTime: 200)
        let wheelStream = SingleElementSequence(element: wheelValue)
        let crankStream = SingleElementSequence(element: crankValue)
        let cumulative = CumulativeSpy()

        let server = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
            .crankRevolutions(crankStream)
            .build()

        let wheelIterator = server.configuration.wheel!.revolutions.makeAsyncIterator()
        let crankIterator = server.configuration.crankRevolutions!.makeAsyncIterator()

        let wheelElement = try await wheelIterator.next()
        let crankElement = try await crankIterator.next()

        #expect(wheelElement == wheelValue)
        #expect(crankElement == crankValue)
    }

    @Test func asyncStreamSourcesBuild() {
        let (wheelStream, _) = AsyncStream<WheelRevolution>.makeStream()
        let (crankStream, _) = AsyncStream<CrankRevolution>.makeStream()

        let server = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: CumulativeSpy())
            .crankRevolutions(crankStream)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x03, 0x00]))
    }

    @Test func allSeventeenLocationsBuildsSuccessfully() {
        let allLocations: [SensorLocationKind] = [
            .other,
            .topOfShoe,
            .inShoe,
            .hip,
            .frontWheel,
            .leftCrank,
            .rightCrank,
            .leftPedal,
            .rightPedal,
            .frontHub,
            .rearDropout,
            .chainstay,
            .rearWheel,
            .rearHub,
            .chest,
            .spider,
            .chainRing,
        ]
        let locations = LocationsSpy(
            supported: allLocations,
            current: .chainRing,
        )
        let server = Server.crankRevolutions(crankStream)
            .multipleSensorLocations(locations)
            .build()

        #expect(server.configuration.feature.encode() == Data([0x06, 0x00]))
        #expect(multipleConfiguration(server)?.supported == allLocations)
        #expect(multipleConfiguration(server)?.current == .chainRing)
    }

    private var wheelStream: EmptySequence<WheelRevolution> {
        EmptySequence()
    }

    private var crankStream: EmptySequence<CrankRevolution> {
        EmptySequence()
    }

    private func isLocationNone(_ server: Server) -> Bool {
        if case .none = server.configuration.location {
            return true
        }
        return false
    }

    private func delegateIdentity(_ delegate: (any CumulativeWheelRevolutionsDelegate)?) -> ObjectIdentifier? {
        guard let delegate else {
            return nil
        }
        return ObjectIdentifier(delegate as AnyObject)
    }

    private enum SensorLocationExpectation {
        case none
        case cached(SensorLocationKind)
        case multiple
    }

    private func expectedService(
        featureBytes: [UInt8],
        sensorLocation: SensorLocationExpectation,
        includesControlPoint: Bool,
    ) -> PeripheralService {
        var characteristics: [PeripheralCharacteristic] = [
            PeripheralCharacteristic(
                uuid: CSCS.measurementUUID,
                properties: [.notify],
                permissions: [],
                value: nil,
            ),
            PeripheralCharacteristic(
                uuid: CSCS.featureUUID,
                properties: [.read],
                permissions: [.readable],
                value: Data(featureBytes),
            ),
        ]

        switch sensorLocation {
        case .none:
            break
        case let .cached(kind):
            let value = CSCSensorLocation(assignedNumber: kind.assignedNumber).encode()
            characteristics.append(
                PeripheralCharacteristic(
                    uuid: CSCS.sensorLocationUUID,
                    properties: [.read],
                    permissions: [.readable],
                    value: value,
                ),
            )
        case .multiple:
            characteristics.append(
                PeripheralCharacteristic(
                    uuid: CSCS.sensorLocationUUID,
                    properties: [.read],
                    permissions: [.readable],
                    value: nil,
                ),
            )
        }

        if includesControlPoint {
            characteristics.append(
                PeripheralCharacteristic(
                    uuid: CSCS.controlPointUUID,
                    properties: [.write, .indicate],
                    permissions: [.writeable],
                    value: nil,
                ),
            )
        }

        return PeripheralService(
            uuid: CSCS.serviceUUID,
            isPrimary: true,
            characteristics: characteristics,
        )
    }

    private func hasControlPoint(_ server: Server) -> Bool {
        server.configuration.service.characteristics.contains { $0.uuid == CSCS.controlPointUUID }
    }

    private func sensorLocationValue(_ server: Server) -> Data? {
        server.configuration.service.characteristics
            .first { $0.uuid == CSCS.sensorLocationUUID }
            .map(\.value) ?? nil
    }

    private func multipleConfiguration(_ server: Server) -> MultipleSensorLocationsConfiguration? {
        if case let .multiple(configuration) = server.configuration.location {
            return configuration
        }
        return nil
    }
}

private final class CumulativeSpy: CumulativeWheelRevolutionsDelegate, @unchecked Sendable {
    private(set) var setCount = 0

    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws {
        setCount += 1
    }
}

private struct EmptySequence<Element: Sendable>: AsyncSequence, Sendable {
    struct Iterator: AsyncIteratorProtocol, Sendable {
        func next() async throws -> Element? {
            nil
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator()
    }
}

private struct SingleElementSequence<Element: Sendable>: AsyncSequence, Sendable {
    let element: Element

    struct Iterator: AsyncIteratorProtocol, Sendable {
        var yielded = false
        let element: Element

        mutating func next() async throws -> Element? {
            guard !yielded else {
                return nil
            }
            yielded = true
            return element
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(element: element)
    }
}

private final class LocationsSpy: MultipleSensorLocationsDelegate, @unchecked Sendable {
    var supported: [SensorLocationKind]
    var current: SensorLocationKind
    private(set) var updateCount = 0

    init(supported: [SensorLocationKind], current: SensorLocationKind) {
        self.supported = supported
        self.current = current
    }

    func update(_ location: SensorLocationKind) async throws {
        updateCount += 1
        current = location
    }
}
