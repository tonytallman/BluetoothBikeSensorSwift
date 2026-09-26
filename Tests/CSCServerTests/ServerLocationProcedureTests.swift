import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerLocationProcedureTests {
    @Test(arguments: [
        "crank",
        "wheel",
        "wheelCrank",
    ])
    func updateSupportedLocation(shape: String) async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let cumulative = ScriptedCumulativeDelegate()
        let server = try makeMultipleServer(
            shape: shape,
            locations: locations,
            cumulative: cumulative,
        )
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }

        let transactionID = UUID()
        await fake.emitWriteTransaction(
            updateLocationWrite(centralID: writer, assignedNumber: 0x06, transactionID: transactionID),
        )
        await fake.waitForRecordedCall { call in
            if case let .respond(id, .success, nil) = call {
                return id == transactionID
            }
            return false
        }
        await locations.waitUntilUpdateCount(1)
        #expect(locations.recordedUpdateKinds == [.rightCrank])
        #expect(locations.updateInvocationCount == 1)

        let success = CSCControlPointResponse(
            requestOpcode: 0x03,
            value: 0x01,
            parameter: Data(),
        ).encode()
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, .only(centrals)) = call {
                return value == success && centrals == [writer]
            }
            return false
        }

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x06])
            }
            return false
        }

        if case .multiple(let configuration) = server.configuration.location {
            #expect(configuration.current == .leftCrank)
        } else {
            Issue.record("Expected multiple location configuration")
        }
        await server.waitUntilControlPointProcedureIdle()
    }

    @Test func unsupportedAndOutOfRangeUpdateBytes() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        let invalidUpdateIndication = CSCControlPointResponse(
            requestOpcode: 0x03,
            value: 0x03,
            parameter: Data(),
        ).encode()
        for nth in 1 ... 2 {
            let assigned: UInt8 = nth == 1 ? 0x0A : 0x11
            await fake.emitWriteTransaction(
                updateLocationWrite(centralID: writer, assignedNumber: assigned),
            )
            await fake.waitUntilRecordedCallsSatisfy { calls in
                calls.filter { call in
                    if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                        return value == invalidUpdateIndication
                    }
                    return false
                }.count >= nth
            }
            await server.waitUntilControlPointProcedureIdle()
        }

        #expect(locations.updateInvocationCount == 0)
        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }
    }

    @Test func malformedUpdateIndicatesInvalidParameter() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        let malformedUpdateIndication = CSCControlPointResponse(
            requestOpcode: 0x03,
            value: 0x03,
            parameter: Data(),
        ).encode()
        for nth in 1 ... 2 {
            let body = nth == 1 ? Data([0x03]) : Data([0x03, 0x05, 0xFF])
            await fake.emitWriteTransaction(
                PeripheralWriteTransaction(
                    id: UUID(),
                    requests: [
                        PeripheralWriteRequest(
                            centralID: writer,
                            serviceUUID: CSCS.serviceUUID,
                            characteristicUUID: CSCS.controlPointUUID,
                            offset: 0,
                            value: body,
                        ),
                    ],
                ),
            )
            await fake.waitUntilRecordedCallsSatisfy { calls in
                calls.filter { call in
                    if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                        return value == malformedUpdateIndication
                    }
                    return false
                }.count >= nth
            }
            await server.waitUntilControlPointProcedureIdle()
        }
        #expect(locations.updateInvocationCount == 0)
    }

    @Test func delegateThrowIndicatesOperationFailed() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        locations.setShouldThrow(true)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x03,
                    value: 0x04,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        await server.waitUntilControlPointProcedureIdle()

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }

        await server.stop()
        try await server.start(peripheral: fake)
        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .respond(_, .success, value) = call {
                    return value == Data([0x05])
                }
                return false
            }.count >= 2
        }
    }

    @Test func restartServesLastSuccessfulUpdateArgument() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        var fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)
        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x03,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        await server.waitUntilControlPointProcedureIdle()

        await server.stop()
        fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x06])
            }
            return false
        }
        #expect(locations.current == .leftCrank)
    }

    @Test func wheelPlusStaticLocationProceduresStayUnsupported() async throws {
        let cumulative = ScriptedCumulativeDelegate()
        let fake = FakeBluetoothPeripheral()
        let server = Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: cumulative)
            .staticSensorLocation(.leftCrank)
            .build()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x05))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, _, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x03,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        await server.waitUntilControlPointProcedureIdle()

        await fake.emitWriteTransaction(requestSupportedWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, _, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x04,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
    }

    @Test func updateToAlreadyCurrentLocationStillCallsDelegate() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x05))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x03,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        #expect(locations.recordedUpdateKinds == [.leftCrank])
        await server.waitUntilControlPointProcedureIdle()

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }
    }

    @Test func dynamicSensorLocationReadOffsets() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }

        await emitSensorLocationRead(fake: fake, offset: 1)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data()
            }
            return false
        }

        await emitSensorLocationRead(fake: fake, offset: 2)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x07), nil) = call {
                return true
            }
            return false
        }
    }

    @Test func requestReturnsSnapshotInOrder() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.rearDropout, .rearWheel, .leftCrank],
            current: .rearWheel,
        )
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(requestSupportedWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x04,
                    value: 0x01,
                    parameter: Data([0x0A, 0x0C, 0x05]),
                ).encode()
            }
            return false
        }
        #expect(locations.updateInvocationCount == 0)
        await server.waitUntilControlPointProcedureIdle()

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x0C])
            }
            return false
        }
    }

    @Test func allSeventeenLocationsRequestFitsDefaultMTU() async throws {
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
        let locations = ScriptedLocationDelegate(supported: allLocations, current: .chainRing)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)
        await fake.emitWriteTransaction(requestSupportedWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x04,
                    value: 0x01,
                    parameter: Data(0x00 ... 0x10),
                ).encode()
            }
            return false
        }
        #expect(
            CSCControlPointResponse(
                requestOpcode: 0x04,
                value: 0x01,
                parameter: Data(0x00 ... 0x10),
            ).encode().count == 20,
        )
    }

    @Test func requestWithExtraParameterIndicatesInvalidParameter() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x04, 0x00]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x04,
                    value: 0x03,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
    }

    @Test func requestUsesBuildTimeSupportedSnapshot() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        locations.setSupported([.rearWheel])
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)
        await fake.emitWriteTransaction(requestSupportedWrite(centralID: writer))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x04,
                    value: 0x01,
                    parameter: Data([0x05, 0x06]),
                ).encode()
            }
            return false
        }
    }

    @Test func crankOnlyMultipleRejectsSetCumulative() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        await server.waitUntilControlPointProcedureIdle()

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x05))
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x03,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
    }

    @Test func shortSetCumulativeOnCrankMultipleIndicatesOpCodeNotSupported() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x01]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
    }

    @Test(arguments: ["wheel", "wheelCrank"])
    func wheelServersStillAcceptSetCumulative(shape: String) async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let cumulative = ScriptedCumulativeDelegate()
        let server = try makeMultipleServer(
            shape: shape,
            locations: locations,
            cumulative: cumulative,
        )
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x01, 0x78, 0x56, 0x34, 0x12]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x01,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
        #expect(await cumulative.recordedValues == [0x12345678])

        let measurementUpdates = await fake.recordedCalls.filter { call in
            if case .updateValue(_, _, CSCS.measurementUUID, _) = call { return true }
            return false
        }
        #expect(measurementUpdates.isEmpty)
        await server.waitUntilControlPointProcedureIdle()

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }
    }

    @Test func locationUpdateBackpressureBlocksSecondWrite() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        let success = CSCControlPointResponse(
            requestOpcode: 0x03,
            value: 0x01,
            parameter: Data(),
        ).encode()
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == success
            }
            return false
        }

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x80), nil) = call { return true }
            return false
        }
        #expect(locations.updateInvocationCount == 1)

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                    return value == success
                }
                return false
            }.count == 2
        }
        await server.waitUntilControlPointProcedureIdle()
    }

    @Test func requestBackpressureMatchesUpdatePattern() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(requestSupportedWrite(centralID: writer))
        let success = CSCControlPointResponse(
            requestOpcode: 0x04,
            value: 0x01,
            parameter: Data([0x05]),
        ).encode()
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == success
            }
            return false
        }

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()
        await fake.waitUntilRecordedCallsSatisfy { calls in
            calls.filter { call in
                if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                    return value == success
                }
                return false
            }.count == 2
        }
        await server.waitUntilControlPointProcedureIdle()
    }

    @Test func delegateParkThenReadAfterIndicationAttempt() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        locations.armParkForNextCall()
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        await locations.waitUntilUpdateCount(1)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .error(0x80), nil) = call { return true }
            return false
        }

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }

        locations.release()
        let success = CSCControlPointResponse(
            requestOpcode: 0x03,
            value: 0x01,
            parameter: Data(),
        ).encode()
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == success
            }
            return false
        }

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x06])
            }
            return false
        }
    }

    @Test func unsubscribeAfterBackpressureStillStoresLocation() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        let success = CSCControlPointResponse(
            requestOpcode: 0x03,
            value: 0x01,
            parameter: Data(),
        ).encode()
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == success
            }
            return false
        }

        await fake.emitSubscription(
            .unsubscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )
        await server.waitUntilControlPointProcedureIdle()

        let attempts = await fake.recordedCalls.filter { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == success
            }
            return false
        }
        #expect(attempts.count == 1)

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x06])
            }
            return false
        }

        await fake.setNextUpdateValueAccepted(true)
    }

    @Test func unsubscribeDuringParkDropsIndicationButStoresLocation() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        locations.armParkForNextCall()
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        await locations.waitUntilUpdateCount(1)

        await fake.emitSubscription(
            .unsubscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
            ),
        )

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }

        locations.release()
        await server.waitUntilControlPointProcedureIdle()

        let success = CSCControlPointResponse(
            requestOpcode: 0x03,
            value: 0x01,
            parameter: Data(),
        ).encode()
        let attempts = await fake.recordedCalls.filter { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == success
            }
            return false
        }
        #expect(attempts.isEmpty)

        await emitSensorLocationRead(fake: fake, offset: 0)
        await fake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x06])
            }
            return false
        }
    }

    @Test func stopDuringParkedUpdateLeavesBuildTimeLocation() async throws {
        let locations = ScriptedLocationDelegate(
            supported: [.leftCrank, .rightCrank],
            current: .leftCrank,
        )
        locations.armParkForNextCall()
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(updateLocationWrite(centralID: writer, assignedNumber: 0x06))
        await locations.waitUntilUpdateCount(1)

        await server.stop()
        #expect(locations.updateInvocationCount == 1)

        let controlPointUpdates = await fake.recordedCalls.filter { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                let encoded03 = CSCControlPointResponse(
                    requestOpcode: 0x03,
                    value: 0x01,
                    parameter: Data(),
                ).encode()
                let encoded04 = CSCControlPointResponse(
                    requestOpcode: 0x03,
                    value: 0x04,
                    parameter: Data(),
                ).encode()
                return value == encoded03 || value == encoded04
            }
            return false
        }
        #expect(controlPointUpdates.isEmpty)

        let restartFake = FakeBluetoothPeripheral()
        try await server.start(peripheral: restartFake)
        await emitSensorLocationRead(fake: restartFake, offset: 0)
        await restartFake.waitForRecordedCall { call in
            if case let .respond(_, .success, value) = call {
                return value == Data([0x05])
            }
            return false
        }
    }

    @Test func requestQueuesBehindMeasurementOnSharedPump() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let cumulative = ScriptedCumulativeDelegate()
        let (wheelSequence, yieldWheel) = makeYieldingWheelSequence()
        let server = Server.wheelRevolutions(wheelSequence, setCumulativeWheelRevolutions: cumulative)
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        await fake.setNextUpdateValueAccepted(false)
        try await server.start(peripheral: fake)

        let writer = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: writer,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([writer])
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await yieldWheel(WheelRevolution(cumulativeRevolutions: 42, lastEventTime: 7))
        let wheelPayload = CSCMeasurement(
            cumulativeWheelRevolutions: 42,
            lastWheelEventTime: 7,
        ).encode()!
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == wheelPayload
            }
            return false
        }

        await fake.emitWriteTransaction(requestSupportedWrite(centralID: writer))
        await server.waitUntilOutboundCount(atLeast: 2)

        let controlPointBeforeReady = await fake.recordedCalls.contains { call in
            if case .updateValue(_, _, CSCS.controlPointUUID, _) = call { return true }
            return false
        }
        #expect(!controlPointBeforeReady)

        let callsBeforeReady = await fake.recordedCalls
        let rejectedMeasurementAttempts = callsBeforeReady.filter { call in
            if case let .updateValue(value, _, CSCS.measurementUUID, _) = call {
                return value == wheelPayload
            }
            return false
        }.count
        #expect(rejectedMeasurementAttempts == 1)

        await fake.setNextUpdateValueAccepted(true)
        await fake.emitReadyToUpdateSubscribers()

        let requestIndication = CSCControlPointResponse(
            requestOpcode: 0x04,
            value: 0x01,
            parameter: Data([0x05]),
        ).encode()
        await fake.waitUntilRecordedCallsSatisfy { calls in
            let wheelIndices = calls.indices.filter { index in
                if case let .updateValue(value, _, CSCS.measurementUUID, _) = calls[index] {
                    return value == wheelPayload
                }
                return false
            }
            let requestIndices = calls.indices.filter { index in
                if case let .updateValue(value, _, CSCS.controlPointUUID, _) = calls[index] {
                    return value == requestIndication
                }
                return false
            }
            guard wheelIndices.count >= 2, let requestIndex = requestIndices.first else {
                return false
            }
            return wheelIndices[1] < requestIndex
        }
    }

    @Test func calibrationStillUnsupportedOnMultipleServer() async throws {
        let locations = ScriptedLocationDelegate(supported: [.leftCrank], current: .leftCrank)
        let server = Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
        let fake = FakeBluetoothPeripheral()
        try await server.start(peripheral: fake)

        let writer = UUID()
        await subscribeControlPoint(fake: fake, server: server, centralID: writer)

        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: UUID(),
                requests: [
                    PeripheralWriteRequest(
                        centralID: writer,
                        serviceUUID: CSCS.serviceUUID,
                        characteristicUUID: CSCS.controlPointUUID,
                        offset: 0,
                        value: Data([0x02]),
                    ),
                ],
            ),
        )
        await fake.waitForRecordedCall { call in
            if case let .updateValue(value, _, CSCS.controlPointUUID, _) = call {
                return value == CSCControlPointResponse(
                    requestOpcode: 0x02,
                    value: 0x02,
                    parameter: Data(),
                ).encode()
            }
            return false
        }
    }
}

