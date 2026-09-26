import CSCServer
import Observation
import SwiftUI
import UIKit

@MainActor
protocol ServerViewModel: AnyObject, Observable {
    associatedtype Simulation: SimulationViewModel
    var simulation: Simulation { get }

    var revolutions: RevolutionConfiguration { get set }
    var locationMode: LocationMode { get set }
    var fixedLocation: SensorLocationKind { get set }
    var catalog: [SensorLocationKind] { get }
    func isSupported(_ kind: SensorLocationKind) -> Bool
    func setSupported(_ kind: SensorLocationKind, _ isSupported: Bool)
    var supportedLocations: [SensorLocationKind] { get }
    var multipleCurrentLocation: SensorLocationKind { get set }
    func displayName(for kind: SensorLocationKind) -> String
    var isConfigurationEditable: Bool { get }
    var configurationIssue: String? { get }
    var expectedClientSummary: String { get }

    var statusTitle: String { get }
    var statusDetail: String? { get }
    var bluetoothTitle: String { get }
    var connectionStatusText: String { get }
    var showsWheelSimulation: Bool { get }
    var showsCrankSimulation: Bool { get }
    var showsControlPoint: Bool { get }
    var servedLocationTitle: String? { get }
    var controlPointLog: [ControlPointLogEntry] { get }

    var primaryActionTitle: String { get }
    var isPrimaryActionEnabled: Bool { get }
    func performPrimaryAction()
    var alert: ServerAlert? { get set }

    func sceneDidEnterBackground()
    func sceneDidBecomeActive()
}

struct ServerView<ViewModel: ServerViewModel>: View {
    @Bindable var viewModel: ViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Status", value: viewModel.statusTitle)
                    if let detail = viewModel.statusDetail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Bluetooth", value: viewModel.bluetoothTitle)
                    Text(viewModel.connectionStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(viewModel.primaryActionTitle) {
                        viewModel.performPrimaryAction()
                    }
                    .disabled(!viewModel.isPrimaryActionEnabled)
                }

                ConfigurationSection(viewModel: viewModel)

                if viewModel.showsWheelSimulation {
                    WheelSimulationSection(viewModel: viewModel.simulation)
                }

                if viewModel.showsCrankSimulation {
                    CrankSimulationSection(viewModel: viewModel.simulation)
                }

                if viewModel.showsControlPoint {
                    Section("Control point") {
                        if let served = viewModel.servedLocationTitle {
                            Text(served)
                        }
                        if viewModel.controlPointLog.isEmpty {
                            Text("No control-point activity yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.controlPointLog) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.text)
                                    Text(entry.date.formatted(date: .omitted, time: .standard))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text(
                        "If Bluetooth recovery fails silently after a power cycle, the UI may still show Advertising while the server is suspended.",
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("CSC Server")
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                viewModel.sceneDidEnterBackground()
            case .active:
                viewModel.sceneDidBecomeActive()
            default:
                break
            }
        }
        .alert(
            "Couldn't start server",
            isPresented: Binding(
                get: { viewModel.alert != nil },
                set: { if !$0 { viewModel.alert = nil } },
            ),
            presenting: viewModel.alert,
        ) { alert in
            if alert.offersSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            Button("OK", role: .cancel) {
                viewModel.alert = nil
            }
        } message: { alert in
            Text(alert.message)
        }
    }
}

#if DEBUG
#Preview {
    ServerView(viewModel: PreviewServerViewModel.advertising)
}
#endif
