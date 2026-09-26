import CSCServer
import Foundation

enum RevolutionInputs {
    case wheel(AsyncStream<WheelRevolution>, setCumulative: any CumulativeWheelRevolutionsDelegate)
    case crank(AsyncStream<CrankRevolution>)
    case wheelAndCrank(
        AsyncStream<WheelRevolution>,
        setCumulative: any CumulativeWheelRevolutionsDelegate,
        AsyncStream<CrankRevolution>,
    )
}

enum LocationInput {
    case none
    case fixed(SensorLocationKind)
    case multiple(any MultipleSensorLocationsDelegate)
}

protocol SensorServerFactory {
    func makeServer(revolutions: RevolutionInputs, location: LocationInput) -> any SensorServer
}
