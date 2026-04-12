import SwiftUI

@main
struct BZPlayerApp: App {
    @StateObject private var viewModel = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            PlayerRootView()
                .environmentObject(viewModel)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
