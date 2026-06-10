import AppKit
import SwiftUI

@main
struct PensieveApp: App {
  @NSApplicationDelegateAdaptor(PensieveAppDelegate.self) private var appDelegate
  @StateObject private var workspaceStore: WorkspaceStore
  @StateObject private var launchIntentCoordinator: LaunchIntentCoordinator
  @StateObject private var themeManager: ThemeManager

  init() {
    _workspaceStore = StateObject(wrappedValue: WorkspaceStore())
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
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: true))
    .defaultSize(width: 1180, height: 760)
    .windowResizability(.contentMinSize)
    .commands {
      PensieveCommands(themeManager: themeManager)
    }
  }
}

struct DocumentWindowRootView: View {
  let workspaceStore: WorkspaceStore
  let launchIntentCoordinator: LaunchIntentCoordinator
  let themeManager: ThemeManager
  let initialDocument: DocumentRef?

  @StateObject private var appState: AppState
  @StateObject private var controller: AppController
  @State private var loadedInitialDocumentID: DocumentRef.ID?
  @State private var currentWindow: NSWindow?
  @State private var startupPresentationReady = false

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
    _appState = StateObject(wrappedValue: appState)
    _controller = StateObject(
      wrappedValue: AppController(appState: appState, importsFoldersInBackground: true))
  }

  var body: some View {
    ZStack {
      ContentView()
        .opacity(startupPresentationReady ? 1 : 0)
        .allowsHitTesting(startupPresentationReady)

      if !startupPresentationReady {
        StartupPresentationView()
      }
    }
    .environmentObject(appState)
    .environmentObject(controller)
    .environmentObject(controller.transcriptionService)
    .environmentObject(themeManager)
    .focusedSceneObject(appState)
    .focusedSceneObject(controller)
    .background(
      DocumentWindowAccessor(
        // Fall back to the scene's initialDocument so the FIRST attach already
        // carries the document identity: the registry can track the window as
        // a document window before the (async) document load finishes,
        // instead of briefly registering a document window as a launcher.
        documentID: appState.selectedDocumentID ?? initialDocument?.id,
        title: appState.documentSession.displayTitle,
        representedURL: appState.documentSession.url,
        hasEditableBuffer: appState.documentSession.hasEditableBuffer
      ) { window in
        currentWindow = window
      }
    )
    .frame(minWidth: 720, minHeight: 480)
    .task {
      configureDocumentRouting()
      if let initialDocument {
        openInitialDocument(initialDocument)
        revealStartupWindow()
      } else {
        launchIntentCoordinator.startWhenLaunchIntentsSettle(controller: controller) {
          revealStartupWindow()
        }
      }
    }
    .onChange(of: initialDocument?.id) { _ in
      if let initialDocument {
        startupPresentationReady = false
        openInitialDocument(initialDocument)
        revealStartupWindow()
      }
    }
    .onOpenURL { url in
      controller.openFile(url: url)
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

  private func openInitialDocument(_ ref: DocumentRef) {
    guard loadedInitialDocumentID?.standardizedFileURL != ref.id.standardizedFileURL else {
      return
    }
    loadedInitialDocumentID = ref.id.standardizedFileURL
    controller.start(restoringWorkspace: false)
    controller.openFileInCurrentWindow(url: ref.url)
  }

  private func revealStartupWindow() {
    DispatchQueue.main.async {
      startupPresentationReady = true
    }
  }
}

struct StartupPresentationView: View {
  var body: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)

      Text("Pensieve")
        .font(.headline)
        .foregroundStyle(.secondary)

      Text(BuildIdentity.current.conciseLabel)
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(NSColor.windowBackgroundColor))
    .accessibilityIdentifier("pensieve.startupPresentation")
  }
}
