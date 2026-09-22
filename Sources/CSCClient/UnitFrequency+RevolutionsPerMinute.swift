import Foundation

public extension UnitFrequency {
    /// Revolutions per minute, the standard cadence unit for cycling sensors.
    static let revolutionsPerMinute = UnitFrequency(
        symbol: "rpm",
        converter: UnitConverterLinear(coefficient: 1.0 / 60.0),
    )
}
