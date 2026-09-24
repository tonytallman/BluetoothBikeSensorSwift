import CSCServer

struct CSCServerFactory: SensorServerFactory {
    func makeServer(revolutions: RevolutionInputs, location: LocationInput) -> any SensorServer {
        switch revolutions {
        case let .wheel(wheel, setCumulative):
            switch location {
            case .none:
                return Server.wheelRevolutions(wheel, setCumulativeWheelRevolutions: setCumulative).build()
            case let .fixed(kind):
                return Server
                    .wheelRevolutions(wheel, setCumulativeWheelRevolutions: setCumulative)
                    .staticSensorLocation(kind)
                    .build()
            case let .multiple(delegate):
                return Server
                    .wheelRevolutions(wheel, setCumulativeWheelRevolutions: setCumulative)
                    .multipleSensorLocations(delegate)
                    .build()
            }
        case let .crank(crank):
            switch location {
            case .none:
                return Server.crankRevolutions(crank).build()
            case let .fixed(kind):
                return Server
                    .crankRevolutions(crank)
                    .staticSensorLocation(kind)
                    .build()
            case let .multiple(delegate):
                return Server
                    .crankRevolutions(crank)
                    .multipleSensorLocations(delegate)
                    .build()
            }
        case let .wheelAndCrank(wheel, setCumulative, crank):
            let builder = Server
                .wheelRevolutions(wheel, setCumulativeWheelRevolutions: setCumulative)
                .crankRevolutions(crank)
            switch location {
            case .none:
                return builder.build()
            case let .fixed(kind):
                return builder.staticSensorLocation(kind).build()
            case let .multiple(delegate):
                return builder.multipleSensorLocations(delegate).build()
            }
        }
    }
}
