import CSCServer
import SwiftUI

struct ConfigurationSection<ViewModel: ServerViewModel>: View {
    @Bindable var viewModel: ViewModel

    var body: some View {
        Section("Configuration") {
            Picker("Measurements", selection: $viewModel.revolutions) {
                Text("Wheel").tag(RevolutionConfiguration.wheel)
                Text("Crank").tag(RevolutionConfiguration.crank)
                Text("Wheel + Crank").tag(RevolutionConfiguration.wheelAndCrank)
            }
            .disabled(!viewModel.isConfigurationEditable)

            Picker("Location", selection: $viewModel.locationMode) {
                Text("None").tag(LocationMode.none)
                Text("Fixed").tag(LocationMode.fixed)
                Text("Multiple").tag(LocationMode.multiple)
            }
            .disabled(!viewModel.isConfigurationEditable)

            if viewModel.locationMode == .fixed {
                Picker("Fixed location", selection: $viewModel.fixedLocation) {
                    ForEach(viewModel.catalog, id: \.self) { kind in
                        Text(viewModel.displayName(for: kind)).tag(kind)
                    }
                }
                .disabled(!viewModel.isConfigurationEditable)
            }

            if viewModel.locationMode == .multiple {
                DisclosureGroup("Supported locations") {
                    ForEach(viewModel.catalog, id: \.self) { kind in
                        Toggle(
                            viewModel.displayName(for: kind),
                            isOn: Binding(
                                get: { viewModel.isSupported(kind) },
                                set: { viewModel.setSupported(kind, $0) },
                            ),
                        )
                        .disabled(!viewModel.isConfigurationEditable)
                    }
                }

                Picker("Current location", selection: $viewModel.multipleCurrentLocation) {
                    ForEach(viewModel.supportedLocations, id: \.self) { kind in
                        Text(viewModel.displayName(for: kind)).tag(kind)
                    }
                }
                .disabled(!viewModel.isConfigurationEditable)
            }

            if let issue = viewModel.configurationIssue {
                Text(issue)
                    .foregroundStyle(.red)
            }

            Text("Client sample shows: \(viewModel.expectedClientSummary)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
