import CSCServer
import Foundation

struct SimulationOutputs {
    var wheelContinuation: AsyncStream<WheelRevolution>.Continuation?
    var crankContinuation: AsyncStream<CrankRevolution>.Continuation?
    var wheelAndCrankContinuation: AsyncStream<WheelAndCrankRevolution>.Continuation?

    mutating func yield(wheel: WheelRevolution?, crank: CrankRevolution?) {
        if let wheelAndCrankContinuation {
            wheelAndCrankContinuation.yield(WheelAndCrankRevolution(wheel: wheel, crank: crank))
        } else {
            if let wheel {
                wheelContinuation?.yield(wheel)
            }
            if let crank {
                crankContinuation?.yield(crank)
            }
        }
    }

    mutating func finish() {
        wheelContinuation?.finish()
        crankContinuation?.finish()
        wheelAndCrankContinuation?.finish()
        wheelContinuation = nil
        crankContinuation = nil
        wheelAndCrankContinuation = nil
    }
}
