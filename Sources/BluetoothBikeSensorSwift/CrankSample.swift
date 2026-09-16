import Foundation

/// A crank rotation delta between two CSC measurement notifications.
///
/// `deltaTime` comes from CSC last-crank-event timestamps (1/1024 s resolution),
/// not BLE arrival time.
public struct CrankSample: Sendable, Equatable {
    /// Crank revolutions during this interval.
    public let deltaRevolutions: Int

    /// Elapsed time between CSC crank event timestamps for this interval.
    public let deltaTime: Measurement<UnitDuration>

    public init(
        deltaRevolutions: Int,
        deltaTime: Measurement<UnitDuration>,
    ) {
        self.deltaRevolutions = deltaRevolutions
        self.deltaTime = deltaTime
    }
}
