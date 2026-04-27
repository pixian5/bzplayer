import sys

with open("macos/BZPlayer/Sources/BZPlayerApp/BZPlayerApp.swift", "r") as f:
    lines = f.readlines()

new_lines = []
skip = False
for i, line in enumerate(lines):
    if line.startswith("@MainActor\n") and "class FileInfoViewModel" in lines[i+1]:
        skip = True
    if line.startswith("private struct PlayerWindowRootView: View {"):
        skip = False
        
    if line.startswith("private struct SettingsView: View {"):
        skip = True
    if line.startswith("private final class WeakWindowBinding {"):
        skip = False
        
    if not skip:
        new_lines.append(line)

with open("macos/BZPlayer/Sources/BZPlayerApp/BZPlayerApp.swift", "w") as f:
    f.writelines(new_lines)
