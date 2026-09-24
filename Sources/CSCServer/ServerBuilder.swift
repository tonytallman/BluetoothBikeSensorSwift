/// Type-state marker for wheel revolution selection.
public enum ServerWheel {
    /// Wheel revolutions have not been selected.
    public enum Unselected: Sendable {}
    /// Wheel revolutions have been selected.
    public enum Selected: Sendable {}
}

/// Type-state marker for crank revolution selection.
public enum ServerCrank {
    /// Crank revolutions have not been selected.
    public enum Unselected: Sendable {}
    /// Crank revolutions have been selected.
    public enum Selected: Sendable {}
}

/// Type-state marker for sensor location selection.
public enum ServerLocation {
    /// Sensor location has not been selected.
    public enum Unselected: Sendable {}
    /// A static sensor location has been selected.
    public enum Static: Sendable {}
    /// Multiple sensor locations have been selected.
    public enum Multiple: Sendable {}
}

/// Type-state builder for a CSC sensor server configuration.
public struct ServerBuilder<
    Wheel: Sendable,
    Crank: Sendable,
    Location: Sendable,
>: Sendable {
    private var wheel: WheelConfiguration?
    private var crankRevolutions: AnyAsyncSequence<CrankRevolution>?
    private var location: ServerLocationConfiguration

    internal init(
        wheel: WheelConfiguration? = nil,
        crankRevolutions: AnyAsyncSequence<CrankRevolution>? = nil,
        location: ServerLocationConfiguration = .none,
    ) {
        self.wheel = wheel
        self.crankRevolutions = crankRevolutions
        self.location = location
    }
}

extension Server {
    /// Begins building a server with wheel revolution data and a set-cumulative delegate.
    public static func wheelRevolutions<Revolutions>(
        _ revolutions: Revolutions,
        setCumulativeWheelRevolutions delegate: any SetCumulativeWheelRevolutions,
    ) -> ServerBuilder<
        ServerWheel.Selected,
        ServerCrank.Unselected,
        ServerLocation.Unselected
    >
    where Revolutions: AsyncSequence & Sendable,
          Revolutions.Element == WheelRevolution
    {
        ServerBuilder(
            wheel: WheelConfiguration(
                revolutions: AnyAsyncSequence(revolutions),
                setCumulativeWheelRevolutions: delegate,
            ),
        )
    }

    /// Begins building a server with crank revolution data.
    public static func crankRevolutions<Revolutions>(
        _ revolutions: Revolutions,
    ) -> ServerBuilder<
        ServerWheel.Unselected,
        ServerCrank.Selected,
        ServerLocation.Unselected
    >
    where Revolutions: AsyncSequence & Sendable,
          Revolutions.Element == CrankRevolution
    {
        ServerBuilder(crankRevolutions: AnyAsyncSequence(revolutions))
    }
}

extension ServerBuilder where Wheel == ServerWheel.Unselected {
    /// Adds wheel revolution data and a set-cumulative delegate.
    public func wheelRevolutions<Revolutions>(
        _ revolutions: Revolutions,
        setCumulativeWheelRevolutions delegate: any SetCumulativeWheelRevolutions,
    ) -> ServerBuilder<
        ServerWheel.Selected,
        Crank,
        Location
    >
    where Revolutions: AsyncSequence & Sendable,
          Revolutions.Element == WheelRevolution
    {
        ServerBuilder<ServerWheel.Selected, Crank, Location>(
            wheel: WheelConfiguration(
                revolutions: AnyAsyncSequence(revolutions),
                setCumulativeWheelRevolutions: delegate,
            ),
            crankRevolutions: crankRevolutions,
            location: location,
        )
    }
}

extension ServerBuilder where Crank == ServerCrank.Unselected {
    /// Adds crank revolution data.
    public func crankRevolutions<Revolutions>(
        _ revolutions: Revolutions,
    ) -> ServerBuilder<
        Wheel,
        ServerCrank.Selected,
        Location
    >
    where Revolutions: AsyncSequence & Sendable,
          Revolutions.Element == CrankRevolution
    {
        ServerBuilder<Wheel, ServerCrank.Selected, Location>(
            wheel: wheel,
            crankRevolutions: AnyAsyncSequence(revolutions),
            location: location,
        )
    }
}

extension ServerBuilder where Location == ServerLocation.Unselected {
    /// Selects a fixed sensor location cached for the server lifetime.
    public func staticSensorLocation(
        _ kind: SensorLocationKind,
    ) -> ServerBuilder<
        Wheel,
        Crank,
        ServerLocation.Static
    > {
        ServerBuilder<Wheel, Crank, ServerLocation.Static>(
            wheel: wheel,
            crankRevolutions: crankRevolutions,
            location: .staticLocation(kind),
        )
    }

    /// Selects multiple sensor locations with a delegate for supported and current values.
    public func multipleSensorLocations(
        _ delegate: any MultipleSensorLocationsDelegate,
    ) -> ServerBuilder<
        Wheel,
        Crank,
        ServerLocation.Multiple
    > {
        let supported = delegate.supported
        let current = delegate.current
        precondition(!supported.isEmpty, "Multiple sensor locations require a non-empty supported list")
        precondition(
            Set(supported).count == supported.count,
            "Multiple sensor locations require unique supported entries",
        )
        precondition(
            supported.count <= 17,
            "Multiple sensor locations support at most 17 entries",
        )
        precondition(
            supported.contains(current),
            "Multiple sensor locations require current to be in supported",
        )

        return ServerBuilder<Wheel, Crank, ServerLocation.Multiple>(
            wheel: wheel,
            crankRevolutions: crankRevolutions,
            location: .multiple(
                MultipleSensorLocationsConfiguration(
                    supported: supported,
                    current: current,
                    delegate: delegate,
                ),
            ),
        )
    }
}

extension ServerBuilder
where Wheel == ServerWheel.Selected, Crank == ServerCrank.Unselected {
    /// Builds the server from a wheel-only configuration.
    public consuming func build() -> Server {
        ServerAssembly.assemble(
            wheel: wheel,
            crankRevolutions: crankRevolutions,
            location: location,
        )
    }
}

extension ServerBuilder
where Wheel == ServerWheel.Unselected, Crank == ServerCrank.Selected {
    /// Builds the server from a crank-only configuration.
    public consuming func build() -> Server {
        ServerAssembly.assemble(
            wheel: wheel,
            crankRevolutions: crankRevolutions,
            location: location,
        )
    }
}

extension ServerBuilder
where Wheel == ServerWheel.Selected, Crank == ServerCrank.Selected {
    /// Builds the server from a wheel-and-crank configuration.
    public consuming func build() -> Server {
        ServerAssembly.assemble(
            wheel: wheel,
            crankRevolutions: crankRevolutions,
            location: location,
        )
    }
}
