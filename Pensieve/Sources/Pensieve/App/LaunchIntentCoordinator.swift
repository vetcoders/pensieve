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
  /// Composer v2 Tor B: process exits when the last content window closes.
  private(set) var isComposerWaitMode = false
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

  init(
    settleDelayNanoseconds: UInt64 = 0,
    focusedControllerProvider: @escaping @MainActor () -> AppController? = {
      CommandSurfaceContext.shared.controller
    }
  ) {
    self.settleDelayNanoseconds = settleDelayNanoseconds
    self.focusedControllerProvider = focusedControllerProvider
  }

  /// Apply pure CLI parse results before the first window's settle path runs.
  /// Safe to call from `PensieveApp.init` while `controller` is still nil —
  /// URLs stay pending and drain on `startWhenLaunchIntentsSettle`.
  func applyComposerLaunchArguments(_ arguments: ComposerLaunchArguments) {
    if arguments.wait {
      isComposerWaitMode = true
    }
    if !arguments.fileURLs.isEmpty {
      handle(urls: arguments.fileURLs)
    }
  }

  /// Test / recovery seam: reset wait mode without reconstructing the shared
  /// coordinator (which owns in-flight startup tasks in production).
  func resetComposerWaitModeForTests() {
    isComposerWaitMode = false
  }

  /// The controller an incoming file open should be routed to: the cold-start
  /// launcher controller while it is alive (keeps the launch-document settle
  /// path intact), otherwise the window the user is currently focused on. Never
  /// resolves to a released weak-ref, so an external open is never dropped.
  private var openTargetController: AppController? {
    controller ?? focusedControllerProvider()
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
      // Consumed unconditionally, never behind a short-circuit: the record is spent by ASKING, so
      // a wait-mode launch that skipped the question would leave it armed for the next window.
      let openedLaunchDocuments = self.consumeLaunchDocumentOpen()
      // Composer wait alone (no files) still skips restore: the session is a disposable tafla for
      // $VC_COMPOSER, not a daily-driver workspace reopen.
      let settledIntent: LaunchIntent =
        openedLaunchDocuments || self.isComposerWaitMode ? .explicitDocument : intent
      controller.start(intent: settledIntent)
      self.finishStartupDecision()
    }
  }

  func handle(urls: [URL]) {
    // Same latch, same reason: this path calls `controller.start` too, and `application(_:open:)`
    // hands the URLs over through a `Task`, so a Finder/Dock open that arrives as the app is quitting
    // lands inside the pumped run loop.
    guard !isQuiescedForTermination else { return }
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

  /// Whether cold start should suppress the empty-workspace restore path: launch documents that
  /// have been opened but not yet spent, or composer wait. Reads the record without consuming it —
  /// only the start decision in `startWhenLaunchIntentsSettle` spends it.
  var hasExplicitLaunchIntent: Bool { didOpenLaunchDocuments || isComposerWaitMode }

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

  /// Termination-path injection seams. Production leaves both `nil` and uses the app-wide
  /// singletons; a unit test sets them so it can drive the REAL `applicationWillTerminate` entry
  /// point against a temp database without mutating process-global state other tests share.
  var terminationWindowRegistryOverride: DocumentWindowRegistry?
  var terminationIndexDatabaseOverride: IndexDatabase?
  var terminationFolderManagerOverride: FolderManager?
  var terminationAutosaverOverride: Autosaver?
  var terminationLaunchIntentCoordinatorOverride: LaunchIntentCoordinator?
  /// Launch-pass injection seam, same shape as the termination ones above.
  /// Production leaves it `nil` and reads `RecoveryStore.shared`; a test points
  /// it at a temp directory so the LAUNCH pass can be driven for real without
  /// touching the operator's own crash drafts.
  var launchRecoveryStoreOverride: RecoveryStore?

  /// The application's once-per-process look at the crash-draft directory,
  /// taken at the one moment nothing can be holding a draft open.
  ///
  /// It is READ-ONLY. This used to be a retention sweep that dropped drafts past
  /// 30 days and trimmed the rest to a cap of 20; Monika's decision of 04.08 —
  /// "they don't disappear without my decision" — retired it, matching what the
  /// lifecycle contract's Recovery section always said: a draft is removed by a
  /// successful save, an explicit discard, or a confirmed Don't Save, and by
  /// nothing else. Launching the app is not one of those, so this pass reports
  /// what is stored and deletes nothing.
  ///
  /// It lives HERE, on `applicationDidFinishLaunching`, and not in
  /// `AppController.start`: `start` runs once per WINDOW (every launcher, every
  /// Dock reopen, every "+" tab), while this is a once-per-process fact, and the
  /// hook is the only launch point guaranteed to run BEFORE any window can adopt
  /// a draft. Verified at runtime on macOS 26 (Darwin 25.6), debug build,
  /// 2026-08-03: the `@NSApplicationDelegateAdaptor` instance does receive
  /// `applicationDidFinishLaunching`.
  @discardableResult
  func surveyRecoveredDraftsOnLaunch() -> [RecoveryDraft] {
    (launchRecoveryStoreOverride ?? .shared).loadDrafts()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = true
    traceObservers = DebugTrace.installWindowLifecycleObservers()

    surveyRecoveredDraftsOnLaunch()

    // Window-agnostic close lifecycle. Not every document-bearing window
    // is a DocumentWindow (state-restored WindowGroup scenes / "+"-spawned scene
    // tabs are not), so they have no onClose hook → their document would linger
    // forever in the registry's published open-tab list as a phantom "Open Files"
    // row. The shared lifecycle is idempotent and also restores one launcher
    // after the final content window closes.
    //
    // Composer wait mode: after the registry reconciles the close, if no live
    // window remains we mark termination (so the deferred launcher reopen is
    // suppressed) and quit — unblocking `$VC_COMPOSER` / `open -W`.
    let openTabReconciler = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { note in
      guard let window = note.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        DocumentWindowRegistry.shared.handleWindowClosed(
          window,
          tombstonePolicy: .reusableWindow)
        Self.finishComposerWaitIfWindowless()
      }
    }
    traceObservers.append(openTabReconciler)

    // A bare `swift run` executable (no `.app` bundle, e.g. `make run`) launches as a
    // background process: no Dock icon, window stuck behind other apps, can't be brought
    // to the foreground. Force a regular activation policy in that case so the dev build
    // is actually usable. A packaged `.app` already runs as `.regular`, so this is a no-op
    // there — guarded on a nil bundle identifier to keep shipped behavior untouched.
    // Composer wait always wants foreground activation: the blocking caller is waiting
    // on this process and the user must reach the tafla immediately.
    if Bundle.main.bundleIdentifier == nil
      || LaunchIntentCoordinator.shared.isComposerWaitMode
    {
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
    // Wait-mode instances are disposable composer tafle: Dock re-click must
    // not spawn a second empty session alongside the one `$VC_COMPOSER` owns.
    if LaunchIntentCoordinator.shared.isComposerWaitMode {
      return true
    }
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

  /// Shared close → quit path for Composer wait mode. Idempotent: a second
  /// close while terminate is already in flight is a no-op once
  /// `beginTermination` has flipped the registry flag.
  @MainActor
  static func finishComposerWaitIfWindowless() {
    guard LaunchIntentCoordinator.shared.isComposerWaitMode else { return }
    // Suppress launcher resurrection *before* any deferred reopen scheduled
    // by `handleWindowClosed` can fire.
    DocumentWindowRegistry.shared.beginTermination()
    guard !DocumentWindowRegistry.shared.applicationHasLiveWindow() else { return }
    NSApp.terminate(nil)
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
