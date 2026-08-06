import BluetoothBikeSensorSwift
import Foundation
import Testing

@Suite struct FakeBluetoothCentralTests {
    @Test func currentStateReflectsInitialAndUpdatedValues() async {
        let fake = FakeBluetoothCentral(initialState: .poweredOff)
        #expect(await fake.currentState == .poweredOff)

        await fake.setState(.poweredOn)
        #expect(await fake.currentState == .poweredOn)

        await fake.setState(.unauthorized)
        #expect(await fake.currentState == .unauthorized)
    }

    @Test func stateUpdatesStreamReceivesStateChanges() async {
        let fake = FakeBluetoothCentral(initialState: .poweredOff)
        let stream = await fake.stateUpdates
        let collector = Task { await AsyncTestHelpers.collect(from: stream, maxCount: 2) }

        await fake.setState(.poweredOn)
        await fake.setState(.unauthorized)

        let values = await collector.value
        #expect(values.contains(.poweredOn))
        #expect(values.contains(.unauthorized))
    }

    @Test func scanLifecycleIsRecorded() async {
        let fake = FakeBluetoothCentral()
        let serviceUUID = UUID()

        await fake.startScanning(serviceUUIDs: [serviceUUID])
        await fake.stopScanning()

        let calls = await fake.recordedCalls
        #expect(calls == [
            .startScanning(serviceUUIDs: [serviceUUID]),
            .stopScanning,
        ])
    }

    @Test func discoveriesStreamReceivesEmittedEvents() async {
        let fake = FakeBluetoothCentral()
        let stream = await fake.discoveries
        let collector = Task { await AsyncTestHelpers.collect(from: stream, maxCount: 1) }

        let peripheralID = UUID()
        await fake.emitDiscovery(
            DiscoveredPeripheralEvent(
                id: peripheralID,
                name: "Cadence Sensor",
                manufacturerData: Data([0x01, 0x02]),
                serviceUUIDs: [UUID()],
                rssi: -55,
            ),
        )

        let values = await collector.value
        #expect(values.count == 1)
        #expect(values[0].id == peripheralID)
        #expect(values[0].name == "Cadence Sensor")
    }

    @Test func connectAndDisconnectAreRecorded() async throws {
        let fake = FakeBluetoothCentral()
        let peripheralID = UUID()

        try await fake.connect(id: peripheralID)
        try await fake.disconnect(id: peripheralID)

        let calls = await fake.recordedCalls
        #expect(calls == [
            .connect(id: peripheralID),
            .disconnect(id: peripheralID),
        ])
    }

    @Test func connectFailureCanBeConfigured() async {
        let fake = FakeBluetoothCentral()
        let peripheralID = UUID()
        let expectedError = BluetoothCentralError.connectionFailed(peripheralID, reason: "Test failure")

        await fake.failNextConnect(with: expectedError)

        do {
            try await fake.connect(id: peripheralID)
            Issue.record("Expected connect to throw")
        } catch let error as BluetoothCentralError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

@Suite struct ScannerDependencyTests {
    @Test func scannerAcceptsInjectedFakeCentral() {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        _ = scanner.scan()
    }

    @Test func scannerDefaultInitializerConstructs() {
        let scanner = Scanner()
        _ = scanner.scan()
    }
}

enum AsyncTestHelpers {
    private actor Collector<T: Sendable> {
        private var values: [T] = []

        func append(_ value: T) {
            values.append(value)
        }

        func snapshot() -> [T] {
            values
        }

        func count() -> Int {
            values.count
        }
    }

    static func collect<T: Sendable>(
        from stream: AsyncStream<T>,
        maxCount: Int = 10,
        timeoutNanoseconds: UInt64 = 500_000_000,
    ) async -> [T] {
        let collector = Collector<T>()
        let task = Task {
            for await value in stream {
                await collector.append(value)
                if await collector.count() >= maxCount {
                    break
                }
            }
        }
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        task.cancel()
        return await collector.snapshot()
    }
}
