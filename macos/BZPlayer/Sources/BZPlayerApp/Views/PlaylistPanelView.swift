import SwiftUI

struct PlaylistPanelView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var shouldShowPlaylist: Bool
    @Binding var isHoveringPlaylist: Bool
    @Binding var hoveredPlaylistIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("播放列表")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    viewModel.togglePlaylistOrder()
                } label: {
                    Text(viewModel.playlistOrder.buttonTitle)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .focusable(false)

                Button {
                    viewModel.cycleLoopMode()
                } label: {
                    Text(viewModel.loopMode.buttonTitle)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .focusable(false)
            }

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(viewModel.playlist.enumerated()), id: \.offset) { index, url in
                            let filename = url.lastPathComponent
                            let shouldExpand = hoveredPlaylistIndex == index && shouldShowHoverHint(for: filename, at: index)

                            HStack(alignment: .top) {
                                Text(filename)
                                    .lineLimit(shouldExpand ? nil : 1)
                                    .fixedSize(horizontal: false, vertical: shouldExpand)
                                Spacer()
                                if index == viewModel.currentIndex {
                                    Image(systemName: "play.fill")
                                }
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == viewModel.currentIndex ? Color.blue.opacity(0.35) : Color.clear)
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                            .id(index)
                            .onTapGesture {
                                viewModel.selectPlaylistItem(index)
                            }
                            .onHover { hovering in
                                if hovering, shouldShowHoverHint(for: filename, at: index) {
                                    hoveredPlaylistIndex = index
                                } else if hoveredPlaylistIndex == index {
                                    hoveredPlaylistIndex = nil
                                }
                            }
                        }
                    }
                }
                .task(id: viewModel.currentIndex) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(viewModel.currentIndex, anchor: .center)
                    }
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(viewModel.currentIndex, anchor: .center)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 600)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.85))
        .cornerRadius(10)
        .onHover { hovering in
            isHoveringPlaylist = hovering
            if hovering {
                shouldShowPlaylist = true
            } else {
                hoveredPlaylistIndex = nil
            }
        }
    }

    private func shouldShowHoverHint(for filename: String, at index: Int) -> Bool {
        let font = NSFont.systemFont(ofSize: 13)
        let measured = (filename as NSString).size(withAttributes: [.font: font]).width
        let baseAvailable: CGFloat = 520
        let iconReserved: CGFloat = index == viewModel.currentIndex ? 18 : 0
        let available = max(baseAvailable - iconReserved, 380)
        return measured > available
    }
}
