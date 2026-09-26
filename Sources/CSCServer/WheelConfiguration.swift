package struct WheelConfiguration: Sendable {
    package let revolutions: AnyAsyncSequence<WheelRevolution>
    package let delegate: any CumulativeWheelRevolutionsDelegate
}
