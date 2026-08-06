import SwiftUI

struct WheelCircumferenceSheet: View {
    @Bindable var viewModel: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var metersText: String

    init(viewModel: ScanViewModel) {
        self.viewModel = viewModel
        _metersText = State(
            initialValue: String(format: "%.3f", viewModel.wheelCircumferenceMeters),
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Meters", text: $metersText)
                        .keyboardType(.decimalPad)
                } footer: {
                    Text("Used to calculate speed from wheel revolutions. Default is 2.105 m (700×25C).")
                }
            }
            .navigationTitle("Wheel Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
        let normalized = metersText.replacingOccurrences(of: ",", with: ".")
        guard let meters = Double(normalized) else { return }
        viewModel.applyWheelCircumferenceMeters(meters)
    }
}
