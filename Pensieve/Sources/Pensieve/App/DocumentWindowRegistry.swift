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

private enum DocumentMergeTargetSelection {
  /// Interactive opens follow the document window that is current now.
  case current
  /// A startup restore is one transaction spread over several run-loop turns.
  /// Its owner is captured once; focus changes cannot redirect later tabs.
  case fixed(NSWindow?)
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

/// WHICH AFFORDANCE asked a window to close, as opposed to how much the close
/// turned out to take with it (`DocumentCloseScope`).
///
/// This distinction is the operator's 2026-08-14 decision: a control must have
/// stable semantics independent of the current UI layout. A tab's "×" means
/// "retire this document" whether the window holds five tabs or one, and the red
/// traffic-light button means "this window goes away" just as invariantly.
/// Inferring the meaning from the surviving sibling count made the SAME control
/// mean two different things depending on how many tabs happened to be open.
///
/// Only `.tab` is a positive claim. Everything else — the red button,
/// `Shift+Cmd+W`, a programmatic close, a close arriving with no event to read —
/// is `.unreadable` and is served by the scope resolution that was here before,
/// so a gesture this app cannot recognise never changes behaviour.
enum WindowCloseGesture {
  /// A click landed inside the window's native tab bar. The only affordance
  /// there that can close anything is a tab's "×".
  case tab
  /// Nothing about the close identifies it as a tab gesture.
  case unreadable
}

/// The native-window boundary for document tabs.
///
/// AppKit exposes sheets, panels, settings windows and document windows through
/// the same `NSWindow` APIs. Treating "currently key" as "owns a document" is
/// therefore unsafe: a SwiftUI sheet can become key between two restore steps,
/// and `addTabbedWindow` will happily turn that transient surface into the owner
/// of a real document tab group once it is given the shared identifier.
///
/// Keep the role test in one place. The structural predicate protects the
/// `DocumentWindowAccessor` and window-following sinks before they publish a
/// window. The stronger host predicate is for tab mutation: by then the root
/// must also carry Pensieve's explicit document ownership token (or be the
/// factory's `DocumentWindow` subclass).
enum DocumentWindowOwnership {
  /// Pure structural input used by ownership tests and by the AppKit adapter
  /// below. Unit tests must not manufacture real parent/child or sheet
  /// relationships: `addChildWindow` and `beginSheet` may order their operands
  /// on the operator's active desktop even when every fixture starts hidden.
  struct SurfaceRelationship: Equatable {
    let isPanel: Bool
    let hasSheetParent: Bool
    let hasParent: Bool
    let level: NSWindow.Level
    let styleMask: NSWindow.StyleMask
  }

  static func isRootSurface(_ relationship: SurfaceRelationship) -> Bool {
    !relationship.isPanel
      && !relationship.hasSheetParent
      && !relationship.hasParent
      && relationship.level == .normal
      && relationship.styleMask.contains(.titled)
  }

  static func isRootSurface(_ window: NSWindow) -> Bool {
    isRootSurface(
      SurfaceRelationship(
        isPanel: window is NSPanel,
        hasSheetParent: window.sheetParent != nil,
        hasParent: window.parent != nil,
        level: window.level,
        styleMask: window.styleMask))
  }

  @MainActor
  static func isDocumentHost(_ window: NSWindow) -> Bool {
    isRootSurface(window)
      && (window is DocumentWindow
        || window.tabbingIdentifier == WindowChromeRecipe.documentTabbingIdentifier)
  }

  /// Claims a root that actually hosts `DocumentWindowRootView`. The accessor
  /// performs this synchronously from `viewDidMoveToWindow`, before its deferred
  /// registry attach, so cold-start restore can identify the scene-owned
  /// launcher without falling back to "whatever is key". A transient surface
  /// can never acquire the token through this entry.
  @discardableResult
  @MainActor
  static func claimDocumentHost(_ window: NSWindow) -> Bool {
    guard isRootSurface(window) else { return false }
    if window.tabbingIdentifier != WindowChromeRecipe.documentTabbingIdentifier {
      window.tabbingIdentifier = WindowChromeRecipe.documentTabbingIdentifier
      DebugTrace.logWindowEvent("document-host.claim", window: window)
    }
    return true
  }

  /// Adding or re-parenting native tabs while any member of that group owns a
  /// sheet asks AppKit to reconcile two independent ownership graphs at once.
  /// Reject that individual group mutation. Do not turn this into a global
  /// polling gate: provider onboarding can stay open indefinitely, and retrying
  /// every pending restore tab every 100 ms would be a permanent timer storm.
  @MainActor
  static func isTabMutationHost(_ window: NSWindow) -> Bool {
    guard isDocumentHost(window) else { return false }
    let isClear = tabGroupAllowsMutation(
      attachedSheetStates: (window.tabbedWindows ?? [window]).map { $0.attachedSheet != nil })
    if !isClear {
      DebugTrace.logWindowEvent("document-host.tab-mutation-blocked-by-sheet", window: window)
    }
    return isClear
  }

