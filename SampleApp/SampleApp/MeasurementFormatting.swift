import BluetoothBikeSensorSwift
import Foundation

enum MeasurementFormatting {
    private static let speedFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 1
        formatter.numberFormatter.minimumFractionDigits = 0
        return formatter
    }()

    private static let cadenceFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 0
        formatter.numberFormatter.minimumFractionDigits = 0
        return formatter
    }()

    static func speedInKilometersPerHour(_ speed: Speed) -> String {
        let kmh = speed.converted(to: .kilometersPerHour)
        return speedFormatter.string(from: kmh)
    }

    static func cadenceInRPM(_ cadence: Cadence) -> String {
        let rpm = cadence.converted(to: .revolutionsPerMinute)
        return cadenceFormatter.string(from: rpm)
    }
}
