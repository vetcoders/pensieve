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
  /// One owner for the entire application, including restored native tabs.
  static let shared: AskPanelController = {
    let threads: AskThreadStore
    do {
      threads = AskThreadStore(history: try AskHistoryStore())
    } catch {
      threads = AskThreadStore()
      threads.reportHistoryError(error)
    }
    return AskPanelController(defaults: .standard, threads: threads)
  }()
  @Published private(set) var activeThreadID = UUID()
  let threads: AskThreadStore
  private let defaults: UserDefaults?
  private var rememberedMode: AskPresentationMode = .docked
  private var contentSize: CGSize = .zero
  private var theme: PensieveTheme = .graphite

  weak var ownerWindow: NSWindow?
  private(set) var panel: NSPanel?
  weak var dockAnchorView: AskDockAnchorView?

  @Published var presentation: AskPresentationState {
    didSet {
      if oldValue != presentation {
        persistPresentation()
        onPresentationChange?(presentation)
        if !isSyncing { syncPresentation(presentation, contentSize: contentSize) }
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
    defaults: UserDefaults? = nil,
    threads: AskThreadStore? = nil,
    panelFactory: (@MainActor () -> NSPanel)? = nil,
    presentPanel: @escaping @MainActor (NSPanel) -> Void = { $0.orderFront(nil) },
    dismissPanel: @escaping @MainActor (NSPanel) -> Void = { $0.orderOut(nil) },
    panelIsVisible: @escaping @MainActor (NSPanel) -> Bool = { $0.isVisible },
    onPresentationChange: (@MainActor (AskPresentationState) -> Void)? = nil
  ) {
    self.defaults = defaults
    self.threads = threads ?? AskThreadStore()
    var restored = presentation
    if let defaults {
      restored.isExpanded = defaults.object(forKey: "pensieve.ask.expanded") as? Bool ?? true
      let height = defaults.double(forKey: "pensieve.ask.dockHeight")
      if height > 0 { restored.preferredDockHeight = height }
      rememberedMode =
        AskPresentationMode(
          rawValue:
            defaults.string(forKey: "pensieve.ask.presentationMode") ?? "") ?? .docked
      if rememberedMode == .hidden { rememberedMode = .docked }
      restored.mode =
        defaults.object(forKey: "pensieve.ask.visible") as? Bool == false
        ? .hidden : rememberedMode
    }
    self.presentation = restored
    self.panelFactory = panelFactory ?? { AskPanelController.makeProductionPanelWindow() }
    self.presentPanel = presentPanel
    self.dismissPanel = dismissPanel
    self.panelIsVisible = panelIsVisible
    self.onPresentationChange = onPresentationChange
    super.init()
    if let raw = defaults?.string(forKey: "pensieve.ask.activeThread"),
      let id = UUID(uuidString: raw),
      let record = self.threads.historyRecords.first(where: { $0.id == id })
    {
      self.threads.restore(record)
      activeThreadID = id
    }
  }

  @discardableResult
  func ensureThread(context: AskContext) -> AskThread {
    let thread = threads.thread(for: activeThreadID, context: context)
    defaults?.set(thread.id.uuidString, forKey: "pensieve.ask.activeThread")
    return thread
  }

  /// Context changes mint a thread; changing editor tabs never mutates it.
  func newThread(context: AskContext) {
    threads.existingThread(for: activeThreadID)?.cancel()
    activateThread(threads.newThread(context: context).id)
  }

  func activateThread(_ id: UUID) {
    if threads.existingThread(for: id) == nil,
      let record = threads.historyRecords.first(where: { $0.id == id })
    {
      threads.restore(record)
    }
    guard threads.existingThread(for: id) != nil else { return }
    if id != activeThreadID { threads.existingThread(for: activeThreadID)?.cancel() }
    activeThreadID = id
    defaults?.set(id.uuidString, forKey: "pensieve.ask.activeThread")
  }

  /// Both menu and AppKit quit paths must preserve the conversation before
  /// document consent can retire any other unsaved work. A failed write vetoes
  /// termination while the transcript and draft are still available in memory.
  func prepareForTermination(
    confirmUnsavedHistoryQuit: @MainActor (String) -> Bool = { _ in false },
    resolveDocuments: @MainActor () -> NSApplication.TerminateReply
  ) -> NSApplication.TerminateReply {
    if !threads.cancelAll() {
      let message = threads.historyError ?? "Ask history could not be saved."
      guard confirmUnsavedHistoryQuit(message) else {
        presentation.mode = .docked
        return .terminateCancel
      }
    }
    return resolveDocuments()
  }

  static func confirmQuitWithoutSavedHistory(_ message: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Ask history could not be saved"
    alert.informativeText =
      message + "\nQuit without saving the latest Ask conversations and drafts?"
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Quit Without Saving Ask History")
    return alert.runModal() == .alertSecondButtonReturn
  }

  var isVisible: Bool { presentation.mode != .hidden }

  func setVisible(_ visible: Bool) {
    presentation.mode = visible ? rememberedMode : .hidden
  }

  private func persistPresentation() {
    if presentation.mode != .hidden { rememberedMode = presentation.mode }
    guard let defaults else { return }
    defaults.set(isVisible, forKey: "pensieve.ask.visible")
    defaults.set(rememberedMode.rawValue, forKey: "pensieve.ask.presentationMode")
    defaults.set(presentation.preferredDockHeight, forKey: "pensieve.ask.dockHeight")
    defaults.set(presentation.isExpanded, forKey: "pensieve.ask.expanded")
  }

  /// Only the selected document root may reparent or update the shared host.
  func activateHost(_ anchor: AskDockAnchorView, window: NSWindow?) {
    if dockAnchorView !== anchor { dockAnchorView?.isDocked = false }
    dockAnchorView = anchor
    attachOwnerWindow(window)
  }

  func releaseHost(_ anchor: AskDockAnchorView) {
    guard dockAnchorView === anchor else { return }
    anchor.isDocked = false
    hostingView?.removeFromSuperview()
    dockAnchorView = nil
    attachOwnerWindow(nil)
    if let panel { dismissPanel(panel) }
  }

  func updateTheme(_ theme: PensieveTheme) {
    self.theme = theme
    if let panel { TaflaPanelChrome.applyTheme(theme, to: panel) }
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
    threads.flushHistory()
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
    TaflaPanelChrome.configure(panel)
    TaflaPanelChrome.applyTheme(theme, to: panel)
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

    self.contentSize = contentSize
    if presentation != targetPresentation { self.presentation = targetPresentation }

    switch targetPresentation.mode {
    case .docked:
      if let panel, panelIsVisible(panel) {
        dismissPanel(panel)
      }

      // Retire the old sizing writer before the same hosting view docks.
      panel?.contentView = nil
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
    // AppKit supplies the point in our superview's coordinates. The dock
    // filter uses local coordinates; native descendants keep AppKit's normal
    // hit-test traversal so their frame offsets are applied exactly once.
    let localPoint = convert(point, from: superview)
    guard isDocked, dockRect.contains(localPoint) else {
      return nil
    }
    return super.hitTest(point)
  }
}

/// Bridges SwiftUI content to the persistent NSHostingView owned by `AskPanelController`.
struct AskPanelHostView<Content: View>: NSViewRepresentable {
  @ObservedObject var controller: AskPanelController
  @Binding var presentation: AskPresentationState
  let contentSize: CGSize
  let hostWindow: NSWindow?
  let isActive: Bool
  let theme: PensieveTheme
  let content: () -> Content

  final class Coordinator {
    let controller: AskPanelController
    init(controller: AskPanelController) { self.controller = controller }
  }

  func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

  func makeNSView(context: Context) -> AskDockAnchorView {
    let anchor = AskDockAnchorView()
    updateNSView(anchor, context: context)
    return anchor
  }

  func updateNSView(_ anchor: AskDockAnchorView, context: Context) {
    guard isActive else {
      controller.releaseHost(anchor)
      anchor.isDocked = false
      return
    }
    controller.activateHost(anchor, window: hostWindow)
    if let hosting = controller.hostingView as? NSHostingView<Content> {
      hosting.rootView = content()
    } else if controller.hostingView == nil {
      let hosting = NSHostingView(rootView: content())
      hosting.sizingOptions = []
      hosting.translatesAutoresizingMaskIntoConstraints = true
      hosting.autoresizingMask = []
      controller.hostingView = hosting
    }
    controller.updateTheme(theme)
    controller.syncPresentation(presentation, contentSize: contentSize)
  }

  static func dismantleNSView(_ anchor: AskDockAnchorView, coordinator: Coordinator) {
    coordinator.controller.releaseHost(anchor)
  }
}
