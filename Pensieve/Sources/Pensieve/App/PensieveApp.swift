import SwiftUI

@main
struct PensieveApp: App {
  @StateObject private var appState: AppState
  @StateObject private var controller: AppController
  @StateObject private var themeManager: ThemeManager

  init() {
    let appState = AppState()
    _appState = StateObject(wrappedValue: appState)
    _controller = StateObject(
      wrappedValue: AppController(appState: appState, importsFoldersInBackground: true))
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
          controller.start()
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
