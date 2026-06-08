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
    ContentView()
      .environmentObject(appState)
      .environmentObject(controller)
      .environmentObject(controller.transcriptionService)
      .environmentObject(themeManager)
      .focusedSceneObject(appState)
      .focusedSceneObject(controller)
      .background(
        DocumentWindowAccessor(
          documentID: appState.selectedDocumentID,
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
        } else {
          launchIntentCoordinator.startWhenLaunchIntentsSettle(controller: controller)
        }
      }
      .onChange(of: initialDocument?.id) { _ in
        if let initialDocument {
          openInitialDocument(initialDocument)
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
      currentWindow?.close()
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
}