  static func tabGroupAllowsMutation(attachedSheetStates: [Bool]) -> Bool {
    attachedSheetStates.allSatisfy { !$0 }
  }
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
  private var restoreMergeTarget: WeakWindow?
  private var restoreStepScheduled = false
  private var restorePassInProgress = false
  /// Every document host that belongs to the current restore transaction.
  ///
  /// The pass spans many event-loop turns. A window the user creates or selects
  /// during that time is intentionally NOT added here, even when AppKit places
  /// it in the same native tab group. That gives `finishRestorePass` an
  /// ownership test stronger than "Pensieve is active": it can distinguish the
  /// restore's own selected tab from a newer user selection and avoid stealing
  /// that selection at completion.
  private var restoreParticipantWindows: [ObjectIdentifier: WeakWindow] = [:]
  /// Windows closed while the current restore transaction is alive. Reusable
  /// SwiftUI scene windows cannot be factory-tombstoned forever, but they must
  /// not be re-selected as this pass's host during their close turn.
  private var restoreClosedWindows: [ObjectIdentifier: WeakWindow] = [:]
  /// Documents that reached the screen without the registry presenting them —
  /// see `noteDocumentAlreadyOnScreen`. Consumed by the attach that reports one.
  private var documentsAlreadyOnScreen: Set<URL> = []
  /// Set once the app starts quitting so deferred window maintenance does not
  /// mutate the window graph while AppKit tears the application down.
  private var isTerminating = false
  /// Set when a quit prompt pass has already run AND consented for the terminate
  /// request currently in flight. One-shot: `consumeTerminationPassLatch()`
  /// disarms it on read.
  private var hasSettledTerminationPass = false
  /// Observers and factory bindings.
  var makeDocumentWindow: DocumentWindowFactoryClosure?

  /// Whether New can materialize a second document instance instead of
  /// replacing the controller's current session.
  var canOpenUntitledTab: Bool { makeDocumentWindow != nil }