private func makeMultipleServer(
    shape: String,
    locations: ScriptedLocationDelegate,
    cumulative: ScriptedCumulativeDelegate,
) throws -> Server {
    switch shape {
    case "crank":
        return Server.crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
    case "wheel":
        return Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: cumulative)
            .multipleSensorLocations(locations)
            .build()
    case "wheelCrank":
        return Server.wheelRevolutions(EmptyWheelSequence(), setCumulativeWheelRevolutions: cumulative)
            .crankRevolutions(EmptyCrankSequence())
            .multipleSensorLocations(locations)
            .build()
    default:
        throw TestDelegateError.failure
    }
}

private func subscribeControlPoint(
    fake: FakeBluetoothPeripheral,
    server: Server,
    centralID: UUID,
) async {
    await fake.emitSubscription(
        .subscribed(
            centralID: centralID,
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.controlPointUUID,
        ),
    )
    await server.waitForControlPointSubscribers([centralID])
}

private func emitSensorLocationRead(fake: FakeBluetoothPeripheral, offset: Int) async {
    await fake.emitRead(
        PeripheralReadRequest(
            id: UUID(),
            centralID: UUID(),
            serviceUUID: CSCS.serviceUUID,
            characteristicUUID: CSCS.sensorLocationUUID,
            offset: offset,
        ),
    )
}

