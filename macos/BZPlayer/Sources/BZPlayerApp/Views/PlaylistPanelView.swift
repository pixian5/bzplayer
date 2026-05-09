import SwiftUI

struct PlaylistPanelView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var shouldShowPlaylist: Bool
    @Binding var isHoveringPlaylist: Bool
    @Binding var hoveredPlaylistIndex: Int?

    @State private var visibleDurations: Set<URL> = []
    @State private var selectedIndices: Set<Int> = []
    @State private var lastClickedIndex: Int? = nil
    @State private var selectionClearTaskID: UUID = UUID()


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
                            let hasDuration = visibleDurations.contains(url)
                            let durationText = hasDuration ? (viewModel.playlistDurations[url].map { " [\(formatSeconds($0))]" } ?? " [...]") : ""

                            HStack(alignment: .top) {
                                Text(filename + durationText)
                                    .lineLimit(shouldExpand ? nil : 1)
                                    .fixedSize(horizontal: false, vertical: shouldExpand)
                                Spacer()
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == viewModel.currentIndex ? Color.blue.opacity(0.35) : (selectedIndices.contains(index) ? Color.white.opacity(0.2) : Color.clear))
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                            .id(index)
                            .onTapGesture {
                                let flags = NSApp.currentEvent?.modifierFlags ?? []
                                let isShift = flags.contains(.shift)
                                let isCtrl = flags.contains(.control) || flags.contains(.command)

                                if isCtrl {
                                    if selectedIndices.contains(index) {
                                        selectedIndices.remove(index)
                                    } else {
                                        selectedIndices.insert(index)
                                        lastClickedIndex = index
                                    }
                                } else if isShift {
                                    if let last = lastClickedIndex {
                                        let minIndex = min(last, index)
                                        let maxIndex = max(last, index)
                                        selectedIndices.formUnion(minIndex...maxIndex)
                                    } else {
                                        selectedIndices.insert(index)
                                    }
                                    lastClickedIndex = index
                                } else {
                                    selectedIndices.removeAll()
                                    lastClickedIndex = index
                                    viewModel.selectPlaylistItem(index)
                                    return
                                }

                                if !selectedIndices.isEmpty {
                                    Task {
                                        var totalDuration: Double = 0
                                        for i in selectedIndices {
                                            guard i >= 0 && i < viewModel.playlist.count else { continue }
                                            let u = viewModel.playlist[i]
                                            await viewModel.fetchPlaylistDuration(for: u)
                                            if let d = viewModel.playlistDurations[u] {
                                                totalDuration += d
                                            }
                                        }
                                        let currentTaskID = UUID()
                                        selectionClearTaskID = currentTaskID
                                        viewModel.toastMessage = "选中 \(selectedIndices.count) 个文件，总时长: \(formatSeconds(totalDuration))"
                                        viewModel.showToast = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                            if selectionClearTaskID == currentTaskID {
                                                viewModel.showToast = false
                                                selectedIndices.removeAll()
                                            }
                                        }
                                    }
                                }
                            }
                            .onHover { hovering in
                                if hovering, shouldShowHoverHint(for: filename, at: index) {
                                    hoveredPlaylistIndex = index
                                } else if hoveredPlaylistIndex == index {
                                    hoveredPlaylistIndex = nil
                                }
                            }
                            .contextMenu {
                                Button("打开文件位置") {
                                    viewModel.revealInFinder(url: url)
                                }
                                Button("显示文件时长") {
                                    visibleDurations.insert(url)
                                    Task {
                                        await viewModel.fetchPlaylistDuration(for: url)
                                    }
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
