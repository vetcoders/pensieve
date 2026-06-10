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
    WindowGroup("Pensieve", for: DocumentRef.self) { document in
      PensieveWindowRoot(
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

private struct PensieveWindowRoot: View {
  @Environment(\.openWindow) private var openWindow

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
        // carries the document identity: the registry can merge the window
        // into the native tab group before the (async) document load finishes,
        // instead of briefly registering a document window as a launcher.
        documentID: appState.selectedDocumentID ?? initialDocument?.id,
        title: appState.documentSession.displayTitle,
        representedURL: appState.documentSession.url,
        hasEditableBuffer: appState.documentSession.hasEditableBuffer
      ) { window in
        currentWindow = window
        applyStartupPresentation(to: window)
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
        applyStartupPresentation(to: currentWindow)
        openInitialDocument(initialDocument)
        revealStartupWindow()
      }
    }
    .onOpenURL { url in
      controller.openFile(url: url)
    }
  }

  private func configureDocumentRouting() {
    controller.requestOpenDocumentWindow = { ref in
      DocumentWindowRegistry.shared.open(ref) { ref in
        openWindow(value: ref)
      }
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
      if let currentWindow {
        DocumentWindowRegistry.shared.noteWindowContentReady(currentWindow)
      }
      applyStartupPresentation(to: currentWindow)
    }
  }

  private func applyStartupPresentation(to window: NSWindow?) {
    guard let window else { return }
    // A window born to merge into another window's native tab group stays
    // invisible until DocumentWindowRegistry.completeAttach reveals it as a
    // tab; otherwise it flashes standalone for the document-load beat before
    // addTabbedWindow pulls it in.
    if let initialDocument, DocumentWindowRegistry.shared.expectsMerge(for: initialDocument.id) {
      window.alphaValue = 0
      return
    }
    // Only force visibility once the scene content actually renders; touching
    // alpha earlier would re-reveal a suppressed window into a black tab
    // (never-suppressed windows are visible by default anyway).
    guard startupPresentationReady else { return }
    window.alphaValue = 1
  }
}

private struct StartupPresentationView: View {
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
