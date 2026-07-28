import AppKit
import SwiftUI
import UniformTypeIdentifiers

// AppState is @Observable, so it cannot ride @FocusedObject (Combine-only).
// Expose it as a typed FocusedValue instead; PensieveApp publishes it via
// `.focusedSceneValue(\.appState, appState)`. AppController stays
// ObservableObject and keeps @FocusedObject / .focusedSceneObject.
private struct AppStateFocusedValueKey: FocusedValueKey {
  typealias Value = AppState
}

extension FocusedValues {
  var appState: AppState? {
    get { self[AppStateFocusedValueKey.self] }
    set { self[AppStateFocusedValueKey.self] = newValue }
  }
}

/// App-level fallback owner of the command surface.
///
/// `focusedSceneValue`/`focusedSceneObject` publish only while a scene is
/// ACTIVE. A cold launch that has not been activated yet — and the gap between
/// activation and SwiftUI's next menu rebuild while the main thread is still
/// busy with startup — therefore evaluates `PensieveCommands` with nil focus,
/// which yields an EMPTY command set: SwiftUI installs its default menu bar and
/// `Mode`/`Format`/`Agents` plus every app File item are absent entirely.
/// Measured: no menu rebuild happens at all until `didBecomeActive`.
///
/// Menu-bar structure must not depend on activation timing, so every document
/// root adopts itself here and the commands fall back to the most recently
/// adopted root while focus is silent. Focus still wins whenever it resolves,
/// so the multi-window contract (commands act on the FOCUSED window's state)
/// is unchanged — the fallback only fills the window in which no scene is
/// focused and therefore no menu click can reach the app anyway.
@MainActor
final class CommandSurfaceContext: ObservableObject {
  static let shared = CommandSurfaceContext()

  @Published private(set) var appState: AppState?
  @Published private(set) var controller: AppController?

  /// Adopts a document root as the fallback command target. Always adopted as
  /// a PAIR: a mixed state/controller pair would let a menu action mutate one
  /// window's state through another window's controller.
  func adopt(appState: AppState, controller: AppController) {
    guard self.appState !== appState || self.controller !== controller else { return }
    self.appState = appState
    self.controller = controller
  }

  /// Seeds the fallback ONLY when nothing has adopted yet. The cold menu bar
  /// needs *a* root before any window is key, so the first root's early
  /// build-time `.task` adopts here. But a later BACKGROUND root's `.task` can
  /// run after the actual key window has already adopted — with unconditional
  /// adoption it would steal the surface, and during the focus-silent periods
  /// this fallback covers, menu actions would target that background document
  /// instead of the visible key one. Restricting early adoption to the
  /// no-fallback case keeps the key window (via `didBecomeKey`) authoritative.
  func adoptIfUnset(appState: AppState, controller: AppController) {
    guard self.controller == nil else { return }
    adopt(appState: appState, controller: controller)
  }

  /// Drops the adopted pair when its window closes, so a dead root neither
  /// leaks nor keeps serving menu actions. A no-op when a different root has
  /// already taken over.
  func release(controller: AppController) {
    guard self.controller === controller else { return }
    appState = nil
    self.controller = nil
  }
}

/// Which root the menu bar acts on. Extracted so the pair-consistency rule is
/// pinned by tests rather than by reading the `if let` chain below.
enum CommandTargetResolution {
  static func resolve<State: AnyObject, Controller: AnyObject>(
    focusedState: State?,
    focusedController: Controller?,
    fallbackState: State?,
    fallbackController: Controller?
  ) -> (state: State, controller: Controller)? {
    if let focusedState, let focusedController {
      return (focusedState, focusedController)
    }
    guard let fallbackState, let fallbackController else { return nil }
    return (fallbackState, fallbackController)
  }
}

struct PensieveCommands: Commands {
  @FocusedValue(\.appState) private var focusedAppState: AppState?
  @FocusedObject private var focusedController: AppController?
  @ObservedObject var themeManager: ThemeManager
  @ObservedObject private var surface = CommandSurfaceContext.shared

  var body: some Commands {
    if let target = CommandTargetResolution.resolve(
      focusedState: focusedAppState,
      focusedController: focusedController,
      fallbackState: surface.appState,
      fallbackController: surface.controller
    ) {
      ActivePensieveCommands(
        appState: target.state,
        controller: target.controller,
        themeManager: themeManager,
        recentDocuments: target.controller.recentDocuments
      )
    }
  }
}

