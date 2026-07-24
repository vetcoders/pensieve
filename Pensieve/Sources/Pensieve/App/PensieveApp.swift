import AppKit
import Combine
import SwiftUI

@main
struct PensieveApp: App {
  // RII-B: identifier for the scene-owned cold launcher WindowGroup.
  static let launcherWindowGroupID = "pensieve.launcher"
  @NSApplicationDelegateAdaptor(PensieveAppDelegate.self) private var appDelegate
  // WorkspaceStore is @Observable now → @State, not @StateObject.
  @State private var workspaceStore: WorkspaceStore
  @StateObject private var launchIntentCoordinator: LaunchIntentCoordinator
  @StateObject private var themeManager: ThemeManager
  private let providerSettings: ProviderSettings
  /// The auto-save preference the Settings window edits. The SAME instance the
  /// document store consults, so a flip reaches every open document immediately.
  private let savingSettings: DocumentSavingSettings

  init() {
    // Register the bundled OFL theme fonts into this process's font environment
    // before any view builds. Idempotent and non-fatal — a missing/failed font
    // never blocks launch; the skin CSS fallback chains cover absence.
    BundledFonts.registerOnce()

    let workspaceStore = WorkspaceStore()
    let launchIntentCoordinator = LaunchIntentCoordinator.shared
    let themeManager = ThemeManager()
    providerSettings = ProviderSettings.shared
    savingSettings = DocumentSavingSettings.shared
    _workspaceStore = State(wrappedValue: workspaceStore)
    _launchIntentCoordinator = StateObject(wrappedValue: launchIntentCoordinator)
    _themeManager = StateObject(wrappedValue: themeManager)

    // External-file launches deliberately bypass the value-based WindowGroup.
    // Wire the AppKit factory before AppDelegate's launch fallback so it can
    // materialize the root that will attach a controller and drain those URLs.
    let factory = DocumentWindowFactory(
      workspaceStore: workspaceStore,
      launchIntentCoordinator: launchIntentCoordinator,
      themeManager: themeManager
    )
    DocumentWindowRegistry.shared.makeDocumentWindow = { ref, intent in
      return factory.makeWindow(for: ref, intent: intent)
    }
  }

  var body: some Scene {
    // RII-B — Scene-owned cold launcher (bridge #1). SwiftUI auto-presents the
    // FIRST scene's window at launch, so this id-based (value-less) WindowGroup
    // gives us a launcher window that is scene-owned BY CONSTRUCTION: its root's
    // `focusedSceneValue`/`focusedSceneObject` publish into the owning scene, so
    // `PensieveCommands` (attached here via `.commands`) resolves the exact root
    // AppState/AppController on the first key/main transition — no factory
    // launcher, no manual NSHostingView shell. It carries no `initialDocument`;
    // restoration loads the recovered draft into this same window in place.
    WindowGroup(id: Self.launcherWindowGroupID) {
      DocumentWindowRootView(
        workspaceStore: workspaceStore,
        launchIntentCoordinator: launchIntentCoordinator,
        themeManager: themeManager,
        initialDocument: nil,
        // The scene SwiftUI auto-presents at process start IS the cold launch —
        // the one intent that brings the previous session back whole.
        launchIntent: .coldLaunch
      )
    }
    // Opt OUT of external events here too, not just on the value-based group
    // below. A launcher scene that still claimed Finder/Dock/`open` URL events
    // would let SwiftUI materialize a fresh scene-owned launcher window per
    // event — reviving the detached one-window-per-file path the registry's
    // native-tab merge exists to prevent. With neither scene claiming them,
    // external opens fall through to `application(_:open:)` →
    // LaunchIntentCoordinator → registry tabs.
    .handlesExternalEvents(matching: [])
    .pensieveDocumentWindowChrome()
    .commands {
      PensieveCommands(themeManager: themeManager)
    }

    // The value-based WindowGroup serves any state-restored legacy document
    // scenes (`initialDocument`). Document opens do NOT go through
    // `openWindow(value:)`: DocumentWindowRegistry builds document windows
    // directly in AppKit (DocumentWindowFactory) and attaches them as native
    // tabs before first presentation.
    //
    // No `.commands` here on purpose. SwiftUI assembles ONE app-wide menu bar
    // from the whole scene tree at launch; the `.commands` attached to the
    // primary launcher WindowGroup above already own that single menu bar, so
    // a window restored into THIS group inherits the full Mode/Format/Agents
    // surface — its enabled/disabled state and target follow focus through
    // `CommandSurfaceContext` (Commands.swift), not scene ownership. The
    // menu structure is built from the declaration, so it never depends on a
    // launcher window being open. Re-declaring `PensieveCommands` on this
    // second scene would NOT merge idempotently: `CommandsBuilder` appends
    // per scene, so every `CommandMenu` (Mode/Format/Agents) — and the
    // replaced File groups — would appear TWICE. The single declaration above
    // IS the app-global level that covers both scenes.
    WindowGroup("Pensieve", for: DocumentRef.self) { document in
      DocumentWindowRootView(
        workspaceStore: workspaceStore,
        launchIntentCoordinator: launchIntentCoordinator,
        themeManager: themeManager,
        initialDocument: document.wrappedValue,
        // A scene in this group exists FOR its document, restored or not.
        launchIntent: .explicitDocument
      )
    }
    // Never let SwiftUI spawn a fresh WindowGroup scene per external event:
    // every Finder/Dock/`open` file event was materializing a detached
    // standalone window (bypassing the registry's native-tab merge), one per
    // file. With no scene claiming external events they fall through to
    // `application(_:open:)` → LaunchIntentCoordinator → registry tabs.
    .handlesExternalEvents(matching: [])
    .pensieveDocumentWindowChrome()

    Settings {
      PensieveSettingsView(
        providerSettings: providerSettings,
        savingSettings: savingSettings
      )
    }
  }
}

