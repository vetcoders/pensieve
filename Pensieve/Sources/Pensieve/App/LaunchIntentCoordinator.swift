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

    let validMarkdownURLs = urls.filter(WorkspaceScanner.isMarkdownFile)
    let unsupportedURLs = urls.filter { !WorkspaceScanner.isMarkdownFile($0) }

    for url in validMarkdownURLs {
      controller.openFile(url: url)
    }

    if let firstURL = validMarkdownURLs.first {
      controller.selectDocument(id: firstURL.standardizedFileURL)
    }

    for url in unsupportedURLs {
      controller.openFile(url: url)
    }
  }
}

final class PensieveAppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    Task { @MainActor in
      LaunchIntentCoordinator.shared.handle(urls: urls)
    }
  }
}