private struct ActivePensieveCommands: Commands {
  // @Observable AppState observed via a plain stored property.
  var appState: AppState
  @ObservedObject var controller: AppController
  @ObservedObject var themeManager: ThemeManager
  @ObservedObject var recentDocuments: RecentDocumentsStore

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

      Menu("Open Recent") {
        ForEach(recentDocuments.recentDocuments, id: \.self) { url in
          Button(RecentDocumentsStore.menuTitle(for: url)) {
            controller.openRecentDocument(url: url)
          }
        }

        if !recentDocuments.recentDocuments.isEmpty {
          Divider()
        }

        Button("Clear Menu") {
          recentDocuments.clear()
        }
        .disabled(recentDocuments.recentDocuments.isEmpty)
      }

      Button("Import Word or PDF…") {
        importDocument()
      }

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
      .disabled(!appState.documentHasEditableBuffer)

      Button("Save As…") {
        saveActiveDocumentAs()
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(!appState.documentHasEditableBuffer)

      Button("Share…") {
        DocumentSharing.share(session: appState.documentSession)
      }
      .keyboardShortcut("s", modifiers: [.command, .control])
      .disabled(!appState.documentHasEditableBuffer)

      Button("Export HTML…") {
        DocumentExport.exportHTML(
          session: appState.documentSession,
          theme: themeManager.current,
          fontSize: appState.fontSize,
          themeManager: themeManager
        )
      }
      .disabled(!appState.documentHasEditableBuffer)

      Button("Export PDF…") {
        DocumentExport.exportPDF(
          session: appState.documentSession,
          theme: themeManager.current,
          fontSize: appState.fontSize,
          themeManager: themeManager
        )
      }
      .disabled(!appState.documentHasEditableBuffer)

      Button("Export Word (.docx)…") {
        DocumentExport.exportDOCX(
          session: appState.documentSession,
          theme: themeManager.current,
          fontSize: appState.fontSize,
          themeManager: themeManager
        )
      }
      .disabled(!appState.documentHasEditableBuffer)

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
      .disabled(!appState.documentHasEditableBuffer)
    }

    CommandGroup(after: .toolbar) {
      Toggle(
        "AI Autocomplete",
        isOn: Binding(
          get: { appState.aiAutocompleteEnabled },
          set: { appState.aiAutocompleteEnabled = $0 }
        )
      )
      .accessibilityIdentifier("pensieve.autocomplete.menuToggle")

      Button("Show/Hide Tab Bar") {
        NSApp.sendAction(#selector(NSWindow.toggleTabBar(_:)), to: nil, from: nil)
      }
      .disabled(NSApp.keyWindow == nil && NSApp.mainWindow == nil)
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
      .disabled(!appState.documentHasEditableBuffer)

      Button(appState.previewAutoReload ? "Pause Auto Reload" : "Resume Auto Reload") {
        appState.previewAutoReload.toggle()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])

      Toggle(
        "Scroll Sync",
        isOn: Binding(
          get: { appState.scrollSyncEnabled },
          set: { appState.scrollSyncEnabled = $0 }
        )
      )
      .disabled(!appState.documentHasEditableBuffer)
      .accessibilityIdentifier("pensieve.scrollSync.menuToggle")
    }

    // Tab navigation (Quick Win)
    CommandGroup(after: .windowArrangement) {
      Button(dictationMenuTitle) {
        controller.toggleTranscriptionTafla()
      }
      .keyboardShortcut("d", modifiers: [.command, .option])
      .accessibilityIdentifier("pensieve.dictation.menu.windowToggle")

      Divider()

      Button("Show Next Tab") {
        controller.selectNextTab()
      }
      .keyboardShortcut("]", modifiers: [.command, .shift])

      Button("Show Previous Tab") {
        controller.selectPreviousTab()
      }
      .keyboardShortcut("[", modifiers: [.command, .shift])
    }

