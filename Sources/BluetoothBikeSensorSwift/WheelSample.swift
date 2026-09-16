import Foundation

/// A wheel rotation delta between two CSC measurement notifications.
///
/// `deltaDistance` is derived from revolution count and the client-managed
/// ``ConnectedSensor/wheelCircumference`` at emission time. `deltaTime` comes
/// from CSC last-wheel-event timestamps (1/1024 s resolution), not BLE arrival time.
public struct WheelSample: Sendable, Equatable {
    /// Distance traveled during this interval, in the client's chosen length unit.
    public let deltaDistance: Measurement<UnitLength>

    /// Elapsed time between CSC wheel event timestamps for this interval.
    public let deltaTime: Measurement<UnitDuration>

    public init(
        deltaDistance: Measurement<UnitLength>,
        deltaTime: Measurement<UnitDuration>,
    ) {
        self.deltaDistance = deltaDistance
        self.deltaTime = deltaTime
    }
}
