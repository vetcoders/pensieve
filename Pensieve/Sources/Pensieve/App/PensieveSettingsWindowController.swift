import AppKit
import SwiftUI

/// The panes hosted by Pensieve's single application-owned Settings window.
enum PensieveSettingsSection: Hashable {
  case general
  case ai
  /// Theme and flavor. Added when the titlebar's appearance menu was removed:
  /// the status-bar chip is the primary home, but it only exists in a window
  /// showing a document, so the axes needed one route reachable with ⌘, from
  /// anywhere — including the launcher.
  case appearance
}

enum PensieveSettingsPresentationResult: Equatable {
  case presented
  case blockedByNativeModalSurface

  var userMessage: String? {
    switch self {
    case .presented:
      return nil
    case .blockedByNativeModalSurface:
      return "Close the current dialog before opening Settings."
    }
  }
}

/// A value-only snapshot of AppKit's process-local modal ownership graph.
/// Keeping the decision independent of live windows lets unit tests cover the
/// safety boundary without publishing a fixture to WindowServer.
struct PensieveSettingsNativeModalState: Equatable {
  let hasApplicationModalWindow: Bool
  let hasAttachedSheet: Bool
  let hasSheetParent: Bool

  var blocksSettingsPresentation: Bool {
    hasApplicationModalWindow || hasAttachedSheet || hasSheetParent
  }
}

/// Selection belongs to the retained window controller rather than to a
/// SwiftUI `Settings` scene. Keeping it in one reference object lets every
/// entry point select a pane without creating another native window.
@MainActor
final class PensieveSettingsSelection: ObservableObject {
  @Published var selectedSection: PensieveSettingsSection
  @Published private(set) var presentationError: String?

  init(
    selectedSection: PensieveSettingsSection = .general,
    presentationError: String? = nil
  ) {
    self.selectedSection = selectedSection
    self.presentationError = presentationError
  }

  func reportPresentationError(_ message: String) {
    presentationError = message
  }

  func dismissPresentationError() {
    presentationError = nil
  }
}

/// The sole owner of Pensieve's auxiliary Settings surface.
///
/// A SwiftUI `Settings` scene previously let AppKit own the native window while
/// Pensieve globally allowed automatic window tabbing for documents. That left
/// Settings eligible for system scene restoration and tab-group lifecycle it
/// could not police. This controller instead retains one ordinary `NSWindow`,
/// opts it out of both mechanisms before it is ever shown, and reuses the same
/// object after close.
@MainActor
final class PensieveSettingsWindowController: NSWindowController, ObservableObject {
  static let shared = PensieveSettingsWindowController(
    providerSettings: .shared,
    savingSettings: .shared,
    launchSettings: .shared)

  static let windowIdentifier = NSUserInterfaceItemIdentifier("pensieve.settings.window")

  private let ownedWindow: NSWindow
  private let blockingNativeModalOwner: @MainActor () -> NSWindow?
  private let presentWindow: @MainActor (NSWindow) -> Void
  private let reportBlockedPresentationToDocument:
    @MainActor (PensieveSettingsPresentationResult, NSWindow) -> Bool
  private let notificationCenter: NotificationCenter
  private var windowObservers: [NSObjectProtocol] = []
  @Published private(set) var ownsCommandSurface = false
  let selection: PensieveSettingsSelection

