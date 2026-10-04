import AppKit
import SwiftUI

/// Coordinates the presentation of Ask across docked, native floating panel,
/// and hidden states.
///
/// A single persistent `NSHostingView` is moved between the editor's docked anchor
/// view and the native `NSPanel`. This preserves `AskConversationModel`, draft text,
/// attachments, active streaming turns, and provider state without creating a
/// second session or restarting work.
@MainActor
final class AskPanelController: NSObject, NSWindowDelegate, ObservableObject {
  weak var ownerWindow: NSWindow?
  private(set) var panel: NSPanel?
  weak var dockAnchorView: AskDockAnchorView?

  var presentation: AskPresentationState {
    didSet {
      if oldValue != presentation {
        onPresentationChange?(presentation)
      }
    }
  }

  var onPresentationChange: (@MainActor (AskPresentationState) -> Void)?

  private let panelFactory: @MainActor () -> NSPanel
  private let presentPanel: @MainActor (NSPanel) -> Void
  private let dismissPanel: @MainActor (NSPanel) -> Void
  private let panelIsVisible: @MainActor (NSPanel) -> Bool

  var hostingView: NSView?
  private var isSyncing = false
  private var ownerCloseObserver: Any?
  private var ownerMiniaturizeObserver: Any?
  private var ownerDeminiaturizeObserver: Any?
  private var panelCloseObserver: Any?

  init(
    presentation: AskPresentationState = .expandedDefault,
    panelFactory: (@MainActor () -> NSPanel)? = nil,
    presentPanel: @escaping @MainActor (NSPanel) -> Void = { $0.orderFront(nil) },
    dismissPanel: @escaping @MainActor (NSPanel) -> Void = { $0.orderOut(nil) },
    panelIsVisible: @escaping @MainActor (NSPanel) -> Bool = { $0.isVisible },
    onPresentationChange: (@MainActor (AskPresentationState) -> Void)? = nil
  ) {
    self.presentation = presentation
    self.panelFactory = panelFactory ?? { AskPanelController.makeProductionPanelWindow() }
    self.presentPanel = presentPanel
    self.dismissPanel = dismissPanel
    self.panelIsVisible = panelIsVisible
    self.onPresentationChange = onPresentationChange
    super.init()
  }

  isolated deinit {
    if let ownerCloseObserver { NotificationCenter.default.removeObserver(ownerCloseObserver) }
    if let ownerMiniaturizeObserver {
      NotificationCenter.default.removeObserver(ownerMiniaturizeObserver)
    }
    if let ownerDeminiaturizeObserver {
      NotificationCenter.default.removeObserver(ownerDeminiaturizeObserver)
    }
    if let panelCloseObserver {
      NotificationCenter.default.removeObserver(panelCloseObserver)
    }
    if let panel {
      dismissPanel(panel)
    }
  }

  static func makeProductionPanelWindow() -> NSPanel {
    NonActivatingTaflaPanel(
      contentRect: NSRect(x: 200, y: 200, width: 640, height: 520),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
  }

  func attachOwnerWindow(_ window: NSWindow?) {
    guard ownerWindow !== window else { return }
    if let ownerCloseObserver {
      NotificationCenter.default.removeObserver(ownerCloseObserver)
      self.ownerCloseObserver = nil
    }
    if let ownerMiniaturizeObserver {
      NotificationCenter.default.removeObserver(ownerMiniaturizeObserver)
      self.ownerMiniaturizeObserver = nil
    }
    if let ownerDeminiaturizeObserver {
      NotificationCenter.default.removeObserver(ownerDeminiaturizeObserver)
      self.ownerDeminiaturizeObserver = nil
    }

    self.ownerWindow = window
    guard let window else { return }

    ownerCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleOwnerWindowWillClose()
      }
    }

    ownerMiniaturizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMiniaturizeNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.presentation.mode == .floating, let panel = self.panel else { return }
        self.dismissPanel(panel)
      }
    }

    ownerDeminiaturizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didDeminiaturizeNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.presentation.mode == .floating, let panel = self.panel else { return }
        self.presentPanel(panel)
      }
    }
  }

  func handleOwnerWindowWillClose() {
    if let panel {
      dismissPanel(panel)
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === panel else { return }
    concealPanel()
  }

  /// Title-bar close conceals Ask and preserves the current conversation,
  /// draft, attachments, and active turns.
  func concealPanel() {
    presentation.mode = .hidden
    if let panel {
      dismissPanel(panel)
    }
  }

  @discardableResult
  private func ensurePanel() -> NSPanel {
    if let panel { return panel }
    let newPanel = panelFactory()
    configurePanel(newPanel)
    self.panel = newPanel

    panelCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: newPanel,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.concealPanel()
      }
    }

    return newPanel
  }

  private func configurePanel(_ panel: NSPanel) {
    panel.title = "Ask"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = presentation.isAlwaysOnTop ? .floating : .normal
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(
      width: AskSurfaceLayout.minimumPanelWidth, height: AskSurfaceLayout.minimumPanelHeight)
    panel.contentMinSize = NSSize(
      width: AskSurfaceLayout.minimumPanelWidth, height: AskSurfaceLayout.minimumPanelHeight)
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.sharingType = .readOnly
  }

  func setAlwaysOnTop(_ aot: Bool) {
    presentation.isAlwaysOnTop = aot
    let panel = ensurePanel()
    panel.level = aot ? .floating : .normal
  }

  func syncPresentation(_ targetPresentation: AskPresentationState, contentSize: CGSize) {
    guard !isSyncing else { return }
    isSyncing = true
    defer { isSyncing = false }

    self.presentation = targetPresentation

    switch targetPresentation.mode {
    case .docked:
      if let panel, panelIsVisible(panel) {
        dismissPanel(panel)
      }

      guard let dockAnchorView else { return }
      dockAnchorView.isDocked = true

      let dockH = AskSurfaceLayout.displayedDockHeight(
        presentation: targetPresentation, content: contentSize)
      let statusH = AskSurfaceLayout.statusHeight(for: contentSize.height)
      let editorH = max(0, contentSize.height - statusH - dockH)
      let dockRect = CGRect(x: 0, y: editorH, width: contentSize.width, height: dockH)
      dockAnchorView.dockRect = dockRect

      if let hostingView {
        if hostingView.superview !== dockAnchorView {
          hostingView.removeFromSuperview()
          dockAnchorView.addSubview(hostingView)
        }
        hostingView.frame = dockRect
      }
      dockAnchorView.needsLayout = true

    case .floating:
      if let dockAnchorView {
        dockAnchorView.isDocked = false
        if let hostingView, hostingView.superview === dockAnchorView {
          hostingView.removeFromSuperview()
        }
      }

      let panel = ensurePanel()
      panel.level = targetPresentation.isAlwaysOnTop ? .floating : .normal

      if let hostingView {
        if panel.contentView?.subviews.first !== hostingView {
          hostingView.removeFromSuperview()
          let container = TaflaContentContainer(hostingView: hostingView)
          container.setAccessibilityIdentifier("pensieve.ask.panel")
          container.setAccessibilityRole(.group)
          container.setAccessibilityLabel("Ask native panel")
          panel.contentView = container
        }
      }

      if !panelIsVisible(panel) {
        if let ownerWindow, panel.frame.origin.x <= 0 && panel.frame.origin.y <= 0 {
          let ownerFrame = ownerWindow.frame
          let panelSize = targetPresentation.preferredFloatSize
          let initialOrigin = CGPoint(
            x: max(ownerFrame.maxX - panelSize.width - 24, 60),
            y: max(ownerFrame.minY + 60, 60)
          )
          panel.setFrame(NSRect(origin: initialOrigin, size: panelSize), display: false)
        }
        presentPanel(panel)
      }

    case .hidden:
      if let panel, panelIsVisible(panel) {
        dismissPanel(panel)
      }
      if let dockAnchorView {
        dockAnchorView.isDocked = false
      }
      if let hostingView {
        hostingView.removeFromSuperview()
      }
    }
  }
}

/// Dock anchor NSView placed inside ContentView's ZStack.
/// In docked mode, only the dock rect responds to hit testing; all clicks outside
/// (in the editor or status bar) pass through.
/// In floating and hidden modes, all clicks pass through unconditionally.
final class AskDockAnchorView: NSView {
  override var isFlipped: Bool { true }
  var dockRect: CGRect = .zero
  var isDocked: Bool = false

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isDocked, dockRect.contains(point) else {
      return nil
    }
    for subview in subviews.reversed() {
      let subPoint = convert(point, to: subview)
      if let hit = subview.hitTest(subPoint) {
        return hit
      }
    }
    return self
  }
}

/// Bridges SwiftUI content to the persistent NSHostingView owned by `AskPanelController`.
struct AskPanelHostView<Content: View>: NSViewRepresentable {
  @ObservedObject var controller: AskPanelController
  @Binding var presentation: AskPresentationState
  let contentSize: CGSize
  let hostWindow: NSWindow?
  let content: () -> Content

  func makeNSView(context: Context) -> AskDockAnchorView {
    let anchor = AskDockAnchorView()
    controller.dockAnchorView = anchor
    controller.attachOwnerWindow(hostWindow)

    if controller.hostingView == nil {
      let hosting = NSHostingView(rootView: content())
      hosting.sizingOptions = []
      hosting.translatesAutoresizingMaskIntoConstraints = true
      hosting.autoresizingMask = []
      controller.hostingView = hosting
    }

    controller.syncPresentation(presentation, contentSize: contentSize)
    return anchor
  }

  func updateNSView(_ anchor: AskDockAnchorView, context: Context) {
    controller.dockAnchorView = anchor
    controller.attachOwnerWindow(hostWindow)

    if let hosting = controller.hostingView as? NSHostingView<Content> {
      hosting.rootView = content()
    } else if controller.hostingView == nil {
      let hosting = NSHostingView(rootView: content())
      hosting.sizingOptions = []
      hosting.translatesAutoresizingMaskIntoConstraints = true
      hosting.autoresizingMask = []
      controller.hostingView = hosting
    }

    controller.syncPresentation(presentation, contentSize: contentSize)
  }
}
