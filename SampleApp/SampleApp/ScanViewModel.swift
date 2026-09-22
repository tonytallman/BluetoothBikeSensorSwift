import BluetoothBikeSensorSwift
import Foundation

@MainActor
@Observable
final class ScanViewModel {
    private let scanner = Scanner()
    private var scanTask: Task<Void, Never>?
    private var streamTasks: [UUID: [Task<Void, Never>]] = [:]

    var rows: [SensorRowModel] = []
    var isScanning = false
    var wheelCircumferenceMeters = 2.105
    var isWheelSheetPresented = false
    var alertMessage: String?

    var isAlertPresented: Bool {
        get { alertMessage != nil }
        set { if !newValue { alertMessage = nil } }
    }

    func toggleScan() {
        if isScanning {
            stopScanning()
        } else {
            startScanning()
        }
    }

    func startScanning() {
        guard scanTask == nil else { return }

        isScanning = true
        scanTask = Task {
            let stream = scanner.scan()
            for await sensor in stream {
                guard !Task.isCancelled else { break }
                addDiscoveredSensor(sensor)
            }
            await finishScanning()
        }
    }

    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func finishScanning() async {
        scanTask = nil
        isScanning = false
    }

    private func addDiscoveredSensor(_ sensor: DiscoveredSensor) {
        guard !rows.contains(where: { $0.id == sensor.id }) else { return }
        rows.append(SensorRowModel(discoveredSensor: sensor))
    }

    func connect(row: SensorRowModel) {
        guard row.phase == .discovered else { return }

        row.beginConnecting()

        Task {
            do {
                let connected = try await row.discoveredSensor.connect()
                applyWheelCircumference(to: connected)
                row.applyConnected(connected)
                await subscribeToStreams(for: row)
            } catch let error as ConnectError {
                row.phase = .discovered
                alertMessage = Self.message(for: error)
            } catch {
                row.phase = .discovered
                alertMessage = error.localizedDescription
            }
        }
    }

    func disconnect(row: SensorRowModel) {
        guard let connected = row.connectedSensor else { return }

        cancelStreamTasks(for: row.id)

        Task {
            do {
                let rediscovered = try await connected.disconnect()
                row.applyRediscovered(rediscovered)
            } catch let error as DisconnectError {
                alertMessage = Self.message(for: error)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func updateLocation(row: SensorRowModel) {
        guard let connected = row.connectedSensor,
              case let .multiple(locations) = connected.location,
              let selected = row.selectedLocation
        else {
            return
        }

        Task {
            do {
                try await locations.update(selected)
                row.syncMultipleLocationCurrent(locations.current)
            } catch let error as ControlPointError {
                alertMessage = Self.message(for: error)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func applyWheelCircumferenceMeters(_ meters: Double) {
        wheelCircumferenceMeters = max(meters, 0.1)
        let measurement = currentWheelCircumference
        for row in rows {
            guard let connected = row.connectedSensor else { continue }
            applyWheelCircumference(measurement, to: connected)
        }
    }

    private var currentWheelCircumference: Measurement<UnitLength> {
        Measurement(value: wheelCircumferenceMeters, unit: .meters)
    }

    private func applyWheelCircumference(to connected: ConnectedSensor) {
        applyWheelCircumference(currentWheelCircumference, to: connected)
    }

    private func applyWheelCircumference(
        _ measurement: Measurement<UnitLength>,
        to connected: ConnectedSensor,
    ) {
        switch connected.revolutions {
        case let .wheel(wheel):
            wheel.wheelCircumference = measurement
        case let .wheelAndCrank(wheel, _):
            wheel.wheelCircumference = measurement
        case .crank:
            break
        }
    }

    private func subscribeToStreams(for row: SensorRowModel) async {
        guard let connected = row.connectedSensor else { return }

        var tasks: [Task<Void, Never>] = []

        switch connected.revolutions {
        case let .wheel(wheel):
            tasks.append(contentsOf: await streamTasks(for: row, wheel: wheel))
        case let .crank(crank):
            tasks.append(contentsOf: await streamTasks(for: row, crank: crank))
        case let .wheelAndCrank(wheel, crank):
            tasks.append(contentsOf: await streamTasks(for: row, wheel: wheel))
            tasks.append(contentsOf: await streamTasks(for: row, crank: crank))
        }

        streamTasks[row.id] = tasks
    }

    private func streamTasks(for row: SensorRowModel, wheel: WheelRevolutions) async -> [Task<Void, Never>] {
        let speedStream = await wheel.speed
        return [
            Task {
                for await speed in speedStream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        row.updateSpeedDisplay(MeasurementFormatting.speedInKilometersPerHour(speed))
                    }
                }
                await MainActor.run {
                    self.handleStreamEnded(for: row.id)
                }
            },
        ]
    }

    private func streamTasks(for row: SensorRowModel, crank: CrankRevolutions) async -> [Task<Void, Never>] {
        let cadenceStream = await crank.cadence
        return [
            Task {
                for await cadence in cadenceStream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        row.updateCadenceDisplay(MeasurementFormatting.cadenceInRPM(cadence))
                    }
                }
                await MainActor.run {
                    self.handleStreamEnded(for: row.id)
                }
            },
        ]
    }

    private func handleStreamEnded(for sensorID: UUID) {
        guard let row = rows.first(where: { $0.id == sensorID }),
              row.phase == .connected,
              let connected = row.connectedSensor
        else {
            return
        }

        cancelStreamTasks(for: sensorID)

        Task {
            if let rediscovered = try? await connected.disconnect() {
                row.applyRediscovered(rediscovered)
            } else {
                row.applyRediscovered(row.discoveredSensor)
            }
        }
    }

    private func cancelStreamTasks(for sensorID: UUID) {
        streamTasks[sensorID]?.forEach { $0.cancel() }
        streamTasks.removeValue(forKey: sensorID)
    }

    private static func message(for error: ConnectError) -> String {
        switch error {
        case .notPoweredOn:
            return "Bluetooth is not powered on."
        case .timeout:
            return "Connection timed out."
        case let .failed(reason):
            return "Connection failed: \(reason)"
        case .peripheralNotFound:
            return "Sensor not found."
        case let .serviceDiscoveryFailed(reason):
            return "Service discovery failed: \(reason)"
        }
    }

    private static func message(for error: DisconnectError) -> String {
        switch error {
        case let .failed(reason):
            return "Disconnect failed: \(reason)"
        case .alreadyDisconnected:
            return "Sensor is already disconnected."
        }
    }

    private static func message(for error: ControlPointError) -> String {
        switch error {
        case .unsupportedLocation:
            return "That sensor location is not supported."
        case .controlPointUnavailable:
            return "This sensor does not expose a control point."
        case .procedureInProgress:
            return "Another control-point procedure is already in progress."
        case .opCodeNotSupported:
            return "The sensor does not support that control-point operation."
        case .invalidParameter:
            return "The sensor rejected the control-point parameter."
        case .operationFailed:
            return "The sensor reported that the control-point operation failed."
        case .cccdImproperlyConfigured:
            return "Control-point indications are not enabled."
        case .timedOut:
            return "The control-point procedure timed out."
        case let .failed(reason):
            return "Control-point procedure failed: \(reason)"
        }
    }
}
