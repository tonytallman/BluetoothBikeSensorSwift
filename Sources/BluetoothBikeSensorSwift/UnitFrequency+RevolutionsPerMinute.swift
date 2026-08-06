import Foundation

public extension UnitFrequency {
    static let revolutionsPerMinute = UnitFrequency(
        symbol: "rpm",
        converter: UnitConverterLinear(coefficient: 1.0 / 60.0)
    )
}
