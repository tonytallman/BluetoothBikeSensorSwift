import CSCServer
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ServerLifecycleTests {
    @Test func secondServerStartThrowsAlreadyStarted() async throws {
        let registry = LiveServerRegistry()
        let fakeA = FakeBluetoothPeripheral()
        let fakeB = FakeBluetoothPeripheral()
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        try await serverA.start(peripheral: fakeA, liveServers: registry)
        await #expect(throws: ServerError.alreadyStarted) {
            try await serverB.start(peripheral: fakeB, liveServers: registry)
        }
        #expect(await fakeB.recordedCalls.isEmpty)
        #expect(await fakeA.isAdvertising)

        await serverA.stop()
    }

    @Test func stopReleasesSlot() async throws {
        let registry = LiveServerRegistry()
        let fakeB = FakeBluetoothPeripheral()
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        try await serverA.start(peripheral: FakeBluetoothPeripheral(), liveServers: registry)
        await serverA.stop()
        #expect(!registry.isOccupied)

        try await serverB.start(peripheral: fakeB, liveServers: registry)
        #expect(await fakeB.isAdvertising)
        await serverB.stop()
    }

    @Test(arguments: ["add", "advertise"])
    func failedStartReleasesSlot(failure: String) async throws {
        let registry = LiveServerRegistry()
        let fakeA = FakeBluetoothPeripheral()
        if failure == "add" {
            await fakeA.failNextAdd()
        } else {
            await fakeA.failNextAdvertise()
        }
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        await #expect(throws: ServerError.self) {
            try await serverA.start(peripheral: fakeA, liveServers: registry)
        }
        #expect(!registry.isOccupied)

        let fakeB = FakeBluetoothPeripheral()
        try await serverB.start(peripheral: fakeB, liveServers: registry)
        #expect(await fakeB.isAdvertising)
        await serverB.stop()
    }

    @Test func cancelledStartReleasesSlot() async throws {
        let registry = LiveServerRegistry()
        let fakeA = FakeBluetoothPeripheral(initialState: .unknown)
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        let startTask = Task {
            try await serverA.start(peripheral: fakeA, liveServers: registry)
        }
        await fakeA.waitForStateUpdatesSubscriber()
        #expect(registry.isOccupied)
        startTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        #expect(!registry.isOccupied)

        let fakeB = FakeBluetoothPeripheral()
        try await serverB.start(peripheral: fakeB, liveServers: registry)
        #expect(await fakeB.isAdvertising)
        await serverB.stop()
    }

    @Test func slotHeldUntilTeardownCompletes() async throws {
        let registry = LiveServerRegistry()
        let delegate = ScriptedCumulativeDelegate()
        let fakeA = FakeBluetoothPeripheral()
        let serverA = Server.wheelRevolutions(NeverYieldingWheelSequence(), setCumulativeWheelRevolutions: delegate)
            .build()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        try await serverA.start(peripheral: fakeA, liveServers: registry)
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

        let fakeB = FakeBluetoothPeripheral()
        await #expect(throws: ServerError.alreadyStarted) {
            try await serverB.start(peripheral: fakeB, liveServers: registry)
        }
        #expect(await fakeB.recordedCalls.isEmpty)
        #expect(registry.isOccupied)
        #expect(!secondStopReturned.isSet)

        await delegate.release()
        await firstStop.value
        await secondStop.value
        #expect(secondStopReturned.isSet)
        #expect(!registry.isOccupied)

        try await serverB.start(peripheral: fakeB, liveServers: registry)
        #expect(await fakeB.isAdvertising)
        await serverB.stop()
    }

    @Test func sameServerRestartReclaimsSlot() async throws {
        let registry = LiveServerRegistry()
        let fakeA = FakeBluetoothPeripheral()
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        try await serverA.start(peripheral: fakeA, liveServers: registry)
        await serverA.stop()
        try await serverA.start(peripheral: fakeA, liveServers: registry)
        #expect(registry.isOccupied)

        let fakeB = FakeBluetoothPeripheral()
        await #expect(throws: ServerError.alreadyStarted) {
            try await serverB.start(peripheral: fakeB, liveServers: registry)
        }
        #expect(await fakeB.recordedCalls.isEmpty)

        await serverA.stop()
        #expect(!registry.isOccupied)
    }

    @Test func releasingStartedServerStopsItAndFreesSlot() async throws {
        let registry = LiveServerRegistry()
        let fakeA = FakeBluetoothPeripheral()
        do {
            let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
            try await serverA.start(peripheral: fakeA, liveServers: registry)
        }
        await registry.waitUntilVacant()

        #expect(await !fakeA.isAdvertising)
        #expect(await fakeA.recordedCalls.contains(where: isRemoveService))

        let fakeB = FakeBluetoothPeripheral()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        try await serverB.start(peripheral: fakeB, liveServers: registry)
        #expect(await fakeB.isAdvertising)
        await serverB.stop()
    }

    @Test func sharedRegistryEnforcesSingleLiveServer() async throws {
        let fakeA = FakeBluetoothPeripheral()
        let fakeB = FakeBluetoothPeripheral()
        let serverA = Server.crankRevolutions(NeverYieldingCrankSequence()).build()
        let serverB = Server.crankRevolutions(NeverYieldingCrankSequence()).build()

        try await serverA.start(peripheral: fakeA, liveServers: .shared)
        await #expect(throws: ServerError.alreadyStarted) {
            try await serverB.start(peripheral: fakeB, liveServers: .shared)
        }
        #expect(await fakeB.recordedCalls.isEmpty)

        await serverA.stop()
        try await serverB.start(peripheral: fakeB, liveServers: .shared)
        #expect(await fakeB.isAdvertising)

        await serverB.stop()
        #expect(!LiveServerRegistry.shared.isOccupied)
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
