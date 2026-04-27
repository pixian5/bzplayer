import SwiftUI

struct ControlBarView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Binding var seekValue: Double
    @Binding var isHoveringControlBar: Bool
    let revealControlsAndScheduleHide: () -> Void
    let setControlsVisible: (Bool) -> Void
    let cancelHide: () -> Void
    let scheduleHide: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                        .padding(.horizontal, 2)

                    Slider(value: Binding(
                        get: { seekValue },
                        set: { newValue in
                            revealControlsAndScheduleHide()
                            seekValue = newValue
                            viewModel.seek(to: newValue)
                        }
                    ), in: 0...1)
                    .tint(.blue)
                    .accentColor(.blue)
                    .frame(minWidth: 280)
                }

                Text("\(format(viewModel.currentTime)) / \(format(viewModel.duration))")
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 8) {
                Button("打开文件") {
                    revealControlsAndScheduleHide()
                    viewModel.openFile()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Text("速度：")

                ForEach(viewModel.speedCandidates, id: \.self) { speed in
                    Button("\(speed, specifier: "%g")x") {
                        revealControlsAndScheduleHide()
                        viewModel.setSpeed(speed)
                    }
                    .buttonStyle(.bordered)
                    .tint(abs(viewModel.speed - speed) < 0.001 ? .blue : .gray)
                }

                LongPressSpeedButton(label: "-0.25x", delta: -0.25) { delta in
                    revealControlsAndScheduleHide()
                    viewModel.adjustSpeed(by: delta)
                }
                LongPressSpeedButton(label: "+0.25x", delta: 0.25) { delta in
                    revealControlsAndScheduleHide()
                    viewModel.adjustSpeed(by: delta)
                }

                Text(String(format: "当前：%.2fx", viewModel.speed))

                Button {
                    viewModel.toggleMute()
                } label: {
                    Image(systemName: viewModel.isMuted || viewModel.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Slider(value: Binding(
                    get: { viewModel.volume },
                    set: { viewModel.setVolume($0) }
                ), in: 0...100)
                .frame(width: 80)
                .foregroundStyle(.white)

                Text(String(format: "%.0f%%", viewModel.volume))
                    .foregroundStyle(.white)
                    .frame(width: 35, alignment: .trailing)

                Divider()
                    .frame(height: 20)
                    .background(Color.white.opacity(0.3))

                Spacer()
                Button {
                    viewModel.switchPlaybackBackend()
                } label: {
                    Text(viewModel.playbackEngineStatus)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .focusable(false)
        .onHover { hovering in
            isHoveringControlBar = hovering
            if hovering {
                cancelHide()
                setControlsVisible(true)
            } else {
                scheduleHide()
            }
        }
    }

    private func format(_ time: Double) -> String {
        guard time.isFinite, time > 0 else { return "00:00" }
        let total = Int(time)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
