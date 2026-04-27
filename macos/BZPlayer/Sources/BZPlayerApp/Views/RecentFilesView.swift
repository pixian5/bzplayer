import SwiftUI

struct RecentFilesView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    let containerWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近播放")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 4)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.recentFiles, id: \.self) { path in
                        Button {
                            viewModel.openExternalFiles([URL(fileURLWithPath: path)])
                        } label: {
                            Text(path)
                                .font(.system(size: 26))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: containerWidth * 0.8, height: 400)
        .background(Color.black.opacity(0.75))
        .cornerRadius(12)
        .zIndex(1)
    }
}
