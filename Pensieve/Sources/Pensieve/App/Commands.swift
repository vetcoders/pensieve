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

  private final class WeakWindowSurface {
    weak var window: NSWindow?
    weak var appState: AppState?
    weak var controller: AppController?

    init(window: NSWindow, appState: AppState, controller: AppController) {
      self.window = window
      self.appState = appState
      self.controller = controller
    }
  }

  @Published private(set) var appState: AppState?
  @Published private(set) var controller: AppController?
  private var windowSurfaces: [ObjectIdentifier: WeakWindowSurface] = [:]

  /// Adopts a document root as the fallback command target. Always adopted as
  /// a PAIR: a mixed state/controller pair would let a menu action mutate one
  /// window's state through another window's controller.
  func adopt(appState: AppState, controller: AppController) {
    // This signal is intentionally sent even when the pair is unchanged. A
    // window accessor can resolve after the root's early `.task` already
    // adopted the same controller; that later turn is precisely when a New
    // gesture queued during the attach gap becomes safe to replay.
    LaunchIntentCoordinator.shared.commandTargetDidBecomeAvailable(controller)
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

  /// Records the exact document surface behind a native window. Modal error
  /// reporting must resolve through this ownership map rather than through the
  /// most recently adopted fallback: the latter may be a different document
  /// that merely happened to own the menu before a sheet became key.
  func register(appState: AppState, controller: AppController, for window: NSWindow) {
    pruneWindowSurfaces()
    windowSurfaces = windowSurfaces.filter { _, surface in
      surface.controller !== controller
    }
    windowSurfaces[ObjectIdentifier(window)] = WeakWindowSurface(
      window: window,
      appState: appState,
      controller: controller)
  }

  /// Resolves the non-modal document error surface that visibly owns a modal
  /// block. The exact owner wins; key/main are bounded app-global fallbacks for
  /// a standalone application-modal alert. Deliberately never falls back to
  /// `appState`, because that pair is historical command focus, not native
  /// window ownership.
  func reportingAppState(
    blockingOwner: NSWindow?,
    keyWindow: NSWindow?,
    mainWindow: NSWindow?
  ) -> AppState? {
    pruneWindowSurfaces()
    var seen: Set<ObjectIdentifier> = []
    for candidate in [blockingOwner, keyWindow, mainWindow].compactMap({ $0 }) {
      let identifier = ObjectIdentifier(candidate)
      guard seen.insert(identifier).inserted else { continue }
      if let state = windowSurfaces[identifier]?.appState {
        return state
      }
    }
    return nil
  }

  /// Drops the adopted pair when its window closes, so a dead root neither
  /// leaks nor keeps serving menu actions. A no-op when a different root has
  /// already taken over.
  func release(controller: AppController) {
    windowSurfaces = windowSurfaces.filter { _, surface in
      guard surface.window != nil, surface.appState != nil, surface.controller != nil else {
        return false
      }
      return surface.controller !== controller
    }
    guard self.controller === controller else { return }
    appState = nil
    self.controller = nil
  }

  private func pruneWindowSurfaces() {
    windowSurfaces = windowSurfaces.filter { _, surface in
      surface.window != nil && surface.appState != nil && surface.controller != nil
    }
  }
}

/// WHEN a root takes over the fallback. Extracted for the same reason as
/// `CommandTargetResolution`: the rule is "the KEY window's root owns the
/// surface", and it must hold no matter which of the two triggers observes it
/// first.
///
/// Neither trigger alone is sufficient. `didBecomeKey` fires for windows this
/// root does not own, so it must be filtered by identity — but the root learns
/// its own window from the COALESCED, async window accessor, and a
/// factory-built native tab routinely becomes key BEFORE that callback lands.
/// The key notification never repeats, so a root that missed it would leave the
/// fallback pointed at the previously-key tab for the rest of the tab's life:
/// during focus-silent periods every menu action would then mutate the session
/// the user just navigated AWAY from, while the chrome shows the one they are
/// looking at.
enum CommandSurfaceAdoption {
  static func shouldAdopt(rootWindow: NSWindow?, keyWindow: NSWindow?) -> Bool {
    guard let rootWindow, let keyWindow else { return false }
    return rootWindow === keyWindow
  }
}

