import sys

with open("macos/BZPlayer/Sources/BZPlayerApp/PlayerViewModel.swift", "r") as f:
    content = f.read()

lines = content.split('\n')
new_lines = []
skip = False
for line in lines:
    if line.startswith("private func formatBitrate(_ bitsPerSecond: Float) -> String {"):
        skip = True
        
    if not skip:
        new_lines.append(line)

with open("macos/BZPlayer/Sources/BZPlayerApp/PlayerViewModel.swift", "w") as f:
    f.write('\n'.join(new_lines))
