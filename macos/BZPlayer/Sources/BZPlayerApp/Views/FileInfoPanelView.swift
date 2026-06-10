import SwiftUI
import AppKit

@MainActor
class FileInfoViewModel: ObservableObject {
    @Published var content: String = ""
    @Published var shouldShow: Bool = false
    @Published var activeLanguage: String = "zh"
    private var panel: FileInfoPanel?

    func showPanel(language: String) {
        self.activeLanguage = language
        if panel == nil {
            let panel = FileInfoPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                       styleMask: [.titled, .closable, .resizable],
                                       backing: .buffered,
                                       defer: false)
            panel.center()
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        panel?.title = Localization.translate("文件信息", for: language)
        panel?.updateContent(content, language: language)
        panel?.makeKeyAndOrderFront(nil)
    }
}

private final class FileInfoPanel: NSPanel {
    func updateContent(_ content: String, language: String) {
        contentView = NSHostingView(rootView: FileInfoPanelView(content: content, language: language))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct FileInfoPanelView: View {
    let content: String
    let language: String
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(content, forType: .string)
                } label: {
                    Label(Localization.translate("复制全部", for: language), systemImage: "doc.on.doc")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            ScrollView {
                Text(content)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }
}
