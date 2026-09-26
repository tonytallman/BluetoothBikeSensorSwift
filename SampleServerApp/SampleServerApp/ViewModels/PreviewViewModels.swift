#if DEBUG
import CSCServer
import Observation

@Observable
@MainActor
final class PreviewServerViewModel: ServerViewModel {
    typealias Simulation = PreviewSimulationViewModel

    var simulation = PreviewSimulationViewModel()
    var revolutions: RevolutionConfiguration = .wheelAndCrank
    var locationMode: LocationMode = .none
    var fixedLocation: SensorLocationKind = .rearDropout
    let catalog = SensorLocationCatalog.allKinds
    var multipleCurrentLocation: SensorLocationKind = .rearDropout
    var alert: ServerAlert?
    var controlPointLog: [ControlPointLogEntry] = []

    var configurationIssue: String?
    var expectedClientSummary = "Speed, Cadence"
    var statusTitle = "Advertising CSC service (0x1816)"
    var statusDetail: String?
    var bluetoothTitle = "Powered on · Allowed"
    var connectionStatusText = "Subscribed centrals: 0"
    var showsWheelSimulation = true
    var showsCrankSimulation = true
    var showsControlPoint = true
    var isConfigurationEditable = false
    var servedLocationTitle: String?
    var primaryActionTitle = "Stop"
    var isPrimaryActionEnabled = true

    func isSupported(_ kind: SensorLocationKind) -> Bool { true }
    func setSupported(_ kind: SensorLocationKind, _ isSupported: Bool) {}
    var supportedLocations: [SensorLocationKind] { catalog }
    func displayName(for kind: SensorLocationKind) -> String {
        SensorLocationCatalog.displayName(for: kind)
    }

    func performPrimaryAction() {}
    func sceneDidEnterBackground() {}
    func sceneDidBecomeActive() {}

    static let advertising = PreviewServerViewModel()
    static let stopped: PreviewServerViewModel = {
        let model = PreviewServerViewModel()
        model.statusTitle = "Stopped"
        model.primaryActionTitle = "Start"
        model.isConfigurationEditable = true
        model.showsControlPoint = true
        return model
    }()

    static let suspended: PreviewServerViewModel = {
        let model = PreviewServerViewModel()
        model.statusTitle = "Suspended"
        model.statusDetail =
            "Bluetooth is Powered off. The server advertises again automatically when Bluetooth comes back."
        return model
    }()
}

@Observable
@MainActor
final class PreviewSimulationViewModel: SimulationViewModel {
    var wheelMode: SimulationMode = .automatic
    var speedKilometersPerHour: Double = 25
    var wheelCircumferenceMeters: Double = 2.105
    var crankMode: SimulationMode = .automatic
    var cadenceRevolutionsPerMinute: Double = 90
    var isManualInputEnabled = true
    var wheelReadout = "42 rev"
    var crankReadout = "18 rev"
    var expectedSpeedText = "25.0 km/h"
    var expectedCadenceText = "90 rpm"

    func addWheelRevolution() {}
    func addCrankRevolution() {}
}
#endif
