import AppKit
import Foundation

@MainActor
final class LaunchIntentCoordinator: ObservableObject {
  static let shared = LaunchIntentCoordinator(
    hasLiveDocumentCapableWindow: {
      DocumentWindowRegistry.shared.hasLiveDocumentCapableWindow()
    },
    openExternalDocumentHost: {
      DocumentWindowRegistry.shared.openDocumentHost(intent: .explicitDocument)
    },
    openUntitledDocumentHost: {
      DocumentWindowRegistry.shared.openDocumentHost(intent: .newUntitledTab)
    })

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
  /// Materializes a document host for an external file-open event when the app
  /// is deliberately alive with zero windows. The URL stays in `pendingURLs`;
  /// the new root drains it when its controller attaches, preserving the same
  /// explicit-document launch path as a cold Finder open.
  ///
  /// The question is deliberately "is a DOCUMENT-capable window alive", not "is
  /// any window alive": a visible Settings or About window cannot take a file,
  /// so counting it as a live surface left the external open with no target
  /// controller, no host request, and a URL parked in `pendingURLs` for the rest
  /// of the session.
  private let hasLiveDocumentCapableWindow: @MainActor () -> Bool
  private let openExternalDocumentHost: @MainActor () -> Bool
  private let openUntitledDocumentHost: @MainActor () -> Bool
  /// Injection seam for the extra New gestures a just-created host did not
  /// itself consume. Production routes through the controller's normal native
  /// tab policy; tests can count the queue without depending on AppKit tab
  /// materialization in a headless bundle.
  private let createUntitledDocument: @MainActor (AppController) -> Bool
  private var pendingURLs: [URL] = []
  /// New is a counted gesture, not a boolean intent. The first request can be
  /// represented by the host carrying `.newUntitledTab`; every later request
  /// must still become its own tab once that host's controller attaches.
  private var pendingNewDocumentCount = 0
  /// Creating a tab can synchronously publish/adopt its window and re-enter the
  /// pending queue through `commandTargetDidBecomeAvailable`. One owner drains
  /// at a time so that callback cannot consume the same counted gesture twice.
  private var isDrainingPendingNewDocuments = false
  private var startupTask: Task<Void, Never>?
  private var startupDecisionHandler: StartupDecisionHandler?
  /// A document-capable host exists or has been synchronously requested, but
  /// its SwiftUI controller may not have attached yet. Shared by Finder/Open
  /// and New so interleaved gestures cannot create competing roots.
  private var isDocumentHostRequested = false
  private var isStartupDecisionPending = false
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
    },
    hasLiveDocumentCapableWindow: @escaping @MainActor () -> Bool = { false },
    openExternalDocumentHost: @escaping @MainActor () -> Bool = { false },
    openUntitledDocumentHost: @escaping @MainActor () -> Bool = { false },
    createUntitledDocument: @escaping @MainActor (AppController) -> Bool = {
      $0.createUntitledDocument()
    }
  ) {
    self.settleDelayNanoseconds = settleDelayNanoseconds
    self.focusedControllerProvider = focusedControllerProvider
    self.hasLiveDocumentCapableWindow = hasLiveDocumentCapableWindow
    self.openExternalDocumentHost = openExternalDocumentHost
    self.openUntitledDocumentHost = openUntitledDocumentHost
    self.createUntitledDocument = createUntitledDocument
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
    pendingNewDocumentCount = 0
    isDrainingPendingNewDocuments = false
    isDocumentHostRequested = false
    isStartupDecisionPending = false
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
    isStartupDecisionPending = true
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
      self.drainPendingNewDocuments(
        on: controller,
        hostConsumedOneNewRequest: settledIntent == .newUntitledTab)
      self.finishStartupDecision()
    }
  }

  /// Handles ⌘N/⌘T while no stable document command target exists.
  ///
  /// A host factory returns before SwiftUI attaches its controller. Treating
  /// New as a one-shot host request therefore dropped the second and third key
  /// presses in that gap. Count every gesture, let one `.newUntitledTab` host
  /// consume at most one, and replay the rest only after startup made that host
  /// document-capable. The same queue covers a Finder host already in flight.
  func requestNewDocument() {
    guard !isQuiescedForTermination else { return }

    if let target = openTargetController, !isStartupDecisionPending {
      // A stable target gets a one-shot action. Never retain a failed attempt:
      // doing so made an unavailable source window turn into a surprise tab on
      // some unrelated later open. Older requests are the deliberate attach-
      // gap queue and remain independently retryable.
      drainPendingNewDocuments(on: target, hostConsumedOneNewRequest: false)
      _ = createUntitledDocument(target)
      return
    }

    pendingNewDocumentCount += 1
    guard !hasLiveDocumentCapableWindow(), !isDocumentHostRequested else { return }
    isDocumentHostRequested = openUntitledDocumentHost()
  }

  /// Replays only gestures accepted while a document host was alive or being
  /// built but had not published a stable command controller yet.
  ///
  /// `CommandSurfaceContext` calls this on every adoption attempt, including
  /// the later window-accessor turn where the adopted pair itself is unchanged.
  /// That event-driven handoff avoids an unbounded timer and keeps a failed
  /// one-shot New on an already-stable controller out of this queue entirely.
  func commandTargetDidBecomeAvailable(_ controller: AppController) {
    guard !isQuiescedForTermination, !isStartupDecisionPending else { return }
    drainPendingNewDocuments(on: controller, hostConsumedOneNewRequest: false)
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
    guard let target = openTargetController else {
      // The zero-window process is intentional, but an external open is also
      // an explicit request for a surface. Keep the URLs queued and create one
      // host; its root will attach above and drain them exactly once.
      if !hasLiveDocumentCapableWindow(), !isDocumentHostRequested {
        isDocumentHostRequested = openExternalDocumentHost()
      }
      return
    }
    // The URLs already landed in this window; spend the launch-document intent
    // here so the NEXT window is judged on its own.
    _ = consumeLaunchDocumentOpen()
    target.start(intent: .explicitDocument)
    drainPendingNewDocuments(on: target, hostConsumedOneNewRequest: false)
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
    isStartupDecisionPending = false
    isDocumentHostRequested = false
    let handler = startupDecisionHandler
    startupDecisionHandler = nil
    handler?()
  }

  private func drainPendingNewDocuments(
    on controller: AppController,
    hostConsumedOneNewRequest: Bool
  ) {
    guard !isDrainingPendingNewDocuments else { return }
    isDrainingPendingNewDocuments = true
    defer { isDrainingPendingNewDocuments = false }

    if hostConsumedOneNewRequest, pendingNewDocumentCount > 0 {
      pendingNewDocumentCount -= 1
    }
    while pendingNewDocumentCount > 0 {
      // Claim before crossing into AppKit/SwiftUI: window creation may publish
      // the controller synchronously and re-enter this method. Put the claim
      // back only when the New operation itself refused the request.
      pendingNewDocumentCount -= 1
      guard createUntitledDocument(controller) else {
        pendingNewDocumentCount += 1
        return
      }
    }
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
    // to the registry so the file lands as a native tab — Pensieve's
    // deterministic click/open contract. Special-casing the first URL into
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

@MainActor
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
  /// Dock-reopen injection seam. Production uses the shared registry; tests
  /// drive the real delegate callback against isolated window graphs.
  var reopenWindowRegistryOverride: DocumentWindowRegistry?
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
    DebugTrace.logWindowGraph("applicationDidFinishLaunching")

    surveyRecoveredDraftsOnLaunch()

    // Window-agnostic close lifecycle. The scene-owned launcher and any native
    // tab that AppKit re-hosts are not guaranteed to be a DocumentWindow, so
    // they have no onClose hook → their document would linger
    // forever in the registry's published open-tab list as a phantom "Open Files"
    // row. The shared lifecycle is idempotent. It never creates a replacement
    // window: an explicit Dock reopen is the sole owner of that transition.
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
        DocumentWindowRegistry.shared.openDocumentHost(intent: .coldLaunch)
      }
    }
  }

  /// Clicking the Dock icon with no DOCUMENT window open reopens an EMPTY
  /// launcher. Closing every document is a conscious act; reactivating the app
  /// is not a request to undo it, so nothing is selected back into the new
  /// window.
  ///
  /// AppKit's `hasVisibleWindows` counts every surface, Settings and About
  /// included, so trusting it alone made the Dock icon inert for a session whose
  /// last remaining window cannot hold a document. The decision is the registry's
  /// document-capable answer alone, and `flag` is deliberately not consulted.
  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    // Wait-mode instances are disposable composer tafle: Dock re-click must
    // not spawn a second empty session alongside the one `$VC_COMPOSER` owns.
    if LaunchIntentCoordinator.shared.isComposerWaitMode {
      return true
    }
    return MainActor.assumeIsolated {
      let registry = reopenWindowRegistryOverride ?? .shared
      guard !registry.hasLiveDocumentCapableWindow() else {
        // AppKit may perform its ordinary activation/order work. No custom host
        // was created, so returning false here would swallow the Dock click.
        return true
      }
      // A delegate that creates the host must consume the reopen synchronously.
      // Returning true after doing so asks AppKit to reopen another scene and
      // was the source of duplicate windows after one Dock click.
      return !registry.openDocumentHost(intent: .dockReopen)
    }
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
  /// the application-global command lane because `NSApplication.terminate(_:)`
  /// does NOT reliably reach this hook on every programmatic route. The shipped bundle
  /// explicitly sets `NSSupportsSuddenTermination` to false so AppKit reaches
  /// the final `applicationWillTerminate` durability phase after consent.
  /// Moving the pass OFF the menu item is therefore a data-loss regression, which
  /// is what the 2026-07-29 attempt hit.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      DocumentWindowRegistry.shared.resolveTerminationRequest()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      // `applicationShouldTerminate(_:)` is the synchronous consent/veto
      // phase. Once it returns `.terminateNow`, every quit path arrives here
      // for the final durability sequence: quiesce producers, flush accepted
      // user bytes, persist the working set, drain the index and checkpoint.
      // Keeping those roles separate avoids both an unvetoable quit and a
      // duplicate final flush. See `TerminationSequence`.
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
