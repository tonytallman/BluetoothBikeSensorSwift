import CSCServer
import Foundation

enum RevolutionInputs {
    case wheel(AsyncStream<WheelRevolution>, setCumulative: any SetCumulativeWheelRevolutions)
    case crank(AsyncStream<CrankRevolution>)
    case wheelAndCrank(
        AsyncStream<WheelRevolution>,
        setCumulative: any SetCumulativeWheelRevolutions,
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
