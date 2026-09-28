import CSCClient
import CSCWire
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct ScannerTests {
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

        let collector = Task {
            var sensors: [DiscoveredSensor] = []
            for await sensor in stream {
                sensors.append(sensor)
                if sensors.count >= 1 {
                    break
                }
            }
            return sensors
        }

        await Self.waitForScanStart(fake)

        let peripheralID = UUID()
        var manufacturerData = Data()
        manufacturerData.append(contentsOf: [0x6D, 0x00])

        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: peripheralID,
                name: "Speed Sensor",
                manufacturerData: manufacturerData,
                serviceUUIDs: [CSCS.serviceUUID],
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 1)
        #expect(sensors[0].id == peripheralID)
        #expect(sensors[0].name == "Speed Sensor")
        #expect(sensors[0].manufacturer == "Garmin")
    }

    @Test func filtersNonCSCPeripheral() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()

        let collector = Task {
            var sensors: [DiscoveredSensor] = []
            for await sensor in stream {
                sensors.append(sensor)
                if sensors.count >= 1 {
                    break
                }
            }
            return sensors
        }

        await Self.waitForScanStart(fake)

        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: UUID(),
                name: "Heart Rate",
                manufacturerData: nil,
                serviceUUIDs: [UUID()],
            ),
        )

        let cscID = UUID()
        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: cscID,
                name: "Cadence",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 1)
        #expect(sensors[0].id == cscID)
    }

    @Test func deduplicatesByPeripheralID() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()

        let collector = Task {
            var sensors: [DiscoveredSensor] = []
            for await sensor in stream {
                sensors.append(sensor)
                if sensors.count >= 2 {
                    break
                }
            }
            return sensors
        }

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
        await fake.emitDiscovery(
            DiscoveredPeripheral(
                id: UUID(),
                name: "Other",
                manufacturerData: nil,
                serviceUUIDs: [CSCS.serviceUUID],
            ),
        )

        let sensors = await collector.value
        #expect(sensors.count == 2)
        #expect(sensors.filter { $0.id == peripheralID }.count == 1)
    }

    @Test func stopScanningWhenStreamCancelled() async {
        let fake = FakeBluetoothCentral()
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()

        let collector = Task {
            for await _ in stream {}
        }

        await fake.waitForRecordedCall { call in
            if case .startScanning = call { return true }
            return false
        }
        collector.cancel()
        await fake.waitForRecordedCall { call in
            if case .stopScanning = call { return true }
            return false
        }

        let calls = await fake.recordedCalls
        #expect(calls.contains(.stopScanning))
    }

    @Test func finishesEmptyWhenPoweredOff() async {
        let fake = FakeBluetoothCentral(initialState: .poweredOff)
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()

        var sensors: [DiscoveredSensor] = []
        for await sensor in stream {
            sensors.append(sensor)
        }
        let calls = await fake.recordedCalls

        #expect(sensors.isEmpty)
        #expect(!calls.contains(.startScanning(serviceUUIDs: [CSCS.serviceUUID])))
    }

    @Test func scanStartsPromptlyWhenAlreadyPoweredOn() async {
        let fake = FakeBluetoothCentral(initialState: .poweredOn)
        let scanner = Scanner(central: fake)
        let start = ContinuousClock.now
        let stream = scanner.scan()
        _ = stream

        await Self.waitForScanStart(fake)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func scanStartsAfterUnknownTransitionsToPoweredOn() async {
        let fake = FakeBluetoothCentral(initialState: .unknown)
        let scanner = Scanner(central: fake)
        let stream = scanner.scan()

        await fake.waitForStateUpdatesSubscriber()
        await fake.setState(.poweredOn)

        let collector = Task {
            var sensors: [DiscoveredSensor] = []
            for await sensor in stream {
                sensors.append(sensor)
                if sensors.count >= 1 {
                    break
                }
            }
            return sensors
        }

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
            var sensors: [DiscoveredSensor] = []
            for await sensor in stream {
                sensors.append(sensor)
                if sensors.count >= 2 {
                    break
                }
            }
            return sensors
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
