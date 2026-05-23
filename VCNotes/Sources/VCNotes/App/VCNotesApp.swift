import SwiftUI

@main
struct VCNotesApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("VC Notes") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            VCNotesCommands(appState: appState)
        }
    }
}
