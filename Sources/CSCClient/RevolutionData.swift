import Foundation

/// Wheel and/or crank revolution support exposed by a connected sensor.
public enum RevolutionData: Sendable {
    case wheel(WheelRevolutions)
    case crank(CrankRevolutions)
    case wheelAndCrank(WheelRevolutions, CrankRevolutions)

    package var wheel: WheelRevolutions? {
        switch self {
        case let .wheel(wheel):
            wheel
        case let .wheelAndCrank(wheel, _):
            wheel
        case .crank:
            nil
        }
    }

    package var crank: CrankRevolutions? {
        switch self {
        case let .crank(crank):
            crank
        case let .wheelAndCrank(_, crank):
            crank
        case .wheel:
            nil
        }
    }
}
