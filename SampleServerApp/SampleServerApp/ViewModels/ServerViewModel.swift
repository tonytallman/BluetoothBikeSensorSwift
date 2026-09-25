import CSCServer
import Observation

@Observable
@MainActor
final class RuntimeServerViewModel: ServerViewModel, ControlPointEventSink {
    private(set) var lifecycleTask: Task<Void, Never>?

    private(set) var phase: ServerPhase = .stopped {
        didSet {
            guard oldValue != phase else { return }
            resumePhaseWaiters(for: phase)
        }
    }

    var revolutions: RevolutionConfiguration {
        get { storedRevolutions }
        set {
            guard isConfigurationEditable else { return }
            storedRevolutions = newValue
        }
    }

    var locationMode: LocationMode {
        get { storedLocationMode }
        set {
            guard isConfigurationEditable else { return }
            storedLocationMode = newValue
        }
    }

    var fixedLocation: SensorLocationKind {
        get { storedFixedLocation }
        set {
            guard isConfigurationEditable else { return }
            storedFixedLocation = newValue
        }
    }

    var multipleCurrentLocation: SensorLocationKind {
        get { storedMultipleCurrentLocation }
        set {
            guard isConfigurationEditable else { return }
            storedMultipleCurrentLocation = newValue
        }
    }

    private var storedRevolutions: RevolutionConfiguration = .wheelAndCrank
    private var storedLocationMode: LocationMode = .none
    private var storedFixedLocation: SensorLocationKind = .rearDropout
    private var storedMultipleCurrentLocation: SensorLocationKind = .rearDropout
    private var storedSupportedSelection: Set<SensorLocationKind> = [
        .frontWheel,
        .rearDropout,
        .leftCrank,
        .rightCrank,
    ]

    private var supportedSelection: Set<SensorLocationKind> {
        get { storedSupportedSelection }
        set { applySupportedSelection(newValue) }
    }

    var alert: ServerAlert?

    let catalog = SensorLocationCatalog.allKinds

    private(set) var servedLocation: SensorLocationKind?
    private(set) var subscribedCentralCount = 0 {
        didSet {
            guard oldValue != subscribedCentralCount else { return }
            resumeSubscribedCentralCountWaiters(for: subscribedCentralCount)
        }
    }
    private(set) var controlPointLog: [ControlPointLogEntry] = []

    private let runtimeSimulation: RuntimeSimulationViewModel
    private let factory: any SensorServerFactory
    private let bluetooth: any BluetoothStateMonitor
    private var phaseWaiters: [ServerPhase: [CheckedContinuation<Void, Never>]] = [:]
    private var subscribedCentralCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var subscriberCountTask: Task<Void, Never>?

    init(
        simulation: RuntimeSimulationViewModel,
        factory: any SensorServerFactory,
        bluetooth: any BluetoothStateMonitor,
    ) {
        runtimeSimulation = simulation
        self.factory = factory
        self.bluetooth = bluetooth
    }

    typealias Simulation = RuntimeSimulationViewModel

    var simulation: RuntimeSimulationViewModel {
        runtimeSimulation
    }

    var isConfigurationEditable: Bool {
        phase == .stopped
    }

    var configurationIssue: String? {
        currentConfiguration.validationIssue
    }

    var expectedClientSummary: String {
        currentConfiguration.expectedClientSummary
    }

    var statusTitle: String {
        switch phase {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting…"
        case .running:
            if bluetooth.isActive, bluetooth.status == .poweredOn {
                "Advertising CSC service (0x1816)"
            } else if bluetooth.isActive {
                "Suspended"
            } else {
                "Advertising CSC service (0x1816)"
            }
        case .stopping:
            "Stopping…"
        }
    }

    var statusDetail: String? {
        switch phase {
        case .starting where bluetooth.isActive && bluetooth.status != .poweredOn:
            "Waiting for Bluetooth"
        case .running where bluetooth.isActive && bluetooth.status != .poweredOn:
            "Bluetooth is \(bluetooth.status.displayTitle). The server advertises again automatically when Bluetooth comes back."
        default:
            nil
        }
    }

