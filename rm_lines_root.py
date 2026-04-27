import sys

with open("macos/BZPlayer/Sources/BZPlayerApp/PlayerRootView.swift", "r") as f:
    lines = f.readlines()

new_lines = []
skip = False
for i, line in enumerate(lines):
    if line.startswith("struct LongPressSpeedButton: NSViewRepresentable {"):
        skip = True
    if line.startswith("struct PlayerRootView: View {"):
        skip = False
        
    if not skip:
        new_lines.append(line)

with open("macos/BZPlayer/Sources/BZPlayerApp/PlayerRootView.swift", "w") as f:
    f.writelines(new_lines)
