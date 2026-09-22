import Foundation

/// A CSCS sensor location assigned number (GATT values 0...16).
///
/// Instances are obtained only from a connected sensor (`fixed`, `supported`, or `current`).
/// Compare and select locations using ``kind``; use ``displayName`` for UI labels.
public struct SensorLocation: Sendable, Hashable {
    package let assignedNumber: UInt8

    /// Standard GATT sensor location identity.
    public enum Kind: Sendable, Hashable {
        case other
        case topOfShoe
        case inShoe
        case hip
        case frontWheel
        case leftCrank
        case rightCrank
        case leftPedal
        case rightPedal
        case frontHub
        case rearDropout
        case chainstay
        case rearWheel
        case rearHub
        case chest
        case spider
        case chainRing
        case reserved(UInt8)

        /// Human-readable name for this location kind.
        public var displayName: String {
            switch self {
            case .other:
                return "Other"
            case .topOfShoe:
                return "Top of shoe"
            case .inShoe:
                return "In shoe"
            case .hip:
                return "Hip"
            case .frontWheel:
                return "Front Wheel"
            case .leftCrank:
                return "Left Crank"
            case .rightCrank:
                return "Right Crank"
            case .leftPedal:
                return "Left Pedal"
            case .rightPedal:
                return "Right Pedal"
            case .frontHub:
                return "Front Hub"
            case .rearDropout:
                return "Rear Dropout"
            case .chainstay:
                return "Chainstay"
            case .rearWheel:
                return "Rear Wheel"
            case .rearHub:
                return "Rear Hub"
            case .chest:
                return "Chest"
            case .spider:
                return "Spider"
            case .chainRing:
                return "Chain Ring"
            case let .reserved(value):
                return "Unknown (\(value))"
            }
        }

        package static func fromAssignedNumber(_ value: UInt8) -> Kind {
            switch value {
            case 0: .other
            case 1: .topOfShoe
            case 2: .inShoe
            case 3: .hip
            case 4: .frontWheel
            case 5: .leftCrank
            case 6: .rightCrank
            case 7: .leftPedal
            case 8: .rightPedal
            case 9: .frontHub
            case 10: .rearDropout
            case 11: .chainstay
            case 12: .rearWheel
            case 13: .rearHub
            case 14: .chest
            case 15: .spider
            case 16: .chainRing
            default: .reserved(value)
            }
        }
    }

    /// Standard GATT location identity for this peripheral-reported token.
    public var kind: Kind {
        Kind.fromAssignedNumber(assignedNumber)
    }

    /// Human-readable name for the assigned GATT value.
    public var displayName: String {
        kind.displayName
    }

    package static func fromAssignedNumber(_ value: UInt8) -> SensorLocation {
        SensorLocation(assignedNumber: value)
    }
}
