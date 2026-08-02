import AppKit
import Foundation

@MainActor
final class LaunchIntentCoordinator: ObservableObject {
  static let shared = LaunchIntentCoordinator()

  typealias StartupDecisionHandler = @MainActor () -> Void

  private let settleDelayNanoseconds: UInt64
  private weak var controller: AppController?
  /// Resolves the controller a file open should target when the cold-start
  /// launcher controller above is gone. ⌘O / File ▸ Open File act on the
  /// window the user is actually looking at, resolved through
  /// `CommandSurfaceContext`; a Finder/`open`/Dock file drop must land in that
  /// SAME window, not vanish. `controller` is only ever set by the cold-start
  /// settle path (launcher windows), never by a document window, so once the
  /// original launcher closed a later external open was routed at a released
  /// weak-ref and SILENTLY DROPPED — the app just kept showing the previously
  /// opened document. Falling back to the focused controller closes that hole
  /// while leaving cold launch (launcher attached, no window key yet) unchanged.
  private let focusedControllerProvider: @MainActor () -> AppController?
  private var pendingURLs: [URL] = []
  private var startupTask: Task<Void, Never>?
  private var startupDecisionHandler: StartupDecisionHandler?
  /// Set when launch URLs were actually opened into a window and CONSUMED by
  /// the next start decision.
  ///
  /// Its predecessor (`hasExplicitURLIntent`) was never reset: a session that
  /// had once been launched from the Finder suppressed workspace restore for
  /// every window it opened afterwards, for the lifetime of the process. Two
  /// visually identical sessions then behaved differently on Close depending on
  /// how the app had been started hours earlier. One file open is an intent for
  /// ONE launch, so it is spent on that launch.
  private var didOpenLaunchDocuments = false

  init(
    settleDelayNanoseconds: UInt64 = 0,
    focusedControllerProvider: @escaping @MainActor () -> AppController? = {
      CommandSurfaceContext.shared.controller
    }
  ) {
    self.settleDelayNanoseconds = settleDelayNanoseconds
    self.focusedControllerProvider = focusedControllerProvider
  }

  /// The controller an incoming file open should be routed to: the cold-start
  /// launcher controller while it is alive (keeps the launch-document settle
  /// path intact), otherwise the window the user is currently focused on. Never
  /// resolves to a released weak-ref, so an external open is never dropped.
  private var openTargetController: AppController? {
    controller ?? focusedControllerProvider()
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
    attach(controller: controller)
    startupDecisionHandler = onStartupDecision
    startupTask?.cancel()
    startupTask = Task { @MainActor [weak self, weak controller] in
      guard let self, let controller else { return }
      if self.settleDelayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: self.settleDelayNanoseconds)
      }

      self.drainPendingURLs()
      controller.start(intent: self.consumeLaunchDocumentOpen() ? .explicitDocument : intent)
      self.finishStartupDecision()
    }
  }

  func handle(urls: [URL]) {
    guard !urls.isEmpty else { return }

    pendingURLs.append(contentsOf: urls)
    startupTask?.cancel()
    drainPendingURLs()
    guard let target = openTargetController else { return }
    // The URLs already landed in this window; spend the launch-document intent
    // here so the NEXT window is judged on its own.
    _ = consumeLaunchDocumentOpen()
    target.start(intent: .explicitDocument)
    finishStartupDecision()
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

  /// Whether launch documents were opened and not yet accounted for, resetting
  /// the record as it answers.
  private func consumeLaunchDocumentOpen() -> Bool {
    let didOpen = didOpenLaunchDocuments
    didOpenLaunchDocuments = false
    return didOpen
  }

  private func drainPendingURLs() {
    guard let controller = openTargetController, !pendingURLs.isEmpty else { return }

    let urls = pendingURLs
    pendingURLs.removeAll()
    // Draining is what makes this launch an explicit-document launch. It can
    // happen the moment a controller attaches — before the settle task runs —
    // so the fact is recorded here rather than inferred at the start decision.
    didOpenLaunchDocuments = true

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

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = true
    traceObservers = DebugTrace.installWindowLifecycleObservers()

    // Retention sweep for crash drafts, at the one moment nothing holds one
    // open: drafts nobody came back for within 30 days go, and the rest are
    // capped. Recovery is a safety net, not an archive.
    RecoveryStore.shared.pruneDrafts()

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

  /// The veto point for EVERY quit that does not come from the ⌘Q menu item: the
  /// Dock menu's "Quit", an AppleScript `quit`, a logout, a restart. Those reach
  /// `NSApplication.terminate(_:)` with no firing window, so before this hook
  /// existed they skipped the unsaved-work pass entirely and every window fell to
  /// its teardown path — which can stash a recovery draft but has no veto point
  /// and can never ask. With auto-save off a dirty FILE-BACKED buffer gets no
  /// draft either, so the edit was simply gone.
  ///
  /// Verified at runtime on macOS 26 (Darwin 25.6), staged bundle, 2026-08-02:
  /// `NSApp.delegate` is SwiftUI's own `SwiftUI.AppDelegate` proxy, NOT this
  /// object — but it FORWARDS `applicationShouldTerminate(_:)` to the
  /// `@NSApplicationDelegateAdaptor` instance, and a file probe written from
  /// inside this method landed on an AppleScript quit. ⌘Q keeps its own pass in
  /// `Commands.swift` (unchanged) because `NSApplication.terminate(_:)` does NOT
  /// reliably reach this hook — `NSSupportsSuddenTermination` is true in
  /// `Info.plist`, and a programmatic terminate can exit the process outright.
  /// Moving the pass OFF the menu item is therefore a data-loss regression, which
  /// is what the 2026-07-29 attempt hit.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      DocumentWindowRegistry.shared.resolveTerminationRequest()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // The last document window closing during Quit must not resurrect a
    // launcher; tell the registry the app is going away before its windows tear
    // down.
    MainActor.assumeIsolated {
      DocumentWindowRegistry.shared.beginTermination()

      // Last writable moment in the process. Until now the saved working set was
      // only handed to cfprefsd, which writes it back on its own schedule —
      // measured here at up to ~14 s after exit, long enough to overwrite
      // whatever touched those defaults in the meantime. Flushing here makes the
      // state on disk final by the time the process is gone.
      FolderManager.shared.flushWorkingSet()
    }
  }
}
