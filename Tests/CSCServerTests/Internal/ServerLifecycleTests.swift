import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerLifecycleTests {
    @Test(arguments: ["add", "advertise"])
    func failedStartAllowsRestart(failure: String) async throws {
        let fakeA = FakeBluetoothPeripheral()
        if failure == "add" {
            await fakeA.failNextAdd()
        } else {
            await fakeA.failNextAdvertise()
        }
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        await #expect(throws: ServerError.self) {
            try await serverA.start(peripheral: fakeA)
        }

        try await serverA.start(peripheral: fakeA)
        #expect(await fakeA.isAdvertising)
        await serverA.stop()
    }

    @Test func cancelledStartAllowsRestart() async throws {
        let fakeA = FakeBluetoothPeripheral(initialState: .unknown)
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        let startTask = Task {
            try await serverA.start(peripheral: fakeA)
        }
        await fakeA.waitForStateUpdatesSubscriber()
        startTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }

        let fakeAfterCancel = FakeBluetoothPeripheral()
        try await serverA.start(peripheral: fakeAfterCancel)
        #expect(await fakeAfterCancel.isAdvertising)
        await serverA.stop()
    }

    @Test func secondStopWaitsForInFlightTeardown() async throws {
        let delegate = ScriptedCumulativeDelegate()
        let fakeA = FakeBluetoothPeripheral()
        let serverA = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .build()
        try await serverA.start(peripheral: fakeA)
        let writer = UUID()
        await fakeA.subscribeControlPoint(server: serverA, centralID: writer)

        await delegate.armParkIgnoringCancellationForNextCall()
        #expect(await fakeA.writeControlPoint(controlPointWrite(centralID: writer, value: setCumulativeValue(1))) == .success)
        await delegate.waitUntilRecordedCount(1)

        let firstStop = Task {
            await serverA.stop()
        }
        await delegate.waitUntilCancellationRequested()
        let secondStopReturned = ReturnFlag()
        let secondStop = Task {
            await serverA.stop()
            secondStopReturned.set()
        }

        await serverA.waitUntilStopWaiterCount(2)

        await #expect(throws: ServerError.alreadyStarted) {
            try await serverA.start(peripheral: FakeBluetoothPeripheral())
        }

        #expect(!secondStopReturned.isSet)

        await delegate.release()
        await firstStop.value
        await secondStop.value
        #expect(secondStopReturned.isSet)
    }

    @Test func twoServersCanStartConcurrently() async throws {
        let fakeA = FakeBluetoothPeripheral()
        let fakeB = FakeBluetoothPeripheral()
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        try await serverA.start(peripheral: fakeA)
        try await serverB.start(peripheral: fakeB)
        #expect(await fakeA.isAdvertising)
        #expect(await fakeB.isAdvertising)

        await serverA.stop()
        await serverB.stop()
    }

    @Test func releasingStartedServerStopsIt() async throws {
        let fakeA = FakeBluetoothPeripheral()
        do {
            let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
            try await serverA.start(peripheral: fakeA)
        }
        await fakeA.waitUntilRecordedCallsSatisfy { calls in
            calls.contains(where: isRemoveService)
        }

        #expect(await !fakeA.isAdvertising)
        #expect(await fakeA.recordedCalls.contains(where: isRemoveService))
    }
}

private final class ReturnFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}
