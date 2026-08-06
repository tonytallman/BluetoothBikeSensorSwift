import Foundation

/// Instantaneous cadence from a CSCS sensor, as ``Measurement`` in ``UnitFrequency``.
///
/// Use ``UnitFrequency/revolutionsPerMinute`` for RPM values.
public typealias Cadence = Measurement<UnitFrequency>
