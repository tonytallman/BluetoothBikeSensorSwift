import BluetoothBikeSensorSwift
import Foundation
import Testing

@Suite struct ScannerScanTests {
    private static func waitForScanStart(_ fake: FakeBluetoothCentral) async {
        for _ in 0..<50 {
            let calls = await fake.recordedCalls
            if calls.contains(where: {
                if case .startScanning = $0 { return true }
                return false
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
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
            DiscoveredPeripheralEvent(
                id: peripheralID,
                name: "Speed Sensor",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
                rssi: -60,
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 1)
        #expect(sensors[0].id == peripheralID)
        #expect(sensors[0].name == "Speed Sensor")
        #expect(sensors[0].hasSpeed)
        #expect(sensors[0].hasCadence)
    }

    @Test func filtersNonCSCPeripheral() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()
        let collector = Task { await AsyncTestHelpers.collect(from: stream, maxCount: 1) }

        await Self.waitForScanStart(fake)

        await fake.emitDiscovery(
            DiscoveredPeripheralEvent(
                id: UUID(),
                name: "Heart Rate",
                manufacturerData: nil,
                serviceUUIDs: [UUID()],
                rssi: -50,
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
        let event = DiscoveredPeripheralEvent(
            id: peripheralID,
            name: "Cadence",
            manufacturerData: nil,
            serviceUUIDs: [CSCS.serviceUUID],
            rssi: -55,
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
            DiscoveredPeripheralEvent(
                id: UUID(),
                name: "Garmin Sensor",
                manufacturerData: manufacturerData,
                serviceUUIDs: [CSCS.serviceUUID],
                rssi: -48,
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
            DiscoveredPeripheralEvent(
                id: peripheralID,
                name: "Delayed Sensor",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
                rssi: -50,
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
            DiscoveredPeripheralEvent(
                id: firstID,
                name: "First",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
                rssi: -55,
            ),
        )

        await fake.setState(.poweredOff)

        let secondID = UUID()
        await fake.emitDiscovery(
            DiscoveredPeripheralEvent(
                id: secondID,
                name: "Second",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
                rssi: -60,
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 2)
        #expect(sensors.map(\.id) == [firstID, secondID])

        let calls = await fake.recordedCalls
        #expect(!calls.contains(.stopScanning))
    }
}