struct DocumentWindowRootView: View {
  let workspaceStore: WorkspaceStore
  let launchIntentCoordinator: LaunchIntentCoordinator
  let themeManager: ThemeManager
  let initialDocument: DocumentRef?
  /// Why THIS window came into existence. Fixed at construction and never
  /// re-read from shared state, so a second window born a moment later cannot
  /// change what this one restores.
  let launchIntent: LaunchIntent

  // AppState is @Observable now → @State, not @StateObject.
  @State private var appState: AppState
  @StateObject private var controller: AppController
  @State private var loadedInitialDocumentID: DocumentRef.ID?
  @State private var initialDocumentLoadResolved = false
  @State private var currentWindow: NSWindow?

  init(
    workspaceStore: WorkspaceStore,
    launchIntentCoordinator: LaunchIntentCoordinator,
    themeManager: ThemeManager,
    initialDocument: DocumentRef?,
    launchIntent: LaunchIntent
  ) {
    self.workspaceStore = workspaceStore
    self.launchIntentCoordinator = launchIntentCoordinator
    self.themeManager = themeManager
    self.initialDocument = initialDocument
    self.launchIntent = launchIntent

    let appState = AppState(workspaceStore: workspaceStore)
    _appState = State(wrappedValue: appState)
    _controller = StateObject(
      wrappedValue: AppController(appState: appState, importsFoldersInBackground: true))
  }

