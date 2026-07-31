import AppKit
import SwiftUI

struct OpenDocumentDescriptor: Identifiable {
  let identity: DocumentIdentity
  var displayTitle: String
  var fileURL: URL?
  var isDirty: Bool
  fileprivate var windowAssociation: WeakWindow?

  var id: DocumentIdentity { identity }
  var window: NSWindow? { windowAssociation?.window }
}

enum WindowCloseTombstonePolicy {
  case reusableWindow
  case factoryWindow
}

@MainActor
final class DocumentWindowRegistry: ObservableObject {
  static let shared = DocumentWindowRegistry()
  private let documentTabbingIdentifier = WindowChromeRecipe.documentTabbingIdentifier

  typealias DeferredMainWork = @MainActor () -> Void
  /// Builds a fully configured document window WITHOUT ordering it on screen.
  /// `nil` ref means an untitled (launcher-mode) document tab. The registry
  /// attaches the returned window as a native tab BEFORE first presentation,
  /// which makes the legacy standalone-window flash impossible by
  /// construction.
  typealias DocumentWindowFactoryClosure = @MainActor (DocumentRef?) -> NSWindow?

  private var windowsByDocumentID: [URL: WeakWindow] = [:]
  private var launcherWindows: [ObjectIdentifier: WeakWindow] = [:]
  private var contentWindows: [ObjectIdentifier: WeakWindow] = [:]
  private var preferredLauncherID: ObjectIdentifier?
  private var deferredOpenDocumentIDs: Set<URL> = []
  private var deferredAttachDocumentIDs: Set<URL> = []
  private var orderedDocumentIDs: Set<URL> = []
  private var windowsByIdentity: [DocumentIdentity: WeakWindow] = [:]
  /// Each document window's owning controller, keyed by the window. Open Files
  /// mirrors EVERY window's documents into EVERY window's sidebar, so a close
  /// invoked from one window can target a document living in another. The dirty
  /// guard must run in the target's OWN session, so `closeOpenDocument` resolves
  /// the owner through this map instead of guarding only the caller's session.
  private var controllersByWindow: [ObjectIdentifier: WeakController] = [:]
  private var fallbackUntitledIdentities: [ObjectIdentifier: DocumentIdentity] = [:]
  /// The sole ordered publication authority for Open Files. File-only callers
  /// get a derived compatibility projection via `openTabDocumentIDs`.
  @Published private(set) var openDocuments: [OpenDocumentDescriptor] = []
  var openTabDocumentIDs: [URL] { openDocuments.compactMap(\.fileURL) }
  /// Windows born from the tab bar's "+" button: launcher-mode content living
  /// as a document tab. They report no document and no editable buffer on
  /// first attach, which would otherwise classify them as empty launchers and
  /// feed them to the reaping sweeps.
  private var untitledTabWindows: [ObjectIdentifier: WeakWindow] = [:]
  private var closedWindows: [ObjectIdentifier: WeakWindow] = [:]
  private var launcherSweepPending = false
  private var launcherSweepSparedWindow: WeakWindow?
  private var launcherReopenPending = false
  private var launcherReopenAwaitingFactory = false
  /// Set once the app starts quitting so the last document window's close does
  /// not resurrect a launcher mid-termination — and so the key/close churn of a
  /// dying window group cannot rewrite the restore record the user's last
  /// action left behind.
  private(set) var isTerminating = false
  /// Observers and factory bindings.
  var makeDocumentWindow: DocumentWindowFactoryClosure? {
    didSet {
      guard makeDocumentWindow != nil, launcherReopenAwaitingFactory else { return }
      launcherReopenAwaitingFactory = false
      requestLauncherReopenIfAppWouldBeWindowless()
    }
  }

  /// Mark the app as terminating (called from `applicationWillTerminate`) so the
  /// last-window-close handler suppresses its launcher reopen.
  func beginTermination() {
    isTerminating = true
    launcherReopenAwaitingFactory = false
  }

  /// Opens a new empty launcher window. Used when the app is reactivated from
  /// the Dock with no visible windows, or during cold start if SwiftUI does not
  /// provide one automatically.
  func openLauncherWindow() {
    guard let factory = makeDocumentWindow else { return }
    if let launcher = factory(nil) {
      registerLauncher(launcher)
      orderAndActivateWindow(launcher)
    }
  }

  private let canMutateWindowTabs: @MainActor () -> Bool
  private let scheduleDeferredMainWork: (@escaping DeferredMainWork) -> Void
  private let scheduleLauncherWindowSweep: (@escaping DeferredMainWork) -> Void
  private let mergeWindowIntoTabs: @MainActor (NSWindow, NSWindow) -> Void
  private let orderAndActivateWindow: @MainActor (NSWindow) -> Void
  private let currentMergeTarget: @MainActor () -> NSWindow?
  private let applicationWindows: @MainActor () -> [NSWindow]
  private let closeWindow: @MainActor (NSWindow) -> Void