  /// Mark the app as terminating (called from `applicationWillTerminate`) so
  /// deferred sweeps and close-scope resolution stop mutating window state.
  func beginTermination() {
    isTerminating = true
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

  /// The app's ONE way to materialize a document host when none exists: the
  /// factory launcher above, or — before SwiftUI has installed that factory —
  /// the `NSDocumentController` fallback that lets AppKit build the first scene.
  ///
  /// Every windowless entry point funnels here (cold-launch fallback, Dock
  /// reopen, an external file open, and the zero-window File menu), so the
  /// "which of the two paths applies" decision exists once. A second copy of it
  /// is how one caller ends up creating a host the others cannot see.
  ///
  /// Returns whether a document-capable surface actually resulted, so a caller
  /// with a one-shot guard (see `LaunchIntentCoordinator`) can tell a real host
  /// from a factory that refused.
  @discardableResult
  func openDocumentHost(intent: LaunchIntent) -> Bool {
    guard makeDocumentWindow != nil else {
      return NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
    }
    openLauncherWindow(intent: intent)
    return hasLiveDocumentCapableWindow()
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
  /// Ordering WITHOUT taking application focus, for the end of a restore pass
  /// the user has already walked away from. See `finishRestorePass`.
  private let orderWindowWithoutActivating: @MainActor (NSWindow) -> Void
  /// Whether Pensieve is the app the user is currently in. A seam so the restore
  /// pins can state which side of that they are exercising instead of inheriting
  /// whatever the test host's activation state happens to be.
  private let isApplicationActive: @MainActor () -> Bool
  /// The actual selected/key surface at restore completion. Kept separate from
  /// `currentMergeTarget`: merge routing is pinned for the transaction, while
  /// this value answers whether the user selected something outside it.
  private let currentKeyWindow: @MainActor () -> NSWindow?
  private let currentMergeTarget: @MainActor () -> NSWindow?
  private let applicationWindows: @MainActor () -> [NSWindow]
  private let closeWindow: @MainActor (NSWindow) -> Void
  private let setStartupRestoreInProgress: @MainActor (Bool) -> Void
  /// The windows sharing `window`'s native tab group, `window` included. A seam
  /// because `NSWindowTabGroup` does not materialize in a headless test bundle,
  /// and the tab-vs-window close scope is decided from exactly this list.
  private let tabGroupWindows: @MainActor (NSWindow) -> [NSWindow]
  /// Structural tab-mutation eligibility. Production delegates to
  /// `DocumentWindowOwnership`; unit tests can inject a relationship snapshot
  /// instead of publishing a native sheet merely to make this answer false.
  private let isTabMutationHost: @MainActor (NSWindow) -> Bool
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
      NSApplication.shared.activate(ignoringOtherApps: true)
    },
    orderWindowWithoutActivating: @escaping @MainActor (NSWindow) -> Void = { window in
      window.orderFront(nil)
    },
    isApplicationActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
    currentKeyWindow: @escaping @MainActor () -> NSWindow? = {
      NSApplication.shared.keyWindow
    },
    currentMergeTarget: @escaping @MainActor () -> NSWindow? = {
      NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        ?? NSApplication.shared.windows.first
    },
    applicationWindows: @escaping @MainActor () -> [NSWindow] = {
      NSApplication.shared.windows
    },
    closeWindow: @escaping @MainActor (NSWindow) -> Void = { window in
      window.close()
    },
    setStartupRestoreInProgress: @escaping @MainActor (Bool) -> Void = { inProgress in
      ProviderOnboardingCoordinator.shared.setStartupRestoreInProgress(inProgress)
    },
    tabGroupWindows: @escaping @MainActor (NSWindow) -> [NSWindow] = { window in
      window.tabbedWindows ?? [window]
    },
    isTabMutationHost: @escaping @MainActor (NSWindow) -> Bool = {
      DocumentWindowOwnership.isTabMutationHost($0)
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
    self.orderWindowWithoutActivating = orderWindowWithoutActivating
    self.isApplicationActive = isApplicationActive
    self.currentKeyWindow = currentKeyWindow
    self.currentMergeTarget = currentMergeTarget
    self.applicationWindows = applicationWindows
    self.tabGroupWindows = tabGroupWindows
    self.isTabMutationHost = isTabMutationHost
    self.closeWindow = closeWindow
    self.setStartupRestoreInProgress = setStartupRestoreInProgress
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
    guard !refs.isEmpty else { return }
    if !restorePassInProgress {
      restorePassInProgress = true
      restoreClosedWindows.removeAll()
      restoreParticipantWindows.removeAll()
      restoreMergeTarget = currentMergeTarget().flatMap(restoreEligibleDocumentHost).map(
        WeakWindow.init)
      if let target = restoreMergeTarget?.window {
        noteRestoreParticipant(target)
      }
      setStartupRestoreInProgress(true)
    }
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
    guard !pendingRestoreRefs.isEmpty else {
      finishRestorePass()
      return
    }

    if let pinned = restoreMergeTarget?.window {
      if restoreEligibleDocumentHost(pinned) == nil {
        restoreMergeTarget = nil
        if restoreFrontmostWindow?.window === pinned {
          restoreFrontmostWindow = nil
        }
      } else if !canMutateWindowTabs()
        || !isTabMutationHost(pinned)
      {
        scheduleNextRestoreStep()
        return
      }
    }

    if restoreMergeTarget?.window == nil,
      let transactionSurvivor = restoreFrontmostWindow?.window.flatMap(
        restoreEligibleDocumentHost)
    {
      restoreMergeTarget = WeakWindow(transactionSurvivor)
      noteRestoreParticipant(transactionSurvivor)
      // Adoption is a host change, not a licence to mutate: the survivor can be
      // carrying a sheet on the very turn it is adopted. Without this the ref
      // went to `open(_:presentation:mergeTargetSelection:)`, whose validation
      // rejects a sheeted target, and the document fanned out as a standalone
      // window — the split restore the pinned and candidate paths already park
      // for.
      guard canMutateWindowTabs(),
        isTabMutationHost(transactionSurvivor)
      else {
        scheduleNextRestoreStep()
        return
      }
    }

    if restoreMergeTarget?.window == nil,
      let candidate = currentMergeTarget().flatMap(restoreEligibleDocumentHost)
    {
      restoreMergeTarget = WeakWindow(candidate)
      noteRestoreParticipant(candidate)
      guard canMutateWindowTabs(), isTabMutationHost(candidate) else {
        scheduleNextRestoreStep()
        return
      }
    } else if !canMutateWindowTabs() {
      scheduleNextRestoreStep()
      return
    }

    let ref = pendingRestoreRefs.removeFirst()
    // `open` ACTIVATES an already-open identity instead of creating one, and the
    // most likely thing a user does during a slow restore is click a file the
    // pass has not reached yet. That window is theirs — it was built by their
    // interactive open and fronted for them — so the pass must not adopt it:
    // claiming it as a participant makes `finishRestorePass` read the user's own
    // selection as its own and yank focus onto the pass's last tab, and adopting
    // it as `restoreMergeTarget` would silently make it this transaction's host.
    // Only a window this step actually created belongs to the transaction.
    let refIdentity = DocumentIdentity.file(ref.id.standardizedFileURL).standardized
    let windowBeforeOpen = windowsByIdentity[refIdentity]?.window
    if let window = open(
      ref,
      presentation: .joinTabGroupInBackground,
      mergeTargetSelection: .fixed(restoreMergeTarget?.window)
    ), window !== windowBeforeOpen {
      // If the original host disappeared, the first successfully created
      // replacement becomes the host for the rest of THIS transaction. Never
      // follow a later arbitrary key window between restore turns.
      if restoreMergeTarget?.window == nil {
        restoreMergeTarget = WeakWindow(window)
      }
      noteRestoreParticipant(window)
      restoreFrontmostWindow = WeakWindow(window)
    }
    guard !pendingRestoreRefs.isEmpty else {
      finishRestorePass()
      return
    }
    scheduleNextRestoreStep()
  }

  /// Books the next turn of the pass — both for progress (one tab per turn) and
  /// for PARKING: every gate above answers a refusal by re-booking this same
  /// step instead of ejecting the ref.
  ///
  /// The tradeoff is deliberate and is a polling one. While a modal or a sheet
  /// holds the host, the pass re-asks on the restore scheduler's cadence (20 ms)
  /// and makes no progress, so a modal that never goes away keeps the remaining
  /// refs — and the onboarding gate this pass owns — pending for as long as it
  /// hangs. That is fail-closed by choice: the alternative is the mis-merge this
  /// hardening exists to prevent, where a blocked ref leaves the transaction,
  /// follows whatever window is key later, and splits the restore across roots.
  /// The polling is bounded to the life of one restore pass, and the ban on
  /// polling gates in `DocumentWindowOwnership.isTabMutationHost` is about
  /// process-wide retry timers, not this transaction's own turn schedule.
  private func scheduleNextRestoreStep() {
    guard !restoreStepScheduled else { return }
    restoreStepScheduled = true
    scheduleRestoreStep { [weak self] in
      self?.openNextRestoredDocument()
    }
  }

  private func finishRestorePass() {
    let frontmost =
      restoreFrontmostWindow?.window.flatMap(restoreEligibleDocumentHost)
      ?? restoreMergeTarget?.window.flatMap(restoreEligibleDocumentHost)
    let selectedWindow = currentKeyWindow()
    let userSelectedOutsideRestore = selectedWindow.map { !isRestoreParticipant($0) } ?? false
    restoreFrontmostWindow = nil
    restoreMergeTarget = nil
    restoreClosedWindows.removeAll()
    restorePassInProgress = false
    if let frontmost {
      // A restore pass spans many run-loop turns and can run for seconds on a
      // large working set. The user is free to switch to another app while it
      // does, and this closing order is not a reason to yank them back:
      // activation is only ever the completion of something they asked Pensieve
      // for. When the app is NOT frontmost the window still takes its place in
      // the window order — so the restore's chosen tab is what they find when
      // they come back — without pulling focus across the app boundary.
      if isApplicationActive(), !userSelectedOutsideRestore {
        orderAndActivateWindow(frontmost)
      } else if !isApplicationActive() {
        orderWindowWithoutActivating(frontmost)
      }
    }
    restoreParticipantWindows.removeAll()
    // Final tab selection is part of the transaction. Releasing onboarding
    // before this ordering could attach its sheet to the previous selected tab
    // and make AppKit re-parent the group under an active sheet one last time.
    setStartupRestoreInProgress(false)
  }

  private func noteRestoreParticipant(_ window: NSWindow) {
    restoreParticipantWindows[ObjectIdentifier(window)] = WeakWindow(window)
  }

  private func isRestoreParticipant(_ window: NSWindow) -> Bool {
    restoreParticipantWindows[ObjectIdentifier(window)]?.window === window
  }

  @discardableResult
  private func open(
    _ ref: DocumentRef,
    presentation: DocumentWindowPresentation,
    mergeTargetSelection: DocumentMergeTargetSelection = .current
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
    guard DocumentWindowOwnership.claimDocumentHost(window) else {
      DebugTrace.log("registry.open \(documentID.lastPathComponent) -> factory returned transient")
      DebugTrace.logWindowEvent("registry.open.rejected-factory-window", window: window)
      closeWindow(window)
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
    let mergeTarget: NSWindow?
    switch mergeTargetSelection {
    case .current:
      mergeTarget = currentDocumentMergeTarget()
    case .fixed(let candidate):
      mergeTarget = candidate.flatMap(validatedDocumentMergeTarget)
    }
    if let target = mergeTarget, target !== window {
      guard prepareTabbedWindow(target), prepareTabbedWindow(window) else {
        orderAndActivateWindow(window)
        closeEmptyLauncherWindows(except: window)
        return window
      }
      // Every window in a tab group ends up sharing one frame — AppKit enforces
      // that on each insertion, and enforces it by RESIZING the windows already
      // in the group, which lays each of their view trees out synchronously.
      // The factory hands us a window sized to its own recipe, so that sync had
      // something to do on every single open. Adopting the target's frame here
      // — before the window has ever been shown, while its hosting view still
      // has nothing laid out — leaves the group already consistent and the sync
      // with nothing to resize.
      window.setFrame(target.frame, display: false)
      DebugTrace.logWindowMutation("registry.open.add-tab.begin", owner: target, member: window)
      switch presentation {
      case .activateNow:
        mergeWindowIntoTabs(target, window)
      case .joinTabGroupInBackground:
        mergeWindowIntoTabsBehind(target, window)
      }
      DebugTrace.logWindowMutation("registry.open.add-tab.end", owner: target, member: window)
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
  /// notifications. Both routes reconcile registry state; only never-reused
  /// factory windows are tombstoned against late SwiftUI attach callbacks.
  ///
  /// Closing the last window deliberately leaves the process windowless. A
  /// later Dock activation is the sole owner of creating a replacement
  /// launcher (`applicationShouldHandleReopen`). Creating one here made the red
  /// close button appear ineffective and could restore an older document into
  /// a brand-new native window while the closing window was still fading out.
  func handleWindowClosed(
    _ window: NSWindow,
    tombstonePolicy: WindowCloseTombstonePolicy
  ) {
    reconcileClosedWindowState(window)
    if tombstonePolicy == .factoryWindow {
      closedWindows[ObjectIdentifier(window)] = WeakWindow(window)
    }
  }

  /// Compatibility entry for process-wide reusable SwiftUI/AppKit scene closes.
  /// Production routes may call the explicit policy API directly; this wrapper
  /// reconciles the scene without tombstoning a reusable window.
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
    if restorePassInProgress {
      restoreClosedWindows[windowID] = WeakWindow(window)
      if restoreMergeTarget?.window === window {
        restoreMergeTarget = nil
      }
      if restoreFrontmostWindow?.window === window {
        restoreFrontmostWindow = nil
      }
    }
    releaseStaleDocumentMappings(for: window, keeping: nil)
    removeDescriptors(for: window, keeping: nil)
    contentWindows.removeValue(forKey: windowID)
    launcherWindows.removeValue(forKey: windowID)
    untitledTabWindows.removeValue(forKey: windowID)
    fallbackUntitledIdentities.removeValue(forKey: windowID)
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

  /// Whether the app still has a window that could HOST A DOCUMENT.
  ///
  /// `applicationHasLiveWindow()` answers the broader question — "is any surface
  /// of this app alive" — and Settings, About and every other auxiliary window
  /// answers it `true` while being structurally unable to take a file. An
  /// external open (Finder double-click, `open`, Dock drop) arriving at a
  /// process whose only remaining window is Settings therefore found no target
  /// controller, was told a live window existed, never asked for a host, and
  /// parked its URL in `pendingURLs` forever. Callers deciding whether a
  /// DOCUMENT surface has to be materialized ask this one instead.
  func hasLiveDocumentCapableWindow() -> Bool {
    purgeClosedLauncherWindows()
    if launcherWindows.values.contains(where: { $0.window != nil })
      || contentWindows.values.contains(where: { $0.window != nil })
      || windowsByDocumentID.values.contains(where: { $0.window != nil })
    {
      return true
    }
    return applicationWindows().contains(where: isLiveDocumentCapableWindow)
  }

  /// The native tab bar's "+" (and the system `newWindowForTab:` action), for
  /// EVERY window class this app puts documents in.
  ///
  /// The single decision point the two window paths were missing. A factory
  /// `DocumentWindow` reaches it through its own `newWindowForTab` override; a
  /// SwiftUI scene-owned window — the launcher, which is where a recovered
  /// draft lives — reaches it through `DocumentWindowTabBridge`. Both arrive
  /// here ONCE. In Pensieve v1 this gesture is deterministic: it always creates
  /// a tab in the source group, exactly like ⌘N / ⌘T, and never delegates
  /// placement to macOS's global tab preference.
  @discardableResult
  func newDocumentForTab(from sourceWindow: NSWindow) -> Bool {
    guard DocumentWindowOwnership.isDocumentHost(sourceWindow) else {
      DebugTrace.log("newDocumentForTab rejected ineligible source '\(sourceWindow.title)'")
      return false
    }
    return newUntitledTab(from: sourceWindow)
  }

  /// The tab bar's "+" button: opens a NEW untitled document tab in the same
  /// tab group instead of the system default (a detached standalone window).
  /// Mirrors `open()`'s modal contract: deferred, not dropped, while a modal
  /// run loop blocks native tab mutation.
  @discardableResult
  func newUntitledTab(from window: NSWindow) -> Bool {
    guard isTabMutationHost(window) else {
      DebugTrace.log("newUntitledTab rejected ineligible source '\(window.title)'")
      return false
    }
    guard canOpenUntitledTab else {
      DebugTrace.log("newUntitledTab -> no window factory wired")
      return false
    }
    guard canMutateWindowTabs() else {
      scheduleDeferredMainWork { [weak self, weak window] in
        guard let self, let window else { return }
        newUntitledTab(from: window)
      }
      return true
    }
    guard let newWindow = makeUntitledWindow() else { return false }
    guard isTabMutationHost(window) else {
      DebugTrace.log("newUntitledTab source became ineligible during factory creation")
      retireUnplacedUntitledWindow(newWindow)
      return false
    }
    guard prepareTabbedWindow(window) else {
      DebugTrace.log("newUntitledTab source lost document ownership during factory creation")
      retireUnplacedUntitledWindow(newWindow)
      return false
    }
    DebugTrace.log("newUntitledTab from '\(window.title)'")
    DebugTrace.logWindowMutation("registry.new-tab.add.begin", owner: window, member: newWindow)
    mergeWindowIntoTabs(window, newWindow)
    DebugTrace.logWindowMutation("registry.new-tab.add.end", owner: window, member: newWindow)
    orderAndActivateWindow(newWindow)
    return true
  }

  private func makeUntitledWindow() -> NSWindow? {
    guard let makeDocumentWindow, let newWindow = makeDocumentWindow(nil, .newUntitledTab) else {
      DebugTrace.log("new untitled document -> factory unavailable")
      return nil
    }
    guard prepareTabbedWindow(newWindow) else {
      DebugTrace.log("new untitled document -> factory returned transient")
      closeWindow(newWindow)
      return nil
    }
    untitledTabWindows[ObjectIdentifier(newWindow)] = WeakWindow(newWindow)
    markContentWindow(newWindow)
    publishPendingUntitledTab(newWindow)
    return newWindow
  }

  /// Publishes the new tab into Open Files at the moment it is CREATED, before
  /// it is merged and ordered front.
  ///
  /// The native tab group mutates synchronously at the click, while the accessor
  /// that used to be the descriptor's only source attaches several run-loop
  /// turns later. Open Files therefore trailed the tab bar by exactly the number
  /// of tabs still waiting for their SwiftUI root — a sidebar that disagreed
  /// with the tabs above it for as long as that took.
  ///
  /// The identity is minted here and PARKED in `fallbackUntitledIdentities`, so
  /// the accessor's own attach reconciles this row instead of appending a second
  /// one: an attach carrying the session's identity replaces this descriptor in
  /// place (`publish` matches on the window first), and an attach that has no
  /// identity of its own reuses the parked one.
  private func publishPendingUntitledTab(_ window: NSWindow) {
    let windowID = ObjectIdentifier(window)
    let identity = fallbackUntitledIdentities[windowID] ?? .untitled(UUID())
    fallbackUntitledIdentities[windowID] = identity
    _ = publish(
      identity: identity,
      displayTitle: normalizedTitle(window.title, fallback: "Untitled"),
      fileURL: nil,
      isDirty: false,
      window: window)
  }

  /// A factory window that never became a tab. It was already published, so it
  /// has to be retired through the same reconcile a close runs — otherwise the
  /// abandoned window survives as a phantom Open Files row.
  private func retireUnplacedUntitledWindow(_ window: NSWindow) {
    reconcileClosedWindowState(window)
    closeWindow(window)
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
    guard DocumentWindowOwnership.isRootSurface(window) else {
      DebugTrace.log("registry.attach rejected transient window '\(window.title)'")
      DebugTrace.logWindowEvent("registry.attach.rejected-transient", window: window)
      return false
    }
    DebugTrace.log(
      "registry.attach doc=\(documentID?.lastPathComponent ?? "nil") '\(window.title)'"
    )
    // A closed window's SwiftUI accessor can fire one last main-queue pass
    // AFTER the close; re-registering it would resurrect the window as a
    // phantom tab that is visible but half-dead.
    if isFactoryTombstoned(window) {
      DebugTrace.log("registry.attach rejected: window already closed")
      return false
    }
    // Every document window — factory-built, restored, or launcher-promoted —
    // shares the document tabbing identifier so the system keeps grouping them
    // (the "+" button) AND keeps "Window > Merge All Windows" enabled. That menu
    // greys out when windows don't share an identifier, so non-factory windows
    // are normalized ONTO the shared identifier, never nilled into mergeless islands.
    if window.tabbingIdentifier != documentTabbingIdentifier {
      guard prepareTabbedWindow(window) else { return false }
    }
    // The other half of the same normalization. A window this app did not BUILD
    // answers the tab bar's "+" with whatever its own class does — for the
    // SwiftUI scene launcher (and the recovered-draft window that IS it) that
    // is a detached scene window, placement and registry bypassed. Bridged here
    // because this is the one seam every window class reaches on its way into
    // the app, and because the window's real class can only be learned from a
    // real window. Idempotent per class; `DocumentWindow` is skipped, so the
    // factory's own override stays the single route.
    DocumentWindowTabBridge.install(for: window)

    let windowID = ObjectIdentifier(window)
    var resolvedIdentity =
      identity?.standardized
      ?? documentID.map { DocumentIdentity.file($0.standardizedFileURL) }
    if resolvedIdentity == nil, hasEditableBuffer {
      resolvedIdentity = fallbackUntitledIdentities[windowID] ?? .untitled(UUID())
      fallbackUntitledIdentities[windowID] = resolvedIdentity
    }

    guard let resolvedIdentity else {
      // A "+" tab whose session has not reached the accessor yet still owns the
      // pending descriptor minted for it at creation. That row IS the Open Files
      // truth for this tab, so an identity-less pass must not sweep it away and
      // reopen the very gap `publishPendingUntitledTab` closes.
      let isPendingUntitledTab = untitledTabWindows[windowID]?.window === window
      releaseStaleDocumentMappings(for: window, keeping: nil)
      if !isPendingUntitledTab {
        removeDescriptors(for: window, keeping: nil)
      }
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
    // (`openFileInCurrentWindow`, a restore loading into the launch window)
    // must release the previous mapping, or `open()` keeps "activating" this
    // window for documents it no longer shows and the next open of the old
    // document becomes a silent no-op.
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

  /// Whether a root accessor may publish its host into the per-window command
  /// and close-routing surfaces before `attach` reconciles document identity.
  ///
  /// Duplicate identity is intentionally NOT a rejection here: that root is
  /// still a live document host that needs its own controller and close hook,
  /// even while the registry waits for the duplicate owner to release the
  /// identity. A factory tombstone is different — a queued SwiftUI accessor
  /// pass must not resurrect that half-closed native window as `currentWindow`.
  func canPublishDocumentHost(_ window: NSWindow) -> Bool {
    guard DocumentWindowOwnership.isDocumentHost(window) else { return false }
    guard !isFactoryTombstoned(window) else {
      DebugTrace.logWindowEvent("document-accessor.rejected-tombstone", window: window)
      return false
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

  /// Reverse lookup for placement decisions initiated by a controller. Using
  /// the registered owner avoids borrowing whichever unrelated window happens
  /// to be key while a menu command is resolving.
  func window(hosting controller: AppController) -> NSWindow? {
    applicationWindows().first { window in
      controllersByWindow[ObjectIdentifier(window)]?.controller === controller
    }
  }

  /// Whether `window` is the one native surface New may intentionally reuse.
  ///
  /// Buffer state alone cannot answer this. A factory-created untitled tab is
  /// briefly empty while its SwiftUI controller attaches, but it is already a
  /// user-created document surface and a second New must create another tab.
  /// Only a window still owned by the launcher's registry role is reusable.
  func isReusableLauncherWindow(_ window: NSWindow) -> Bool {
    let windowID = ObjectIdentifier(window)
    return launcherWindows[windowID]?.window === window
      && contentWindows[windowID]?.window == nil
      && untitledTabWindows[windowID]?.window == nil
      && !windowsByIdentity.values.contains { $0.window === window }
      && !windowHoldsLiveWork(window)
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

  /// Whether `window` is the ONLY window in its tab group — a close arriving
  /// through it leaves no sibling tab behind.
  ///
  /// Always false while the app is terminating: quit is not a per-tab gesture,
  /// and every window looks lone once the group has been torn down around it.
  func isLoneTab(_ window: NSWindow) -> Bool {
    guard !isTerminating else { return false }
    return tabGroupWindows(window).allSatisfy { $0 === window }
  }

  /// Answers what a close that arrived through `window` actually took with it.
  ///
  /// The GESTURE is authoritative when it can be read at all. AppKit hands the
  /// tab's "×" and the window's red button to the same close primitive, but the
  /// two affordances occupy disjoint regions of the window — the "×" lives
  /// inside the native tab bar's titlebar accessory, the red button in the
  /// standard window-button area (measured; see
  /// `WindowChromeRecipe.tabBarAccessoryFrames`) — so the event AppKit is
  /// dispatching identifies which one fired. A `.tab` gesture is a decision
  /// about the DOCUMENT and answers `.tab` immediately, whatever the tab group
  /// looks like.
  ///
  /// An `.unreadable` gesture falls back to the scope heuristic this method
  /// carried before, which infers from what survives: a tab leaving a window
  /// that stays open leaves its SIBLING tabs registered, while a window close
  /// takes the whole group down in the same pass. So the sibling list is
  /// captured now and read back once the close has settled — if any sibling is
  /// still a live document window, one tab left a live window (`.tab`);
  /// otherwise the window itself went away (`.window`). With no siblings the
  /// heuristic has no resolution left and answers `.window` synchronously,
  /// which is why an unrecognised gesture can never retire a lone window's
  /// file.
  ///
  /// EVERY close is `.window` once the app is terminating: quit tears every
  /// window down at the same time, and reading that as the user closing
  /// documents would empty the working set the next launch restores from.
  func resolveCloseScope(
    for window: NSWindow,
    gesture: WindowCloseGesture = .unreadable,
    then report: @escaping @MainActor (DocumentCloseScope) -> Void
  ) {
    guard !isTerminating else {
      report(.window)
      return
    }
    guard gesture != .tab else {
      report(.tab)
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
    guard let target = currentDocumentMergeTarget(),
      target !== window,
      isTabMutationHost(window),
      !areWindowsInSameTabGroup(target, window)
    else {
      return
    }

    guard prepareTabbedWindow(target), prepareTabbedWindow(window) else { return }
    DebugTrace.logWindowMutation("registry.existing.add-tab.begin", owner: target, member: window)
    mergeWindowIntoTabs(target, window)
    DebugTrace.logWindowMutation("registry.existing.add-tab.end", owner: target, member: window)
  }

  /// Resolves the injected AppKit focus candidate to a proven document host.
  /// Never "repairs" an unknown key window by assigning it the document tabbing
  /// identifier: Settings, a provider sheet or a helper panel must remain what
  /// they are. A scene-owned launcher becomes eligible when its root accessor
  /// attaches and gives it the explicit identifier.
  private func currentDocumentMergeTarget() -> NSWindow? {
    guard let candidate = currentMergeTarget() else { return nil }
    return validatedDocumentMergeTarget(candidate)
  }

  private func validatedDocumentMergeTarget(_ candidate: NSWindow) -> NSWindow? {
    guard restoreEligibleDocumentHost(candidate) != nil,
      isTabMutationHost(candidate)
    else {
      DebugTrace.log("registry.merge rejected non-document target '\(candidate.title)'")
      DebugTrace.logWindowEvent("registry.merge.rejected-target", window: candidate)
      return nil
    }
    return candidate
  }

  private func restoreEligibleDocumentHost(_ candidate: NSWindow) -> NSWindow? {
    let windowID = ObjectIdentifier(candidate)
    guard candidate.contentView != nil,
      !isFactoryTombstoned(candidate),
      restoreClosedWindows[windowID]?.window !== candidate,
      DocumentWindowOwnership.isDocumentHost(candidate)
    else {
      return nil
    }
    return candidate
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
    guard DocumentWindowOwnership.isDocumentHost(window) else {
      DebugTrace.logWindowEvent("registry.content-promotion.rejected-host", window: window)
      return
    }
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

  /// The document-capable half of `isLiveApplicationWindow`: same liveness
  /// evidence, but only for a window that carries Pensieve's document-host
  /// token. A SwiftUI scene launcher acquires that token synchronously in
  /// `DocumentWindowAccessor.viewDidMoveToWindow` (see
  /// `DocumentWindowOwnership.claimDocumentHost`), so an untracked launcher
  /// still counts here — while Settings, About and panels never do.
  private func isLiveDocumentCapableWindow(_ window: NSWindow) -> Bool {
    DocumentWindowOwnership.isDocumentHost(window) && isLiveApplicationWindow(window)
  }

  private func registerLauncher(_ window: NSWindow) {
    purgeClosedLauncherWindows()
    guard DocumentWindowOwnership.claimDocumentHost(window) else {
      DebugTrace.log("registry.launcher rejected transient window '\(window.title)'")
      return
    }
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

  @discardableResult
  private func prepareTabbedWindow(_ window: NSWindow) -> Bool {
    guard DocumentWindowOwnership.claimDocumentHost(window) else { return false }
    if window.tabbingMode != .automatic {
      window.tabbingMode = .automatic
    }
    DebugTrace.logWindowEvent("document-host.prepare-tab-merge", window: window)
    return true
  }

  private func isFactoryTombstoned(_ window: NSWindow) -> Bool {
    closedWindows[ObjectIdentifier(window)]?.window === window
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
  let registry: DocumentWindowRegistry
  var onWindow: ((NSWindow) -> Void)?

  @MainActor
  init(
    documentID: URL?,
    identity: DocumentIdentity?,
    title: String?,
    representedURL: URL?,
    isDirty: Bool,
    hasEditableBuffer: Bool,
    registry: DocumentWindowRegistry? = nil,
    onWindow: ((NSWindow) -> Void)? = nil
  ) {
    self.documentID = documentID
    self.identity = identity
    self.title = title
    self.representedURL = representedURL
    self.isDirty = isDirty
    self.hasEditableBuffer = hasEditableBuffer
    self.registry = registry ?? .shared
    self.onWindow = onWindow
  }

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
      // This callback is synchronous with AppKit attaching the root view. Claim
      // the role before notifying the registry's deferred metadata path: a
      // cold-start `.task` can begin restore in between those two moments.
      if let window {
        if !DocumentWindowOwnership.claimDocumentHost(window) {
          DebugTrace.logWindowEvent("document-accessor.rejected-host", window: window)
        }
      }
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

  func attachIfNeeded(from view: NSView, coordinator: Coordinator) {
    guard let observedWindow = view.window,
      DocumentWindowOwnership.isDocumentHost(observedWindow)
    else { return }

    DispatchQueue.main.async {
      guard let window = view.window, window === observedWindow else { return }
      // A root representable can be re-parented while SwiftUI/AppKit animate a
      // sheet or reshuffle native tabs. Publishing that transient window as the
      // document host poisons provider ownership, command routing and every
      // later tab open before the registry has a chance to reject it.
      guard registry.canPublishDocumentHost(window) else { return }

      // Window protection is a per-pass side effect, not registry metadata.
      // SwiftUI can replace its AppKitWindow delegate while native tabs are
      // selected or reshuffled without changing the document identity, title,
      // URL or dirty state below. The registry attach may be coalesced in that
      // case, but `onWindow` must still re-wrap the current delegate; otherwise
      // the next tab "x" bypasses Save / Don't Save / Cancel and reaches the
      // too-late willClose recovery fallback.
      onWindow?(window)

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

      let attached = registry.attach(
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
