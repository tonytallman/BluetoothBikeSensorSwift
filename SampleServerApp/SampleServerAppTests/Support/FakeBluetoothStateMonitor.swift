import Observation

@testable import SampleServerApp

@Observable
@MainActor
final class FakeBluetoothStateMonitor: BluetoothStateMonitor {
    var isActive = false
    var status: BluetoothStatus = .unknown
    var authorization: BluetoothAuthorization = .notDetermined
    private(set) var activateCount = 0

    func activate() {
        activateCount += 1
        isActive = true
    }
}
