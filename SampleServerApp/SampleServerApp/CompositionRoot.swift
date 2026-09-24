import SwiftUI

@MainActor
final class CompositionRoot {
    private let bluetooth = CoreBluetoothStateMonitor()
    private let factory: any SensorServerFactory = CSCServerFactory()

    func makeServerViewModel() -> RuntimeServerViewModel {
        RuntimeServerViewModel(
            simulation: makeSimulationViewModel(),
            factory: factory,
            bluetooth: bluetooth,
        )
    }

    private func makeSimulationViewModel() -> RuntimeSimulationViewModel {
        RuntimeSimulationViewModel()
    }
}
