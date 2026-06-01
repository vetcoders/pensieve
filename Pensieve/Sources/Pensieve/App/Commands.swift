import SwiftUI

struct PensieveCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Save") {
                NotificationCenter.default.post(name: .vcSaveActiveDocument, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(appState.selectedDocument == nil)
        }

        // Mode menu - editor modes and reading preferences
        CommandMenu("Mode") {
            ForEach(EditorMode.allCases) { mode in
                Button("\(mode.label) Mode") {
                    appState.mode = mode
                }
                .keyboardShortcut(KeyEquivalent(Character("\(mode.rawValue)")), modifiers: [.command])
            }

            Divider()

            Button(appState.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                appState.sidebarVisible.toggle()
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])

            Button(appState.richMarkdownEnabled ? "Disable Rich Markdown" : "Enable Rich Markdown") {
                appState.richMarkdownEnabled.toggle()
            }
            .keyboardShortcut("/", modifiers: [.command])
        }

        // Format menu — font sizing
        CommandMenu("Format") {
            Button("Bigger Font") {
                appState.bumpFontSize(by: 1)
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Smaller Font") {
                appState.bumpFontSize(by: -1)
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("Reset Font") {
                appState.resetFontSize()
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            NotificationCenter.default.post(
                name: .vcOpenFolder,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }
}

extension Notification.Name {
    static let vcOpenFolder = Notification.Name("Pensieve.openFolder")
    static let vcSaveActiveDocument = Notification.Name("Pensieve.saveActiveDocument")
    static let vcDocumentChanged = Notification.Name("Pensieve.documentChanged")
}