    var bluetoothTitle: String {
        if bluetooth.isActive {
            "\(bluetooth.status.displayTitle) · \(bluetooth.authorization.displayTitle)"
        } else {
            "Authorization: \(bluetooth.authorization.displayTitle) · State is checked when the server starts"
        }
    }

    var connectionStatusText: String {
        switch phase {
        case .running where subscribedCentralCount == 0:
            "Waiting for a client"
        case .running:
            "Subscribed centrals: \(subscribedCentralCount)"
        default:
            "Subscribed centrals: 0"
        }
    }

    var showsWheelSimulation: Bool {
        revolutions == .wheel || revolutions == .wheelAndCrank
    }

    var showsCrankSimulation: Bool {
        revolutions == .crank || revolutions == .wheelAndCrank
    }

    var showsControlPoint: Bool {
        showsWheelSimulation || locationMode == .multiple
    }

    var servedLocationTitle: String? {
        guard locationMode == .multiple, let servedLocation else { return nil }
        return "Served location: \(displayName(for: servedLocation))"
    }

    var primaryActionTitle: String {
        switch phase {
        case .stopped:
            "Start"
        case .starting:
            "Cancel"
        case .running:
            "Stop"
        case .stopping:
            "Stopping…"
        }
    }

    var isPrimaryActionEnabled: Bool {
        switch phase {
        case .stopped:
            configurationIssue == nil
        case .starting, .running:
            true
        case .stopping:
            false
        }
    }

    func performPrimaryAction() {
        if let lifecycleTask {
            lifecycleTask.cancel()
            return
        }
        guard phase == .stopped, let session = makeSession() else { return }
        bluetooth.activate()
        phase = .starting
        lifecycleTask = Task { await run(session) }
    }

    func sceneDidEnterBackground() {
        runtimeSimulation.pause()
    }

    func sceneDidBecomeActive() {
        runtimeSimulation.resume()
    }

    func isSupported(_ kind: SensorLocationKind) -> Bool {
        supportedSelection.contains(kind)
    }

    func setSupported(_ kind: SensorLocationKind, _ isSupported: Bool) {
        guard isConfigurationEditable else { return }
        var next = storedSupportedSelection
        if isSupported {
            next.insert(kind)
        } else {
            next.remove(kind)
        }
        applySupportedSelection(next)
    }

    private func applySupportedSelection(_ selection: Set<SensorLocationKind>) {
        storedSupportedSelection = selection
        if !selection.contains(storedMultipleCurrentLocation),
           let first = SensorLocationCatalog.supportedKinds(from: selection).first {
            storedMultipleCurrentLocation = first
        }
    }

    var supportedLocations: [SensorLocationKind] {
        SensorLocationCatalog.supportedKinds(from: supportedSelection)
    }

    func displayName(for kind: SensorLocationKind) -> String {
        SensorLocationCatalog.displayName(for: kind)
    }

    func cumulativeWheelRevolutionsDidChange(to value: UInt32) {
        runtimeSimulation.setCumulativeWheelRevolutions(value)
        appendLog("Set cumulative wheel revolutions → \(value)")
    }

    func sensorLocationDidChange(to location: SensorLocationKind) {
        servedLocation = location
        storedMultipleCurrentLocation = location
        appendLog("Sensor location updated → \(displayName(for: location))")
    }

    func waitForPhase(_ expected: ServerPhase) async {
        if phase == expected { return }
        await withCheckedContinuation { continuation in
            phaseWaiters[expected, default: []].append(continuation)
        }
    }

    func waitForSubscribedCentralCount(_ expected: Int) async {
        if subscribedCentralCount == expected { return }
        await withCheckedContinuation { continuation in
            subscribedCentralCountWaiters[expected, default: []].append(continuation)
        }
    }

