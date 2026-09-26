@testable import SampleServerApp

final class ManualTimeSource: MonotonicTimeSource, @unchecked Sendable {
    var elapsed: Duration = .zero
}