  init(
    canMutateWindowTabs: @escaping @MainActor () -> Bool = { NSApp.modalWindow == nil },
    scheduleDeferredMainWork: @escaping (@escaping DeferredMainWork) -> Void = { work in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        Task { @MainActor in work() }
      }
    },
    scheduleLauncherWindowSweep: @escaping (@escaping DeferredMainWork) -> Void = { work in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        Task { @MainActor in work() }
      }
    },
    mergeWindowIntoTabs: @escaping @MainActor (NSWindow, NSWindow) -> Void = { target, window in
      target.addTabbedWindow(window, ordered: .above)
    },
    orderAndActivateWindow: @escaping @MainActor (NSWindow) -> Void = { window in
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    },
    currentMergeTarget: @escaping @MainActor () -> NSWindow? = {
      NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApp.windows.first
    },
    applicationWindows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
    closeWindow: @escaping @MainActor (NSWindow) -> Void = { window in
      window.close()
    },
    makeDocumentWindow: DocumentWindowFactoryClosure? = nil
  ) {
    self.canMutateWindowTabs = canMutateWindowTabs
    self.scheduleDeferredMainWork = scheduleDeferredMainWork
    self.scheduleLauncherWindowSweep = scheduleLauncherWindowSweep
    self.mergeWindowIntoTabs = mergeWindowIntoTabs
    self.orderAndActivateWindow = orderAndActivateWindow
    self.currentMergeTarget = currentMergeTarget
    self.applicationWindows = applicationWindows
    self.closeWindow = closeWindow
    self.makeDocumentWindow = makeDocumentWindow
  }

  /// Opens (or activates) the window for a document. The whole flow is
  /// synchronous on the main actor: the factory builds the window, the
  /// registry records it and merges it into the current window's native tab
  /// group BEFORE the window is ever ordered on screen, so it first appears
  /// already as a tab. The per-window SwiftUI scene cold-starts AFTER
  /// presentation, inside the tab, behind the in-tab startup spinner.
  func open(_ ref: DocumentRef) {
    let documentID = ref.id.standardizedFileURL
    let identity = DocumentIdentity.file(documentID).standardized
    guard canMutateWindowTabs() else {
      deferOpen(ref, documentID: documentID)
      return
    }

    if let existing = windowsByIdentity[identity]?.window {
      // Belt to handleDocumentWindowClosed's braces: a closed DocumentWindow
      // has its contentView torn down — never resurrect it; drop the dead
      // mapping and fall through to creating a fresh window.
      if existing.contentView != nil {
        DebugTrace.log(
          "registry.open \(documentID.lastPathComponent) -> activate existing '\(existing.title)'")
        mergeExistingWindowIntoCurrentTabsIfNeeded(existing)
        orderAndActivateWindow(existing)
        closeEmptyLauncherWindows(except: existing)
        return
      }
      DebugTrace.log("registry.open \(documentID.lastPathComponent) -> dropping dead mapping")
      windowsByDocumentID.removeValue(forKey: documentID)
      windowsByIdentity.removeValue(forKey: identity)
      orderedDocumentIDs.remove(documentID)
      forgetOpenDocument(identity)
    }

    guard let makeDocumentWindow else {
      DebugTrace.log("registry.open \(documentID.lastPathComponent) -> no window factory wired")
      return
    }
    guard let window = makeDocumentWindow(ref) else {
      DebugTrace.log("registry.open \(documentID.lastPathComponent) -> factory returned nil")
      return
    }
    DebugTrace.log("registry.open \(documentID.lastPathComponent) -> factory created window")

    // Register synchronously — there is no in-flight gap: a re-click for the
    // same document hits the existing-window path above instead of spawning a
    // second window.
    markContentWindow(window)
    windowsByDocumentID[documentID] = WeakWindow(window)
    orderedDocumentIDs.insert(documentID)
    _ = publish(
      identity: identity,
      displayTitle: ref.title,
      fileURL: documentID,
      isDirty: false,
      window: window)

    if let target = currentMergeTarget(), target !== window {
      prepareTabbedWindow(target)
      prepareTabbedWindow(window)
      mergeWindowIntoTabs(target, window)
      DebugTrace.log("merged '\(window.title)' into '\(target.title)' before first presentation")
    }
    orderAndActivateWindow(window)
    closeEmptyLauncherWindows(except: window)
  }

  /// The single close lifecycle for factory callbacks and process-wide AppKit
  /// notifications. Both routes reconcile registry state and request the same
  /// coalesced last-window reopen; only never-reused factory windows are
  /// tombstoned against late SwiftUI attach callbacks.
  func handleWindowClosed(
    _ window: NSWindow,
    tombstonePolicy: WindowCloseTombstonePolicy
  ) {
    reconcileClosedWindowState(window)
    if tombstonePolicy == .factoryWindow {
      closedWindows[ObjectIdentifier(window)] = WeakWindow(window)
    }
    requestLauncherReopenIfAppWouldBeWindowless()
  }

  /// Compatibility entry for process-wide reusable SwiftUI/AppKit scene closes.
  /// Production routes may call the explicit policy API directly; this wrapper
  /// preserves the merged PR #10 contract without tombstoning reusable scenes.
  func handleApplicationWindowClosed(_ window: NSWindow) {
    handleWindowClosed(window, tombstonePolicy: .reusableWindow)
  }

  /// Compatibility entry for focused window tests and non-factory callers.
  /// Production close routes call `handleWindowClosed` with an explicit policy.
  func reconcileClosedWindow(_ window: NSWindow) {
    handleWindowClosed(window, tombstonePolicy: .reusableWindow)
  }

  /// Compatibility entry for older factory bindings and focused tests.
  func handleDocumentWindowClosed(_ window: NSWindow) {
    handleWindowClosed(window, tombstonePolicy: .factoryWindow)
  }

  private func reconcileClosedWindowState(_ window: NSWindow) {
    let windowID = ObjectIdentifier(window)
    DebugTrace.log("registry.reconcileClosed '\(window.title)'")
    releaseStaleDocumentMappings(for: window, keeping: nil)
    removeDescriptors(for: window, keeping: nil)
    contentWindows.removeValue(forKey: windowID)
    launcherWindows.removeValue(forKey: windowID)
    untitledTabWindows.removeValue(forKey: windowID)
    fallbackUntitledIdentities.removeValue(forKey: windowID)
  }

  /// After the last document window closes the app is left with no window and
  /// no focused controller — the New command (which targets the focused
  /// window's `AppState`) then has nothing to act on, so the user can neither
  /// see the empty-state surface nor start a new document. Re-open a launcher so
  /// a window stays alive on the empty state, matching the VS Code-style "last
  /// editor closed, window remains" behaviour. Deferred so it runs after AppKit
  /// finishes the in-progress close; suppressed during termination so Quit is
  /// never fought by a resurrected launcher, and a no-op when any other document
  /// or launcher window is still alive.
  private func requestLauncherReopenIfAppWouldBeWindowless() {
    guard !isTerminating, !launcherReopenPending else { return }
    guard !hasContentWindow else {
      launcherReopenAwaitingFactory = false
      return
    }
    guard makeDocumentWindow != nil else {
      launcherReopenAwaitingFactory = true
      return
    }
    launcherReopenAwaitingFactory = false
    launcherReopenPending = true
    scheduleDeferredMainWork { [weak self] in
      guard let self else { return }
      self.launcherReopenPending = false
      guard !self.isTerminating else { return }
      self.purgeClosedLauncherWindows()
      guard !self.hasContentWindow else { return }
      let hasLauncher = self.launcherWindows.values.contains { $0.window != nil }
      guard !hasLauncher else { return }
      let hasLiveDocumentWindow = self.windowsByDocumentID.values.contains {
        $0.window?.contentView != nil
      }
      guard !hasLiveDocumentWindow else { return }
      self.openLauncherWindow()
    }
  }

  /// Whether the app still has a window that can carry real product UI.
  /// AppKit/SwiftUI can retain invisible placeholder scenes in `NSApp.windows`;
  /// those phantoms must not block cold-start recovery or count as survivors
  /// when redundant launchers are reaped.
  func applicationHasLiveWindow() -> Bool {
    purgeClosedLauncherWindows()
    if launcherWindows.values.contains(where: { $0.window != nil })
      || contentWindows.values.contains(where: { $0.window != nil })
      || windowsByDocumentID.values.contains(where: { $0.window != nil })
    {
      return true
    }
    return applicationWindows().contains(where: isLiveApplicationWindow)
  }

  /// The tab bar's "+" button: opens a NEW untitled document tab in the same
  /// tab group instead of the system default (a detached standalone window).
  /// Mirrors `open()`'s modal contract: deferred, not dropped, while a modal
  /// run loop blocks native tab mutation.
  func newUntitledTab(from window: NSWindow) {
    guard canMutateWindowTabs() else {
      scheduleDeferredMainWork { [weak self, weak window] in
        guard let self, let window else { return }
        newUntitledTab(from: window)
      }
      return
    }
    guard let makeDocumentWindow, let newWindow = makeDocumentWindow(nil) else {
      DebugTrace.log("newUntitledTab -> no window factory wired")
      return
    }
    DebugTrace.log("newUntitledTab from '\(window.title)'")
    untitledTabWindows[ObjectIdentifier(newWindow)] = WeakWindow(newWindow)
    markContentWindow(newWindow)
    prepareTabbedWindow(window)
    prepareTabbedWindow(newWindow)
    mergeWindowIntoTabs(window, newWindow)
    orderAndActivateWindow(newWindow)
  }

  @discardableResult
  func attach(
    _ window: NSWindow,
    identity: DocumentIdentity? = nil,
    documentID: URL?,
    title: String? = nil,
    representedURL: URL? = nil,
    isDirty: Bool = false,
    hasEditableBuffer: Bool = false
  ) -> Bool {
    DebugTrace.log(
      "registry.attach doc=\(documentID?.lastPathComponent ?? "nil") '\(window.title)'"
    )
    // A closed window's SwiftUI accessor can fire one last main-queue pass
    // AFTER the close; re-registering it would resurrect the window as a
    // phantom tab that is visible but half-dead.
    if closedWindows[ObjectIdentifier(window)]?.window === window {
      DebugTrace.log("registry.attach rejected: window already closed")
      return false
    }
    // Every document window — factory-built, restored, or launcher-promoted —
    // shares the document tabbing identifier so the system keeps grouping them
    // (the "+" button) AND keeps "Window > Merge All Windows" enabled. That menu
    // greys out when windows don't share an identifier, so non-factory windows
    // are normalized ONTO the shared identifier, never nilled into mergeless islands.
    if window.tabbingIdentifier != documentTabbingIdentifier {
      prepareTabbedWindow(window)
    }

    let windowID = ObjectIdentifier(window)
    var resolvedIdentity =
      identity?.standardized
      ?? documentID.map { DocumentIdentity.file($0.standardizedFileURL) }
    if resolvedIdentity == nil, hasEditableBuffer {
      resolvedIdentity = fallbackUntitledIdentities[windowID] ?? .untitled(UUID())
      fallbackUntitledIdentities[windowID] = resolvedIdentity
    }

    guard let resolvedIdentity else {
      releaseStaleDocumentMappings(for: window, keeping: nil)
      removeDescriptors(for: window, keeping: nil)
      if hasEditableBuffer {
        markContentWindow(window)
        window.title = normalizedTitle(title, fallback: "Untitled")
        window.representedURL = representedURL
        closeEmptyLauncherWindows(except: window)
        return true
      }
      if untitledTabWindows[ObjectIdentifier(window)]?.window === window {
        // A "+" tab in its launcher-mode state: content by fiat, never reaped.
        markContentWindow(window)
        window.title = normalizedTitle(title, fallback: "Untitled")
        window.representedURL = nil
        return true
      }
      registerLauncher(window)
      closeEmptyLauncherWindowIfDocumentTabsExist(window)
      return true
    }

    if let existing = windowsByIdentity[resolvedIdentity]?.window, existing !== window {
      DebugTrace.log("registry.attach rejected duplicate identity \(resolvedIdentity.persistentID)")
      // The window switched in place onto a document another window already
      // owns. It no longer legitimately shows its PREVIOUS document, so drop
      // this window's stale descriptor/mapping before rejecting — otherwise
      // Open Files and `open(previous)` keep targeting this window as if it
      // still showed the old document, sending later activation/close actions
      // to the wrong tab. `existing`'s ownership of the duplicate is untouched.
      releaseStaleDocumentMappings(for: window, keeping: nil)
      removeDescriptors(for: window, keeping: nil)
      return false
    }

    markContentWindow(window)
    let documentID = resolvedIdentity.fileURL
    let fallbackTitle = documentID?.deletingPathExtension().lastPathComponent ?? "Untitled"
    window.title = normalizedTitle(title, fallback: fallbackTitle)
    window.representedURL = representedURL ?? documentID

    guard
      publish(
        identity: resolvedIdentity,
        displayTitle: window.title,
        fileURL: documentID,
        isDirty: isDirty,
        window: window)
    else { return false }

    // A window displays exactly one document: switching documents in place
    // (the default in-window click routing) must release the previous
    // mapping, or `open()` keeps "activating" this window for documents it no
    // longer shows and Open in New Window becomes a silent no-op.
    releaseStaleDocumentMappings(for: window, keeping: documentID)
    if let documentID {
      if windowsByDocumentID[documentID]?.window !== window {
        orderedDocumentIDs.remove(documentID)
      }
      windowsByDocumentID[documentID] = WeakWindow(window)
    }

    guard canMutateWindowTabs() else {
      if let documentID {
        deferAttach(
          window,
          identity: resolvedIdentity,
          documentID: documentID,
          title: title,
          representedURL: representedURL,
          isDirty: isDirty,
          hasEditableBuffer: hasEditableBuffer)
      }
      return true
    }

    if let documentID {
      completeAttach(window, documentID: documentID)
    } else {
      closeEmptyLauncherWindows(except: window)
    }
    return true
  }

  func closeWindowIfEmptyLauncher(_ window: NSWindow?) {
    guard let window else { return }
    // Reaping never closes the window the user is looking at (see
    // `isReapSafe`): an empty launcher the user is focused on is the empty
    // state, not garbage.
    guard isReapSafe(window) else { return }
    let windowID = ObjectIdentifier(window)
    guard contentWindows[windowID]?.window == nil else { return }
    launcherWindows.removeValue(forKey: windowID)
    closeWindow(window)
  }

  /// Architectural invariant for the empty/no-document state: reaping is
  /// cleanup of REDUNDANT or PHANTOM empty launchers (notably the invisible
  /// `<untitled>` WindowGroup scenes SwiftUI leaks) — it must NEVER close the
  /// window the user is actually looking at. A visible, focused window IS the
  /// user's surface (an open document OR the empty-state placeholder); it may
  /// only be closed by an explicit user action (red button, Close menu →
  /// `closeDocumentWindow`/`closeAllDocumentWindows`), never as a reap side
  /// effect. This is what keeps the empty state durable instead of flashing
  /// and dying.
  private func isReapSafe(_ window: NSWindow) -> Bool {
    !(window.isVisible && (window.isKeyWindow || window.isMainWindow))
  }

  private func completeAttach(_ window: NSWindow, documentID: URL) {
    if orderedDocumentIDs.insert(documentID).inserted {
      orderAndActivateWindow(window)
    }
    closeEmptyLauncherWindows(except: window)
  }

  private func releaseStaleDocumentMappings(for window: NSWindow, keeping documentID: URL?) {
    let staleIDs = windowsByDocumentID.compactMap { key, value in
      value.window === window && key != documentID ? key : nil
    }
    for staleID in staleIDs {
      DebugTrace.log("release stale mapping \(staleID.lastPathComponent) from '\(window.title)'")
      windowsByDocumentID.removeValue(forKey: staleID)
      orderedDocumentIDs.remove(staleID)
    }
  }

  @discardableResult
  private func publish(
    identity: DocumentIdentity,
    displayTitle: String,
    fileURL: URL?,
    isDirty: Bool,
    window: NSWindow
  ) -> Bool {
    let identity = identity.standardized
    if let existing = windowsByIdentity[identity]?.window, existing !== window {
      return false
    }

    let association = WeakWindow(window)
    let descriptor = OpenDocumentDescriptor(
      identity: identity,
      displayTitle: displayTitle,
      fileURL: fileURL?.standardizedFileURL,
      isDirty: isDirty,
      windowAssociation: association)

    if let index = openDocuments.firstIndex(where: { $0.window === window }) {
      let previousIdentity = openDocuments[index].identity
      if previousIdentity != identity {
        windowsByIdentity.removeValue(forKey: previousIdentity)
        if let previousURL = openDocuments[index].fileURL {
          windowsByDocumentID.removeValue(forKey: previousURL)
          orderedDocumentIDs.remove(previousURL)
        }
      }
      openDocuments[index] = descriptor
    } else if let index = openDocuments.firstIndex(where: { $0.identity == identity }) {
      openDocuments[index] = descriptor
    } else {
      openDocuments.append(descriptor)
    }
    windowsByIdentity[identity] = association
    return true
  }

  private func removeDescriptors(for window: NSWindow, keeping identity: DocumentIdentity?) {
    let removed = openDocuments.filter { $0.window === window && $0.identity != identity }
    guard !removed.isEmpty else { return }
    for descriptor in removed {
      windowsByIdentity.removeValue(forKey: descriptor.identity)
    }
    openDocuments.removeAll { $0.window === window && $0.identity != identity }
  }

  private func forgetOpenDocument(_ identity: DocumentIdentity) {
    windowsByIdentity.removeValue(forKey: identity.standardized)
    openDocuments.removeAll { $0.identity == identity.standardized }
  }

  /// Close the window/tab currently showing `documentID` (sidebar "Close from
  /// Open Files"). The close drives the normal teardown → forgetOpenDocument, so
  /// the published list updates itself; no direct list mutation here.
  func closeDocumentWindow(_ documentID: URL) {
    closeDocument(.file(documentID.standardizedFileURL))
  }

  func closeDocument(_ identity: DocumentIdentity) {
    guard let window = windowsByIdentity[identity.standardized]?.window else { return }
    closeWindow(window)
  }

  /// Associates a document window with the controller driving its session. The
  /// window's SwiftUI root registers here once its window resolves and drops the
  /// association when the window closes; stale weak entries clear lazily.
  func registerController(_ controller: AppController, for window: NSWindow) {
    controllersByWindow[ObjectIdentifier(window)] = WeakController(controller)
  }

  func unregisterController(for window: NSWindow) {
    controllersByWindow.removeValue(forKey: ObjectIdentifier(window))
  }

  /// The controller owning the window that currently shows `identity`, so a
  /// cross-window close routes its dirty guard through the target's own session.
  func controller(for identity: DocumentIdentity) -> AppController? {
    guard let window = windowsByIdentity[identity.standardized]?.window else { return nil }
    return controllersByWindow[ObjectIdentifier(window)]?.controller
  }

  func activate(_ identity: DocumentIdentity) {
    guard let window = windowsByIdentity[identity.standardized]?.window else { return }
    orderAndActivateWindow(window)
  }

  /// Close every open document tab (sidebar "Clear Open Files"). Snapshot first:
  /// closeWindow mutates the maps the list is derived from.
  func closeAllDocumentWindows() {
    var seen: Set<ObjectIdentifier> = []
    let windows = openDocuments.compactMap(\.window).filter {
      seen.insert(ObjectIdentifier($0)).inserted
    }
    for window in windows { closeWindow(window) }
  }

  private func mergeExistingWindowIntoCurrentTabsIfNeeded(_ window: NSWindow) {
    guard let target = currentMergeTarget(),
      target !== window,
      !areWindowsInSameTabGroup(target, window)
    else {
      return
    }

    prepareTabbedWindow(target)
    prepareTabbedWindow(window)
    mergeWindowIntoTabs(target, window)
  }

  private func areWindowsInSameTabGroup(_ lhs: NSWindow, _ rhs: NSWindow) -> Bool {
    lhs.tabbedWindows?.contains { $0 === rhs } == true
      || rhs.tabbedWindows?.contains { $0 === lhs } == true
  }

  private func deferOpen(_ ref: DocumentRef, documentID: URL) {
    guard deferredOpenDocumentIDs.insert(documentID).inserted else { return }
    scheduleDeferredMainWork { [weak self] in
      guard let self else { return }
      deferredOpenDocumentIDs.remove(documentID)
      open(ref)
    }
  }

  private func deferAttach(
    _ window: NSWindow,
    identity: DocumentIdentity?,
    documentID: URL,
    title: String?,
    representedURL: URL?,
    isDirty: Bool,
    hasEditableBuffer: Bool
  ) {
    guard deferredAttachDocumentIDs.insert(documentID).inserted else { return }
    scheduleDeferredMainWork { [weak self, weak window] in
      guard let self else { return }
      deferredAttachDocumentIDs.remove(documentID)
      guard let window else { return }
      // Carry the FULL attach metadata: a bare re-attach would re-publish the
      // descriptor with the default `isDirty: false`, clobbering a dirty
      // window's unsaved indicator once the modal turn that forced the defer
      // clears.
      attach(
        window,
        identity: identity,
        documentID: documentID,
        title: title,
        representedURL: representedURL,
        isDirty: isDirty,
        hasEditableBuffer: hasEditableBuffer)
    }
  }

  private func closeEmptyLauncherWindowIfDocumentTabsExist(_ window: NSWindow) {
    guard hasContentWindow else {
      return
    }
    closeEmptyLauncherWindows(except: nil)
  }

  private func closeEmptyLauncherWindows(except activeWindow: NSWindow?) {
    // Attach churn used to queue a separate sweep timer per call; one pending
    // sweep is enough — it reads the LATEST spared window at fire time.
    launcherSweepSparedWindow = activeWindow.map(WeakWindow.init)
    guard !launcherSweepPending else { return }
    launcherSweepPending = true
    scheduleLauncherWindowSweep { [weak self] in
      guard let self else { return }
      launcherSweepPending = false
      let activeWindow = launcherSweepSparedWindow?.window
      purgeClosedLauncherWindows()
      let allWindows = applicationWindows()
      let reapable = allWindows.filter {
        $0 !== activeWindow && self.isEmptyLauncherWindow($0, includingUntracked: true)
      }
      self.reapLaunchersKeepingLastWindow(reapable, among: allWindows)
    }
  }

  /// Close the reapable empty launchers — but NEVER if it would leave the app
  /// with zero windows. Reaping the only window leaves the app alive yet
  /// windowless (the empty state simply vanishes), and paired with
  /// reopen-on-empty it degenerates into a reopen→reap→flash loop. As long as
  /// some other window survives the sweep (a real document window, tracked or
  /// not), reap every redundant launcher; only when ALL windows would be reaped
  /// do we keep one so the user still lands on the empty-state surface.
  func reapLaunchersKeepingLastWindow(
    _ reapable: [NSWindow],
    among allWindows: [NSWindow]
  ) {
    // Architectural invariant (see `isReapSafe`): the reaping sweep never
    // closes the window the user is currently looking at. The earlier
    // "windowless" failure was exactly this — the sweep counted a phantom
    // invisible `<untitled>` WindowGroup scene as a survivor and then reaped
    // the visible empty-state window beside it. Drop visible/focused windows
    // from the kill list entirely; they survive on their own merit.
    var toClose = reapable.filter(isReapSafe)
    let toCloseIDs = Set(toClose.map(ObjectIdentifier.init))
    let aSurvivorRemains = allWindows.contains {
      !toCloseIDs.contains(ObjectIdentifier($0)) && isLiveApplicationWindow($0)
    }
    if !aSurvivorRemains, !toClose.isEmpty {
      toClose.removeLast()
    }
    for window in toClose {
      closeWindow(window)
    }
  }

  private func isEmptyLauncherWindow(
    _ window: NSWindow,
    includingUntracked: Bool = false
  ) -> Bool {
    let windowID = ObjectIdentifier(window)
    // A KEY launcher that is a member of a document tab group is the result
    // of the native tab bar's "+" pressed on a SwiftUI-origin tab (the system
    // spawns a WindowGroup scene as a new tab there) — an intentional new-tab
    // gesture the user is looking at; reaping it would make "+" appear to do
    // nothing. Stale group-member launchers (no longer key) ARE reaped, or
    // they accumulate as empty "Pensieve" tabs during tab churn.
    if (window.tabbedWindows?.count ?? 1) > 1 && window.isKeyWindow { return false }
    let isTrackedLauncher = launcherWindows[windowID]?.window === window
    let isUntrackedLauncher =
      includingUntracked && window.title == "Pensieve" && window.representedURL == nil
    guard isTrackedLauncher || isUntrackedLauncher else { return false }
    return contentWindows[windowID]?.window == nil
      && !windowsByDocumentID.values.contains { $0.window === window }
  }

  private func isLiveApplicationWindow(_ window: NSWindow) -> Bool {
    let windowID = ObjectIdentifier(window)
    return window.isVisible
      || launcherWindows[windowID]?.window === window
      || contentWindows[windowID]?.window === window
      || windowsByDocumentID.values.contains { $0.window === window }
      || window.representedURL != nil
      || (!window.title.isEmpty && window.title != "Pensieve" && window.title != "<untitled>")
  }

  private func registerLauncher(_ window: NSWindow) {
    purgeClosedLauncherWindows()
    let windowID = ObjectIdentifier(window)
    contentWindows.removeValue(forKey: windowID)
    window.title = "Pensieve"
    window.representedURL = nil
    launcherWindows[windowID] = WeakWindow(window)
    preferredLauncherID = windowID
    reconcileLauncherWindows()
  }

  private func markContentWindow(_ window: NSWindow) {
    purgeClosedLauncherWindows()
    let windowID = ObjectIdentifier(window)
    launcherWindows.removeValue(forKey: windowID)
    contentWindows[windowID] = WeakWindow(window)
  }

  private func prepareTabbedWindow(_ window: NSWindow) {
    window.tabbingMode = .automatic
    window.tabbingIdentifier = documentTabbingIdentifier
  }

  private func reconcileLauncherWindows() {
    scheduleLauncherWindowSweep { [weak self] in
      guard let self else { return }
      purgeClosedLauncherWindows()
      let preferredLauncher = preferredLauncherID.flatMap { self.launcherWindows[$0]?.window }
      let shouldCloseAllLaunchers =
        hasContentWindow || hasVisibleContentWindow(except: preferredLauncher)
      let allWindows = applicationWindows()
      let reapable = allWindows.filter { window in
        self.isEmptyLauncherWindow(window, includingUntracked: shouldCloseAllLaunchers)
          && (shouldCloseAllLaunchers || window !== preferredLauncher)
      }
      self.reapLaunchersKeepingLastWindow(reapable, among: allWindows)
    }
  }

  private func purgeClosedLauncherWindows() {
    launcherWindows = launcherWindows.filter { $0.value.window != nil }
    contentWindows = contentWindows.filter { $0.value.window != nil }
    untitledTabWindows = untitledTabWindows.filter { $0.value.window != nil }
    // Closed-window identities only matter while the window object is alive
    // (attach() compares against the live instance); once it deallocates the
    // entry is dead weight, so drop it instead of accumulating stale keys.
    closedWindows = closedWindows.filter { $0.value.window != nil }
    if let preferredLauncherID, launcherWindows[preferredLauncherID]?.window == nil {
      self.preferredLauncherID = nil
    }
  }

  private var hasContentWindow: Bool {
    purgeClosedLauncherWindows()
    return contentWindows.values.contains { $0.window != nil }
  }

  private func hasVisibleContentWindow(except launcherWindow: NSWindow?) -> Bool {
    applicationWindows().contains { window in
      guard window !== launcherWindow else { return false }
      guard launcherWindows[ObjectIdentifier(window)]?.window == nil else { return false }
      return isLiveApplicationWindow(window)
    }
  }

  private func normalizedTitle(_ title: String?, fallback: String) -> String {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? fallback : trimmed
  }
}

