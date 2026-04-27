import sys

with open("macos/BZPlayer/Sources/BZPlayerApp/PlayerRootView.swift", "r") as f:
    content = f.read()

# Replace recentFilesView call
content = content.replace("recentFilesView(containerWidth: proxy.size.width)", "RecentFilesView(containerWidth: proxy.size.width)")

# Replace playlistPanel call
playlist_replacement = """PlaylistPanelView(
                        shouldShowPlaylist: $shouldShowPlaylist,
                        isHoveringPlaylist: $isHoveringPlaylist,
                        hoveredPlaylistIndex: $hoveredPlaylistIndex
                    )"""
content = content.replace("playlistPanel", playlist_replacement, 1)

# Replace controlBar call
controlbar_replacement = """ControlBarView(
                seekValue: $seekValue,
                isHoveringControlBar: $isHoveringControlBar,
                revealControlsAndScheduleHide: revealControlsAndScheduleHide,
                setControlsVisible: setControlsVisible,
                cancelHide: cancelHide,
                scheduleHide: scheduleHide
            )"""
content = content.replace("controlBar", controlbar_replacement, 1)

# Remove the private vars and funcs
lines = content.split('\n')
new_lines = []
skip = False
for line in lines:
    if line.startswith("    private var playlistPanel: some View {"):
        skip = True
    elif line.startswith("    private func recentFilesView(containerWidth: CGFloat) -> some View {"):
        skip = True
    elif line.startswith("    private var controlBar: some View {"):
        skip = True
    elif line.startswith("    private func format(_ time: Double) -> String {"):
        skip = True
    elif line.startswith("    private func shouldShowHoverHint(for filename: String, at index: Int) -> Bool {"):
        skip = True
    elif line.startswith("    private func revealControlsAndScheduleHide() {") and skip:
        # We reached the end of the removed blocks
        skip = False
        
    if not skip:
        new_lines.append(line)

with open("macos/BZPlayer/Sources/BZPlayerApp/PlayerRootView.swift", "w") as f:
    f.write('\n'.join(new_lines))
