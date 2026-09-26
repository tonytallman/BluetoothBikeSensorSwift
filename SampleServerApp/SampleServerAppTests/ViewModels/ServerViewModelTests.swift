import CSCServer
import Testing
@testable import SampleServerApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RuntimeServerViewModelTests {
    private func makeViewModel(
        scripts: [FakeSensorServer.Script] = [.succeed],
    ) -> (RuntimeServerViewModel, FakeSensorServerFactory, FakeBluetoothStateMonitor, FakeLiveServerSlot) {
        let slot = FakeLiveServerSlot()
        let factory = FakeSensorServerFactory(slot: slot, scripts: scripts)
        let bluetooth = FakeBluetoothStateMonitor()
        bluetooth.status = .poweredOn
        bluetooth.authorization = .allowed
        let simulation = RuntimeSimulationViewModel(
            timeSource: ManualTimeSource(),
            ticker: ManualTicker(),
        )
        let viewModel = RuntimeServerViewModel(
            simulation: simulation,
            factory: factory,
            bluetooth: bluetooth,
        )
        return (viewModel, factory, bluetooth, slot)
    }

    @Test func startSucceedsAndActivatesBluetooth() async {
        let (viewModel, factory, bluetooth, _) = makeViewModel()
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        #expect(bluetooth.activateCount == 1)
        #expect(factory.recordCount() == 1)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }

    @Test func startFailureStillStopsServer() async {
        let (viewModel, factory, _, _) = makeViewModel(scripts: [.fail(.notPoweredOn)])
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
        #expect(viewModel.alert != nil)
        let server = await factory.servers.first!
        #expect(await server.stopCount == 1)
    }

    @Test func cancelDuringStart() async {
        let (viewModel, factory, _, slot) = makeViewModel(scripts: [.suspendUntilCancelled])
        viewModel.performPrimaryAction()
        await factory.servers.first!.waitUntilStartEntered()
        viewModel.performPrimaryAction()
        if let task = viewModel.lifecycleTask {
            await task.value
        }
        await viewModel.waitForPhase(.stopped)
        #expect(viewModel.alert == nil)
        #expect(slot.isOccupied == false)
        let server = await factory.servers.first!
        #expect(await server.stopCount == 1)
    }

    @Test func outerLifecycleCancel() async {
        let (viewModel, factory, _, slot) = makeViewModel(scripts: [.suspendUntilCancelled])
        viewModel.performPrimaryAction()
        await factory.servers.first!.waitUntilStartEntered()
        viewModel.lifecycleTask?.cancel()
        if let task = viewModel.lifecycleTask {
            await task.value
        }
        await viewModel.waitForPhase(.stopped)
        #expect(slot.isOccupied == false)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }

    @Test func cancelThenStartSucceedsAnyway() async {
        let (viewModel, factory, _, slot) = makeViewModel(scripts: [.suspendUntilReleased(ignoresCancellation: true)])
        viewModel.performPrimaryAction()
        await factory.servers.first!.waitUntilStartEntered()
        #expect(viewModel.phase == .starting)
        viewModel.performPrimaryAction()
        await factory.servers.first!.release()
        if let task = viewModel.lifecycleTask {
            await task.value
        }
        await viewModel.waitForPhase(.stopped)
        #expect(slot.isOccupied == false)
        let server = await factory.servers.first!
        #expect(await server.stopCount == 1)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }

    @Test func noSecondSessionWhileStarting() async {
        let (viewModel, factory, _, _) = makeViewModel(scripts: [.suspendUntilCancelled])
        viewModel.performPrimaryAction()
        await factory.servers.first!.waitUntilStartEntered()
        viewModel.performPrimaryAction()
        #expect(factory.recordCount() == 1)
        viewModel.lifecycleTask?.cancel()
        if let task = viewModel.lifecycleTask {
            await task.value
        }
        await viewModel.waitForPhase(.stopped)
    }

    @Test func invalidConfigurationDoesNotStart() async {
        let (viewModel, factory, bluetooth, _) = makeViewModel()
        viewModel.locationMode = .multiple
        viewModel.setSupported(.frontWheel, false)
        viewModel.setSupported(.rearDropout, false)
        viewModel.setSupported(.leftCrank, false)
        viewModel.setSupported(.rightCrank, false)
        viewModel.performPrimaryAction()
        #expect(viewModel.lifecycleTask == nil)
        #expect(factory.recordCount() == 0)
        #expect(bluetooth.activateCount == 0)
    }

    @Test func suspendedStatusTitle() async {
        let (viewModel, _, bluetooth, _) = makeViewModel()
        bluetooth.status = .poweredOff
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        #expect(viewModel.statusTitle == "Suspended")
        bluetooth.status = .poweredOn
        #expect(viewModel.statusTitle == "Advertising CSC service (0x1816)")
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }

    @Test func newLocationDelegatePerStart() async throws {
        let (viewModel, factory, _, _) = makeViewModel(scripts: [.succeed, .succeed])
        viewModel.locationMode = .multiple
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        let first = factory.multipleHandler(at: 0)
        #expect(first != nil)
        try await first?.update(.rightCrank)
        #expect(viewModel.multipleCurrentLocation == .rightCrank)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        let second = factory.multipleHandler(at: 1)
        #expect(second?.current == .rightCrank)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }

    @Test func setCumulativeReachesSimulation() async throws {
        let (viewModel, factory, _, _) = makeViewModel()
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        let handler = factory.cumulativeHandler(at: 0)
        try await handler?.setCumulativeWheelRevolutions(1000)
        #expect(viewModel.simulation.wheelReadout.hasPrefix("1000"))
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }

    @Test func subscriberCountDisplayFollowsServerStream() async {
        let slot = FakeLiveServerSlot()
        let counts = FakeMeasurementSubscriberCount()
        let factory = FakeSensorServerFactory(
            slot: slot,
            scripts: [.succeed],
            subscriberCounts: counts,
        )
        let viewModel = RuntimeServerViewModel(
            simulation: RuntimeSimulationViewModel(
                timeSource: ManualTimeSource(),
                ticker: ManualTicker(),
            ),
            factory: factory,
            bluetooth: FakeBluetoothStateMonitor(),
        )
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        #expect(viewModel.connectionStatusText == "Waiting for a client")
        counts.send(1)
        await viewModel.waitForSubscribedCentralCount(1)
        #expect(viewModel.connectionStatusText == "Subscribed centrals: 1")
        counts.send(0)
        await viewModel.waitForSubscribedCentralCount(0)
        #expect(viewModel.connectionStatusText == "Waiting for a client")
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
        #expect(viewModel.connectionStatusText == "Subscribed centrals: 0")
    }

    @Test func restartBuildsNewServer() async {
        let (viewModel, factory, _, _) = makeViewModel(scripts: [.succeed, .succeed])
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        #expect(factory.recordCount() == 2)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }

    @Test func configurationLockedUnlessStopped() async {
        let (viewModel, _, _, _) = makeViewModel()
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        let before = viewModel.revolutions
        viewModel.revolutions = .crank
        #expect(viewModel.revolutions == before)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
        viewModel.revolutions = .crank
        #expect(viewModel.revolutions == .crank)
    }

    @Test func locationUpdateWhileStoppingDoesNotCrash() async {
        let (viewModel, _, _, _) = makeViewModel()
        viewModel.locationMode = .multiple
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopping)
        viewModel.sensorLocationDidChange(to: .leftCrank)
        #expect(viewModel.multipleCurrentLocation == .leftCrank)
        await viewModel.waitForPhase(.stopped)
    }

    @Test func stopFromRunningFinishesLifecycle() async {
        let (viewModel, _, _, _) = makeViewModel()
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
        #expect(viewModel.lifecycleTask == nil)
        #expect(viewModel.phase == .stopped)
    }

    @Test func factoryReceivesOnlyConfiguredStreams() async {
        let (viewModel, factory, _, _) = makeViewModel()
        viewModel.revolutions = .wheel
        viewModel.locationMode = .none
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        #expect(factory.recordCount() == 1)
        if case .wheel = factory.records[0].revolutions {
        } else {
            Issue.record("Expected wheel-only revolution input")
        }
        if case .none = factory.records[0].location {
        } else {
            Issue.record("Expected no location input")
        }
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }

    @Test func subscriberCountDisplayWorksOnSecondSession() async {
        let slot = FakeLiveServerSlot()
        let counts = FakeMeasurementSubscriberCount()
        let factory = FakeSensorServerFactory(
            slot: slot,
            scripts: [.succeed, .succeed],
            subscriberCounts: counts,
        )
        let viewModel = RuntimeServerViewModel(
            simulation: RuntimeSimulationViewModel(
                timeSource: ManualTimeSource(),
                ticker: ManualTicker(),
            ),
            factory: factory,
            bluetooth: FakeBluetoothStateMonitor(),
        )
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        counts.send(2)
        await viewModel.waitForSubscribedCentralCount(2)
        #expect(viewModel.connectionStatusText == "Subscribed centrals: 2")
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.running)
        counts.send(3)
        await viewModel.waitForSubscribedCentralCount(3)
        #expect(viewModel.connectionStatusText == "Subscribed centrals: 3")
        viewModel.performPrimaryAction()
        await viewModel.waitForPhase(.stopped)
    }
}
