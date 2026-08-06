public struct Scanner: Sendable {
    private let central: any BluetoothCentral

    /// Client entry point. Production dependencies are wired here.
    public init() {
        self.init(central: CoreBluetoothCentral())
    }

    /// Test and same-package injection only.
    package init(central: any BluetoothCentral) {
        self.central = central
    }

    public func scan() -> AsyncStream<DiscoveredSensor> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
