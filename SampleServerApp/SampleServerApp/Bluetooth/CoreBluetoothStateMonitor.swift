import CoreBluetooth
import Observation

@Observable
@MainActor
final class CoreBluetoothStateMonitor: NSObject, BluetoothStateMonitor {
    private(set) var isActive = false
    private(set) var status: BluetoothStatus = .unknown
    private(set) var authorization: BluetoothAuthorization

    private var manager: CBPeripheralManager?

    override init() {
        authorization = Self.authorization(from: CBManager.authorization)
        super.init()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        manager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false],
        )
        applyState(manager?.state ?? .unknown)
    }

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        MainActor.assumeIsolated {
            applyState(state)
        }
    }

    private func applyState(_ state: CBManagerState) {
        authorization = Self.authorization(from: CBManager.authorization)
        status = Self.status(from: state)
    }

    private static func status(from state: CBManagerState) -> BluetoothStatus {
        switch state {
        case .unknown:
            .unknown
        case .resetting:
            .resetting
        case .unsupported:
            .unsupported
        case .unauthorized:
            .unauthorized
        case .poweredOff:
            .poweredOff
        case .poweredOn:
            .poweredOn
        @unknown default:
            .unknown
        }
    }

    private static func authorization(from value: CBManagerAuthorization) -> BluetoothAuthorization {
        switch value {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .allowedAlways:
            .allowed
        @unknown default:
            .notDetermined
        }
    }
}

extension CoreBluetoothStateMonitor: CBPeripheralManagerDelegate {}
