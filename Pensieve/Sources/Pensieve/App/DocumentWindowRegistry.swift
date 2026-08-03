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

/// How a freshly opened document window joins the app.
enum DocumentWindowPresentation {
  /// The user asked for this document NOW: its tab goes in front and the app
  /// activates. Every interactive open uses this.
  case activateNow
  /// Bulk restore: the tab joins the group BEHIND the selected one and is never
  /// made key, so it never becomes the selected tab and the tabs already in the
  /// group are not resized around it. The caller orders the final window front
  /// once, so the end state is the same as a run of `activateNow` opens —
  /// without re-laying-out every tab already in the group on the way there.
  case joinTabGroupInBackground
}

/// How much a close that arrived through one window actually closed.
///
/// The Open Files working set turns on this distinction: retiring a document is
/// a decision about the DOCUMENT (the user closed this file), while a window
/// going away is a decision about the WINDOW and leaves every file it held in
/// the set the next launch restores.
enum DocumentCloseScope {
  /// One tab left a window that is still open.
  case tab
  /// The window itself went away, taking every tab in it along.
  case window
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
  ///
  /// The `LaunchIntent` travels WITH the build request rather than through a
  /// registry-wide "current intent" field: the window is built synchronously
  /// but its SwiftUI root starts up later, so two launchers in flight would
  /// read a shared field that had already moved on.
  typealias DocumentWindowFactoryClosure = @MainActor (DocumentRef?, LaunchIntent) -> NSWindow?

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
  /// The launch restore's queue: refs still waiting for their tab, the window
  /// the pass will order front when the queue drains, and whether a step is
  /// already booked for a later run-loop turn.
  private var pendingRestoreRefs: [DocumentRef] = []
  private var restoreFrontmostWindow: WeakWindow?
  private var restoreStepScheduled = false
  /// Documents that reached the screen without the registry presenting them —
  /// see `noteDocumentAlreadyOnScreen`. Consumed by the attach that reports one.
  private var documentsAlreadyOnScreen: Set<URL> = []
  private var launcherReopenPending = false
  private var launcherReopenAwaitingFactory = false
  /// Set once the app starts quitting so the last document window's close does
  /// not resurrect a launcher mid-termination.
  private var isTerminating = false
  /// Set when a quit prompt pass has already run AND consented for the terminate
  /// request currently in flight. One-shot: `consumeTerminationPassLatch()`
  /// disarms it on read.
  private var hasSettledTerminationPass = false
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
  /// provide one automatically. The caller states WHICH of those it is; the
  /// intent decides how much of the previous session the launcher brings back.
  func openLauncherWindow(intent: LaunchIntent) {
    guard let factory = makeDocumentWindow else { return }
    if let launcher = factory(nil, intent) {
      registerLauncher(launcher)
      orderAndActivateWindow(launcher)
    }
  }

