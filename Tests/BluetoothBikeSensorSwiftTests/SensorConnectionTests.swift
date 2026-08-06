import BluetoothBikeSensorSwift
import Foundation
import Testing

@Suite struct SensorConnectionTests {
    private func makeSensor(
        fake: FakeBluetoothCentral,
        id: UUID = UUID(),
        name: String = "Test Sensor"
    ) -> DiscoveredSensor {
        DiscoveredSensor(
            id: id,
            name: name,
            manufacturer: nil,
            hasSpeed: true,
            hasCadence: true,
            central: fake
        )
    }

    @Test func connectSuccessDiscoversCSCService() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        _ = try await sensor.connect()

        let calls = await fake.recordedCalls
        #expect(calls.contains(.connect(id: sensorID)))
        #expect(calls.contains(.discoverServices(id: sensorID, serviceUUIDs: [CSCS.serviceUUID])))
    }

    @Test func disconnectReturnsRediscoverableSensor() async throws {
        let fake = FakeBluetoothCentral()
        let sensor = makeSensor(fake: fake)

        let connected = try await sensor.connect()
        let rediscovered = try await connected.disconnect()
        let reconnected = try await rediscovered.connect()

        _ = reconnected
        let calls = await fake.recordedCalls
        #expect(calls.filter {
            if case .connect = $0 { return true }
            return false
        }.count == 2)
    }

    @Test func connectFailureMapsToConnectError() async {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        await fake.failNextConnect(with: .connectionFailed(sensorID, reason: "Refused"))

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .failed(reason: "Refused"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func connectTimeout() async {
        let fake = FakeBluetoothCentral()
        let sensor = makeSensor(fake: fake)
        let originalTimeout = DiscoveredSensor.connectTimeoutNanoseconds
        DiscoveredSensor.connectTimeoutNanoseconds = 100_000_000
        defer { DiscoveredSensor.connectTimeoutNanoseconds = originalTimeout }

        await fake.hangNextConnect()

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .timeout)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func serviceDiscoveryFailure() async {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)

        await fake.failNextDiscoverServices(
            with: .serviceNotFound(sensorID, serviceUUID: CSCS.serviceUUID)
        )

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .serviceDiscoveryFailed(reason: "Service not found: \(CSCS.serviceUUID)"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let calls = await fake.recordedCalls
        #expect(calls.contains(.disconnect(id: sensorID)))
    }

    @Test func connectFailsWhenNotPoweredOn() async {
        let fake = FakeBluetoothCentral(initialState: .poweredOff)
        let sensor = makeSensor(fake: fake)

        do {
            _ = try await sensor.connect()
            Issue.record("Expected connect to throw")
        } catch let error as ConnectError {
            #expect(error == .notPoweredOn)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func multiConnectionAllowed() async throws {
        let fake = FakeBluetoothCentral()
        let first = makeSensor(fake: fake, id: UUID(), name: "First")
        let second = makeSensor(fake: fake, id: UUID(), name: "Second")

        _ = try await first.connect()
        _ = try await second.connect()

        let calls = await fake.recordedCalls
        #expect(calls.filter {
            if case .connect = $0 { return true }
            return false
        }.count == 2)
    }

    @Test func disconnectAlreadyDisconnected() async throws {
        let fake = FakeBluetoothCentral()
        let sensorID = UUID()
        let sensor = makeSensor(fake: fake, id: sensorID)
        let connected = try await sensor.connect()

        await fake.failNextDisconnect(with: .peripheralNotFound(sensorID))

        do {
            _ = try await connected.disconnect()
            Issue.record("Expected disconnect to throw")
        } catch let error as DisconnectError {
            #expect(error == .alreadyDisconnected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
