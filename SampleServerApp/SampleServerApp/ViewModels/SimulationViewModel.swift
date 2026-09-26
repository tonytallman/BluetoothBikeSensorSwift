import CSCServer
import Observation

@Observable
@MainActor
final class RuntimeSimulationViewModel: SimulationViewModel {
    var wheelMode: SimulationMode = .automatic {
        didSet { wheelModeDidChange(from: oldValue) }
    }

    var speedKilometersPerHour: Double = 25 {
        didSet { refreshWheelPeriodIfNeeded() }
    }

    var wheelCircumferenceMeters: Double = 2.105 {
        didSet { refreshWheelPeriodIfNeeded() }
    }

    var crankMode: SimulationMode = .automatic {
        didSet { crankModeDidChange(from: oldValue) }
    }

    var cadenceRevolutionsPerMinute: Double = 90 {
        didSet { refreshCrankPeriodIfNeeded() }
    }

    private(set) var isManualInputEnabled = false
    private(set) var wheelReadout = "0 rev"
    private(set) var crankReadout = "0 rev"

    var expectedSpeedText: String {
        String(format: "%.1f km/h", speedKilometersPerHour)
    }

    var expectedCadenceText: String {
        String(format: "%.0f rpm", cadenceRevolutionsPerMinute)
    }

    private var outputs: SimulationOutputs?
    private var wheelSchedule = RevolutionSchedule()
    private var crankSchedule = RevolutionSchedule()
    private var activeTimeline = ActiveTimeline()
    private let timeSource: any MonotonicTimeSource
    private let ticker: any SimulationTicker
    private var tickerTask: Task<Void, Never>?
    private var isSimulating = false
    private var activeShowsWheel = false
    private var activeShowsCrank = false

    init(
        timeSource: any MonotonicTimeSource = ContinuousTimeSource(),
        ticker: any SimulationTicker = SleepingTicker(interval: .seconds(1)),
    ) {
        self.timeSource = timeSource
        self.ticker = ticker
    }

    func begin(_ outputs: SimulationOutputs, showsWheel: Bool, showsCrank: Bool) {
        self.outputs = outputs
        isSimulating = true
        isManualInputEnabled = true
        activeShowsWheel = showsWheel
        activeShowsCrank = showsCrank
        let now = nowActive()
        if showsWheel, wheelMode == .automatic {
            wheelSchedule.beginAutomatic(at: now, period: wheelPeriod())
        }
        if showsCrank, crankMode == .automatic {
            crankSchedule.beginAutomatic(at: now, period: crankPeriod())
        }
        updateReadouts()
        tickerTask = Task { [weak self] in
            guard let self else { return }
            for await _ in ticker.ticks() {
                guard !Task.isCancelled else { return }
                await self.handleTick()
            }
        }
    }

    func end() {
        isSimulating = false
        isManualInputEnabled = false
        tickerTask?.cancel()
        tickerTask = nil
        wheelSchedule.stopAutomatic()
        crankSchedule.stopAutomatic()
        outputs = nil
        activeShowsWheel = false
        activeShowsCrank = false
    }

    func tick() {
        handleTick()
    }

    func pause() {
        activeTimeline.pause(at: timeSource.elapsed)
    }

    func resume() {
        activeTimeline.resume(at: timeSource.elapsed)
    }

    func setCumulativeWheelRevolutions(_ value: UInt32) {
        wheelSchedule.setCumulativeRevolutions(UInt64(value))
        updateReadouts()
    }

    func addWheelRevolution() {
        guard isSimulating, activeShowsWheel, wheelMode == .manual, var outputs else { return }
        let sample = wheelSchedule.manualRevolution(at: nowActive())
        outputs.yieldWheel(sample.wheelRevolution)
        updateReadouts()
    }

    func addCrankRevolution() {
        guard isSimulating, activeShowsCrank, crankMode == .manual, var outputs else { return }
        let sample = crankSchedule.manualRevolution(at: nowActive())
        outputs.yieldCrank(sample.crankRevolution)
        updateReadouts()
    }

    private func handleTick() {
        guard isSimulating, var outputs else { return }
        let now = nowActive()
        if activeShowsWheel, wheelMode == .automatic,
           let sample = wheelSchedule.advance(to: now) {
            outputs.yieldWheel(sample.wheelRevolution)
            updateReadouts()
        }
        if activeShowsCrank, crankMode == .automatic,
           let sample = crankSchedule.advance(to: now) {
            outputs.yieldCrank(sample.crankRevolution)
            updateReadouts()
        }
    }

    private func wheelModeDidChange(from oldValue: SimulationMode) {
        guard isSimulating, activeShowsWheel else { return }
        let now = nowActive()
        switch (oldValue, wheelMode) {
        case (.automatic, .manual):
            wheelSchedule.stopAutomatic()
        case (.manual, .automatic):
            wheelSchedule.beginAutomatic(at: now, period: wheelPeriod())
        default:
            break
        }
    }

    private func crankModeDidChange(from oldValue: SimulationMode) {
        guard isSimulating, activeShowsCrank else { return }
        let now = nowActive()
        switch (oldValue, crankMode) {
        case (.automatic, .manual):
            crankSchedule.stopAutomatic()
        case (.manual, .automatic):
            crankSchedule.beginAutomatic(at: now, period: crankPeriod())
        default:
            break
        }
    }

    private func refreshWheelPeriodIfNeeded() {
        guard isSimulating, activeShowsWheel, wheelMode == .automatic else { return }
        wheelSchedule.setPeriod(wheelPeriod(), at: nowActive())
    }

    private func refreshCrankPeriodIfNeeded() {
        guard isSimulating, activeShowsCrank, crankMode == .automatic else { return }
        crankSchedule.setPeriod(crankPeriod(), at: nowActive())
    }

    private func wheelPeriod() -> Duration {
        RevolutionPeriod.wheelPeriod(
            speedKilometersPerHour: speedKilometersPerHour,
            circumferenceMeters: wheelCircumferenceMeters,
        )
    }

    private func crankPeriod() -> Duration {
        RevolutionPeriod.crankPeriod(revolutionsPerMinute: cadenceRevolutionsPerMinute)
    }

    private func nowActive() -> Duration {
        activeTimeline.activeElapsed(at: timeSource.elapsed)
    }

    private func updateReadouts() {
        wheelReadout = "\(wheelSchedule.cumulative) rev"
        crankReadout = "\(crankSchedule.cumulative) rev"
    }
}