private final class WeakWindow {
  weak var window: NSWindow?

  init(_ window: NSWindow) {
    self.window = window
  }
}

private final class WeakController {
  weak var controller: AppController?

  init(_ controller: AppController) {
    self.controller = controller
  }
}

struct DocumentWindowAccessor: NSViewRepresentable {
  let documentID: URL?
  let identity: DocumentIdentity?
  let title: String?
  let representedURL: URL?
  let isDirty: Bool
  let hasEditableBuffer: Bool
  var onWindow: ((NSWindow) -> Void)?

  /// SwiftUI re-evaluates this representable on EVERY render pass of the
  /// window root — focus changes, keystrokes, published-object churn. Without
  /// coalescing each pass dispatched a registry attach (plus its launcher
  /// sweep) for every window, which showed up as 10-15 redundant attach calls
  /// per interaction in field traces. The coordinator remembers what was last
  /// attached and only goes to the registry when something it cares about
  /// actually changed.
  final class Coordinator {
    var lastWindowID: ObjectIdentifier?
    var lastIdentity: DocumentIdentity?
    var lastDocumentID: URL?
    var lastTitle: String?
    var lastRepresentedURL: URL?
    var lastIsDirty: Bool?
    var lastHasEditableBuffer: Bool?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  /// Plain `NSView` plus a one-runloop-turn dispatch is a timing heuristic:
  /// if the window arrives later than that single turn (and no further
  /// SwiftUI update fires), the attach never happens. `viewDidMoveToWindow()`
  /// is AppKit's guaranteed signal that the window slot changed, so use it as
  /// an additional attach trigger.
  final class WindowObservingView: NSView {
    var onWindowChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindowChanged?()
    }
  }

