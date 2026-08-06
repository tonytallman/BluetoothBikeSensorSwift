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
                connected.wheelCircumference = currentWheelCircumference
                row.applyConnected(connected)
                subscribeToStreams(for: row)
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

    func applyWheelCircumferenceMeters(_ meters: Double) {
        wheelCircumferenceMeters = max(meters, 0.1)
        let measurement = currentWheelCircumference
        for row in rows {
            row.connectedSensor?.wheelCircumference = measurement
        }
    }

    private var currentWheelCircumference: Measurement<UnitLength> {
        Measurement(value: wheelCircumferenceMeters, unit: .meters)
    }

    private func subscribeToStreams(for row: SensorRowModel) {
        guard let connected = row.connectedSensor else { return }

        var tasks: [Task<Void, Never>] = []

        if let speedStream = connected.speed {
            tasks.append(Task {
                for await speed in speedStream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        row.updateSpeedDisplay(MeasurementFormatting.speedInKilometersPerHour(speed))
                    }
                }
                await MainActor.run {
                    self.handleStreamEnded(for: row.id)
                }
            })
        } else {
            row.speedText = nil
        }

        if let cadenceStream = connected.cadence {
            tasks.append(Task {
                for await cadence in cadenceStream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        row.updateCadenceDisplay(MeasurementFormatting.cadenceInRPM(cadence))
                    }
                }
                await MainActor.run {
                    self.handleStreamEnded(for: row.id)
                }
            })
        } else {
            row.cadenceText = nil
        }

        streamTasks[row.id] = tasks
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
}
