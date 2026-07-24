import AppKit
import Foundation

@MainActor
final class LaunchIntentCoordinator: ObservableObject {
  static let shared = LaunchIntentCoordinator()

  typealias StartupDecisionHandler = @MainActor () -> Void

  private let settleDelayNanoseconds: UInt64
  private weak var controller: AppController?
  private var pendingURLs: [URL] = []
  private var startupTask: Task<Void, Never>?
  private var startupDecisionHandler: StartupDecisionHandler?
  private var hasExplicitURLIntent = false

  /// One-way switch set by `quiesceForTermination()`.
  ///
  /// Cancelling `startupTask` is not enough on its own, and never was. The task's only suspension is
  /// `try? await Task.sleep(...)`, so a cancellation raised there is SWALLOWED by the `try?` and the
  /// body runs on to `controller.start` regardless — and with the production settle delay of 0 the
  /// body has no suspension point at all, so a cancel issued before it is scheduled cannot stop it
  /// either. The latch is what actually stops it. It is ONE-WAY because
  /// `startWhenLaunchIntentsSettle` re-arms the task on every call: a lone cancel would be undone by
  /// the next scene that settles, which during a quit is a scene the pumped run loop can still build.
  private var isQuiescedForTermination = false

  init(settleDelayNanoseconds: UInt64 = 0) {
    self.settleDelayNanoseconds = settleDelayNanoseconds
  }

  /// Termination command, issued by `TerminationSequence` in the quiescence phase (see the phase Q
  /// inventory there — this type is a member of it, not a second owner of the phase state).
  ///
  /// This coordinator is a producer OF producers: `controller.start` restores the workspace and
  /// creates fresh validation, build, watcher, manifest and index work. Left alive, a startup task
  /// that has not settled yet runs inside the quit's own pumped run loop and rebuilds exactly what
  /// phase Q has just stopped — and a manifest/cache commit that lands while its post-latch index
  /// write is refused leaves the launch metadata ahead of FTS for the next cold start's skip
  /// decision.
  ///
  /// Idempotent, and nothing may re-arm afterwards — which is what keeps the drain that follows a
  /// wait for a FINITE set of work rather than a target this coordinator keeps moving.
  func quiesceForTermination() {
    isQuiescedForTermination = true
    startupTask?.cancel()
    startupTask = nil
    startupDecisionHandler = nil
    pendingURLs.removeAll()
  }

  /// Starts `controller` once any launch URLs have settled. `intent` is the one
  /// the window was BUILT with; a file-open event that arrives before the
  /// settle upgrades this single launch to `.explicitDocument` — the window is
  /// showing that file, so it must not also restore a session around it.
  func startWhenLaunchIntentsSettle(
    controller: AppController,
    intent: LaunchIntent,
    onStartupDecision: @escaping StartupDecisionHandler = {}
  ) {
    guard !isQuiescedForTermination else { return }
    attach(controller: controller)
    startupDecisionHandler = onStartupDecision
    startupTask?.cancel()
    startupTask = Task { @MainActor [weak self, weak controller] in
      guard let self, let controller else { return }
      if self.settleDelayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: self.settleDelayNanoseconds)
      }

      // Re-checked HERE, after the settle, and not only at arming time. This is the window the
      // arming guard cannot cover: the task was armed while the app was running and is scheduled to
      // run later, so the quit that arrives in between reaches it only through this check. See
      // `isQuiescedForTermination` for why the `cancel()` above does not close it.
      guard !self.isQuiescedForTermination else { return }

      self.drainPendingURLs()
      controller.start(intent: self.hasExplicitURLIntent ? .explicitDocument : intent)
      self.finishStartupDecision()
    }
  }

  func handle(urls: [URL]) {
    // Same latch, same reason: this path calls `controller.start` too, and `application(_:open:)`
    // hands the URLs over through a `Task`, so a Finder/Dock open that arrives as the app is quitting
    // lands inside the pumped run loop.
    guard !isQuiescedForTermination else { return }
    guard !urls.isEmpty else { return }

    hasExplicitURLIntent = true
    pendingURLs.append(contentsOf: urls)
    startupTask?.cancel()
    drainPendingURLs()
    controller?.start(intent: .explicitDocument)
    if controller != nil {
      finishStartupDecision()
    }
  }

  func waitForStartupDecision() async {
    await startupTask?.value
  }

  private func attach(controller: AppController) {
    self.controller = controller
    drainPendingURLs()
  }

  private func finishStartupDecision() {
    let handler = startupDecisionHandler
    startupDecisionHandler = nil
    handler?()
  }

  private func drainPendingURLs() {
    guard let controller, !pendingURLs.isEmpty else { return }

    let urls = pendingURLs
    pendingURLs.removeAll()

    let supportedFileURLs = urls.filter(isSupportedLaunchFile)
    let unsupportedURLs = urls.filter { !isSupportedLaunchFile($0) }

    // `openFile` picks the destination per window state: an empty window is
    // reused in place (cold start), a window already showing a document routes
    // to the registry so the file lands as a native tab — the system "Prefer
    // tabs when opening documents" contract. Special-casing the first URL into
    // `openFileInCurrentWindow` replaced the document the user was reading
    // whenever a Finder/Dock open arrived at a running app.
    for url in supportedFileURLs {
      controller.openFile(url: url)
    }

    if controller.requestOpenDocumentWindow == nil, let firstURL = supportedFileURLs.first,
      WorkspaceScanner.isMarkdownFile(firstURL)
    {
      controller.selectDocument(id: firstURL.standardizedFileURL)
    }

    for url in unsupportedURLs {
      controller.openFile(url: url)
    }
  }

  private func isSupportedLaunchFile(_ url: URL) -> Bool {
    ["md", "markdown", "txt", "docx", "pdf"].contains(url.pathExtension.lowercased())
  }
}

