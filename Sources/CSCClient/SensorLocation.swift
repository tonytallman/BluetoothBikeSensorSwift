internal import CSCWire
import Foundation

/// Sensor location support for one connection. Only `.multiple` can change after connect.
public enum LocationSupport: Sendable {
    case unavailable
    case fixed(SensorLocation)
    case multiple(MultipleSensorLocations)
}

/// A CSCS sensor location assigned number (GATT values 0...16).
///
/// Instances are obtained only from a connected sensor (`fixed`, `supported`, or `current`).
/// Compare and select locations using ``kind``; use ``displayName`` for UI labels.
public struct SensorLocation: Sendable, Hashable {
    let assignedNumber: UInt8

    package init(assignedNumber: UInt8) {
        self.assignedNumber = assignedNumber
    }

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

        /// GATT Sensor Location assigned numbers 0...16. Any other byte is ``Kind/reserved(_:)``,
        /// whose ``Kind/displayName`` is `Unknown (n)`.
        init(assignedNumber: UInt8) {
            switch assignedNumber {
            case 0: self = .other
            case 1: self = .topOfShoe
            case 2: self = .inShoe
            case 3: self = .hip
            case 4: self = .frontWheel
            case 5: self = .leftCrank
            case 6: self = .rightCrank
            case 7: self = .leftPedal
            case 8: self = .rightPedal
            case 9: self = .frontHub
            case 10: self = .rearDropout
            case 11: self = .chainstay
            case 12: self = .rearWheel
            case 13: self = .rearHub
            case 14: self = .chest
            case 15: self = .spider
            case 16: self = .chainRing
            default: self = .reserved(assignedNumber)
            }
        }
    }

    /// Standard GATT location identity for this peripheral-reported token.
    public var kind: Kind {
        Kind(assignedNumber: assignedNumber)
    }

    /// Human-readable name for the assigned GATT value.
    public var displayName: String {
        kind.displayName
    }
}

/// Multiple sensor locations supported by a connected CSCS sensor.
/// Multiple sensor locations for one connection.
///
/// `current` is guarded by `lock` and stored `nonisolated(unsafe)` so this `Sendable` class
/// can be read from any thread while ``update(_:)`` writes it. The lock is not held across
/// the control-point await.
public final class MultipleSensorLocations: Sendable {
    private let lock = NSLock()

    /// This connection's ``ControlPoint``. ``WheelRevolutions`` holds the same actor when the
    /// connection also has wheel data. Exposed so tests can ``ControlPoint/waitUntilIdle()``
    /// after a procedure that timed out with its write still outstanding.
    package let controlPoint: ControlPoint

    /// Sensor locations this peripheral supports.
    public let supported: [SensorLocation]

    private nonisolated(unsafe) var currentStorage: SensorLocation

    /// The sensor's current location assignment.
    public var current: SensorLocation {
        lock.withLock { currentStorage }
    }

    init(
        supported: [SensorLocation],
        current: SensorLocation,
        controlPoint: ControlPoint,
    ) {
        self.supported = supported
        currentStorage = current
        self.controlPoint = controlPoint
    }

    /// Writes Update Sensor Location.
    ///
    /// A token that is not in ``supported`` throws ``ControlPointError/unsupportedLocation``
    /// before any write. `current` changes only after the indication succeeds, so a timeout or
    /// a refused procedure leaves the previous location in place.
    public func update(_ location: SensorLocation) async throws {
        guard supported.contains(location) else {
            throw ControlPointError.unsupportedLocation
        }

        _ = try await controlPoint.perform(.updateSensorLocation(location.assignedNumber))
        lock.withLock {
            currentStorage = location
        }
    }
}
