import CSCServer
import Foundation

struct SimulationOutputs {
    var wheelContinuation: AsyncStream<WheelRevolution>.Continuation?
    var crankContinuation: AsyncStream<CrankRevolution>.Continuation?
    var wheelAndCrankContinuation: AsyncStream<WheelAndCrankRevolution>.Continuation?

    mutating func yieldWheel(_ revolution: WheelRevolution) {
        wheelContinuation?.yield(revolution)
    }

    mutating func yieldCrank(_ revolution: CrankRevolution) {
        crankContinuation?.yield(revolution)
    }

    mutating func yieldWheelAndCrank(_ revolution: WheelAndCrankRevolution) {
        wheelAndCrankContinuation?.yield(revolution)
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
