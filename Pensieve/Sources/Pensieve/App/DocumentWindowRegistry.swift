import AppKit
import SwiftUI

@MainActor
final class DocumentWindowRegistry {
  static let shared = DocumentWindowRegistry()

  private var windowsByDocumentID: [URL: WeakWindow] = [:]
  private var pendingMergeTargets: [URL: WeakWindow] = [:]

  private init() {}

  func open(_ ref: DocumentRef, openWindow: OpenWindowAction) {
    let documentID = ref.id.standardizedFileURL
    if let existing = windowsByDocumentID[documentID]?.window {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      closeEmptyLauncherWindows(except: existing)
      return
    }

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
    windowsByDocumentID[documentID] = WeakWindow(window)

    if let target = pendingMergeTargets.removeValue(forKey: documentID)?.window,
      target !== window
    {
      target.tabbingMode = .preferred
      target.tabbingIdentifier = window.tabbingIdentifier
      target.addTabbedWindow(window, ordered: .above)
    }

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
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
