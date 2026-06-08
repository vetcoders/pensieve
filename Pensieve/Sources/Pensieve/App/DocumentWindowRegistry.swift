import AppKit
import SwiftUI

@MainActor
final class DocumentWindowRegistry {
  static let shared = DocumentWindowRegistry()

  typealias DeferredMainWork = @MainActor () -> Void
  typealias DocumentOpener = @MainActor (DocumentRef) -> Void

  private var windowsByDocumentID: [URL: WeakWindow] = [:]
  private var launcherWindows: [ObjectIdentifier: WeakWindow] = [:]
  private var pendingMergeTargets: [URL: WeakWindow] = [:]
  private var deferredOpenDocumentIDs: Set<URL> = []
  private var deferredAttachDocumentIDs: Set<URL> = []
  private var orderedDocumentIDs: Set<URL> = []
  private let canMutateWindowTabs: @MainActor () -> Bool
  private let scheduleDeferredMainWork: (@escaping DeferredMainWork) -> Void
  private let scheduleLauncherWindowSweep: (@escaping DeferredMainWork) -> Void
  private let mergeWindowIntoTabs: @MainActor (NSWindow, NSWindow) -> Void
  private let orderAndActivateWindow: @MainActor (NSWindow) -> Void
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
    self.applicationWindows = applicationWindows
    self.closeWindow = closeWindow
  }

  func open(_ ref: DocumentRef, openDocument: @escaping DocumentOpener) {
    let documentID = ref.id.standardizedFileURL
    guard canMutateWindowTabs() else {
      deferOpen(ref, documentID: documentID, openDocument: openDocument)
      return
    }

    if let existing = windowsByDocumentID[documentID]?.window {
      orderAndActivateWindow(existing)
      closeEmptyLauncherWindows(except: existing)
      return
    }
    windowsByDocumentID[documentID] = nil
    orderedDocumentIDs.remove(documentID)

    if let target = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
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
    window.tabbingMode = .automatic
    window.tabbingIdentifier = "Pensieve.DocumentWindow"

    guard let documentID = documentID?.standardizedFileURL else {
      if hasEditableBuffer {
        launcherWindows.removeValue(forKey: ObjectIdentifier(window))
        window.title = normalizedTitle(title, fallback: "Untitled")
        window.representedURL = representedURL
        return
      }
      registerLauncher(window)
      closeEmptyLauncherWindowIfDocumentTabsExist(window)
      return
    }
    launcherWindows.removeValue(forKey: ObjectIdentifier(window))
    let fallbackTitle = documentID.deletingPathExtension().lastPathComponent
    window.title = normalizedTitle(title, fallback: fallbackTitle)
    window.representedURL = representedURL ?? documentID

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

  private func completeAttach(_ window: NSWindow, documentID: URL) {
    if let target = pendingMergeTargets.removeValue(forKey: documentID)?.window,
      target !== window
    {
      target.tabbingMode = .automatic
      target.tabbingIdentifier = window.tabbingIdentifier
      mergeWindowIntoTabs(target, window)
    }

    if orderedDocumentIDs.insert(documentID).inserted {
      orderAndActivateWindow(window)
    }
    closeEmptyLauncherWindows(except: window)
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
    guard windowsByDocumentID.values.contains(where: { $0.window != nil }) else {
      return
    }
    closeEmptyLauncherWindows(except: nil)
  }

  private func closeEmptyLauncherWindows(except activeWindow: NSWindow?) {
    scheduleLauncherWindowSweep { [weak self, activeWindow] in
      guard let self else { return }
      purgeClosedLauncherWindows()
      for window in applicationWindows()
      where window !== activeWindow && isEmptyLauncherWindow(window) {
        closeWindow(window)
      }
    }
  }

  private func isEmptyLauncherWindow(_ window: NSWindow) -> Bool {
    let windowID = ObjectIdentifier(window)
    guard launcherWindows[windowID]?.window === window else { return false }
    return !windowsByDocumentID.values.contains { $0.window === window }
  }

  private func registerLauncher(_ window: NSWindow) {
    purgeClosedLauncherWindows()
    window.title = "Pensieve"
    window.representedURL = nil
    launcherWindows[ObjectIdentifier(window)] = WeakWindow(window)
  }

  private func purgeClosedLauncherWindows() {
    launcherWindows = launcherWindows.filter { $0.value.window != nil }
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
