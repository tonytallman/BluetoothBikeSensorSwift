import CSCServer
import Foundation

enum RevolutionConfiguration: Equatable {
    case wheel
    case crank
    case wheelAndCrank
}

enum LocationMode: Equatable {
    case none
    case fixed
    case multiple
}

enum LocationConfiguration: Equatable {
    case none
    case fixed(SensorLocationKind)
    case multiple(supported: [SensorLocationKind], current: SensorLocationKind)
}

struct ServerConfiguration: Equatable {
    var revolutions: RevolutionConfiguration
    var location: LocationConfiguration

    var validationIssue: String? {
        switch location {
        case .none, .fixed:
            nil
        case let .multiple(supported, current):
            if supported.isEmpty {
                "Select at least one supported location."
            } else if !supported.contains(current) {
                "Current location must be one of the supported locations."
            } else {
                nil
            }
        }
    }

    var expectedFeatureBits: UInt16 {
        switch (revolutions, locationKind) {
        case (.wheel, .none): 0x0001
        case (.wheel, .fixed): 0x0001
        case (.wheel, .multiple): 0x0005
        case (.crank, .none): 0x0002
        case (.crank, .fixed): 0x0002
        case (.crank, .multiple): 0x0006
        case (.wheelAndCrank, .none): 0x0003
        case (.wheelAndCrank, .fixed): 0x0003
        case (.wheelAndCrank, .multiple): 0x0007
        }
    }

    var expectedCharacteristics: [String] {
        switch (revolutions, locationKind) {
        case (.wheel, .none):
            ["Measurement", "Feature", "Control Point"]
        case (.wheel, .fixed):
            ["Measurement", "Feature", "Sensor Location", "Control Point"]
        case (.wheel, .multiple):
            ["Measurement", "Feature", "Sensor Location", "Control Point"]
        case (.crank, .none):
            ["Measurement", "Feature"]
        case (.crank, .fixed):
            ["Measurement", "Feature", "Sensor Location"]
        case (.crank, .multiple):
            ["Measurement", "Feature", "Sensor Location", "Control Point"]
        case (.wheelAndCrank, .none):
            ["Measurement", "Feature", "Control Point"]
        case (.wheelAndCrank, .fixed):
            ["Measurement", "Feature", "Sensor Location", "Control Point"]
        case (.wheelAndCrank, .multiple):
            ["Measurement", "Feature", "Sensor Location", "Control Point"]
        }
    }

    var expectedClientSummary: String {
        switch (revolutions, locationKind) {
        case (.wheel, .none):
            "Speed"
        case (.wheel, .fixed):
            "Speed, \"Location: X\""
        case (.wheel, .multiple):
            "Speed, location picker"
        case (.crank, .none):
            "Cadence"
        case (.crank, .fixed):
            "Cadence, \"Location: X\""
        case (.crank, .multiple):
            "Cadence, location picker"
        case (.wheelAndCrank, .none):
            "Speed, Cadence"
        case (.wheelAndCrank, .fixed):
            "Speed, Cadence, \"Location: X\""
        case (.wheelAndCrank, .multiple):
            "Speed, Cadence, location picker"
        }
    }

    private var locationKind: LocationKind {
        switch location {
        case .none: .none
        case .fixed: .fixed
        case .multiple: .multiple
        }
    }

    private enum LocationKind {
        case none
        case fixed
        case multiple
    }
}
