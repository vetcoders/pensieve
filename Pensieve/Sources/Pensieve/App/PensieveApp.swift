import SwiftUI

@main
struct PensieveApp: App {
  @NSApplicationDelegateAdaptor(PensieveAppDelegate.self) private var appDelegate
  @StateObject private var appState: AppState
  @StateObject private var controller: AppController
  @StateObject private var launchIntentCoordinator: LaunchIntentCoordinator
  @StateObject private var themeManager: ThemeManager

  init() {
    let appState = AppState()
    _appState = StateObject(wrappedValue: appState)
    _controller = StateObject(
      wrappedValue: AppController(appState: appState, importsFoldersInBackground: true))
    _launchIntentCoordinator = StateObject(wrappedValue: LaunchIntentCoordinator.shared)
    _themeManager = StateObject(wrappedValue: ThemeManager())
  }

  var body: some Scene {
    WindowGroup("Pensieve") {
      ContentView()
        .environmentObject(appState)
        .environmentObject(controller)
        .environmentObject(themeManager)
        .frame(minWidth: 720, minHeight: 480)
        .task {
          launchIntentCoordinator.startWhenLaunchIntentsSettle(controller: controller)
        }
        .onOpenURL { url in
          launchIntentCoordinator.handle(urls: [url])
        }
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: true))
    .defaultSize(width: 1180, height: 760)
    .windowResizability(.contentMinSize)
    .commands {
      PensieveCommands(appState: appState, controller: controller)
    }
  }
}
