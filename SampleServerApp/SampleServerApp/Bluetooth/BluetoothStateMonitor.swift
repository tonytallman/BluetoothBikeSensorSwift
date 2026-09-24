import Observation

@MainActor
protocol BluetoothStateMonitor: AnyObject, Observable {
    var isActive: Bool { get }
    var status: BluetoothStatus { get }
    var authorization: BluetoothAuthorization { get }
    func activate()
}
