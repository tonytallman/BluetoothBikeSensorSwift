import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct ConnectedSensorTests {
    @Test func rapidConnectDisconnectReconnect() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        var current = CSCClientTestSupport.sensor(id: sensorID, central: fake)

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
    }

    @Test(arguments: ["disconnectAlreadyDisconnected", "disconnectFailureMapsToDisconnectError"])
    func disconnectFailureMapsToDisconnectError(caseName: String) async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()

        switch caseName {
        case "disconnectAlreadyDisconnected":
            await fake.failNext(.disconnect, with: .peripheralNotFound(sensorID))
            do {
                _ = try await connected.disconnect()
                Issue.record("Expected disconnect to throw")
            } catch let error as DisconnectError {
                #expect(error == .alreadyDisconnected)
            }
        case "disconnectFailureMapsToDisconnectError":
            await fake.failNext(.disconnect, with: .connectionFailed(sensorID, reason: "Link dropped"))
            do {
                _ = try await connected.disconnect()
                Issue.record("Expected disconnect to throw")
            } catch let error as DisconnectError {
                #expect(error == .failed(reason: "Link dropped"))
            }
        default:
            Issue.record("Unknown case")
        }
    }

    @Test func disconnectFinishesAllStreams() async throws {
        let fake = FakeBluetoothCentral()
        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)
        let crank = try #require(connected.revolutions.crank)

        let speedStream = await wheel.speed
        let cadenceStream = await crank.cadence
        let wheelStream = await wheel.wheelSamples
        let crankStream = await crank.crankSamples

        let speedTask = Task { await consumeStream(speedStream) }
        let cadenceTask = Task { await consumeStream(cadenceStream) }
        let wheelTask = Task { await consumeStream(wheelStream) }
        let crankTask = Task { await consumeStream(crankStream) }

        _ = try await connected.disconnect()

        #expect(await speedTask.value)
        #expect(await cadenceTask.value)
        #expect(await wheelTask.value)
        #expect(await crankTask.value)
    }

    @Test func discoverServicesAfterLinkLossFailsFast() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        _ = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        await fake.emit(.disconnected(peripheralID: sensorID))

        do {
            try await fake.discoverServices(id: sensorID, serviceUUIDs: [CSCS.serviceUUID])
            Issue.record("Expected discoverServices to throw")
        } catch let error as BluetoothCentralError {
            #expect(error == .disconnected(sensorID, reason: nil))
        }
    }

    @Test func disconnectAfterLinkLossDoesNotHangOnSetNotify() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()

        await fake.hangNextSetNotify()
        await fake.emit(.disconnected(peripheralID: sensorID))

        let start = ContinuousClock.now
        _ = try await connected.disconnect()
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func unexpectedDisconnectFinishesAllStreams() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)
        let crank = try #require(connected.revolutions.crank)

        let speedStream = await wheel.speed
        let cadenceStream = await crank.cadence
        let wheelStream = await wheel.wheelSamples
        let crankStream = await crank.crankSamples

        let speedTask = Task {
            var speeds: [Speed] = []
            for await value in speedStream {
                speeds.append(value)
            }
            return speeds
        }
        let cadenceTask = Task { await consumeStream(cadenceStream) }
        let wheelTask = Task { await consumeStream(wheelStream) }
        let crankTask = Task { await consumeStream(crankStream) }

        await emitWheel(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitWheel(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)

        await fake.emit(.disconnected(peripheralID: sensorID))

        let speeds = await speedTask.value
        #expect(speeds.count == 1)
        #expect(await cadenceTask.value)
        #expect(await wheelTask.value)
        #expect(await crankTask.value)
    }

    @Test(arguments: ["speedStreamsWhenWheelFeatureLacksControlPoint", "speedAndCadenceStreamWhenWheelAndCrankLackControlPoint"])
    func streamsWithoutControlPoint(caseName: String) async throws {
        let fake: FakeBluetoothCentral
        let sensorID = UUID()
        switch caseName {
        case "speedStreamsWhenWheelFeatureLacksControlPoint":
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([.wheelRevolutionData]).encode(),
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.crankOnlyCharacteristics(),
            )
        case "speedAndCadenceStreamWhenWheelAndCrankLackControlPoint":
            fake = FakeBluetoothCentral(
                featureData: CSCFeature([.wheelRevolutionData, .crankRevolutionData]).encode(),
                discoveredCharacteristicUUIDs: FakeCharacteristicSets.crankOnlyCharacteristics(),
            )
        default:
            fake = FakeBluetoothCentral()
        }

        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)

        if caseName == "speedAndCadenceStreamWhenWheelAndCrankLackControlPoint" {
            let crank = try #require(connected.revolutions.crank)
            let speedStream = await wheel.speed
            let cadenceStream = await crank.cadence
            var speedIterator = speedStream.makeAsyncIterator()
            var cadenceIterator = cadenceStream.makeAsyncIterator()

            await emitCombined(fake: fake, id: sensorID, wheelRev: 100, crankRev: 10, eventTime: 1_024)
            await emitCombined(fake: fake, id: sensorID, wheelRev: 102, crankRev: 11, eventTime: 2_048)

            #expect(await speedIterator.next() != nil)
            #expect(await cadenceIterator.next() != nil)
        } else {
            let speedStream = await wheel.speed
            var speedIterator = speedStream.makeAsyncIterator()
            await emitWheel(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
            await emitWheel(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)
            #expect(await speedIterator.next() != nil)
        }

        _ = try await connected.disconnect()
    }

    @Test func combinedPayloadEmitsBothSamples() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)
        let crank = try #require(connected.revolutions.crank)

        var wheelIterator = (await wheel.wheelSamples).makeAsyncIterator()
        var crankIterator = (await crank.crankSamples).makeAsyncIterator()

        await emitCombined(fake: fake, id: sensorID, wheelRev: 100, crankRev: 10, eventTime: 1_024)
        await emitCombined(fake: fake, id: sensorID, wheelRev: 102, crankRev: 11, eventTime: 2_048)

        let wheelSample = await wheelIterator.next()
        let crankSample = await crankIterator.next()
        #expect(wheelSample?.deltaDistance.converted(to: .meters).value == 4.21)
        #expect(wheelSample?.deltaTime.converted(to: .seconds).value == 1.0)
        #expect(crankSample?.deltaRevolutions == 1)
        #expect(crankSample?.deltaTime.converted(to: .seconds).value == 1.0)
    }

    @Test func interleavedPacketsEmitBothFamilies() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)
        let crank = try #require(connected.revolutions.crank)

        var wheelIterator = (await wheel.wheelSamples).makeAsyncIterator()
        var crankIterator = (await crank.crankSamples).makeAsyncIterator()

        await emitWheel(fake: fake, id: sensorID, revolutions: 100, eventTime: 1_024)
        await emitCrank(fake: fake, id: sensorID, revolutions: 10, eventTime: 1_024)
        await emitWheel(fake: fake, id: sensorID, revolutions: 102, eventTime: 2_048)
        await emitCrank(fake: fake, id: sensorID, revolutions: 11, eventTime: 2_048)

        let wheelSample = await wheelIterator.next()
        let crankSample = await crankIterator.next()
        #expect(wheelSample?.deltaDistance.converted(to: .meters).value == 4.21)
        #expect(crankSample?.deltaRevolutions == 1)
    }

    @Test func streamRequestedAfterDisconnectFinishes() async throws {
        let fake = FakeBluetoothCentral()
        let connected = try await CSCClientTestSupport.sensor(central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)

        _ = try await connected.disconnect()

        let stream = await wheel.speed
        var finished = false
        for await _ in stream {
        }
        finished = true
        #expect(finished)
    }

    @Test func combinedPayloadOneSideIdle() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let connected = try await CSCClientTestSupport.sensor(id: sensorID, central: fake).connect()
        let wheel = try #require(connected.revolutions.wheel)
        let crank = try #require(connected.revolutions.crank)

        var wheelIterator = (await wheel.wheelSamples).makeAsyncIterator()
        var crankIterator = (await crank.crankSamples).makeAsyncIterator()
        var speedIterator = (await wheel.speed).makeAsyncIterator()
        var cadenceIterator = (await crank.cadence).makeAsyncIterator()

        await emitCombined(fake: fake, id: sensorID, wheelRev: 100, crankRev: 10, eventTime: 1_024)
        await emitCombined(fake: fake, id: sensorID, wheelRev: 102, crankRev: 10, eventTime: 1_024)
        await emitCombined(fake: fake, id: sensorID, wheelRev: 102, crankRev: 11, eventTime: 2_048)

        #expect(await wheelIterator.next() != nil)
        #expect(await speedIterator.next() != nil)
        let crankSample = await crankIterator.next()
        #expect(crankSample?.deltaRevolutions == 1)
        #expect(crankSample?.deltaTime.converted(to: .seconds).value == 1.0)
        #expect(await cadenceIterator.next() != nil)
    }

    private func consumeStream<T>(_ stream: AsyncStream<T>) async -> Bool {
        for await _ in stream {}
        return true
    }

    private func emitWheel(
        fake: FakeBluetoothCentral,
        id: UUID,
        revolutions: UInt32,
        eventTime: UInt16,
    ) async {
        await CSCClientTestSupport.emitMeasurement(
            CSCMeasurement(
                cumulativeWheelRevolutions: revolutions,
                lastWheelEventTime: eventTime,
            ),
            from: fake,
            peripheralID: id,
        )
    }

    private func emitCrank(
        fake: FakeBluetoothCentral,
        id: UUID,
        revolutions: UInt16,
        eventTime: UInt16,
    ) async {
        await CSCClientTestSupport.emitMeasurement(
            CSCMeasurement(
                cumulativeCrankRevolutions: revolutions,
                lastCrankEventTime: eventTime,
            ),
            from: fake,
            peripheralID: id,
        )
    }

    private func emitCombined(
        fake: FakeBluetoothCentral,
        id: UUID,
        wheelRev: UInt32,
        crankRev: UInt16,
        eventTime: UInt16,
    ) async {
        await CSCClientTestSupport.emitMeasurement(
            CSCMeasurement(
                cumulativeWheelRevolutions: wheelRev,
                lastWheelEventTime: eventTime,
                cumulativeCrankRevolutions: crankRev,
                lastCrankEventTime: eventTime,
            ),
            from: fake,
            peripheralID: id,
        )
    }
}
