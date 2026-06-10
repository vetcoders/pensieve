import AppKit
import SwiftUI

@MainActor
final class DocumentWindowRegistry {
  static let shared = DocumentWindowRegistry()
  private let documentTabbingIdentifier = "Pensieve.DocumentWindow"

  typealias DeferredMainWork = @MainActor () -> Void
  typealias DocumentOpener = @MainActor (DocumentRef) -> Void

  private var windowsByDocumentID: [URL: WeakWindow] = [:]
  private var launcherWindows: [ObjectIdentifier: WeakWindow] = [:]
  private var contentWindows: [ObjectIdentifier: WeakWindow] = [:]
  private var preferredLauncherID: ObjectIdentifier?
  private var pendingMergeTargets: [URL: WeakWindow] = [:]
  private var openInFlightDocumentIDs: Set<URL> = []
  private var suppressionRunLoopObserver: CFRunLoopObserver?
  private var contentReadyWindowIDs: Set<ObjectIdentifier> = []
  private var attachedWindowsAwaitingContent: [ObjectIdentifier: WeakWindow] = [:]
  private var deferredOpenDocumentIDs: Set<URL> = []
  private var deferredAttachDocumentIDs: Set<URL> = []
  private var orderedDocumentIDs: Set<URL> = []
  private let canMutateWindowTabs: @MainActor () -> Bool
  private let scheduleDeferredMainWork: (@escaping DeferredMainWork) -> Void
  private let scheduleLauncherWindowSweep: (@escaping DeferredMainWork) -> Void
  private let mergeWindowIntoTabs: @MainActor (NSWindow, NSWindow) -> Void
  private let orderAndActivateWindow: @MainActor (NSWindow) -> Void
  private let currentMergeTarget: @MainActor () -> NSWindow?
  private let revealWindow: @MainActor (NSWindow) -> Void
  private let scheduleSuppressionFailsafe: (@escaping DeferredMainWork) -> Void
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
    revealWindow: @escaping @MainActor (NSWindow) -> Void = { window in
      window.alphaValue = 1
    },
    scheduleSuppressionFailsafe: @escaping (@escaping DeferredMainWork) -> Void = { work in
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        Task { @MainActor in work() }
      }
    },
    applicationWindows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
    closeWindow: @escaping @MainActor (NSWindow) -> Void = { window in
      window.close()
    }
  ) {
    self.canMutateWindowTabs = canMutateWindowTabs
    self.scheduleDeferredMainWork = scheduleDeferredMainWork
    self.scheduleLauncherWindowSweep = scheduleLauncherWindowSweep
    self.mergeWindowIntoTabs = mergeWindowIntoTabs
    self.orderAndActivateWindow = orderAndActivateWindow
    self.currentMergeTarget = currentMergeTarget
    self.revealWindow = revealWindow
    self.scheduleSuppressionFailsafe = scheduleSuppressionFailsafe
    self.applicationWindows = applicationWindows
    self.closeWindow = closeWindow
  }

  /// Called from the `NSWindow.didBecomeKey` observer, synchronously within the
  /// window's first presentation — BEFORE its first frame commits. A SwiftUI
  /// `openWindow` scene takes 0.5-1.2s to materialize (fresh AppState +
  /// controller), and the window is presented at the start of that gap: the
  /// SwiftUI-side accessor (`DocumentWindowAccessor`) only runs at the end, far
  /// too late to stop the standalone-window flash. Hiding the window here and
  /// revealing in `completeAttach` (or the failsafe) closes that gap.
  func suppressIfMaterializingDocumentWindow(_ window: NSWindow) {
    guard !openInFlightDocumentIDs.isEmpty else { return }
    guard window.alphaValue > 0 else { return }
    let windowID = ObjectIdentifier(window)
    guard contentWindows[windowID]?.window == nil,
      launcherWindows[windowID]?.window == nil,
      !windowsByDocumentID.values.contains(where: { $0.window === window })
    else { return }

    DebugTrace.log("suppress materializing window '\(window.title)'")
    window.alphaValue = 0
    // The scene may never attach (open failed, window closed mid-flight, or a
    // mis-identified bystander window) — never leave anything invisible.
    scheduleSuppressionFailsafe { [weak self, weak window] in
      guard let self, let window else { return }
      revealWindow(window)
    }
  }

  /// Sweeps every application window through the suppression check. Runs from
  /// a main-runloop observer ordered BEFORE the CoreAnimation transaction
  /// commit, so a window SwiftUI ordered on screen earlier in the same turn is
  /// hidden before its first frame ever reaches the screen. (`didBecomeKey`
  /// alone is ~50ms / a few committed frames too late.)
  func suppressMaterializingWindowsBeforeFrameCommit() {
    guard !openInFlightDocumentIDs.isEmpty else {
      removeSuppressionObserverIfIdle()
      return
    }
    for window in applicationWindows() {
      suppressIfMaterializingDocumentWindow(window)
    }
  }

  private func installSuppressionObserverIfNeeded() {
    guard suppressionRunLoopObserver == nil else { return }
    // Order 0 runs ahead of the CA commit observer (order 2_000_000): the
    // alpha change lands in the same transaction as the window's first frame.
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault,
      CFRunLoopActivity.beforeWaiting.rawValue,
      true,
      0
    ) { [weak self] _, _ in
      MainActor.assumeIsolated {
        self?.suppressMaterializingWindowsBeforeFrameCommit()
      }
    }
    suppressionRunLoopObserver = observer
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }

  private func removeSuppressionObserverIfIdle() {
    guard openInFlightDocumentIDs.isEmpty, let observer = suppressionRunLoopObserver else {
      return
    }
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
    suppressionRunLoopObserver = nil
  }

  /// True between `open()` and the matching `attach()` for a document whose
  /// upcoming window will be merged into an existing window's native tab
  /// group. Presentation uses this to keep the freshly created window
  /// invisible so the user never sees it flash standalone before the merge;
  /// `completeAttach` reveals it once it is already a tab.
  func expectsMerge(for documentID: URL?) -> Bool {
    guard let documentID = documentID?.standardizedFileURL else {
      return false
    }
    let result = pendingMergeTargets[documentID]?.window != nil
    return result
  }

  func open(_ ref: DocumentRef, openDocument: @escaping DocumentOpener) {
    let documentID = ref.id.standardizedFileURL
    guard canMutateWindowTabs() else {
      deferOpen(ref, documentID: documentID, openDocument: openDocument)
      return
    }

    if let existing = windowsByDocumentID[documentID]?.window {
      DebugTrace.log(
        "registry.open \(documentID.lastPathComponent) -> activate existing '\(existing.title)'")
      mergeExistingWindowIntoCurrentTabsIfNeeded(existing)
      orderAndActivateWindow(existing)
      closeEmptyLauncherWindows(except: existing)
      return
    }
    // A document window takes a beat to materialize (new scene, cold state).
    // Re-clicks in that gap would spawn a second window for the same document
    // AND clobber pendingMergeTargets with the half-built window — which makes
    // completeAttach see target === window and silently skip the merge.
    // Coalesce: the first attach for this document clears the latch.
    guard openInFlightDocumentIDs.insert(documentID).inserted else {
      DebugTrace.log("registry.open \(documentID.lastPathComponent) coalesced (in flight)")
      return
    }
    installSuppressionObserverIfNeeded()

    windowsByDocumentID[documentID] = nil
    orderedDocumentIDs.remove(documentID)

    if let target = currentMergeTarget() {
      pendingMergeTargets[documentID] = WeakWindow(target)
    }
    DebugTrace.log("registry.open \(documentID.lastPathComponent) spawning scene")
    openDocument(ref)
  }

  func attach(
    _ window: NSWindow,
    documentID: URL?,
    title: String? = nil,
    representedURL: URL? = nil,
    hasEditableBuffer: Bool = false
  ) {
    DebugTrace.log(
      "registry.attach doc=\(documentID?.lastPathComponent ?? "nil") '\(window.title)' alpha=\(window.alphaValue)"
    )
    prepareStandaloneTabbing(for: window)

    guard let documentID = documentID?.standardizedFileURL else {
      releaseStaleDocumentMappings(for: window, keeping: nil)
      if hasEditableBuffer {
        markContentWindow(window)
        window.title = normalizedTitle(title, fallback: "Untitled")
        window.representedURL = representedURL
        revealWindow(window)
        closeEmptyLauncherWindows(except: window)
        return
      }
      registerLauncher(window)
      revealWindow(window)
      closeEmptyLauncherWindowIfDocumentTabsExist(window)
      return
    }
    openInFlightDocumentIDs.remove(documentID)
    removeSuppressionObserverIfIdle()
    markContentWindow(window)
    let fallbackTitle = documentID.deletingPathExtension().lastPathComponent
    window.title = normalizedTitle(title, fallback: fallbackTitle)
    window.representedURL = representedURL ?? documentID

    // A window displays exactly one document: switching documents in place
    // (the default in-window click routing) must release the previous
    // mapping, or `open()` keeps "activating" this window for documents it no
    // longer shows and Open in New Window becomes a silent no-op.
    releaseStaleDocumentMappings(for: window, keeping: documentID)
    if windowsByDocumentID[documentID]?.window !== window {
      orderedDocumentIDs.remove(documentID)
    }
    windowsByDocumentID[documentID] = WeakWindow(window)

    guard canMutateWindowTabs() else {
      // A modal can outlive any reasonable suppression window — reveal now and
      // accept the legacy standalone-then-merge visual rather than an
      // invisible window for the modal's lifetime.
      revealWindow(window)
      deferAttach(window, documentID: documentID)
      return
    }

    completeAttach(window, documentID: documentID)
  }

  func closeWindowIfEmptyLauncher(_ window: NSWindow?) {
    guard let window else { return }
    let windowID = ObjectIdentifier(window)
    guard contentWindows[windowID]?.window == nil else { return }
    launcherWindows.removeValue(forKey: windowID)
    closeWindow(window)
  }

  private func completeAttach(_ window: NSWindow, documentID: URL) {
    let pendingTarget = pendingMergeTargets.removeValue(forKey: documentID)?.window
    if let target = pendingTarget,
      target !== window
    {
      prepareTabbedWindow(target)
      prepareTabbedWindow(window)
      mergeWindowIntoTabs(target, window)
      DebugTrace.log("merged '\(window.title)' into '\(target.title)'")
    }

    if orderedDocumentIDs.insert(documentID).inserted {
      orderAndActivateWindow(window)
    }
    // Reveal strictly after the merge so a presentation-suppressed window
    // first becomes visible as a tab, never as a standalone window. A window
    // we hid pre-first-frame additionally waits for its scene to report the
    // content as actually rendered — `alphaValue` flips on the window server
    // immediately, so revealing before the first content commit shows a black
    // tab for the rest of the scene build (~1s).
    let windowID = ObjectIdentifier(window)
    if window.alphaValue > 0 || contentReadyWindowIDs.remove(windowID) != nil {
      revealWindow(window)
    } else {
      attachedWindowsAwaitingContent[windowID] = WeakWindow(window)
    }
    closeEmptyLauncherWindows(except: window)
  }

  /// Called by the window's scene once its content is past the startup
  /// presentation (first real frame is in the same transaction). Completes the
  /// suppressed-window handshake: merge done + content ready -> reveal.
  func noteWindowContentReady(_ window: NSWindow) {
    let windowID = ObjectIdentifier(window)
    if attachedWindowsAwaitingContent.removeValue(forKey: windowID)?.window === window {
      DebugTrace.log("content ready -> reveal '\(window.title)'")
      revealWindow(window)
      return
    }
    contentReadyWindowIDs.insert(windowID)
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
    openDocument: @escaping DocumentOpener
  ) {
    guard deferredOpenDocumentIDs.insert(documentID).inserted else { return }
    scheduleDeferredMainWork { [weak self] in
      guard let self else { return }
      deferredOpenDocumentIDs.remove(documentID)
      open(ref, openDocument: openDocument)
    }
  }

  private func deferAttach(_ window: NSWindow, documentID: URL) {
    guard deferredAttachDocumentIDs.insert(documentID).inserted else { return }
    scheduleDeferredMainWork { [weak self, weak window] in
      guard let self else { return }
      deferredAttachDocumentIDs.remove(documentID)
      guard let window else { return }
      attach(window, documentID: documentID)
    }
  }

  private func closeEmptyLauncherWindowIfDocumentTabsExist(_ window: NSWindow) {
    guard hasContentWindow else {
      return
    }
    closeEmptyLauncherWindows(except: nil)
  }

  private func closeEmptyLauncherWindows(except activeWindow: NSWindow?) {
    scheduleLauncherWindowSweep { [weak self, activeWindow] in
      guard let self else { return }
      purgeClosedLauncherWindows()
      for window in applicationWindows()
      where window !== activeWindow && isEmptyLauncherWindow(window, includingUntracked: true) {
        closeWindow(window)
      }
    }
  }

  private func isEmptyLauncherWindow(
    _ window: NSWindow,
    includingUntracked: Bool = false
  ) -> Bool {
    let windowID = ObjectIdentifier(window)
    let isTrackedLauncher = launcherWindows[windowID]?.window === window
    let isUntrackedLauncher =
      includingUntracked && window.title == "Pensieve" && window.representedURL == nil
    guard isTrackedLauncher || isUntrackedLauncher else { return false }
    return contentWindows[windowID]?.window == nil
      && !windowsByDocumentID.values.contains { $0.window === window }
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

  private func prepareStandaloneTabbing(for window: NSWindow) {
    window.tabbingMode = .automatic
    if (window.tabbedWindows?.count ?? 1) <= 1 {
      window.setValue(nil, forKey: "tabbingIdentifier")
    }
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
      for window in applicationWindows()
      where isEmptyLauncherWindow(window, includingUntracked: shouldCloseAllLaunchers)
        && (shouldCloseAllLaunchers
          || window !== preferredLauncher)
      {
        closeWindow(window)
      }
    }
  }

  private func purgeClosedLauncherWindows() {
    launcherWindows = launcherWindows.filter { $0.value.window != nil }
    contentWindows = contentWindows.filter { $0.value.window != nil }
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
      return window.representedURL != nil || window.title != "Pensieve"
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

struct DocumentWindowAccessor: NSViewRepresentable {
  let documentID: URL?
  let title: String?
  let representedURL: URL?
  let hasEditableBuffer: Bool
  var onWindow: ((NSWindow) -> Void)?

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      if let window = view.window {
        onWindow?(window)
        DocumentWindowRegistry.shared.attach(
          window,
          documentID: documentID,
          title: title,
          representedURL: representedURL,
          hasEditableBuffer: hasEditableBuffer)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      if let window = nsView.window {
        onWindow?(window)
        DocumentWindowRegistry.shared.attach(
          window,
          documentID: documentID,
          title: title,
          representedURL: representedURL,
          hasEditableBuffer: hasEditableBuffer)
      }
    }
  }
}
