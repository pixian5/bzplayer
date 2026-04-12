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

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.title3)
                .fontWeight(.semibold)

            Text("可通过 ⌘, 打开本页。")
                .foregroundStyle(.secondary)

            Button("关联常见视频格式") {
                viewModel.associateCommonVideoFormats()
            }

            Text(viewModel.fileAssociationStatus)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(16)
        .frame(width: 420, height: 220)
    }
}
