import SwiftUI

@main
struct PensieveApp: App {
    @StateObject private var appState: AppState
    @StateObject private var controller: AppController

    init() {
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)
        _controller = StateObject(wrappedValue: AppController(appState: appState))
    }

    var body: some Scene {
        WindowGroup("Pensieve") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(controller)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    IndexDatabase.shared.open(into: appState)
                    controller.restoreLastFolder()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            PensieveCommands(appState: appState, controller: controller)
        }
    }
}
