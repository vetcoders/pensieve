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
    self.applicationWindows = applicationWindows
    self.closeWindow = closeWindow
  }

  /// True between `open()` and the matching `attach()` for a document whose
  /// upcoming window will be merged into an existing window's native tab
  /// group. Presentation uses this to keep the freshly created window
  /// invisible so the user never sees it flash standalone before the merge;
  /// `completeAttach` reveals it once it is already a tab.
  func expectsMerge(for documentID: URL?) -> Bool {
    guard let documentID = documentID?.standardizedFileURL else { return false }
    return pendingMergeTargets[documentID]?.window != nil
  }

  func open(_ ref: DocumentRef, openDocument: @escaping DocumentOpener) {
    let documentID = ref.id.standardizedFileURL
    guard canMutateWindowTabs() else {
      deferOpen(ref, documentID: documentID, openDocument: openDocument)
      return
    }

    if let existing = windowsByDocumentID[documentID]?.window {
      mergeExistingWindowIntoCurrentTabsIfNeeded(existing)
      orderAndActivateWindow(existing)
      closeEmptyLauncherWindows(except: existing)
      return
    }
    windowsByDocumentID[documentID] = nil
    orderedDocumentIDs.remove(documentID)

    if let target = currentMergeTarget() {
      pendingMergeTargets[documentID] = WeakWindow(target)
    }
    openDocument(ref)
  }

  func attach(
    _ window: NSWindow,
    documentID: URL?,
    title: String? = nil,
    representedURL: URL? = nil,
    hasEditableBuffer: Bool = false
  ) {
    prepareStandaloneTabbing(for: window)

    guard let documentID = documentID?.standardizedFileURL else {
      if hasEditableBuffer {
        markContentWindow(window)
        window.title = normalizedTitle(title, fallback: "Untitled")
        window.representedURL = representedURL
        closeEmptyLauncherWindows(except: window)
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
    if let target = pendingMergeTargets.removeValue(forKey: documentID)?.window,
      target !== window
    {
      prepareTabbedWindow(target)
      prepareTabbedWindow(window)
      mergeWindowIntoTabs(target, window)
    }

    if orderedDocumentIDs.insert(documentID).inserted {
      orderAndActivateWindow(window)
    }
    // Reveal strictly after the merge so a presentation-suppressed window
    // first becomes visible as a tab, never as a standalone window.
    revealWindow(window)
    closeEmptyLauncherWindows(except: window)
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
