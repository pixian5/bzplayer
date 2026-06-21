import AppKit

@MainActor
struct InputDispatcher {
    let viewModel: PlayerViewModel

    func handleKeyEvent(_ event: NSEvent, in window: NSWindow?) -> Bool {
        // 空格键
        if event.keyCode == 49 {
            viewModel.togglePause()
            return true
        }
        // Cmd+W
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.keyCode == 13 {
            viewModel.closeCurrentFile()
            return true
        }
        // Cmd+C
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.keyCode == 8 {
            viewModel.copyCurrentOrSelectedFilesToClipboard()
            return true
        }
        // Cmd+O
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.keyCode == 31 {
            viewModel.openFile()
            return true
        }
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option) else {
            return false
        }
        // 可配置快捷键 - 在 switch 之前处理
        if event.keyCode == viewModel.audioStepDownKeyCode {
            viewModel.adjustAudioDelay(by: -viewModel.audioDelayStepMs)
            return true
        }
        if event.keyCode == viewModel.audioStepUpKeyCode {
            viewModel.adjustAudioDelay(by: viewModel.audioDelayStepMs)
            return true
        }
        if event.keyCode == viewModel.speedToggleKeyCode {
            if !event.isARepeat {
                viewModel.toggleSpeed()
            }
            return true
        }
        switch event.keyCode {
        case 51: // Backspace / Delete
            viewModel.deleteCurrentFileAndTrash()
            return true
        case 123:
            viewModel.seekBy(seconds: -viewModel.shortcutSeekSeconds)
            return true
        case 124:
            viewModel.seekBy(seconds: viewModel.shortcutSeekSeconds)
            return true
        case 125:
            viewModel.seekByConfiguredFrameStep(-1)
            return true
        case 126:
            viewModel.seekByConfiguredFrameStep(1)
            return true
        case 41: // Semicolon ;
            // 在 ClickCaptureView 中处理长按
            return true
        case 39: // Quote '
            // 在 ClickCaptureView 中处理长按
            return true
        case 27: // Left bracket [
            viewModel.adjustAudioDelay(by: -50)
            return true
        case 29: // Right bracket ]
            viewModel.adjustAudioDelay(by: 50)
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers {
        case "1": viewModel.setSpeedForNumericKey(1); return true
        case "2": viewModel.setSpeedForNumericKey(2); return true
        case "3": viewModel.setSpeedForNumericKey(3); return true
        case "4": viewModel.setSpeedForNumericKey(4); return true
        case "5": viewModel.setSpeedForNumericKey(5); return true
        case "6": viewModel.setSpeedForNumericKey(6); return true
        case "7": viewModel.setSpeedForNumericKey(7); return true
        case "8": viewModel.setSpeedForNumericKey(8); return true
        case "9": viewModel.setSpeedForNumericKey(9); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            viewModel.toggleFullscreen(in: window)
            return true
        default:
            if event.keyCode == viewModel.previousFileKeyCode {
                if !event.isARepeat {
                    viewModel.previousFile()
                }
                return true
            }
            if event.keyCode == viewModel.nextFileKeyCode {
                if !event.isARepeat {
                    viewModel.nextFile()
                }
                return true
            }
        }
        return false
    }
}
