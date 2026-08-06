import BluetoothBikeSensorSwift
import SwiftUI

struct ContentView: View {
    private let scanner = Scanner()

    var body: some View {
        VStack(spacing: 16) {
            Text("Bluetooth Bike Sensor")
                .font(.title)
                .fontWeight(.semibold)

            Text("Implementation in progress")
                .foregroundStyle(.secondary)

            Text("Library linked")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .onAppear { _ = scanner }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
