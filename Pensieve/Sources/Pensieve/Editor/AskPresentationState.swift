import CoreGraphics
import Foundation

/// Dock, float, or hidden. The float is an overlay inside the owner content
/// rect. This value does not open a window, register restoration, or subscribe
/// to a stream. Conversation, draft, attachments, provider, and request identity
/// live beside it and are not copied when the mode changes.
struct AskPresentationState: Equatable, Sendable {
  var mode: AskPresentationMode
  var isExpanded: Bool
  /// User-resized dock height, including grip, header, transcript, and composer.
  /// Window clamping reads it; only a dock drag writes it.
  var preferredDockHeight: CGFloat
  var floatOrigin: CGPoint
  var preferredFloatSize: CGSize

  static var expandedDefault: AskPresentationState {
    let content = AskSurfaceLayout.referenceContent
    return AskPresentationState(
      mode: .docked,
      isExpanded: true,
      preferredDockHeight: AskSurfaceLayout.preferredExpandedDockHeight,
      floatOrigin: AskSurfaceLayout.defaultFloatOrigin(in: content),
      preferredFloatSize: CGSize(
        width: 420, height: AskSurfaceLayout.preferredExpandedDockHeight))
  }

  mutating func apply(_ command: AskSurfaceCommand, content: CGSize) -> AskCommandEffect {
    switch command {
    case .hide:
      mode = .hidden
      return .concealed
    case .stop:
      return .cancelTurn
    case .dock:
      mode = .docked
      return .presented
    case .float:
      mode = .floating
      return .presented
    case .expand:
      isExpanded = true
      if mode == .hidden { mode = .docked }
      return .presented
    case .collapse:
      isExpanded = false
      if mode == .hidden { mode = .docked }
      return .presented
    }
  }

  /// Writes the dock the user asked for, capped so the editor floor and the
  /// status bar still fit. Does not cover a later, larger window: the stored
  /// height is what the drag could actually reach.
  mutating func resizeDock(to proposed: CGFloat, in content: CGSize) {
    let maxDock = AskSurfaceLayout.maxDockHeight(content: content)
    let lower = min(AskSurfaceLayout.collapsedDockHeight, maxDock)
    preferredDockHeight = min(max(proposed, lower), max(maxDock, lower))
    isExpanded = preferredDockHeight > AskSurfaceLayout.collapsedDockHeight + 0.5
    mode = .docked
  }

  mutating func dragFloat(from start: CGPoint, by translation: CGSize, in content: CGSize) {
    floatOrigin = CGPoint(x: start.x + translation.width, y: start.y + translation.height)
    mode = .floating
    floatOrigin = AskSurfaceLayout.displayedFloatFrame(presentation: self, content: content).origin
  }

  mutating func resizeFloat(from start: CGSize, by translation: CGSize, in content: CGSize) {
    preferredFloatSize = CGSize(
      width: max(1, start.width + translation.width),
      height: max(1, start.height + translation.height))
    mode = .floating
    let shown = AskSurfaceLayout.displayedFloatFrame(presentation: self, content: content)
    preferredFloatSize = shown.size
    floatOrigin = shown.origin
    isExpanded = shown.size.height > AskSurfaceLayout.collapsedDockHeight + 0.5
  }

  /// Pulls the float origin back inside the owner after the window changes size.
  /// The remembered dock height and float size stay, so growing the window
  /// returns the room the user already chose.
  mutating func clampOrigin(to content: CGSize) {
    guard mode == .floating else { return }
    floatOrigin = AskSurfaceLayout.displayedFloatFrame(presentation: self, content: content).origin
  }
}

enum AskPresentationMode: String, Equatable, Sendable {
  case docked
  case floating
  case hidden
}

enum AskSurfaceCommand: Equatable, Sendable {
  case hide
  case stop
  case dock
  case float
  case expand
  case collapse
}

enum AskCommandEffect: Equatable, Sendable {
  /// The surface leaves the layout. The turn keeps running.
  case concealed
  /// The owner should cancel the in-flight turn. The surface stays where it is.
  case cancelTurn
  case presented
}

/// What this surface refuses to own. Hide is not Stop, and neither one
/// registers a second window or a second stream subscriber.
enum AskWindowPolicy {
  static let restorationClassName: String? = nil
  static let nativeWindowClassName: String? = nil
  static let subscribesToStream = false
}

/// The injected conversation rides along. Transitions rewrite `presentation`
/// only, so the request, draft, attachments, and subscriber count stay put.
struct AskSurfaceCarry<
  Conversation: Equatable, Draft: Equatable, Attachments: Equatable, Provider: Equatable
>: Equatable {
  var conversation: Conversation
  var draft: Draft
  var attachments: Attachments
  var provider: Provider
  var requestID: UUID
  var streamSubscribers: Int
  var presentation: AskPresentationState

  mutating func apply(_ command: AskSurfaceCommand, content: CGSize) -> AskCommandEffect {
    presentation.apply(command, content: content)
  }
}

/// SF Symbols for the chrome. Hide and Stop are different controls.
enum AskSurfaceSymbol {
  static let expand = "chevron.up"
  static let collapse = "chevron.down"
  static let float = "pip.enter"
  static let dock = "pip.exit"
  static let hide = "xmark"
  static let stop = "stop.fill"
  static let grip = "line.3.horizontal"
}

enum AskChromeRole: Equatable, Sendable {
  case floatingShell
  case dockShell
  case chromeGroup
  case transcript
}

enum AskChromeMaterial: Equatable, Sendable {
  case liquidGlass
  case systemMaterial
  case solidTheme
  case plain
}

/// Pointer routing for the dock grip and the floating corner.
/// The dock grip grows the dock. The same grip moves the overlay while
/// floating and must not rewrite the remembered dock height. The corner
/// exists only in floating mode. Neither path opens a window.
enum AskPointerGesture: Equatable, Sendable {
  case dockResize
  case floatDrag
  case floatResize
}

enum AskPointerRoute {
  static func grip(mode: AskPresentationMode) -> AskPointerGesture {
    mode == .floating ? .floatDrag : .dockResize
  }

  static func corner(mode: AskPresentationMode) -> AskPointerGesture? {
    mode == .floating ? .floatResize : nil
  }

  /// Dock drag uses an inverted y: dragging up grows the dock.
  /// Float resize adds the translation, so dragging down and right grows it.
  static func apply(
    _ gesture: AskPointerGesture,
    to state: inout AskPresentationState,
    content: CGSize,
    dockStart: CGFloat,
    originStart: CGPoint,
    sizeStart: CGSize,
    translation: CGSize
  ) {
    switch gesture {
    case .dockResize:
      state.resizeDock(to: dockStart - translation.height, in: content)
    case .floatDrag:
      state.dragFloat(from: originStart, by: translation, in: content)
    case .floatResize:
      state.resizeFloat(from: sizeStart, by: translation, in: content)
    }
  }
}

extension AskChromeMaterial {
  /// macOS 26 glass groups the floating shell and the chrome controls.
  /// Earlier systems use the system material. Reduce Transparency drops both
  /// for the theme's solid source colour. Transcript prose never takes glass.
  static func resolve(
    majorVersion: Int, reduceTransparency: Bool, role: AskChromeRole
  ) -> AskChromeMaterial {
    if role == .transcript { return .plain }
    if reduceTransparency { return .solidTheme }
    if majorVersion >= 26, role == .floatingShell || role == .chromeGroup {
      return .liquidGlass
    }
    return .systemMaterial
  }
}
