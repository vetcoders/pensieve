import SwiftUI

@main
struct VCNotesApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("VC Notes") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    IndexDatabase.shared.open(into: appState)
                    FolderManager.shared.restoreLastFolder(into: appState)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            VCNotesCommands(appState: appState)
        }
    }
}