private func updateLocationWrite(
    centralID: UUID,
    assignedNumber: UInt8,
    transactionID: UUID = UUID(),
) -> PeripheralWriteTransaction {
    PeripheralWriteTransaction(
        id: transactionID,
        requests: [
            PeripheralWriteRequest(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
                offset: 0,
                value: Data([0x03, assignedNumber]),
            ),
        ],
    )
}

private func requestSupportedWrite(
    centralID: UUID,
    transactionID: UUID = UUID(),
) -> PeripheralWriteTransaction {
    PeripheralWriteTransaction(
        id: transactionID,
        requests: [
            PeripheralWriteRequest(
                centralID: centralID,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.controlPointUUID,
                offset: 0,
                value: Data([0x04]),
            ),
        ],
    )
}

private func makeYieldingWheelSequence() -> (
    sequence: YieldingWheelSequence,
    yield: @Sendable (WheelRevolution) async -> Void,
) {
    let sequence = YieldingWheelSequence()
    return (sequence, { revolution in
        await sequence.yield(revolution)
    })
}

private struct EmptyCrankSequence: AsyncSequence, Sendable {
    typealias Element = CrankRevolution
    typealias AsyncIterator = Iterator

    struct Iterator: AsyncIteratorProtocol {
        func next() async -> CrankRevolution? { nil }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

private struct EmptyWheelSequence: AsyncSequence, Sendable {
    typealias Element = WheelRevolution
    typealias AsyncIterator = Iterator

    struct Iterator: AsyncIteratorProtocol {
        func next() async -> WheelRevolution? { nil }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}
