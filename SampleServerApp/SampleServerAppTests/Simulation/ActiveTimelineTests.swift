import Testing
@testable import SampleServerApp

@Suite(.serialized) struct ActiveTimelineTests {
    @Test func pauseExcludesInterval() {
        var timeline = ActiveTimeline()
        timeline.pause(at: .seconds(10))
        timeline.resume(at: .seconds(20))
        let elapsed = timeline.activeElapsed(at: .seconds(30))
        #expect(elapsed == .seconds(20))
    }

    @Test func doublePauseAndResumeAreIdempotent() {
        var timeline = ActiveTimeline()
        timeline.pause(at: .seconds(5))
        timeline.pause(at: .seconds(6))
        timeline.resume(at: .seconds(10))
        timeline.resume(at: .seconds(11))
        #expect(timeline.activeElapsed(at: .seconds(15)) == .seconds(10))
    }

    @Test func activeElapsedDoesNotMoveWhilePaused() {
        var timeline = ActiveTimeline()
        timeline.pause(at: .seconds(5))
        #expect(timeline.activeElapsed(at: .seconds(100)) == .seconds(5))
    }
}
