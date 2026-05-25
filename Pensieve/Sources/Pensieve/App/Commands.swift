import SwiftUI
import UniformTypeIdentifiers

struct PensieveCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: AppController

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("New File…") {
                createNewFile()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Divider()

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

            Divider()

            Button("Reload Preview") {
                appState.requestPreviewRefresh()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(appState.documentSession.document == nil)

            Button(appState.previewAutoReload ? "Pause Auto Reload" : "Resume Auto Reload") {
                appState.previewAutoReload.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        // Format menu — Markdown formatting and font sizing
        CommandMenu("Format") {
            Section {
                Button("Bold") {
                    controller.applyMarkdownFormat(.bold)
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(appState.documentSession.document == nil)

                Button("Italic") {
                    controller.applyMarkdownFormat(.italic)
                }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(appState.documentSession.document == nil)

                Button("Strikethrough") {
                    controller.applyMarkdownFormat(.strike)
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(appState.documentSession.document == nil)

                Button("Quote") {
                    controller.applyMarkdownFormat(.quote)
                }
                .keyboardShortcut("'", modifiers: [.command])
                .disabled(appState.documentSession.document == nil)

                Button("Code") {
                    controller.applyMarkdownFormat(.code)
                }
                .keyboardShortcut("`", modifiers: [.command])
                .disabled(appState.documentSession.document == nil)

                Button("Link") {
                    controller.applyMarkdownFormat(.link)
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(appState.documentSession.document == nil)

                Button("Bulleted List") {
                    controller.applyMarkdownFormat(.bulletedList)
                }
                .keyboardShortcut("8", modifiers: [.command, .shift])
                .disabled(appState.documentSession.document == nil)

                Button("Numbered List") {
                    controller.applyMarkdownFormat(.numberedList)
                }
                .keyboardShortcut("7", modifiers: [.command, .shift])
                .disabled(appState.documentSession.document == nil)
            }

            Divider()

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

    private func createNewFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = markdownContentTypes
        panel.canCreateDirectories = true
        panel.directoryURL = defaultNewFileDirectory()
        panel.nameFieldStringValue = uniqueNewFileName(in: panel.directoryURL)
        panel.prompt = "Create"
        if panel.runModal() == .OK, let url = panel.url {
            controller.createMarkdownFile(url: url)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = markdownContentTypes
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

    private var markdownContentTypes: [UTType] {
        [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown")
        ].compactMap { $0 }
    }

    private func defaultNewFileDirectory() -> URL? {
        if let activeURL = appState.documentSession.url {
            return activeURL.deletingLastPathComponent()
        }
        if let rootURL = appState.workspaceRoots.first?.url {
            return rootURL
        }
        if let openFileURL = appState.openFiles.first?.url {
            return openFileURL.deletingLastPathComponent()
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private func uniqueNewFileName(in directory: URL?) -> String {
        guard let directory else { return "Untitled.md" }

        let fm = FileManager.default
        let base = "Untitled"
        let ext = "md"
        var candidate = "\(base).\(ext)"
        var index = 2

        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(index).\(ext)"
            index += 1
        }

        return candidate
    }
}