  private let canMutateWindowTabs: @MainActor () -> Bool
  private let scheduleDeferredMainWork: (@escaping DeferredMainWork) -> Void
  private let scheduleLauncherWindowSweep: (@escaping DeferredMainWork) -> Void
  /// Hands the next restored tab to a LATER run-loop turn. See
  /// `openRestoredDocuments`: one insertion is main-thread work the app cannot
  /// interrupt, and the window is already on screen while the rest arrive.
  private let scheduleRestoreStep: (@escaping DeferredMainWork) -> Void
  private let mergeWindowIntoTabs: @MainActor (NSWindow, NSWindow) -> Void
  /// Same merge, ordered BEHIND the target: the window joins the tab group
  /// without becoming the selected tab. AppKit only displays the selected tab,
  /// so a window merged this way is never laid out until the user switches to
  /// it — which is what makes a twelve-file restore cost twelve window
  /// constructions instead of twelve full SwiftUI layout + preview renders.
  private let mergeWindowIntoTabsBehind: @MainActor (NSWindow, NSWindow) -> Void
  private let orderAndActivateWindow: @MainActor (NSWindow) -> Void
  private let currentMergeTarget: @MainActor () -> NSWindow?
  private let applicationWindows: @MainActor () -> [NSWindow]
  private let closeWindow: @MainActor (NSWindow) -> Void
  /// The windows sharing `window`'s native tab group, `window` included. A seam
  /// because `NSWindowTabGroup` does not materialize in a headless test bundle,
  /// and the tab-vs-window close scope is decided from exactly this list.
  private let tabGroupWindows: @MainActor (NSWindow) -> [NSWindow]

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
    // A TIMER hop, not `DispatchQueue.main.async`: the main queue's run-loop
    // source drains the blocks enqueued while it is draining, so a chain of
    // `async` steps can run back to back inside ONE turn and never let the app
    // service an event. A deadline in the future forces the run loop around.
    scheduleRestoreStep: @escaping (@escaping DeferredMainWork) -> Void = { work in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
        Task { @MainActor in work() }
      }
    },
    mergeWindowIntoTabs: @escaping @MainActor (NSWindow, NSWindow) -> Void = { target, window in
      target.addTabbedWindow(window, ordered: .above)
    },
    mergeWindowIntoTabsBehind: @escaping @MainActor (NSWindow, NSWindow) -> Void = {
      target, window in
      target.addTabbedWindow(window, ordered: .below)
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
    tabGroupWindows: @escaping @MainActor (NSWindow) -> [NSWindow] = { window in
      window.tabbedWindows ?? [window]
    },
    makeDocumentWindow: DocumentWindowFactoryClosure? = nil
  ) {
    self.canMutateWindowTabs = canMutateWindowTabs
    self.scheduleDeferredMainWork = scheduleDeferredMainWork
    self.scheduleLauncherWindowSweep = scheduleLauncherWindowSweep
    self.scheduleRestoreStep = scheduleRestoreStep
    self.mergeWindowIntoTabs = mergeWindowIntoTabs
    self.mergeWindowIntoTabsBehind = mergeWindowIntoTabsBehind
    self.orderAndActivateWindow = orderAndActivateWindow
    self.currentMergeTarget = currentMergeTarget
    self.applicationWindows = applicationWindows
    self.tabGroupWindows = tabGroupWindows
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
    open(ref, presentation: .activateNow)
  }

  /// The launch restore's bulk open — every ad-hoc file the user left open at
  /// quit, in one pass.
  ///
  /// Opening them one interactive `open(_:)` at a time was the launch
  /// beachball. Each of those calls makes its window the selected tab, and
  /// AppKit answers a tab-group insertion by syncing the frames of the windows
  /// ALREADY in the group to the newcomer
  /// (`-[NSWindowStackController _syncInactiveTabWindowSizesToWindow:]`); every
  /// one of those frame changes forces a synchronous full layout of that tab's
  /// view tree, and a Pensieve document window lays out to a complete Markdown
  /// preview render. Twelve restored files therefore paid a quadratic number of
  /// full renders on the main thread before the app drew anything — minutes, on
  /// a workspace the size of the operator's.
  ///
  /// So the restore joins the tab group WITHOUT selecting each tab, and orders
  /// the last one front once at the end. Same files, same order, same window in
  /// front when the dust settles.
  ///
  /// That removed the quadratic term and NOT the beachball. Measured on the
  /// staged build (twelve ad-hoc files, window on screen at t+0.7s, first event
  /// serviced at t+8.6s): `_syncInactiveTabWindowSizesToWindow:` ends in an
  /// explicit `CA::Transaction::commit()`, and a CoreAnimation commit runs the
  /// PROCESS-WIDE layout pass — so the newcomer's own hosting view, brand new
  /// and entirely dirty, is laid out synchronously inside the insertion whether
  /// or not its tab is selected. A tab behind the selected one does not "wait
  /// to be looked at": it pays its first full SwiftUI layout the moment it
  /// joins the group, ~0.6s of it. Twelve of those back to back is ONE
  /// uninterruptible main-thread block, and by then the window is already on
  /// screen — which is what the operator sees as a frozen app.
  ///
  /// The cost per tab is the tab's own first layout and is not this pass's to
  /// avoid. The freeze is: so the queue is drained ONE tab per run-loop turn.
  /// The app services events between tabs, the window stays alive while the
  /// rest of the working set arrives, and the pass still ends in exactly one
  /// ordering.
  func openRestoredDocuments(_ refs: [DocumentRef]) {
    pendingRestoreRefs.append(contentsOf: refs)
    guard !restoreStepScheduled else { return }
    openNextRestoredDocument()
  }

  /// Records a document as ALREADY on screen in a window the registry did not
  /// present. The launch window loads the first restored file into ITSELF
  /// rather than spawning a tab for it: that window is up from the start, but
  /// its SwiftUI accessor attaches asynchronously — late enough to land after
  /// this pass has fronted its last tab. Without the note, `completeAttach`
  /// reads that attach as the document's first presentation and pulls the
  /// launch window in front of the tab the restore deliberately chose.
  ///
  /// A note describes exactly ONE presentation and the attach reporting it
  /// consumes it, so a later close-and-reopen of the same document is a genuine
  /// first presentation again.
  func noteDocumentAlreadyOnScreen(_ documentID: URL) {
    documentsAlreadyOnScreen.insert(documentID.standardizedFileURL)
  }

  private func openNextRestoredDocument() {
    restoreStepScheduled = false
    if !pendingRestoreRefs.isEmpty {
      let ref = pendingRestoreRefs.removeFirst()
      if let window = open(ref, presentation: .joinTabGroupInBackground) {
        restoreFrontmostWindow = WeakWindow(window)
      }
    }
    guard !pendingRestoreRefs.isEmpty else {
      finishRestorePass()
      return
    }
    restoreStepScheduled = true
    scheduleRestoreStep { [weak self] in
      self?.openNextRestoredDocument()
    }
  }

  private func finishRestorePass() {
    let frontmost = restoreFrontmostWindow?.window
    restoreFrontmostWindow = nil
    guard let frontmost else { return }
    orderAndActivateWindow(frontmost)
  }

  @discardableResult
  private func open(
    _ ref: DocumentRef,
    presentation: DocumentWindowPresentation
  ) -> NSWindow? {
    let documentID = ref.id.standardizedFileURL
    let identity = DocumentIdentity.file(documentID).standardized
    guard canMutateWindowTabs() else {
      deferOpen(ref, documentID: documentID, presentation: presentation)
      return nil
    }

    if let existing = windowsByIdentity[identity]?.window {
      // Belt to handleDocumentWindowClosed's braces: a closed DocumentWindow
      // has its contentView torn down — never resurrect it; drop the dead
      // mapping and fall through to creating a fresh window.
      if existing.contentView != nil {
        DebugTrace.log(
          "registry.open \(documentID.lastPathComponent) -> activate existing '\(existing.title)'")
        mergeExistingWindowIntoCurrentTabsIfNeeded(existing)
        if presentation == .activateNow {
          orderAndActivateWindow(existing)
        }
        closeEmptyLauncherWindows(except: existing)
        return existing
      }
      DebugTrace.log("registry.open \(documentID.lastPathComponent) -> dropping dead mapping")
      windowsByDocumentID.removeValue(forKey: documentID)
      windowsByIdentity.removeValue(forKey: identity)
      orderedDocumentIDs.remove(documentID)
      forgetOpenDocument(identity)
    }

    guard let makeDocumentWindow else {
      DebugTrace.log("registry.open \(documentID.lastPathComponent) -> no window factory wired")
      return nil
    }
    guard let window = makeDocumentWindow(ref, .explicitDocument) else {
      DebugTrace.log("registry.open \(documentID.lastPathComponent) -> factory returned nil")
      return nil
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

    var didJoinTabGroup = false
    if let target = currentMergeTarget(), target !== window {
      prepareTabbedWindow(target)
      prepareTabbedWindow(window)
      // Every window in a tab group ends up sharing one frame — AppKit enforces
      // that on each insertion, and enforces it by RESIZING the windows already
      // in the group, which lays each of their view trees out synchronously.
      // The factory hands us a window sized to its own recipe, so that sync had
      // something to do on every single open. Adopting the target's frame here
      // — before the window has ever been shown, while its hosting view still
      // has nothing laid out — leaves the group already consistent and the sync
      // with nothing to resize.
      window.setFrame(target.frame, display: false)
      switch presentation {
      case .activateNow:
        mergeWindowIntoTabs(target, window)
      case .joinTabGroupInBackground:
        mergeWindowIntoTabsBehind(target, window)
      }
      didJoinTabGroup = true
      DebugTrace.log("merged '\(window.title)' into '\(target.title)' before first presentation")
    }
    // A window with no group to join has no other way onto the screen: order it
    // front even during a restore, or the file "came back" into an invisible
    // window. With a group, the restore's own final ordering is the only one.
    if presentation == .activateNow || !didJoinTabGroup {
      orderAndActivateWindow(window)
    }
    closeEmptyLauncherWindows(except: window)
    return window
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
  ///
  /// The replacement launcher starts with `.dockReopen`: the user emptied the
  /// app on purpose, so the workspace comes back but no document is picked for
  /// them. Starting it as a cold launch is what made `Close` on the last
  /// document look like a no-op — the launcher immediately absorbed
  /// `documents.first` back in.
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
      self.openLauncherWindow(intent: .dockReopen)
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
    guard let makeDocumentWindow, let newWindow = makeDocumentWindow(nil, .newUntitledTab) else {
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
    // A window that started showing a document without going through `open()`
    // has no other way of getting in front — unless it is already there, which
    // is what a note says. Both facts are consumed here: the ordering record is
    // taken either way, the activation only when nobody put it on screen first.
    let isFirstPresentation = orderedDocumentIDs.insert(documentID).inserted
    let wasAlreadyOnScreen = documentsAlreadyOnScreen.remove(documentID) != nil
    if isFirstPresentation, !wasAlreadyOnScreen {
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

  /// Whether `window` is still a live, registered document window. The root
  /// view drops its registration on `willCloseNotification`, so this is the
  /// app's own answer to "did that window survive the close", independent of
  /// AppKit's tab-group bookkeeping.
  func hasRegisteredController(for window: NSWindow) -> Bool {
    controllersByWindow[ObjectIdentifier(window)]?.controller != nil
  }

  /// Answers what a close that arrived through `window` actually took with it.
  ///
  /// AppKit routes the tab's "×" and the window's red button through the SAME
  /// `performClose`, so the gesture cannot be read at the moment it fires. The
  /// scope can: a tab leaving a window that stays open leaves its SIBLING tabs
  /// registered, while a window close takes the whole group down in the same
  /// pass. So the sibling list is captured now and read back once the close has
  /// settled — if any sibling is still a live document window, one tab left a
  /// live window (`.tab`); otherwise the window itself went away (`.window`).
  ///
  /// A window with no tab siblings is `.window` by construction, answered
  /// synchronously: closing the only document window IS closing a window, and
  /// there is nothing to wait for. So is EVERY close once the app is
  /// terminating: quit tears every window down at the same time, and reading
  /// that as the user closing documents would empty the working set the next
  /// launch restores from.
  func resolveCloseScope(
    for window: NSWindow,
    then report: @escaping @MainActor (DocumentCloseScope) -> Void
  ) {
    guard !isTerminating else {
      report(.window)
      return
    }
    let siblings = tabGroupWindows(window).filter { $0 !== window }
    guard !siblings.isEmpty else {
      report(.window)
      return
    }
    scheduleDeferredMainWork { [weak self] in
      guard let self else { return }
      guard !self.isTerminating else {
        report(.window)
        return
      }
      let groupSurvived = siblings.contains { self.hasRegisteredController(for: $0) }
      report(groupSurvived ? .tab : .window)
    }
  }

  /// Every window controller still alive, deduplicated. `TerminationSequence` flushes each window's
  /// pending edit through these directly instead of waiting for `NSWindow.willCloseNotification`:
  /// `applicationWillTerminate` runs BEFORE window teardown, so on a Dock quit or a logout that
  /// per-window hook fires after the app has already decided it is done — far too late to be the
  /// app's final save. Dead weak entries are dropped here rather than left to accumulate.
  func liveDocumentControllers() -> [AppController] {
    controllersByWindow = controllersByWindow.filter { $0.value.controller != nil }
    var seen: Set<ObjectIdentifier> = []
    return controllersByWindow.values.compactMap(\.controller).filter {
      seen.insert(ObjectIdentifier($0)).inserted
    }
  }

  /// The controller that should DRIVE a quit prompt pass. The pass asks EVERY
  /// registered window regardless of who drives it; the driver only decides which
  /// window is asked LAST, so the frontmost one wins — its prompt then reads as
  /// "the window you quit from".
  ///
  /// A quit from the Dock menu, an AppleScript `quit` or a logout has no firing
  /// window at all, which is exactly why this cannot be sourced from the ⌘Q menu
  /// item's focused controller: any registered controller resolves the identical
  /// set. `nil` means no document window is live — a quit with nothing to ask
  /// about.
  func terminationPassDriver() -> AppController? {
    let frontmost = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    if let frontmost,
      let controller = controllersByWindow[ObjectIdentifier(frontmost)]?.controller
    {
      return controller
    }
    return liveDocumentControllers().first
  }

  /// Records that the unsaved-work pass for the terminate request now in flight
  /// has ALREADY run and consented. ⌘Q runs the pass inside its own menu item and
  /// only then calls `NSApplication.terminate(_:)`; without this the AppKit hook
  /// would run a second pass and ask every window twice.
  ///
  /// Armed only on CONSENT, never on Cancel: a cancelled pass must leave the next
  /// terminate request to ask again from scratch.
  func armTerminationPassLatch() {
    hasSettledTerminationPass = true
  }

  /// Reads the latch and immediately disarms it, so it covers exactly ONE
  /// terminate request. A latch that outlived its request would let the NEXT
  /// Dock quit through unprompted — the same silent-loss shape this whole path
  /// exists to close.
  func consumeTerminationPassLatch() -> Bool {
    defer { hasSettledTerminationPass = false }
    return hasSettledTerminationPass
  }

  /// The app's answer to a terminate request, wherever it came from: the Dock
  /// menu's "Quit", an AppleScript `quit`, a logout, or ⌘Q's own
  /// `NSApplication.terminate(_:)`.
  ///
  /// The pass is fully synchronous — `DocumentStore` resolves each dirty session
  /// through `NSAlert.runModal()` — so this answers in ONE shot with
  /// `.terminateNow` / `.terminateCancel`. No `.terminateLater` handshake is
  /// needed, and none is wired: `.terminateLater` obliges the app to call
  /// `reply(toApplicationShouldTerminate:)` exactly once on every path, an
  /// obligation nothing here can drop or double-fire because it never takes it on.
  func resolveTerminationRequest() -> NSApplication.TerminateReply {
    // ⌘Q already asked, in the menu item, and every window consented. Asking
    // again here would prompt each window twice for a single quit.
    if consumeTerminationPassLatch() { return .terminateNow }
    // No live document window means nothing can hold unsaved work.
    guard let driver = terminationPassDriver() else { return .terminateNow }
    return driver.applicationShouldTerminate() ? .terminateNow : .terminateCancel
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

  private func deferOpen(
    _ ref: DocumentRef,
    documentID: URL,
    presentation: DocumentWindowPresentation
  ) {
    guard deferredOpenDocumentIDs.insert(documentID).inserted else { return }
    scheduleDeferredMainWork { [weak self] in
      guard let self else { return }
      deferredOpenDocumentIDs.remove(documentID)
      open(ref, presentation: presentation)
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
      // A sweep is a DEFERRED `asyncAfter`: it cannot be cancelled, so one armed just before the
      // quit fires INSIDE the termination sequence's pumped run loop. Closing a window there posts
      // `willCloseNotification`, which runs a save — a brand-new managed write arriving after the
      // sequence already flushed and drained. The quit tears every window down by itself anyway.
      guard !isTerminating else { return }
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
    // Registry bookkeeping is not evidence of emptiness. A window holding a
    // recovered crash draft has no URL, so the accessor never publishes a
    // document identity and it stays filed as a "launcher" — the sweep used to
    // reap it 0.2s after the draft landed in it. A window still waiting for its
    // launch restore is the mirror case: the document IS coming, it just has
    // not reached the accessor yet, and on a slow workspace the timer wins.
    // Ask the session what it actually holds before reaping anything.
    if windowHoldsLiveWork(window) { return false }
    let isTrackedLauncher = launcherWindows[windowID]?.window === window
    let isUntrackedLauncher =
      includingUntracked && window.title == "Pensieve" && window.representedURL == nil
    guard isTrackedLauncher || isUntrackedLauncher else { return false }
    return contentWindows[windowID]?.window == nil
      && !windowsByDocumentID.values.contains { $0.window === window }
  }

  /// Whether the session driving `window` holds work, is still resolving
  /// whether it will, or has work in flight that has not reached the session
  /// yet. Windows with no registered controller (untracked AppKit windows,
  /// tests without a controller) report false and stay sweepable.
  private func windowHoldsLiveWork(_ window: NSWindow) -> Bool {
    guard let controller = controllersByWindow[ObjectIdentifier(window)]?.controller else {
      return false
    }
    return controller.hasEditableBuffer
      || controller.isAwaitingLaunchRestore
      || controller.hasPendingImportWork
      // A large document being read off the main actor: real work, no buffer yet.
      || controller.hasPendingDocumentLoad
  }

  /// Files `window` as a content window even though no document identity backs
  /// it. Used when a window adopts a recovery draft: the work is real, the URL
  /// is not, and only the session knows.
  func markWindowAsContent(_ window: NSWindow) {
    markContentWindow(window)
  }

  /// Re-runs the launcher sweep after a window's launch decision settles, so a
  /// window protected while restoring is re-evaluated once the answer is known.
  func reconcileLaunchersAfterRestoreSettled() {
    reconcileLauncherWindows()
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
      // Same reason as the sweep in `closeEmptyLauncherWindows`: an uncancellable deferred reap must
      // not close windows — and so trigger saves — while the termination sequence is running.
      guard !isTerminating else { return }
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
