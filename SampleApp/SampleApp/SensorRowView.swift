import BluetoothBikeSensorSwift
import SwiftUI

struct SensorRowView: View {
    let row: SensorRowModel
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onUpdateLocation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SensorInfoView(metadata: row.metadata)

            switch row.phase {
            case .discovered:
                DiscoveredSensorRowState(onConnect: onConnect).content
            case .connecting:
                ConnectingSensorRowState().content
            case .connected:
                ConnectedSensorRowState(
                    supportsSpeed: row.supportsSpeed,
                    supportsCadence: row.supportsCadence,
                    speedText: row.speedText,
                    cadenceText: row.cadenceText,
                    locationPresentation: row.locationPresentation,
                    selectedLocation: Binding(
                        get: { row.selectedLocation },
                        set: { row.selectedLocation = $0 },
                    ),
                    onUpdateLocation: onUpdateLocation,
                    onDisconnect: onDisconnect,
                ).content
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SensorInfoView: View {
    let metadata: SensorMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metadata.name ?? "Unknown sensor")
                .font(.headline)

            if let manufacturer = metadata.manufacturer {
                Text(manufacturer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(metadata.id.uuidString.prefix(8) + "…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct DiscoveredSensorRowState: SensorRowState {
    let onConnect: () -> Void

    var content: some View {
        Button("Connect", action: onConnect)
            .buttonStyle(.borderedProminent)
    }
}

private struct ConnectingSensorRowState: SensorRowState {
    var content: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Connecting…")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConnectedSensorRowState: SensorRowState {
    let supportsSpeed: Bool
    let supportsCadence: Bool
    let speedText: String?
    let cadenceText: String?
    let locationPresentation: ConnectedLocationPresentation
    @Binding var selectedLocation: SensorLocation?
    let onUpdateLocation: () -> Void
    let onDisconnect: () -> Void

    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if supportsSpeed {
                MeasurementLine(label: "Speed", value: speedText)
            }
            if supportsCadence {
                MeasurementLine(label: "Cadence", value: cadenceText)
            }

            locationSection

            Button("Disconnect", role: .destructive, action: onDisconnect)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        switch locationPresentation {
        case .unavailable:
            EmptyView()
        case let .fixed(displayName):
            MeasurementLine(label: "Location", value: displayName)
        case let .multiple(supported, current):
            VStack(alignment: .leading, spacing: 8) {
                MeasurementLine(label: "Location", value: current.displayName)

                Picker("Sensor location", selection: $selectedLocation) {
                    ForEach(supported, id: \.self) { location in
                        Text(location.displayName).tag(Optional(location))
                    }
                }
                .pickerStyle(.menu)

                Button("Update Location", action: onUpdateLocation)
                    .buttonStyle(.bordered)
                    .disabled(selectedLocation == current)
            }
        }
    }
}

private struct MeasurementLine: View {
    let label: String
    let value: String?

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .font(.body.monospacedDigit())
        }
    }
}

protocol SensorRowState {
    associatedtype Content: View
    @ViewBuilder var content: Content { get }
}
