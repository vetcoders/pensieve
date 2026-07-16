import AppKit
import Combine
import SwiftUI

@main
struct PensieveApp: App {
  @NSApplicationDelegateAdaptor(PensieveAppDelegate.self) private var appDelegate
  // WorkspaceStore is @Observable now → @State, not @StateObject.
  @State private var workspaceStore: WorkspaceStore
  @StateObject private var launchIntentCoordinator: LaunchIntentCoordinator
  @StateObject private var themeManager: ThemeManager
  private let providerSettings: ProviderSettings

  init() {
    providerSettings = ProviderSettings.shared
    _workspaceStore = State(wrappedValue: WorkspaceStore())
    _launchIntentCoordinator = StateObject(wrappedValue: LaunchIntentCoordinator.shared)
    _themeManager = StateObject(wrappedValue: ThemeManager())
  }

  var body: some Scene {
    // The WindowGroup scene serves the launcher window and any state-restored
    // legacy document scenes (`initialDocument`). Document opens do NOT go
    // through `openWindow(value:)` anymore: DocumentWindowRegistry builds
    // document windows directly in AppKit (DocumentWindowFactory) and attaches
    // them as native tabs before first presentation.
    WindowGroup("Pensieve", for: DocumentRef.self) { document in
      DocumentWindowRootView(
        workspaceStore: workspaceStore,
        launchIntentCoordinator: launchIntentCoordinator,
        themeManager: themeManager,
        initialDocument: document.wrappedValue
      )
    }
    // Never let SwiftUI spawn a fresh WindowGroup scene per external event:
    // every Finder/Dock/`open` file event was materializing a detached
    // standalone window (bypassing the registry's native-tab merge), one per
    // file. With no scene claiming external events they fall through to
    // `application(_:open:)` → LaunchIntentCoordinator → registry tabs.
    .handlesExternalEvents(matching: [])
    .pensieveDocumentWindowChrome()
    .commands {
      PensieveCommands(themeManager: themeManager)
    }

    Settings {
      ProviderSettingsView(settings: providerSettings)
    }
  }
}

struct DocumentWindowRootView: View {
  let workspaceStore: WorkspaceStore
  let launchIntentCoordinator: LaunchIntentCoordinator
  let themeManager: ThemeManager
  let initialDocument: DocumentRef?

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
    initialDocument: DocumentRef?
  ) {
    self.workspaceStore = workspaceStore
    self.launchIntentCoordinator = launchIntentCoordinator
    self.themeManager = themeManager
    self.initialDocument = initialDocument

    let appState = AppState(workspaceStore: workspaceStore)
    _appState = State(wrappedValue: appState)
    _controller = StateObject(
      wrappedValue: AppController(appState: appState, importsFoldersInBackground: true))
  }

  var body: some View {
    ContentView()
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
          title: appState.documentTitle,
          representedURL: appState.documentURL,
          hasEditableBuffer: appState.documentHasEditableBuffer
        ) { window in
          currentWindow = window
        }
      )
      .frame(
        minWidth: WindowChromeRecipe.minimumContentSize.width,
        minHeight: WindowChromeRecipe.minimumContentSize.height
      )
      .task {
        configureDocumentRouting()
        if let initialDocument {
          openInitialDocument(initialDocument)
        } else {
          launchIntentCoordinator.startWhenLaunchIntentsSettle(controller: controller)
        }
      }
      .onChange(of: initialDocument?.id) { _ in
        if let initialDocument {
          initialDocumentLoadResolved = false
          openInitialDocument(initialDocument)
        }
      }
      .onOpenURL { url in
        controller.openFile(url: url)
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
      }
  }

  private func configureDocumentRouting() {
    let factory = DocumentWindowFactory(
      workspaceStore: workspaceStore,
      launchIntentCoordinator: launchIntentCoordinator,
      themeManager: themeManager
    )
    DocumentWindowRegistry.shared.makeDocumentWindow = { ref in
      factory.makeWindow(for: ref)
    }
    controller.requestOpenDocumentWindow = { ref in
      DocumentWindowRegistry.shared.open(ref)
    }
    controller.requestCloseCurrentWindowIfEmpty = {
      guard !appState.documentSession.hasEditableBuffer else { return }
      DocumentWindowRegistry.shared.closeWindowIfEmptyLauncher(currentWindow)
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
    controller.start(restoringWorkspace: false)
    controller.openFileInCurrentWindow(url: ref.url)
    // openFileInCurrentWindow loads synchronously: on success
    // selectedDocumentID is set, on failure it stays nil. Either way the
    // pre-load fallback has done its job and must stop.
    initialDocumentLoadResolved = true
  }

}
