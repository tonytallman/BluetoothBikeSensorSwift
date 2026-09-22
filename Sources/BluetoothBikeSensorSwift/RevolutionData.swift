import Foundation

/// Wheel and/or crank revolution support exposed by a connected sensor.
public enum RevolutionData: Sendable {
    case wheel(WheelRevolutions)
    case crank(CrankRevolutions)
    case wheelAndCrank(WheelRevolutions, CrankRevolutions)
}
