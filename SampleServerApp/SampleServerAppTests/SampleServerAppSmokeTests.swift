import Testing
@testable import SampleServerApp

@MainActor
@Suite(.serialized) struct SampleServerAppSmokeTests {
    @Test func compositionRootBuildsViewModel() {
        let viewModel = CompositionRoot().makeServerViewModel()
        #expect(viewModel.phase == .stopped)
    }
}
