import CSCServer
import Foundation

struct SimulationOutputs {
    var wheelContinuation: AsyncStream<WheelRevolution>.Continuation?
    var crankContinuation: AsyncStream<CrankRevolution>.Continuation?

    mutating func yieldWheel(_ revolution: WheelRevolution) {
        wheelContinuation?.yield(revolution)
    }

    mutating func yieldCrank(_ revolution: CrankRevolution) {
        crankContinuation?.yield(revolution)
    }

    mutating func finish() {
        wheelContinuation?.finish()
        crankContinuation?.finish()
        wheelContinuation = nil
        crankContinuation = nil
    }
}
