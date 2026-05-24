import SwiftUI

struct PensieveCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: AppController

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Save") {
                controller.saveActiveDocument()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(appState.selectedDocument == nil)
        }

        // Mode menu - editor modes and reading preferences
        CommandMenu("Mode") {
            ForEach(EditorMode.allCases) { mode in
                Button("\(mode.label) Mode") {
                    controller.setMode(mode)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(mode.rawValue)")), modifiers: [.command])
            }

            Divider()

            Button(appState.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                controller.toggleSidebar()
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])

            Button(appState.richMarkdownEnabled ? "Disable Rich Markdown" : "Enable Rich Markdown") {
                controller.toggleRichMarkdown()
            }
            .keyboardShortcut("/", modifiers: [.command])
        }

        // Format menu — font sizing
        CommandMenu("Format") {
            Button("Bigger Font") {
                controller.bumpFontSize(by: 1)
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Smaller Font") {
                controller.bumpFontSize(by: -1)
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("Reset Font") {
                controller.resetFontSize()
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
            controller.openFolder(url: url)
        }
    }
}