/// Which window `Shift+Cmd+W` closes. Extracted for the same reason as
/// `CommandSurfaceAdoption`: SwiftUI's `Commands` body cannot be pinned by a
/// test directly, so the target-selection rule is pinned here instead. Mirrors
/// the `keyWindow ?? mainWindow` fallback `DocumentSharing` already uses.
enum CloseWindowTarget {
  static func resolve(keyWindow: NSWindow?, mainWindow: NSWindow?) -> NSWindow? {
    keyWindow ?? mainWindow
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

/// Which command family owns the menu bar. An auxiliary Settings window has
/// precedence over a still-live document fallback: otherwise its key window
/// receives document Save/Mode/Format/Close actions for a background buffer.
enum PensieveCommandSurfaceRoute: Equatable {
  case settings
  case document
  case zeroWindow

  static func resolve(settingsOwnsSurface: Bool, hasDocumentTarget: Bool) -> Self {
    if settingsOwnsSurface { return .settings }
    return hasDocumentTarget ? .document : .zeroWindow
  }
}

/// How the File menu acts when it was built with NO command target — the
/// deliberate zero-window state a Mac document app keeps living in after its
/// last window closes (`Shift+Cmd+W`).
///
/// Every action here funnels into the lanes the app already owns for a window
/// it does not have yet: an open goes through `LaunchIntentCoordinator.handle`,
/// the same entry a Finder/`open`/Dock drop uses, so the coordinator's
/// one-shot host guard covers a menu-driven open too and a launcher already on
/// its way is never doubled; New goes through the registry's single
/// `openDocumentHost(intent:)` factory. Nothing here creates a window by
/// itself.
///
struct ZeroWindowCommandLane {
  var openExternalURLs: @MainActor ([URL]) -> Void = { urls in
    LaunchIntentCoordinator.shared.handle(urls: urls)
  }
  var requestNewDocument: @MainActor () -> Void = {
    LaunchIntentCoordinator.shared.requestNewDocument()
  }

  /// ⌘O, ⇧⌘O and Open Recent. Handed to the coordinator whether or not a root
  /// exists: `handle(urls:)` routes to the focused window when there is one and
  /// materializes exactly one host when there is not — the same double-open and
  /// one-shot guards an external open relies on.
  @MainActor
  func open(urls: [URL]) {
    guard !urls.isEmpty else { return }
    openExternalURLs(urls)
  }

  /// ⌘N / ⌘T. The coordinator resolves the controller again at action time and
  /// counts the gesture while a host is attaching. One `.newUntitledTab` host
  /// consumes the first request; rapid later requests are replayed as native
  /// tabs rather than being dropped or spawning competing roots.
  @MainActor
  func newDocument() {
    requestNewDocument()
  }
}

/// The native pickers the File menu opens. Shared by the live and the
/// zero-window command surfaces so both offer exactly the same file types and
/// the same prompts — a second copy is how the two menus drift apart.
enum DocumentOpenPanel {
  static var markdownContentTypes: [UTType] {
    [
      UTType(filenameExtension: "md"),
      UTType(filenameExtension: "markdown"),
      .plainText,
    ].compactMap { $0 }
  }

  static var documentImportContentTypes: [UTType] {
    [UTType(filenameExtension: "docx"), .pdf].compactMap { $0 }
  }

  static var openableContentTypes: [UTType] {
    markdownContentTypes + documentImportContentTypes
  }

  @MainActor
  static func chooseFileToOpen() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = openableContentTypes
    panel.prompt = "Open"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  @MainActor
  static func chooseFolderToOpen() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}

/// Commands that belong to the APPLICATION rather than to one document root.
/// Their lane stays installed while the process has zero windows and during a
/// focused-value rebuild, so About remains Pensieve's BuildIdentity surface and
/// ⌘Q can never fall back to SwiftUI's unguarded default termination command.
struct ApplicationCommandLane {
  var resolveTermination: @MainActor () -> NSApplication.TerminateReply = {
    DocumentWindowRegistry.shared.resolveTerminationRequest()
  }
  var terminate: @MainActor () -> Void = {
    NSApplication.shared.terminate(nil)
  }
  var showAbout: @MainActor () -> Void = {
    PensieveAboutPanel.show()
  }
  var showSettings:
    @MainActor (PensieveSettingsSection) -> PensieveSettingsPresentationResult = { section in
    PensieveSettingsWindowController.shared.show(section: section)
  }

  @discardableResult
  @MainActor
  func openSettings() -> PensieveSettingsPresentationResult {
    showSettings(.general)
  }

  @MainActor
  func quit() {
    guard resolveTermination() == .terminateNow else { return }
    terminate()
  }
}

@MainActor
private enum PensieveAboutPanel {
  static func show() {
    let identity = BuildIdentity.current
    let alert = NSAlert()
    alert.messageText = identity.aboutTitle
    alert.informativeText = identity.aboutDetails
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

private struct GlobalPensieveCommands: Commands {
  var lane = ApplicationCommandLane()

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Pensieve") {
        lane.showAbout()
      }
    }

    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        lane.openSettings()
      }
      .keyboardShortcut(",", modifiers: [.command])
    }

