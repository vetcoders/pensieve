import SwiftUI
import UniformTypeIdentifiers

struct PensieveCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: AppController

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("Open File…") {
                openFile()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Open Folder…") {
                openFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Exclude from Workspace…") {
                excludeFromWorkspace()
            }
            .disabled(appState.workspaceRoots.isEmpty)

            Button("Clear Workspace Exclusions") {
                controller.clearWorkspaceExclusions()
            }
            .disabled(appState.excludedWorkspacePaths.isEmpty)

            Divider()

            Button("Save") {
                controller.saveActiveDocument()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(appState.selectedDocument == nil)
        }

        // File menu — replace the default Save/Close group so ⌘W closes the
        // active document session instead of the window itself. Save lives in
        // the .newItem block above; here we only own Close.
        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                controller.closeActiveDocument()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(appState.documentSession.document == nil)
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

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown")
        ].compactMap { $0 }
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            controller.openFile(url: url)
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

    private func excludeFromWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.message = "Choose folders or files inside the current workspace to exclude from import."
        if panel.runModal() == .OK {
            controller.excludeFromWorkspace(urls: panel.urls)
        }
    }
}