    // Agents menu — every item opens the SAME configuration sheet as the
    // toolbar ✈ (one gateway: subject + workflow/agent/root pickers + explicit
    // Dispatch confirmation). A menu click never launches a run by itself; it
    // only preselects the clicked workflow for the ACTIVE document.
    // Sandboxed (App Store) build: items stay visible but disabled — dispatch
    // spawns external processes the sandbox forbids (SandboxCapabilities).
    CommandMenu("Agents") {
      Button("Dispatch Document to Agent…") {
        controller.requestCurrentDocumentDispatch(workflow: "implement", source: .agentsMenu)
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(
        !appState.documentHasEditableBuffer
          || !SandboxCapabilities.allowsExternalAgentDispatch()
      )
      .accessibilityIdentifier("pensieve.agents.menu.dispatchDocument")

      Menu("Dispatch Document with Workflow") {
        ForEach(controller.agentWorkflows, id: \.self) { workflow in
          Button("\(workflow)…") {
            controller.requestCurrentDocumentDispatch(
              workflow: workflow, source: .agentsWorkflowMenu)
          }
        }
      }
      .disabled(
        !appState.documentHasEditableBuffer
          || !SandboxCapabilities.allowsExternalAgentDispatch()
      )
      .accessibilityIdentifier("pensieve.agents.menu.dispatchDocumentWorkflow")

      if !SandboxCapabilities.allowsExternalAgentDispatch() {
        Section {
          Text(SandboxCapabilities.dispatchUnavailableExplanation)
        }
      }
    }

    // Format menu — Markdown formatting and font sizing. Menu items route
    // through the wrapper-string surface `formatSelection(with:)` (the legacy
    // MarkdownEditor contract); it resolves into the same
    // `applyMarkdownFormat` funnel the toolbar strip calls with typed cases.
    CommandMenu("Format") {
      Section {
        Button("Bold") {
          controller.formatSelection(with: "**")
        }
        .keyboardShortcut("b", modifiers: [.command])
        .disabled(!appState.documentHasEditableBuffer)

        Button("Italic") {
          controller.formatSelection(with: "*")
        }
        .keyboardShortcut("i", modifiers: [.command])
        .disabled(!appState.documentHasEditableBuffer)

        Button("Strikethrough") {
          controller.formatSelection(with: "~~")
        }
        .keyboardShortcut("x", modifiers: [.command, .shift])
        .disabled(!appState.documentHasEditableBuffer)

        Button("Quote") {
          controller.formatSelection(with: ">")
        }
        .keyboardShortcut("'", modifiers: [.command])
        .disabled(!appState.documentHasEditableBuffer)

        Button("Code") {
          controller.formatSelection(with: "`")
        }
        .keyboardShortcut("`", modifiers: [.command])
        .disabled(!appState.documentHasEditableBuffer)

        Button("Link") {
          controller.formatSelection(with: "[]()")
        }
        .keyboardShortcut("k", modifiers: [.command])
        .disabled(!appState.documentHasEditableBuffer)

        Button("Bulleted List") {
          controller.formatSelection(with: "-")
        }
        .keyboardShortcut("8", modifiers: [.command, .shift])
        .disabled(!appState.documentHasEditableBuffer)

        Button("Numbered List") {
          controller.formatSelection(with: "1.")
        }
        .keyboardShortcut("7", modifiers: [.command, .shift])
        .disabled(!appState.documentHasEditableBuffer)

        Button("Tidy Table") {
          controller.tidyTable()
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!appState.documentHasEditableBuffer)
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
    panel.allowedContentTypes = openableContentTypes
    panel.prompt = "Open"
    if panel.runModal() == .OK, let url = panel.url {
      controller.openFileInCurrentWindow(url: url)
    }
  }

  private func importDocument() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = documentImportContentTypes
    panel.prompt = "Import"
    panel.message = "Word and text-based PDF files open as unsaved Markdown drafts."
    if panel.runModal() == .OK, let url = panel.url {
      controller.importDocument(url: url)
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
    Task { await controller.moveItemToTrash(url: url) }
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

  private var documentImportContentTypes: [UTType] {
    [UTType(filenameExtension: "docx"), .pdf].compactMap { $0 }
  }

  private var openableContentTypes: [UTType] {
    markdownContentTypes + documentImportContentTypes
  }

  private var sidebarActionTargetURL: URL? {
    appState.sidebarFocusedURL
      ?? appState.documentURL
      ?? appState.selectedDocumentID
  }

  private var dictationMenuTitle: String {
    controller.isTranscriptionTaflaVisible
      ? "Hide Dictation"
      : "Show Dictation"
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
