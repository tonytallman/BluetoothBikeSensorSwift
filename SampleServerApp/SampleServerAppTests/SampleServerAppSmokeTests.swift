import Testing
@testable import SampleServerApp

@MainActor
@Suite struct SampleServerAppSmokeTests {
    @Test func compositionRootBuildsViewModel() {
        let viewModel = CompositionRoot().makeServerViewModel()
        #expect(viewModel.phase == .stopped)
    }
}