    private func run(_ session: Session) async {
        let server = session.server
        var outputs = session.outputs
        subscriberCountTask = Task { @MainActor [server] in
            let stream = await server.measurementSubscriberCount
            for await count in stream {
                subscribedCentralCount = count
            }
        }
        let startTask = Task { try await server.start() }
        let result = await withTaskCancellationHandler {
            await startTask.result
        } onCancel: {
            startTask.cancel()
        }

        if case .success = result, !Task.isCancelled {
            phase = .running
            if locationMode == .multiple {
                servedLocation = multipleCurrentLocation
            }
            runtimeSimulation.begin(
                outputs,
                showsWheel: showsWheelSimulation,
                showsCrank: showsCrankSimulation,
            )
            await suspendUntilCancelled()
        }

        phase = .stopping
        if let task = subscriberCountTask {
            task.cancel()
            await task.value
        }
        subscriberCountTask = nil
        subscribedCentralCount = 0
        runtimeSimulation.end()
        await server.stop()
        outputs.finish()
        phase = .stopped
        lifecycleTask = nil

        if case let .failure(error) = result, !Task.isCancelled {
            alert = .startFailure(
                error,
                status: bluetooth.status,
                authorization: bluetooth.authorization,
            )
        }
    }

    private func suspendUntilCancelled() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    private struct Session {
        let server: any SensorServer
        var outputs: SimulationOutputs
    }

    private var currentConfiguration: ServerConfiguration {
        ServerConfiguration(
            revolutions: revolutions,
            location: locationConfiguration,
        )
    }

    private var locationConfiguration: LocationConfiguration {
        switch locationMode {
        case .none:
            .none
        case .fixed:
            .fixed(fixedLocation)
        case .multiple:
            .multiple(
                supported: supportedLocations,
                current: multipleCurrentLocation,
            )
        }
    }

    private func makeSession() -> Session? {
        guard configurationIssue == nil else { return nil }

        var outputs = SimulationOutputs()
        var wheelStream: AsyncStream<WheelRevolution>?
        var crankStream: AsyncStream<CrankRevolution>?

        switch revolutions {
        case .wheel, .wheelAndCrank:
            let pair = AsyncStream.makeStream(
                of: WheelRevolution.self,
                bufferingPolicy: .bufferingNewest(1),
            )
            wheelStream = pair.stream
            outputs.wheelContinuation = pair.continuation
        case .crank:
            break
        }

        switch revolutions {
        case .crank, .wheelAndCrank:
            let pair = AsyncStream.makeStream(
                of: CrankRevolution.self,
                bufferingPolicy: .bufferingNewest(1),
            )
            crankStream = pair.stream
            outputs.crankContinuation = pair.continuation
        case .wheel:
            break
        }

        let cumulativeHandler = CumulativeWheelRevolutionsHandler(sink: self)
        let locationInput = makeLocationInput()
        let revolutionInput = makeRevolutionInputs(
            wheelStream: wheelStream,
            crankStream: crankStream,
            cumulativeHandler: cumulativeHandler,
        )
        let server = factory.makeServer(
            revolutions: revolutionInput,
            location: locationInput,
        )
        return Session(server: server, outputs: outputs)
    }

    private func makeLocationInput() -> LocationInput {
        switch locationMode {
        case .none:
            .none
        case .fixed:
            .fixed(fixedLocation)
        case .multiple:
            .multiple(
                SensorLocationsHandler(
                    supported: supportedLocations,
                    current: multipleCurrentLocation,
                    sink: self,
                ),
            )
        }
    }

    private func makeRevolutionInputs(
        wheelStream: AsyncStream<WheelRevolution>?,
        crankStream: AsyncStream<CrankRevolution>?,
        cumulativeHandler: CumulativeWheelRevolutionsHandler,
    ) -> RevolutionInputs {
        switch revolutions {
        case .wheel:
            .wheel(wheelStream!, setCumulative: cumulativeHandler)
        case .crank:
            .crank(crankStream!)
        case .wheelAndCrank:
            .wheelAndCrank(
                wheelStream!,
                setCumulative: cumulativeHandler,
                crankStream!,
            )
        }
    }

    private func appendLog(_ text: String) {
        var entries = controlPointLog
        entries.insert(ControlPointLogEntry(text: text), at: 0)
        if entries.count > 20 {
            entries = Array(entries.prefix(20))
        }
        controlPointLog = entries
    }

    private func resumePhaseWaiters(for phase: ServerPhase) {
        let waiters = phaseWaiters.removeValue(forKey: phase) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeSubscribedCentralCountWaiters(for count: Int) {
        let waiters = subscribedCentralCountWaiters.removeValue(forKey: count) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