final class PensieveAppDelegate: NSObject, NSApplicationDelegate {
  private var traceObservers: [NSObjectProtocol] = []

  /// Termination-path injection seams. Production leaves both `nil` and uses the app-wide
  /// singletons; a unit test sets them so it can drive the REAL `applicationWillTerminate` entry
  /// point against a temp database without mutating process-global state other tests share.
  var terminationWindowRegistryOverride: DocumentWindowRegistry?
  var terminationIndexDatabaseOverride: IndexDatabase?
  var terminationFolderManagerOverride: FolderManager?
  var terminationAutosaverOverride: Autosaver?
  var terminationLaunchIntentCoordinatorOverride: LaunchIntentCoordinator?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = true
    traceObservers = DebugTrace.installWindowLifecycleObservers()

    // Window-agnostic close lifecycle. Not every document-bearing window
    // is a DocumentWindow (state-restored WindowGroup scenes / "+"-spawned scene
    // tabs are not), so they have no onClose hook → their document would linger
    // forever in the registry's published open-tab list as a phantom "Open Files"
    // row. The shared lifecycle is idempotent and also restores one launcher
    // after the final content window closes.
    let openTabReconciler = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { note in
      guard let window = note.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        DocumentWindowRegistry.shared.handleWindowClosed(
          window,
          tombstonePolicy: .reusableWindow)
      }
    }
    traceObservers.append(openTabReconciler)

    // A bare `swift run` executable (no `.app` bundle, e.g. `make run`) launches as a
    // background process: no Dock icon, window stuck behind other apps, can't be brought
    // to the foreground. Force a regular activation policy in that case so the dev build
    // is actually usable. A packaged `.app` already runs as `.regular`, so this is a no-op
    // there — guarded on a nil bundle identifier to keep shipped behavior untouched.
    if Bundle.main.bundleIdentifier == nil {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }

    // Give SwiftUI one scheduler turn to install its window factory, then create
    // a launcher only when restoration produced no LIVE window. `NSApp.windows`
    // alone is insufficient because SwiftUI can retain invisible placeholder
    // scenes. A fixed 150 ms sleep made every unlucky launch visibly wait even
    // though no work was pending.
    Task { @MainActor in
      await Task.yield()
      if !DocumentWindowRegistry.shared.applicationHasLiveWindow() {
        if DocumentWindowRegistry.shared.makeDocumentWindow != nil {
          DocumentWindowRegistry.shared.openLauncherWindow(intent: .coldLaunch)
        } else {
          NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
        }
      }
    }
  }

  /// Clicking the Dock icon with no windows open reopens an EMPTY launcher.
  /// Closing every document is a conscious act; reactivating the app is not a
  /// request to undo it, so nothing is selected back into the new window.
  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag else { return true }
    Task { @MainActor in
      if DocumentWindowRegistry.shared.makeDocumentWindow != nil {
        DocumentWindowRegistry.shared.openLauncherWindow(intent: .dockReopen)
      } else {
        NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
      }
    }
    return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    Task { @MainActor in
      LaunchIntentCoordinator.shared.handle(urls: urls)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      // This notification is the one termination hook the app actually receives:
      // `applicationShouldTerminate(_:)` on THIS delegate is never invoked under
      // `@NSApplicationDelegateAdaptor` (falsified at runtime on 2026-07-29), so wiring anything
      // there would have looked right and done nothing. Every quit path — Dock, logout, shutdown,
      // the custom ⌘Q item — arrives here, which is why the whole termination contract (final
      // window saves → index drain → truncating checkpoint) has exactly one owner and it hangs off
      // this call. See `TerminationSequence`.
      TerminationSequence(
        registry: terminationWindowRegistryOverride ?? .shared,
        indexDatabase: terminationIndexDatabaseOverride ?? .shared,
        folderManager: terminationFolderManagerOverride,
        autosaver: terminationAutosaverOverride,
        launchIntentCoordinator: terminationLaunchIntentCoordinatorOverride
      ).runBlockingMainRunLoop()
    }
  }
}
