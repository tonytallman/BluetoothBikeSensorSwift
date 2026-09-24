import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerSubscriberCountTests {
    @Test func subscriberCountTracksSubscribeUnsubscribeRadioLossAndStop() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let stream = await server.measurementSubscriberCount
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)

        try await server.start(peripheral: fake)
        #expect(await iterator.next() == 0)

        let first = UUID()
        await fake.subscribeMeasurement(server: server, centralID: first)
        #expect(await iterator.next() == 1)

        let second = UUID()
        await fake.emitSubscription(
            .subscribed(
                centralID: second,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([first, second])
        #expect(await iterator.next() == 2)

        await fake.emitSubscription(
            .unsubscribed(
                centralID: first,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        #expect(await iterator.next() == 1)

        await fake.setState(.poweredOff)
        await server.waitForMeasurementSubscribers([])
        #expect(await iterator.next() == 0)

        await server.stop()
        #expect(await iterator.next() == 0)
    }

    @Test func restartAndLateSubscriberReceiveCurrentValue() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let stream = await server.measurementSubscriberCount
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)

        try await server.start(peripheral: fake)
        #expect(await iterator.next() == 0)
        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)
        #expect(await iterator.next() == 1)

        let lateStream = await server.measurementSubscriberCount
        var lateIterator = lateStream.makeAsyncIterator()
        #expect(await lateIterator.next() == 1)

        await server.stop()
        #expect(await iterator.next() == 0)

        try await server.start(peripheral: fake)
        #expect(await iterator.next() == 0)
        await fake.subscribeMeasurement(server: server, centralID: central)
        #expect(await iterator.next() == 1)
    }

    @Test func duplicateSubscribeDoesNotDoubleCount() async throws {
        let fake = FakeBluetoothPeripheral()
        let server = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let stream = await server.measurementSubscriberCount
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)

        try await server.start(peripheral: fake)
        #expect(await iterator.next() == 0)

        let central = UUID()
        await fake.subscribeMeasurement(server: server, centralID: central)
        #expect(await iterator.next() == 1)

        await fake.emitSubscription(
            .subscribed(
                centralID: central,
                serviceUUID: CSCS.serviceUUID,
                characteristicUUID: CSCS.measurementUUID,
            ),
        )
        await server.waitForMeasurementSubscribers([central])

        let lateStream = await server.measurementSubscriberCount
        var lateIterator = lateStream.makeAsyncIterator()
        #expect(await lateIterator.next() == 1)
    }
}
