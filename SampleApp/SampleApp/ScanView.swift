import SwiftUI

struct ScanView: View {
    @State private var viewModel = ScanViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No Sensors", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text(emptyStateMessage)
                    }
                } else {
                    List(viewModel.rows) { row in
                        SensorRowView(
                            row: row,
                            onConnect: { viewModel.connect(row: row) },
                            onDisconnect: { viewModel.disconnect(row: row) },
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Sensors")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.isWheelSheetPresented = true
                    } label: {
                        Label("Wheel Size", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isScanning ? "Stop" : "Scan") {
                        viewModel.toggleScan()
                    }
                }
            }
            .sheet(isPresented: $viewModel.isWheelSheetPresented) {
                WheelCircumferenceSheet(viewModel: viewModel)
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { viewModel.isAlertPresented },
                    set: { viewModel.isAlertPresented = $0 },
                ),
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.alertMessage ?? "")
            }
        }
    }

    private var emptyStateMessage: String {
        if viewModel.isScanning {
            return "Scanning for CSC sensors nearby…"
        }
        return "Tap Scan to discover cycling speed and cadence sensors."
    }
}

#Preview {
    ScanView()
}
