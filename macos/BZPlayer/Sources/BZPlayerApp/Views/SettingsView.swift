import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var seekSecondsText = ""
    @State private var frameStepText = ""
    @State private var audioDelayStepMsText = ""

    var body: some View {
        ScrollView {
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

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("快捷键")
                        .font(.headline)

                    HStack {
                        Text("左右方向键跳转秒数")
                            .frame(width: 150, alignment: .leading)
                        TextField("秒数", text: $seekSecondsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit(applyShortcutSettings)
                        Stepper("", value: Binding(
                            get: { viewModel.shortcutSeekSeconds },
                            set: { viewModel.setShortcutSeekSeconds($0) }
                        ), in: 0.5...60, step: 0.5)
                        .labelsHidden()
                    }

                    HStack {
                        Text("上下方向键跳转帧数")
                            .frame(width: 150, alignment: .leading)
                        TextField("帧数", text: $frameStepText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit(applyShortcutSettings)
                        Stepper("", value: Binding(
                            get: { viewModel.shortcutFrameStepCount },
                            set: { viewModel.setShortcutFrameStepCount($0) }
                        ), in: 1...240, step: 1)
                        .labelsHidden()
                    }

                    Text("左/右：按设定秒数后退/前进；上/下：按设定帧数后退/前进。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("上一文件快捷键")
                            .frame(width: 150, alignment: .leading)
                        Text("上一")
                        Picker("", selection: Binding(
                            get: { Int(viewModel.previousFileKeyCode) },
                            set: { viewModel.setPreviousFileKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                        Text("下一")
                        Picker("", selection: Binding(
                            get: { Int(viewModel.nextFileKeyCode) },
                            set: { viewModel.setNextFileKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }

                    Text("默认上一文件是 `[`，下一文件是 `]`，按物理键位处理，不受中英文输入影响。速度调节为 `;` 和 `'`。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("音频步进快捷键")
                            .frame(width: 150, alignment: .leading)
                        Text("减小")
                        Picker("", selection: Binding(
                            get: { Int(viewModel.audioStepDownKeyCode) },
                            set: { viewModel.setAudioStepDownKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                        Text("增加")
                        Picker("", selection: Binding(
                            get: { Int(viewModel.audioStepUpKeyCode) },
                            set: { viewModel.setAudioStepUpKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }

                    HStack {
                        Text("倍速切换快捷键")
                            .frame(width: 150, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { Int(viewModel.speedToggleKeyCode) },
                            set: { viewModel.setSpeedToggleKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }

                    Text("默认音频步进为 `,` 和 `.`，倍速切换为 `=`，按物理键位处理。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("打开文件时窗口")
                            .frame(width: 150, alignment: .leading)
                        Picker("打开文件时窗口", selection: Binding(
                            get: { viewModel.windowOpenBehavior },
                            set: { viewModel.setWindowOpenBehavior($0) }
                        )) {
                            ForEach(PlayerViewModel.WindowOpenBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.title).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    Text("默认最大化。尽量大表示按视频比例尽可能铺满屏幕可视区域，不强行加黑边占满。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("允许多窗口", isOn: Binding(
                        get: { viewModel.allowMultipleWindows },
                        set: { viewModel.setAllowMultipleWindows($0) }
                    ))
                    .toggleStyle(.checkbox)

                    Text("关闭后，新打开的文件会直接在当前窗口播放，不另开新窗口。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        
                    Toggle("显示最近播放", isOn: Binding(
                        get: { viewModel.showRecentFiles },
                        set: { viewModel.setShowRecentFiles($0) }
                    ))
                    .toggleStyle(.checkbox)

                    Text("开启后，当没有播放任何文件时，将显示最近播放的文件列表。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("音频延迟步进")
                            .frame(width: 150, alignment: .leading)
                        TextField("ms", text: $audioDelayStepMsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit(applyAudioDelayStepMs)
                        Stepper("", value: Binding(
                            get: { viewModel.audioDelayStepMs },
                            set: { viewModel.setAudioDelayStepMs($0) }
                        ), in: 1...500, step: 10)
                        .labelsHidden()
                        Text("ms")
                    }

                    Text("音频延迟步进决定每次按音频步进快捷键时延迟的增减量，每个文件的延迟值独立记忆。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                }
            }
        }
        .padding(16)
        .frame(width: 1100, height: 920)
        .onAppear {
            syncShortcutFields()
            syncAudioDelayStepField()
        }
        .onChange(of: viewModel.shortcutSeekSeconds) { _ in
            syncShortcutFields()
        }
        .onChange(of: viewModel.shortcutFrameStepCount) { _ in
            syncShortcutFields()
        }
        .onChange(of: viewModel.audioDelayStepMs) { _ in
            syncAudioDelayStepField()
        }
        .onExitCommand {
            NSApp.keyWindow?.close()
        }
    }

    private func syncShortcutFields() {
        seekSecondsText = String(format: "%.1f", viewModel.shortcutSeekSeconds)
        frameStepText = "\(viewModel.shortcutFrameStepCount)"
    }

    private func syncAudioDelayStepField() {
        audioDelayStepMsText = String(format: "%.0f", viewModel.audioDelayStepMs)
    }

    private func applyAudioDelayStepMs() {
        if let step = Double(audioDelayStepMsText), step >= 1 {
            viewModel.setAudioDelayStepMs(step)
        } else {
            audioDelayStepMsText = String(format: "%.0f", viewModel.audioDelayStepMs)
        }
    }

    private func applyShortcutSettings() {
        if let seek = Double(seekSecondsText) {
            viewModel.setShortcutSeekSeconds(seek)
        } else {
            seekSecondsText = String(format: "%.1f", viewModel.shortcutSeekSeconds)
        }

        if let frames = Int(frameStepText) {
            viewModel.setShortcutFrameStepCount(frames)
        } else {
            frameStepText = "\(viewModel.shortcutFrameStepCount)"
        }
    }

    private var keyShortcutOptions: [KeyShortcutOption] {
        [
            .init(label: ";", keyCode: 41),
            .init(label: "'", keyCode: 39),
            .init(label: ",", keyCode: 43),
            .init(label: ".", keyCode: 47),
            .init(label: "/", keyCode: 44),
            .init(label: "[", keyCode: 33),
            .init(label: "]", keyCode: 30),
            .init(label: "-", keyCode: 27),
            .init(label: "=", keyCode: 24),
            .init(label: "\\", keyCode: 42)
        ]
    }
}

private struct KeyShortcutOption {
    let label: String
    let keyCode: UInt16
}