    CommandGroup(replacing: .appTermination) {
      Button("Quit Pensieve") {
        lane.quit()
      }
      .keyboardShortcut("q", modifiers: [.command])
    }
  }
}

struct PensieveCommands: Commands {
  @FocusedValue(\.appState) private var focusedAppState: AppState?
  @FocusedObject private var focusedController: AppController?
  @ObservedObject var themeManager: ThemeManager
  @ObservedObject private var surface = CommandSurfaceContext.shared
  @ObservedObject private var settingsController = PensieveSettingsWindowController.shared

  var body: some Commands {
    GlobalPensieveCommands()

    let target = CommandTargetResolution.resolve(
      focusedState: focusedAppState,
      focusedController: focusedController,
      fallbackState: surface.appState,
      fallbackController: surface.controller
    )
    switch PensieveCommandSurfaceRoute.resolve(
      settingsOwnsSurface: settingsController.ownsCommandSurface,
      hasDocumentTarget: target != nil)
    {
    case .settings:
      // Settings is auxiliary, but the application-level File/New/Open lane
      // remains useful. Its own Close command replaces the document close
      // family, while Mode/Format/Agents stay absent because no document
      // command collection is installed in this branch.
      DocumentlessFileCommands(recentDocuments: RecentDocumentsStore.shared)
      SettingsWindowCommands(controller: settingsController)
    case .document:
      if let target {
      ActivePensieveCommands(
        appState: target.state,
        controller: target.controller,
        themeManager: themeManager,
        recentDocuments: target.controller.recentDocuments
      )
      }
    case .zeroWindow:
      // Closing the last window leaves the process alive on purpose, and every
      // item above needs a document root to act on — so the whole File menu used
      // to vanish with it: no New, no Open, no Open Recent, and ⌘N/⌘O/⌘T dead.
      // A Mac document app keeps a working File menu with zero windows; this is
      // that menu, and it is the ONLY branch that runs without a root.
      DocumentlessFileCommands(recentDocuments: RecentDocumentsStore.shared)
    }
  }
}

private struct SettingsWindowCommands: Commands {
  @ObservedObject var controller: PensieveSettingsWindowController

  private var lane: SettingsWindowCommandLane {
    SettingsWindowCommandLane {
      controller.close()
    }
  }

  var body: some Commands {
    CommandGroup(replacing: .saveItem) {
      Button("Close Settings") {
        lane.close()
      }
      .keyboardShortcut("w", modifiers: [.command])
    }
  }
}

/// Action-time target for Settings' ⌘W. Keeping the closure independent of a
/// document controller makes the critical shortcut directly testable without
/// ordering a native Settings fixture on screen.
struct SettingsWindowCommandLane {
  var closeSettings: @MainActor () -> Void

