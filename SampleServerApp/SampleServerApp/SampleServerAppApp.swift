import SwiftUI

@main
struct SampleServerAppApp: App {
    @State private var viewModel = CompositionRoot().makeServerViewModel()

    var body: some Scene {
        WindowGroup {
            ServerView(viewModel: viewModel)
        }
    }
}
