import CSCServer
import Observation
import SwiftUI

@MainActor
protocol SimulationViewModel: AnyObject, Observable {
    var wheelMode: SimulationMode { get set }
    var speedKilometersPerHour: Double { get set }
    var wheelCircumferenceMeters: Double { get set }
    var crankMode: SimulationMode { get set }
    var cadenceRevolutionsPerMinute: Double { get set }
    var isManualInputEnabled: Bool { get }
    var wheelReadout: String { get }
    var crankReadout: String { get }
    var expectedSpeedText: String { get }
    var expectedCadenceText: String { get }
    func addWheelRevolution()
    func addCrankRevolution()
}

struct WheelSimulationSection<ViewModel: SimulationViewModel>: View {
    @Bindable var viewModel: ViewModel

    var body: some View {
        Section("Wheel") {
            Picker("Mode", selection: $viewModel.wheelMode) {
                Text("Automatic").tag(SimulationMode.automatic)
                Text("Manual").tag(SimulationMode.manual)
            }
            .pickerStyle(.segmented)

            LabeledContent("Speed") {
                Slider(value: $viewModel.speedKilometersPerHour, in: 5 ... 60, step: 0.5)
            }
            Text("Target: \(viewModel.expectedSpeedText)")

            LabeledContent("Circumference") {
                Slider(value: $viewModel.wheelCircumferenceMeters, in: 1.0 ... 3.0, step: 0.001)
            }
            Text(String(format: "%.3f m", viewModel.wheelCircumferenceMeters))

            Button("+1 wheel revolution") {
                viewModel.addWheelRevolution()
            }
            .disabled(!viewModel.isManualInputEnabled || viewModel.wheelMode != .manual)

            LabeledContent("Readout", value: viewModel.wheelReadout)
        }
    }
}

struct CrankSimulationSection<ViewModel: SimulationViewModel>: View {
    @Bindable var viewModel: ViewModel

    var body: some View {
        Section("Crank") {
            Picker("Mode", selection: $viewModel.crankMode) {
                Text("Automatic").tag(SimulationMode.automatic)
                Text("Manual").tag(SimulationMode.manual)
            }
            .pickerStyle(.segmented)

            LabeledContent("Cadence") {
                Slider(value: $viewModel.cadenceRevolutionsPerMinute, in: 30 ... 150, step: 1)
            }
            Text("Target: \(viewModel.expectedCadenceText)")

            Button("+1 crank revolution") {
                viewModel.addCrankRevolution()
            }
            .disabled(!viewModel.isManualInputEnabled || viewModel.crankMode != .manual)

            LabeledContent("Readout", value: viewModel.crankReadout)
        }
    }
}
