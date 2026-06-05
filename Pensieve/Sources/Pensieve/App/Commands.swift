import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PensieveCommands: Commands {
  @FocusedObject private var appState: AppState?
  @FocusedObject private var controller: AppController?

  var body: some Commands {
    if let appState, let controller {
      ActivePensieveCommands(appState: appState, controller: controller)
    }
  }
}

private struct ActivePensieveCommands: Commands {
  @ObservedObject var appState: AppState
  @ObservedObject var controller: AppController

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Pensieve") {
        showAboutPanel()
      }
    }

    // File menu
    CommandGroup(replacing: .newItem) {
      Button("New File…") {
        controller.createUntitledDocument()
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

      Button("New Folder") {
        createFolder()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(defaultNewFileDirectory() == nil)

      Divider()

      Button("Exclude from Workspace…") {
        excludeFromWorkspace()
      }
      .disabled(appState.workspaceRoots.isEmpty)

      Button("Clear Workspace Exclusions") {
        controller.clearWorkspaceExclusions()
      }
      .disabled(appState.excludedWorkspacePaths.isEmpty)

      Button("Close Folder") {
        controller.closeWorkspace()
      }
      .keyboardShortcut("w", modifiers: [.command, .shift])
      .disabled(appState.workspaceRoots.isEmpty)

      Divider()

      Button("Save") {
        saveActiveDocument()
      }
      .keyboardShortcut("s", modifiers: [.command])
      .disabled(!appState.documentSession.hasEditableBuffer)

      Button("Save As…") {
        saveActiveDocumentAs()
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(!appState.documentSession.hasEditableBuffer)

      Button("Share…") {
        DocumentSharing.share(session: appState.documentSession)
      }
      .keyboardShortcut("s", modifiers: [.command, .control])
      .disabled(!appState.documentSession.hasEditableBuffer)

      Divider()

      Button("Rename") {
        requestSidebarRename()
      }
      .keyboardShortcut(.return, modifiers: [])
      .disabled(sidebarActionTargetURL == nil)

      Button("Duplicate") {
        duplicateSidebarTarget()
      }
      .keyboardShortcut("d", modifiers: [.command])
      .disabled(sidebarActionTargetURL == nil)

      Button("Move to Trash") {
        moveSidebarTargetToTrash()
      }
      .keyboardShortcut(.delete, modifiers: [.command])
      .disabled(sidebarActionTargetURL == nil)
    }

    CommandGroup(replacing: .appTermination) {
      Button("Quit Pensieve") {
        if controller.applicationShouldTerminate() {
          NSApplication.shared.terminate(nil)
        }
      }
      .keyboardShortcut("q", modifiers: [.command])
    }

    // File menu — replace the default Save/Close group so ⌘W closes the
    // active document session instead of the window itself. Save lives in
    // the .newItem block above; here we only own Close.
    CommandGroup(replacing: .saveItem) {
      Button("Close") {
        controller.closeActiveDocument()
      }
      .keyboardShortcut("w", modifiers: [.command])
      .disabled(!appState.documentSession.hasEditableBuffer)
    }

    // Edit menu — Find & Replace routes into Pensieve's own squared find bar.
    // The text field remains native NSSearchField, but NSTextFinder's system
    // bar is intentionally bypassed so the layout belongs to the app surface.
    CommandGroup(after: .textEditing) {
      Divider()

      Button("Find…") {
        showFindBar(replace: false)
      }
      .keyboardShortcut("f", modifiers: [.command])

      Button("Find and Replace…") {
        showFindBar(replace: true)
      }
      .keyboardShortcut("f", modifiers: [.command, .option])

      Button("Find Next") {
        appState.pendingFindCommand = FindBarCommand(action: .next)
      }
      .keyboardShortcut("g", modifiers: [.command])

      Button("Find Previous") {
        appState.pendingFindCommand = FindBarCommand(action: .previous)
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])

      Button("Use Selection for Find") {
        showFindBar(replace: false)
        appState.pendingFindCommand = FindBarCommand(action: .useSelection)
      }
      .keyboardShortcut("e", modifiers: [.command])
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
      .disabled(!appState.documentSession.hasEditableBuffer)

      Button(appState.previewAutoReload ? "Pause Auto Reload" : "Resume Auto Reload") {
        appState.previewAutoReload.toggle()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    // Tab navigation (Quick Win)
    CommandGroup(after: .windowArrangement) {
      Button("Show Next Tab") {
        controller.selectNextTab()
      }
      .keyboardShortcut("]", modifiers: [.command, .shift])

      Button("Show Previous Tab") {
        controller.selectPreviousTab()
      }
      .keyboardShortcut("[", modifiers: [.command, .shift])
    }

    // Format menu — Markdown formatting and font sizing
    CommandMenu("Format") {
      Section {
        Button("Bold") {
          controller.applyMarkdownFormat(.bold)
        }
        .keyboardShortcut("b", modifiers: [.command])
        .disabled(!appState.documentSession.hasEditableBuffer)

        Button("Italic") {
          controller.applyMarkdownFormat(.italic)
        }
        .keyboardShortcut("i", modifiers: [.command])
        .disabled(!appState.documentSession.hasEditableBuffer)

        Button("Strikethrough") {
          controller.applyMarkdownFormat(.strike)
        }
        .keyboardShortcut("x", modifiers: [.command, .shift])
        .disabled(!appState.documentSession.hasEditableBuffer)

        Button("Quote") {
          controller.applyMarkdownFormat(.quote)
        }
        .keyboardShortcut("'", modifiers: [.command])
        .disabled(!appState.documentSession.hasEditableBuffer)

        Button("Code") {
          controller.applyMarkdownFormat(.code)
        }
        .keyboardShortcut("`", modifiers: [.command])
        .disabled(!appState.documentSession.hasEditableBuffer)

        Button("Link") {
          controller.applyMarkdownFormat(.link)
        }
        .keyboardShortcut("k", modifiers: [.command])
        .disabled(!appState.documentSession.hasEditableBuffer)

        Button("Bulleted List") {
          controller.applyMarkdownFormat(.bulletedList)
        }
        .keyboardShortcut("8", modifiers: [.command, .shift])
        .disabled(!appState.documentSession.hasEditableBuffer)

        Button("Numbered List") {
          controller.applyMarkdownFormat(.numberedList)
        }
        .keyboardShortcut("7", modifiers: [.command, .shift])
        .disabled(!appState.documentSession.hasEditableBuffer)

        Button("Tidy Table") {
          controller.tidyTable()
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!appState.documentSession.hasEditableBuffer)
      }

      Divider()

      Button(appState.tableTidyOnPaste ? "Pause Tidy Table on Paste" : "Resume Tidy Table on Paste")
      {
        appState.tableTidyOnPaste.toggle()
      }

      Button(appState.asciiSafeTables ? "Disable ASCII-Safe Tables" : "Enable ASCII-Safe Tables") {
        appState.asciiSafeTables.toggle()
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

  private func saveActiveDocument() {
    if appState.documentSession.isUntitled {
      saveActiveDocumentAs()
    } else {
      controller.saveActiveDocument()
    }
  }

  private func saveActiveDocumentAs() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = markdownContentTypes
    panel.canCreateDirectories = true
    panel.directoryURL = defaultNewFileDirectory()
    panel.nameFieldStringValue = defaultSaveFileName(in: panel.directoryURL)
    panel.prompt = "Save"
    if panel.runModal() == .OK, let url = panel.url {
      controller.saveActiveDocument(as: url)
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

  private func createFolder() {
    guard let directory = defaultNewFileDirectory() else { return }
    controller.createFolder(url: directory.appendingPathComponent("New Folder"))
  }

  private func requestSidebarRename() {
    guard let url = sidebarActionTargetURL else { return }
    appState.pendingSidebarRenameURL = url.standardizedFileURL
  }

  private func duplicateSidebarTarget() {
    guard let url = sidebarActionTargetURL else { return }
    controller.duplicateItem(url: url)
  }

  private func moveSidebarTargetToTrash() {
    guard let url = sidebarActionTargetURL else { return }
    if isDirectory(url) {
      let alert = NSAlert()
      alert.messageText = "Move \(url.lastPathComponent) to Trash?"
      alert.informativeText = "This folder and its contents will move to the system Trash."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Move to Trash")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    controller.moveItemToTrash(url: url)
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
      UTType(filenameExtension: "markdown"),
      .plainText,
    ].compactMap { $0 }
  }

  private var sidebarActionTargetURL: URL? {
    appState.sidebarFocusedURL
      ?? appState.documentSession.url
      ?? appState.selectedDocumentID
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func defaultNewFileDirectory() -> URL? {
    if let focusedURL = appState.sidebarFocusedURL {
      if isDirectory(focusedURL) {
        return focusedURL
      }
      return focusedURL.deletingLastPathComponent()
    }
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

  private func defaultSaveFileName(in directory: URL?) -> String {
    if let url = appState.documentSession.url {
      return url.lastPathComponent
    }
    guard let directory else { return appState.documentSession.displayTitle }

    let fm = FileManager.default
    let base = appState.documentSession.displayTitle
      .replacingOccurrences(of: ".md", with: "")
      .replacingOccurrences(of: ".markdown", with: "")
      .replacingOccurrences(of: ".txt", with: "")
    let ext = "md"
    var candidate = "\(base).\(ext)"
    var index = 2

    while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
      candidate = "\(base) \(index).\(ext)"
      index += 1
    }

    return candidate
  }

  private func showFindBar(replace: Bool) {
    appState.findReplaceMode = replace
    appState.findBarVisible = true
    appState.findFocusToken &+= 1
  }

  private func showAboutPanel() {
    let identity = BuildIdentity.current
    let alert = NSAlert()
    alert.messageText = identity.aboutTitle
    alert.informativeText = identity.aboutDetails
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