  @MainActor
  func close() {
    closeSettings()
  }
}

/// The application-owned File/New/Open lane used whenever the KEY command
/// surface is not a document — both the true zero-window state and Settings.
/// Deliberately a subset: every item that acts ON a document (Save, Export,
/// Close, Format, Mode, Agents) needs a foreground document session.
/// Application-global About and protected Quit live in
/// `GlobalPensieveCommands`; Settings adds its own Close family alongside this
/// lane.
private struct DocumentlessFileCommands: Commands {
  @ObservedObject var recentDocuments: RecentDocumentsStore
  var lane = ZeroWindowCommandLane()

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New File") {
        lane.newDocument()
      }
      .keyboardShortcut("n", modifiers: [.command])

      Button("New Tab") {
        lane.newDocument()
      }
      .keyboardShortcut("t", modifiers: [.command])

      Divider()

      Button("Open File…") {
        guard let url = DocumentOpenPanel.chooseFileToOpen() else { return }
        lane.open(urls: [url])
      }
      .keyboardShortcut("o", modifiers: [.command])

      Menu("Open Recent") {
        ForEach(recentDocuments.recentDocuments, id: \.self) { url in
          Button(RecentDocumentsStore.menuTitle(for: url)) {
            lane.open(urls: [url])
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

      Button("Open Folder…") {
        guard let url = DocumentOpenPanel.chooseFolderToOpen() else { return }
        lane.open(urls: [url])
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
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
    // File menu
    CommandGroup(replacing: .newItem) {
      Button("New File") {
        controller.createUntitledDocument()
      }
      .keyboardShortcut("n", modifiers: [.command])

      Button("New Tab") {
        controller.createUntitledDocument()
      }
      .keyboardShortcut("t", modifiers: [.command])

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

    // File menu — replace the default Save/Close group so ⌘W closes the
    // active document session instead of the window itself. Save lives in
    // the .newItem block above; here we only own Close.
    CommandGroup(replacing: .saveItem) {
      Button("Close") {
        controller.closeActiveDocument()
      }
      .keyboardShortcut("w", modifiers: [.command])
      .disabled(!appState.documentHasEditableBuffer)

      Button("Close Window") {
        closeKeyWindow()
      }
      .keyboardShortcut("w", modifiers: [.command, .shift])
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

      Toggle(
        "Show All Files",
        isOn: Binding(
          get: { appState.showAllFilesInSidebar },
          set: { appState.showAllFilesInSidebar = $0 }
        )
      )
      .accessibilityIdentifier("pensieve.sidebar.showAllFiles.menuToggle")

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
    if appState.documentSession.isUntitled
      && appState.documentSession.recoverySourceURL == nil
    {
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
    guard let url = DocumentOpenPanel.chooseFileToOpen() else { return }
    // The File menu is an explicit document-open gesture, just like Open
    // Recent and Finder/Dock opens. Let the controller reuse an idle window
    // or route to the existing/new native tab; loading in place here would
    // replace a live document before the tab policy gets a chance to act.
    controller.openFile(url: url)
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
    guard let url = DocumentOpenPanel.chooseFolderToOpen() else { return }
    controller.openFolder(url: url)
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

  private var markdownContentTypes: [UTType] { DocumentOpenPanel.markdownContentTypes }

  private var documentImportContentTypes: [UTType] {
    DocumentOpenPanel.documentImportContentTypes
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

  /// `Shift+Cmd+W` — closes the key window exactly like the red button: via
  /// `performClose`, which routes through `windowShouldClose` and therefore the
  /// unsaved-work guard. Files stay in Open Files (window-close is a tidying
  /// gesture, not a document-close); no DocumentStore mutation happens here.
  private func closeKeyWindow() {
    CloseWindowTarget.resolve(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)?
      .performClose(nil)
  }

  private func showFindBar(replace: Bool) {
    appState.findReplaceMode = replace
    appState.findBarVisible = true
    appState.findFocusToken &+= 1
  }

}
