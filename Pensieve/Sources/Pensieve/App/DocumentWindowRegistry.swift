import AppKit
import SwiftUI

@MainActor
final class DocumentWindowRegistry {
  static let shared = DocumentWindowRegistry()

  typealias DeferredMainWork = @MainActor () -> Void

  private var windowsByDocumentID: [URL: WeakWindow] = [:]
  private var pendingMergeTargets: [URL: WeakWindow] = [:]
  private var deferredOpenDocumentIDs: Set<URL> = []
  private var deferredAttachDocumentIDs: Set<URL> = []
  private var orderedDocumentIDs: Set<URL> = []
  private let canMutateWindowTabs: @MainActor () -> Bool
  private let scheduleDeferredMainWork: (@escaping DeferredMainWork) -> Void
  private let mergeWindowIntoTabs: @MainActor (NSWindow, NSWindow) -> Void
  private let orderAndActivateWindow: @MainActor (NSWindow) -> Void

  init(
    canMutateWindowTabs: @escaping @MainActor () -> Bool = { NSApp.modalWindow == nil },
    scheduleDeferredMainWork: @escaping (@escaping DeferredMainWork) -> Void = { work in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        Task { @MainActor in work() }
      }
    },
    mergeWindowIntoTabs: @escaping @MainActor (NSWindow, NSWindow) -> Void = { target, window in
      target.addTabbedWindow(window, ordered: .above)
    },
    orderAndActivateWindow: @escaping @MainActor (NSWindow) -> Void = { window in
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  ) {
    self.canMutateWindowTabs = canMutateWindowTabs
    self.scheduleDeferredMainWork = scheduleDeferredMainWork
    self.mergeWindowIntoTabs = mergeWindowIntoTabs
    self.orderAndActivateWindow = orderAndActivateWindow
  }

  func open(_ ref: DocumentRef, openWindow: OpenWindowAction) {
    let documentID = ref.id.standardizedFileURL
    guard canMutateWindowTabs() else {
      deferOpen(ref, documentID: documentID, openWindow: openWindow)
      return
    }

    if let existing = windowsByDocumentID[documentID]?.window {
      orderAndActivateWindow(existing)
      closeEmptyLauncherWindows(except: existing)
      return
    }
    windowsByDocumentID[documentID] = nil
    orderedDocumentIDs.remove(documentID)

    if let target = NSApp.keyWindow ?? NSApp.mainWindow {
      pendingMergeTargets[documentID] = WeakWindow(target)
    }
    openWindow(value: ref)
  }

  func attach(_ window: NSWindow, documentID: URL?) {
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "Pensieve.DocumentWindow"

    guard let documentID = documentID?.standardizedFileURL else {
      closeEmptyLauncherWindowIfDocumentTabsExist(window)
      return
    }
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
      target.tabbingMode = .preferred
      target.tabbingIdentifier = window.tabbingIdentifier
      mergeWindowIntoTabs(target, window)
    }

    if orderedDocumentIDs.insert(documentID).inserted {
      orderAndActivateWindow(window)
    }
  }

  private func deferOpen(_ ref: DocumentRef, documentID: URL, openWindow: OpenWindowAction) {
    guard deferredOpenDocumentIDs.insert(documentID).inserted else { return }
    scheduleDeferredMainWork { [weak self] in
      guard let self else { return }
      deferredOpenDocumentIDs.remove(documentID)
      open(ref, openWindow: openWindow)
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
    DispatchQueue.main.async {
      if window.title == "Pensieve" {
        window.close()
      }
    }
  }

  private func closeEmptyLauncherWindows(except activeWindow: NSWindow) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      for window in NSApp.windows where window !== activeWindow && window.title == "Pensieve" {
        window.close()
      }
    }
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
  var onWindow: ((NSWindow) -> Void)?

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      if let window = view.window {
        onWindow?(window)
        DocumentWindowRegistry.shared.attach(window, documentID: documentID)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      if let window = nsView.window {
        onWindow?(window)
        DocumentWindowRegistry.shared.attach(window, documentID: documentID)
      }
    }
  }
}
