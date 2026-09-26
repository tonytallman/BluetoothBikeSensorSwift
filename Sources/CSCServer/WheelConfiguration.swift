/// Pairs the wheel revolution source with the delegate that handles Set Cumulative Value.
package struct WheelConfiguration: Sendable {
    package let revolutions: AnyAsyncSequence<WheelRevolution>
    package let setCumulativeWheelRevolutions: any SetCumulativeWheelRevolutions
}
