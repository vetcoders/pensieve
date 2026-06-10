import AppKit
import SwiftUI

@MainActor
final class DocumentWindowRegistry {
  static let shared = DocumentWindowRegistry()
  private let documentTabbingIdentifier = "Pensieve.DocumentWindow"

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
  /// Windows born from the tab bar's "+" button: launcher-mode content living
  /// as a document tab. They report no document and no editable buffer on
  /// first attach, which would otherwise classify them as empty launchers and
  /// feed them to the reaping sweeps.
  private var untitledTabWindows: [ObjectIdentifier: WeakWindow] = [:]
  var makeDocumentWindow: DocumentWindowFactoryClosure?
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
    guard canMutateWindowTabs() else {
      deferOpen(ref, documentID: documentID)
      return
    }

    if let existing = windowsByDocumentID[documentID]?.window {
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
      orderedDocumentIDs.remove(documentID)
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

    if let target = currentMergeTarget(), target !== window {
      prepareTabbedWindow(target)
      prepareTabbedWindow(window)
      mergeWindowIntoTabs(target, window)
      DebugTrace.log("merged '\(window.title)' into '\(target.title)' before first presentation")
    }
    orderAndActivateWindow(window)
    closeEmptyLauncherWindows(except: window)
  }

  /// Called from `DocumentWindow.close()` before AppKit tears the window
  /// down: drops every registry mapping so the document can re-open in a
  /// fresh window instead of resurrecting the closed (retained) one.
  func handleDocumentWindowClosed(_ window: NSWindow) {
    let windowID = ObjectIdentifier(window)
    DebugTrace.log("registry.windowClosed '\(window.title)'")
    releaseStaleDocumentMappings(for: window, keeping: nil)
    contentWindows.removeValue(forKey: windowID)
    launcherWindows.removeValue(forKey: windowID)
    untitledTabWindows.removeValue(forKey: windowID)
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

  func attach(
    _ window: NSWindow,
    documentID: URL?,
    title: String? = nil,
    representedURL: URL? = nil,
    hasEditableBuffer: Bool = false
  ) {
    DebugTrace.log(
      "registry.attach doc=\(documentID?.lastPathComponent ?? "nil") '\(window.title)'"
    )
    // Factory-built document windows keep their tabbing identifier so the
    // system keeps grouping them (and keeps showing "+"); only windows from
    // other origins (launcher scene, restored scenes) are normalized back to
    // standalone tabbing.
    if window.tabbingIdentifier != documentTabbingIdentifier {
      prepareStandaloneTabbing(for: window)
    }

    guard let documentID = documentID?.standardizedFileURL else {
      releaseStaleDocumentMappings(for: window, keeping: nil)
      if hasEditableBuffer {
        markContentWindow(window)
        window.title = normalizedTitle(title, fallback: "Untitled")
        window.representedURL = representedURL
        closeEmptyLauncherWindows(except: window)
        return
      }
      if untitledTabWindows[ObjectIdentifier(window)]?.window === window {
        // A "+" tab in its launcher-mode state: content by fiat, never reaped.
        markContentWindow(window)
        window.title = normalizedTitle(title, fallback: "Untitled")
        window.representedURL = nil
        return
      }
      registerLauncher(window)
      closeEmptyLauncherWindowIfDocumentTabsExist(window)
      return
    }
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
    // A launcher that is a MEMBER of a document tab group is the result of
    // the native tab bar's "+" pressed on a SwiftUI-origin tab (the system
    // spawns a WindowGroup scene as a new tab there). That is an intentional
    // new-tab gesture — reaping it would make "+" appear to do nothing.
    if (window.tabbedWindows?.count ?? 1) > 1 { return false }
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
    untitledTabWindows = untitledTabWindows.filter { $0.value.window != nil }
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
