import CSCServer
import Foundation

struct RevolutionSchedule: Equatable {
    private(set) var cumulative: UInt64 = 0
    private(set) var lastEventElapsed: Duration = .zero
    private var anchor: Duration = .zero
    private var nextEvent: Duration?
    private(set) var period: Duration = .zero
    private(set) var isAutomatic = false

    mutating func beginAutomatic(at now: Duration, period: Duration) {
        self.period = period
        isAutomatic = true
        anchor = now
        nextEvent = now + period
    }

    mutating func stopAutomatic() {
        isAutomatic = false
        nextEvent = nil
    }

    mutating func setPeriod(_ newPeriod: Duration, at now: Duration) {
        period = newPeriod
        guard isAutomatic else { return }
        nextEvent = anchor + newPeriod
        if let nextEvent, nextEvent <= now {
            _ = advance(to: now)
        }
    }

    @discardableResult
    mutating func advance(to now: Duration) -> WheelRevolutionSample? {
        guard isAutomatic, var next = nextEvent else { return nil }
        var produced: WheelRevolutionSample?
        while next <= now {
            cumulative &+= 1
            lastEventElapsed = next
            anchor = next
            next += period
            produced = WheelRevolutionSample(
                cumulative: cumulative,
                lastEventElapsed: lastEventElapsed,
            )
        }
        nextEvent = next
        return produced
    }

    mutating func manualRevolution(at now: Duration) -> WheelRevolutionSample {
        cumulative &+= 1
        lastEventElapsed = now
        anchor = now
        if isAutomatic {
            nextEvent = now + period
        }
        return WheelRevolutionSample(
            cumulative: cumulative,
            lastEventElapsed: lastEventElapsed,
        )
    }

    mutating func setCumulativeRevolutions(_ value: UInt64) {
        cumulative = value
    }
}

struct WheelRevolutionSample: Equatable {
    let cumulative: UInt64
    let lastEventElapsed: Duration

    var wheelRevolution: WheelRevolution {
        WheelRevolution(
            cumulativeRevolutions: UInt32(truncatingIfNeeded: cumulative),
            lastEventTime: EventTime.wireValue(for: lastEventElapsed),
        )
    }

    var crankRevolution: CrankRevolution {
        CrankRevolution(
            cumulativeRevolutions: UInt16(truncatingIfNeeded: cumulative),
            lastEventTime: EventTime.wireValue(for: lastEventElapsed),
        )
    }
}