  func makeNSView(context: Context) -> NSView {
    let view = WindowObservingView(frame: .zero)
    configure(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let view = nsView as? WindowObservingView else { return }
    configure(view, coordinator: context.coordinator)
  }

  private func configure(_ view: WindowObservingView, coordinator: Coordinator) {
    // Reinstalled on every pass so the callback captures the latest property
    // values of this representable (it is a value type; stale copies would
    // attach outdated titles/documents).
    view.onWindowChanged = { [weak view] in
      guard let view else { return }
      attachIfNeeded(from: view, coordinator: coordinator)
    }
    attachIfNeeded(from: view, coordinator: coordinator)
  }

  private func attachIfNeeded(from view: NSView, coordinator: Coordinator) {
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      let windowID = ObjectIdentifier(window)
      let unchanged =
        coordinator.lastWindowID == windowID
        && coordinator.lastIdentity == identity
        && coordinator.lastDocumentID == documentID
        && coordinator.lastTitle == title
        && coordinator.lastRepresentedURL == representedURL
        && coordinator.lastIsDirty == isDirty
        && coordinator.lastHasEditableBuffer == hasEditableBuffer
      if unchanged { return }

      onWindow?(window)
      let attached = DocumentWindowRegistry.shared.attach(
        window,
        identity: identity,
        documentID: documentID,
        title: title,
        representedURL: representedURL,
        isDirty: isDirty,
        hasEditableBuffer: hasEditableBuffer)
      // Commit the coalescing cache ONLY after the registry accepted this pass.
      // A rejected attach (e.g. a duplicate identity whose owner window still
      // holds the mapping) must stay "changed" so a later render pass — after
      // the owner closes and frees the identity — retries and lands the window
      // in Open Files, instead of being cached as done and left orphaned.
      guard attached else { return }
      coordinator.lastWindowID = windowID
      coordinator.lastIdentity = identity
      coordinator.lastDocumentID = documentID
      coordinator.lastTitle = title
      coordinator.lastRepresentedURL = representedURL
      coordinator.lastIsDirty = isDirty
      coordinator.lastHasEditableBuffer = hasEditableBuffer
    }
  }
}