  convenience init(
    providerSettings: ProviderSettings,
    savingSettings: DocumentSavingSettings,
    launchSettings: LaunchSettings,
    themeManager: ThemeManager = .shared
  ) {
    let selection = PensieveSettingsSelection()
    let rootView = PensieveSettingsView(
      providerSettings: providerSettings,
      savingSettings: savingSettings,
      launchSettings: launchSettings,
      themeManager: themeManager,
      selection: selection)
    let hostingView = NSHostingView(rootView: rootView)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: true)
    window.contentView = hostingView
    self.init(window: window, selection: selection)
    window.center()
  }

  /// Internal initializer keeps the native ownership contract directly
  /// testable without presenting a real Settings fixture on the desktop.
  init(
    window: NSWindow,
    selection: PensieveSettingsSelection,
    blockingNativeModalOwner: @escaping @MainActor () -> NSWindow? = {
      PensieveSettingsWindowController.currentBlockingNativeModalOwner()
    },
    presentWindow: @escaping @MainActor (NSWindow) -> Void = { window in
      NSApplication.shared.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    },
    reportBlockedPresentation:
      @escaping @MainActor (PensieveSettingsPresentationResult, NSWindow) -> Bool = {
        result, blockingOwner in
        guard let message = result.userMessage else { return true }
        let context = CommandSurfaceContext.shared
        guard
          let appState = context.reportingAppState(
            blockingOwner: blockingOwner,
            keyWindow: NSApplication.shared.keyWindow,
            mainWindow: NSApplication.shared.mainWindow
          )
        else {
          NSSound.beep()
          return false
        }
        appState.lastError = message
        NSSound.beep()
        return true
      },
    notificationCenter: NotificationCenter = .default
  ) {
    ownedWindow = window
    self.selection = selection
    self.blockingNativeModalOwner = blockingNativeModalOwner
    self.presentWindow = presentWindow
    reportBlockedPresentationToDocument = reportBlockedPresentation
    self.notificationCenter = notificationCenter
    super.init(window: window)
    enforceOwnershipContract()
    observeCommandSurfaceOwnership()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    for observer in windowObservers {
      notificationCenter.removeObserver(observer)
    }
  }

  /// Selects the requested pane and returns the retained native surface. This
  /// seam is intentionally separate from ordering so tests can prove close →
  /// reopen identity without flashing AppKit fixtures on the active desktop.
  @discardableResult
  func prepareForPresentation(section: PensieveSettingsSection) -> NSWindow {
    selection.selectedSection = section
    if window !== ownedWindow {
      window = ownedWindow
    }
    enforceOwnershipContract()
    return ownedWindow
  }

  @discardableResult
  func show(section: PensieveSettingsSection) -> PensieveSettingsPresentationResult {
    guard let blockingOwner = blockingNativeModalOwner() else {
      selection.dismissPresentationError()
      let window = prepareForPresentation(section: section)
      presentWindow(window)
      synchronizeCommandSurfaceOwnership(keyWindow: NSApplication.shared.keyWindow)
      return .presented
    }
    let result = PensieveSettingsPresentationResult.blockedByNativeModalSurface
    DebugTrace.log("settings-presentation=blocked reason=native-modal-surface")
    let reachedDocumentSurface = reportBlockedPresentationToDocument(result, blockingOwner)
    if !reachedDocumentSurface, let message = result.userMessage {
      // A Settings-owned sheet has no document AppState by design. Keep the
      // failure in the retained Settings model instead of guessing at the
      // last document that happened to own the menu bar. If Settings is
      // hidden, the modal gate intentionally prevents ordering it on screen.
      selection.reportPresentationError(message)
    }
    return result
  }

  private static func currentBlockingNativeModalOwner() -> NSWindow? {
    let application = NSApplication.shared
    if let modalWindow = application.modalWindow {
      return modalWindow.sheetParent ?? modalWindow
    }
    if let owner = application.windows.first(where: { $0.attachedSheet != nil }) {
      return owner
    }
    if let sheet = application.windows.first(where: { $0.sheetParent != nil }) {
      return sheet.sheetParent ?? sheet
    }
    return nil
  }

  static func currentNativeModalState() -> PensieveSettingsNativeModalState {
    let windows = NSApplication.shared.windows
    return PensieveSettingsNativeModalState(
      hasApplicationModalWindow: NSApplication.shared.modalWindow != nil,
      hasAttachedSheet: windows.contains { $0.attachedSheet != nil },
      hasSheetParent: windows.contains { $0.sheetParent != nil })
  }

  /// Updates the menu-routing signal using object identity only. Kept internal
  /// so the Settings precedence can be pinned with unpublished test windows.
  func synchronizeCommandSurfaceOwnership(keyWindow: NSWindow?) {
    ownsCommandSurface = keyWindow === ownedWindow
  }

  private func observeCommandSurfaceOwnership() {
    windowObservers.append(
      notificationCenter.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        MainActor.assumeIsolated {
          self?.synchronizeCommandSurfaceOwnership(keyWindow: notification.object as? NSWindow)
        }
      })
    windowObservers.append(
      notificationCenter.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: ownedWindow,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.synchronizeCommandSurfaceOwnership(keyWindow: nil)
        }
      })
    windowObservers.append(
      notificationCenter.addObserver(
        forName: NSWindow.willCloseNotification,
        object: ownedWindow,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.synchronizeCommandSurfaceOwnership(keyWindow: nil)
        }
      })
  }

  private func enforceOwnershipContract() {
    ownedWindow.identifier = Self.windowIdentifier
    ownedWindow.setAccessibilityIdentifier(Self.windowIdentifier.rawValue)
    ownedWindow.title = "Settings"
    ownedWindow.tabbingMode = .disallowed
    ownedWindow.tabbingIdentifier = ""
    ownedWindow.isReleasedWhenClosed = false
    ManagedWindowRestoration.disable(on: ownedWindow)
  }
}