  var body: some View {
    ContentView(hostWindow: $currentWindow)
      // Every window this app can build — the scene-owned launcher (which is
      // where restoration puts the recovered document), a state-restored
      // WindowGroup scene, and every factory-built native tab — shares THIS
      // root, so declaring the skin's appearance once here is what makes a
      // light skin light on all of them, chrome included.
      .pensieveSkinAppearance(themeManager)
      .environment(appState)
      .environmentObject(controller)
      .environmentObject(controller.transcriptionService)
      .environmentObject(themeManager)
      .focusedSceneValue(\.appState, appState)
      .focusedSceneObject(controller)
      .background(
        DocumentWindowAccessor(
          // Fall back to the scene's initialDocument so the FIRST attach already
          // carries the document identity: the registry can track the window as
          // a document window before the (async) document load finishes,
          // instead of briefly registering a document window as a launcher.
          // The fallback ends once the load resolves — a FAILED load must stop
          // advertising the document so the registry releases its mapping
          // instead of pinning this empty window to the URL forever.
          documentID: DocumentWindowRootView.accessorDocumentID(
            selected: appState.selectedDocumentID,
            initialDocument: initialDocument,
            loadResolved: initialDocumentLoadResolved),
          identity: appState.windowModel.documentIdentity
            ?? DocumentWindowRootView.accessorDocumentID(
              selected: appState.selectedDocumentID,
              initialDocument: initialDocument,
              loadResolved: initialDocumentLoadResolved
            ).map { DocumentIdentity.file($0.standardizedFileURL) },
          title: appState.documentTitle,
          representedURL: appState.documentURL,
          isDirty: appState.documentIsDirty,
          hasEditableBuffer: appState.documentHasEditableBuffer
        ) { window in
          currentWindow = window
          // Publish this window's owning controller so a cross-window "Close
          // from Open Files" routes its dirty guard through this session.
          DocumentWindowRegistry.shared.registerController(controller, for: window)
        }
      )
      .frame(
        minWidth: WindowChromeRecipe.minimumContentSize.width,
        minHeight: WindowChromeRecipe.minimumContentSize.height
      )
      .task {
        // Seed BEFORE any load work: the menu bar must carry Pensieve's
        // commands from the first build, not from the first scene activation.
        // Only seed when nothing has adopted yet — a background root building
        // after the key window must not steal the fallback (the key window owns
        // it via `didBecomeKey` below).
        CommandSurfaceContext.shared.adoptIfUnset(appState: appState, controller: controller)
        configureDocumentRouting()
        if let initialDocument {
          openInitialDocument(initialDocument)
        } else {
          launchIntentCoordinator.startWhenLaunchIntentsSettle(
            controller: controller, intent: launchIntent)
        }
      }
      .onChange(of: initialDocument?.id) { _, _ in
        if let initialDocument {
          initialDocumentLoadResolved = false
          openInitialDocument(initialDocument)
        }
      }
      .onOpenURL { url in
        controller.openFile(url: url)
      }
      // Keep the command-surface fallback pointed at the root the user is
      // actually on. `.task` adopts early so the cold menu bar has content
      // before anything is focusable; from the first key transition onwards
      // the fallback mirrors what `focusedSceneValue` would publish, so the
      // menu never binds to a different window's session during the moments
      // AppKit drops key status (menu tracking, activation churn) and the
      // focused values go silent.
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
        notification in
        guard
          CommandSurfaceAdoption.shouldAdopt(
            rootWindow: currentWindow, keyWindow: notification.object as? NSWindow)
        else { return }
        CommandSurfaceContext.shared.adopt(appState: appState, controller: controller)
      }
      // Second half of the same rule. The accessor above is coalesced and
      // async, so a factory-built native tab is regularly key BEFORE this root
      // knows which window is its own — and `didBecomeKey` has already fired
      // and will not fire again. Without this trigger such a tab never adopts,
      // and the fallback keeps serving the PREVIOUS tab's session.
      .onChange(of: currentWindow) { _, resolvedWindow in
        guard
          CommandSurfaceAdoption.shouldAdopt(
            rootWindow: resolvedWindow, keyWindow: NSApp.keyWindow)
        else { return }
        CommandSurfaceContext.shared.adopt(appState: appState, controller: controller)
      }
      // App-wide save-on-close guard. Every window (factory-built document tab AND
      // state-restored WindowGroup scene) shares this root, and every close
      // trigger — red close button, the tab's "×", the sidebar "Close from Open
      // Files", or ⌘W falling through to a native window close — posts
      // `willCloseNotification` for the closing window. Filtering to THIS window's
      // `currentWindow` flushes only its own session, synchronously, before the
      // window/`AppState` tears down — closing the ≤1.5s autosave-debounce data
      // loss without touching the window delegate SwiftUI owns.
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
        notification in
        guard let closingWindow = notification.object as? NSWindow,
          closingWindow === currentWindow
        else {
          return
        }
        controller.savePendingChangesOnClose()
        CommandSurfaceContext.shared.release(controller: controller)
        DocumentWindowRegistry.shared.unregisterController(for: closingWindow)
      }
  }

  private func configureDocumentRouting() {
    controller.requestOpenDocumentWindow = { ref in
      DocumentWindowRegistry.shared.open(ref)
    }
    // The close confirmation is a sheet on THIS window, not an app-modal
    // alert: ⌘W on one document tab must leave every other document usable.
    controller.hostWindowProvider = { currentWindow }
    controller.requestCloseCurrentWindowIfEmpty = {
      guard !appState.documentSession.hasEditableBuffer else { return }
      DocumentWindowRegistry.shared.closeWindowIfEmptyLauncher(currentWindow)
    }
    // A window that adopted the crash draft holds real work behind no URL, so
    // nothing else would ever reclassify it out of "launcher".
    controller.requestPromoteWindowToContent = {
      guard let currentWindow else { return }
      DocumentWindowRegistry.shared.markWindowAsContent(currentWindow)
    }
    controller.requestLauncherSweepReconcile = {
      DocumentWindowRegistry.shared.reconcileLaunchersAfterRestoreSettled()
    }
  }

  /// Document identity reported to the window registry. Before the initial
  /// load resolves, the scene's `initialDocument` stands in for the not-yet
  /// selected document so the first attaches already carry the identity.
  /// After the load resolved, only the real session state counts: a failed
  /// load (deleted/unreadable recent) leaves `selected` nil and the window
  /// must register as a launcher, releasing the pre-open document mapping.
  static func accessorDocumentID(
    selected: URL?,
    initialDocument: DocumentRef?,
    loadResolved: Bool
  ) -> URL? {
    selected ?? (loadResolved ? nil : initialDocument?.id)
  }

  private func openInitialDocument(_ ref: DocumentRef) {
    guard loadedInitialDocumentID?.standardizedFileURL != ref.id.standardizedFileURL else {
      return
    }
    loadedInitialDocumentID = ref.id.standardizedFileURL
    controller.start(intent: .explicitDocument)
    controller.openFileInCurrentWindow(url: ref.url)
    // openFileInCurrentWindow loads synchronously: on success
    // selectedDocumentID is set, on failure it stays nil. Either way the
    // pre-load fallback has done its job and must stop.
    initialDocumentLoadResolved = true
  }

}
