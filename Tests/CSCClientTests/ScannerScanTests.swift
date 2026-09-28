import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct ScannerScanTests {
    private static func waitForScanStart(_ fake: FakeBluetoothCentral) async {
        await fake.waitForRecordedCall { call in
            if case .startScanning = call { return true }
            return false
        }
    }

    @Test func yieldsCSCSensor() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()
        let collector = Task { await AsyncTestHelpers.collect(from: stream, maxCount: 1) }

        await Self.waitForScanStart(fake)

        let peripheralID = UUID()
        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: peripheralID,
                name: "Speed Sensor",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 1)
        #expect(sensors[0].id == peripheralID)
        #expect(sensors[0].name == "Speed Sensor")
    }

    @Test func filtersNonCSCPeripheral() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()
        let collector = Task { await AsyncTestHelpers.collect(from: stream, maxCount: 1) }

        await Self.waitForScanStart(fake)

        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: UUID(),
                name: "Heart Rate",
                manufacturerData: nil,
                serviceUUIDs: [UUID()],
            ),
        )

        let sensors = await collector.value
        #expect(sensors.isEmpty)
    }

    @Test func deduplicatesByPeripheralID() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()
        let collector = Task { await AsyncTestHelpers.collect(from: stream, maxCount: 2) }

        await Self.waitForScanStart(fake)

        let peripheralID = UUID()
        let event = DiscoveredPeripheral(
            id: peripheralID,
            name: "Cadence",
            manufacturerData: nil,
            serviceUUIDs: [CSCS.serviceUUID],
        )

        await fake.emitDiscovery(event)
        await fake.emitDiscovery(event)

        let sensors = await collector.value
        #expect(sensors.count == 1)
        #expect(sensors[0].id == peripheralID)
    }

    @Test func stopScanningWhenStreamCancelled() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()

        let collector = Task {
            for await _ in stream {}
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        collector.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let calls = await fake.recordedCalls
        #expect(calls.contains(.stopScanning))
    }

    @Test func finishesEmptyWhenPoweredOff() async {
        let fake = FakeBluetoothCentral(initialState: .poweredOff)
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()

        let sensors = await AsyncTestHelpers.collect(from: stream, maxCount: 1, timeoutNanoseconds: 200_000_000)
        let calls = await fake.recordedCalls

        #expect(sensors.isEmpty)
        #expect(!calls.contains(.startScanning(serviceUUIDs: [CSCS.serviceUUID])))
    }

    @Test func resolvesManufacturerFromCompanyID() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()
        let collector = Task { await AsyncTestHelpers.collect(from: stream, maxCount: 1) }

        await Self.waitForScanStart(fake)

        var manufacturerData = Data()
        manufacturerData.append(contentsOf: [0x6D, 0x00]) // Garmin company ID, little-endian

        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: UUID(),
                name: "Garmin Sensor",
                manufacturerData: manufacturerData,
                serviceUUIDs: [CSCS.serviceUUID],
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 1)
        #expect(sensors[0].manufacturer == "Garmin")
    }

    @Test func scanStartsAfterUnknownTransitionsToPoweredOn() async {
        let fake = FakeBluetoothCentral(initialState: .unknown)
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()
        let collector = Task {
            await AsyncTestHelpers.collect(from: stream, maxCount: 1, timeoutNanoseconds: 3_000_000_000)
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await fake.setState(.poweredOn)
        await Self.waitForScanStart(fake)

        let peripheralID = UUID()
        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: peripheralID,
                name: "Delayed Sensor",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 1)
        #expect(sensors[0].id == peripheralID)
    }

    @Test func scanContinuesWhenBluetoothPoweredOffMidScan() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()
        let collector = Task {
            await AsyncTestHelpers.collect(from: stream, maxCount: 2, timeoutNanoseconds: 500_000_000)
        }

        await Self.waitForScanStart(fake)

        let firstID = UUID()
        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: firstID,
                name: "First",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
            ),
        )

        await fake.setState(.poweredOff)

        let secondID = UUID()
        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: secondID,
                name: "Second",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 2)
        #expect(sensors.map(\.id) == [firstID, secondID])

        let calls = await fake.recordedCalls
        #expect(!calls.contains(.stopScanning))
    }
}
