import AppKit
import Foundation

@MainActor
final class LaunchIntentCoordinator: ObservableObject {
  static let shared = LaunchIntentCoordinator()

  private let settleDelayNanoseconds: UInt64
  private weak var controller: AppController?
  private var pendingURLs: [URL] = []
  private var startupTask: Task<Void, Never>?
  private var hasExplicitURLIntent = false

  init(settleDelayNanoseconds: UInt64 = 150_000_000) {
    self.settleDelayNanoseconds = settleDelayNanoseconds
  }

  func startWhenLaunchIntentsSettle(controller: AppController) {
    attach(controller: controller)
    startupTask?.cancel()
    startupTask = Task { @MainActor [weak self, weak controller] in
      guard let self, let controller else { return }
      if self.settleDelayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: self.settleDelayNanoseconds)
      }

      self.drainPendingURLs()
      controller.start(restoringWorkspace: !self.hasExplicitURLIntent)
    }
  }

  func handle(urls: [URL]) {
    guard !urls.isEmpty else { return }

    hasExplicitURLIntent = true
    pendingURLs.append(contentsOf: urls)
    startupTask?.cancel()
    drainPendingURLs()
    controller?.start(restoringWorkspace: false)
  }

  func waitForStartupDecision() async {
    await startupTask?.value
  }

  private func attach(controller: AppController) {
    self.controller = controller
    drainPendingURLs()
  }

  private func drainPendingURLs() {
    guard let controller, !pendingURLs.isEmpty else { return }

    let urls = pendingURLs
    pendingURLs.removeAll()

    let supportedFileURLs = urls.filter(isSupportedLaunchFile)
    let unsupportedURLs = urls.filter { !isSupportedLaunchFile($0) }

    for url in supportedFileURLs {
      controller.openFile(url: url)
    }

    if let firstURL = supportedFileURLs.first {
      controller.selectDocument(id: firstURL.standardizedFileURL)
    }

    for url in unsupportedURLs {
      controller.openFile(url: url)
    }
  }

  private func isSupportedLaunchFile(_ url: URL) -> Bool {
    ["md", "markdown", "txt"].contains(url.pathExtension.lowercased())
  }
}

final class PensieveAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Pensieve owns its own in-app document tabs (`DocumentTabStrip`) backed by a single
    // shared `AppState`/`documentSession`. macOS automatic window tabbing layered a second,
    // native tab bar on top of that — and because every window shares the one session, the
    // native tabs all rendered the same document. Disable automatic tabbing so the only tab
    // surface is the app's own, which actually tracks the active document.
    NSWindow.allowsAutomaticWindowTabbing = false

    // A bare `swift run` executable (no `.app` bundle, e.g. `make run`) launches as a
    // background process: no Dock icon, window stuck behind other apps, can't be brought
    // to the foreground. Force a regular activation policy in that case so the dev build
    // is actually usable. A packaged `.app` already runs as `.regular`, so this is a no-op
    // there — guarded on a nil bundle identifier to keep shipped behavior untouched.
    if Bundle.main.bundleIdentifier == nil {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    Task { @MainActor in
      LaunchIntentCoordinator.shared.handle(urls: urls)
    }
  }
}
