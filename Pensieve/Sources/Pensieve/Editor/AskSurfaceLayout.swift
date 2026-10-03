import CoreGraphics

/// Geometry for the Ask dock and the in-window float.
///
/// Content size is the owner window's content size, the same space as
/// `WindowChromeRecipe` (the design cases are 900×700 and 640×480). It is an
/// input, never stored on the presentation. The coordinate space is SwiftUI's:
/// origin at the top-leading corner, y growing downward.
///
/// The bottom 26 pt is the existing `EditorStatusBar` and stays fully inside
/// the content rect. The dock is clamped so a 640×480 content area still keeps
/// 160 pt of editor. The expanded reference dock gives the transcript at least
/// 240 pt and never a permanent 96/120 pt cap. The float is an overlay in that
/// same rect; it does not take editor height and it does not cover the status bar.
enum AskSurfaceLayout {
  /// `EditorStatusBar` uses a fixed 26 pt frame. This cut does not import that
  /// view; the number is the measured chrome the status row already occupies.
  static let statusBarHeight: CGFloat = 26
  static let gripHeight: CGFloat = 10
  static let chromeHeight: CGFloat = 36
  /// Design cap. The composer slot may be shorter when the dock is clamped;
  /// it is never taller than this.
  static let composerMaxHeight: CGFloat = 112
  static let expandedTranscriptFloor: CGFloat = 240
  static let editorFloorAtMinimum: CGFloat = 160
  static let minimumContentHeight: CGFloat = 480
  static let floatMargin: CGFloat = 12
  static let minimumFloatWidth: CGFloat = 320
  static let controlSide: CGFloat = 28
  static let referenceContent = CGSize(width: 900, height: 700)

  /// Grip, header, and the composer cap. The transcript is the slack above this.
  static var collapsedDockHeight: CGFloat {
    gripHeight + chromeHeight + composerMaxHeight
  }

  /// Default expanded dock: the reference transcript floor plus chrome.
  static var preferredExpandedDockHeight: CGFloat {
    collapsedDockHeight + expandedTranscriptFloor
  }

  static var minimumFloatHeight: CGFloat {
    gripHeight + chromeHeight + 64
  }

  static func allocate(
    content rawContent: CGSize, presentation: AskPresentationState
  ) -> AskSurfaceAllocation {
    let content = sanitize(rawContent)
    let statusH = statusHeight(for: content.height)
    let status = CGRect(
      x: 0, y: content.height - statusH, width: content.width, height: statusH)
    switch presentation.mode {
    case .hidden:
      return AskSurfaceAllocation(
        editor: CGRect(x: 0, y: 0, width: content.width, height: content.height - statusH),
        grip: .zero,
        chrome: .zero,
        transcript: .zero,
        composer: .zero,
        status: status,
        askRegion: .zero,
        controls: [])
    case .docked:
      let dockH = displayedDockHeight(presentation: presentation, content: content)
      let editorH = max(0, content.height - statusH - dockH)
      let ask = CGRect(x: 0, y: editorH, width: content.width, height: dockH)
      let parts = split(region: ask)
      return AskSurfaceAllocation(
        editor: CGRect(x: 0, y: 0, width: content.width, height: editorH),
        grip: parts.grip,
        chrome: parts.chrome,
        transcript: parts.transcript,
        composer: parts.composer,
        status: status,
        askRegion: ask,
        controls: controls(grip: parts.grip, chrome: parts.chrome))
    case .floating:
      let frame = displayedFloatFrame(presentation: presentation, content: content)
      let ask = CGRect(origin: frame.origin, size: frame.size)
      let parts = split(region: ask)
      let safeH = content.height - statusH
      return AskSurfaceAllocation(
        editor: CGRect(x: 0, y: 0, width: content.width, height: safeH),
        grip: parts.grip,
        chrome: parts.chrome,
        transcript: parts.transcript,
        composer: parts.composer,
        status: status,
        askRegion: ask,
        controls: controls(grip: parts.grip, chrome: parts.chrome))
    }
  }

  static func displayedDockHeight(
    presentation: AskPresentationState, content rawContent: CGSize
  ) -> CGFloat {
    let content = sanitize(rawContent)
    let maxDock = maxDockHeight(content: content)
    guard presentation.mode == .docked else { return 0 }
    if !presentation.isExpanded {
      return min(collapsedDockHeight, maxDock)
    }
    return min(max(presentation.preferredDockHeight, 0), maxDock)
  }

  static func displayedFloatFrame(
    presentation: AskPresentationState, content rawContent: CGSize
  ) -> AskFloatFrame {
    let content = sanitize(rawContent)
    let safe = safeRect(content)
    var size = presentation.preferredFloatSize
    if !presentation.isExpanded {
      size.height = collapsedDockHeight
    }
    let minWidth = min(minimumFloatWidth, safe.width)
    let minHeight =
      presentation.isExpanded
      ? min(minimumFloatHeight, safe.height) : min(collapsedDockHeight, safe.height)
    size.width = min(max(size.width, minWidth), safe.width)
    size.height = min(max(size.height, minHeight), safe.height)
    if !presentation.isExpanded {
      size.height = min(collapsedDockHeight, safe.height)
    }
    let origin = CGPoint(
      x: clampedAxis(presentation.floatOrigin.x, length: size.width, limit: safe.width),
      y: clampedAxis(presentation.floatOrigin.y, length: size.height, limit: safe.height))
    return AskFloatFrame(origin: origin, size: size)
  }

  static func maxDockHeight(content rawContent: CGSize) -> CGFloat {
    let content = sanitize(rawContent)
    let statusH = statusHeight(for: content.height)
    return max(0, content.height - statusH - editorFloor(contentHeight: content.height))
  }

  /// 160 pt while the content can also hold the chrome band. Shorter than that,
  /// the editor yields so the header controls and the status bar stay inside.
  static func editorFloor(contentHeight: CGFloat) -> CGFloat {
    let afterStatus = max(0, contentHeight - statusHeight(for: contentHeight))
    let room = max(0, afterStatus - gripHeight - chromeHeight)
    return min(editorFloorAtMinimum, room)
  }

  static func safeRect(_ content: CGSize) -> CGRect {
    let size = sanitize(content)
    let statusH = statusHeight(for: size.height)
    return CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - statusH))
  }

  static func statusHeight(for contentHeight: CGFloat) -> CGFloat {
    min(statusBarHeight, max(0, contentHeight))
  }

  static func sanitize(_ content: CGSize) -> CGSize {
    CGSize(width: max(content.width, 0), height: max(content.height, 0))
  }

  static func defaultFloatOrigin(in rawContent: CGSize) -> CGPoint {
    let content = sanitize(rawContent)
    let size = CGSize(width: 420, height: preferredExpandedDockHeight)
    let safe = safeRect(content)
    let shown = AskFloatFrame(origin: .zero, size: size)
    let clamped = CGSize(
      width: min(shown.size.width, safe.width),
      height: min(shown.size.height, safe.height))
    return CGPoint(
      x: max(0, safe.width - clamped.width - floatMargin),
      y: max(0, safe.height - clamped.height - floatMargin))
  }

  private static func split(region: CGRect) -> (
    grip: CGRect, chrome: CGRect, transcript: CGRect, composer: CGRect
  ) {
    var remaining = max(0, region.height)
    let gripH = min(gripHeight, remaining)
    remaining -= gripH
    let chromeH = min(chromeHeight, remaining)
    remaining -= chromeH
    let composerH = min(composerMaxHeight, remaining)
    remaining -= composerH
    let transcriptH = max(0, remaining)
    var y = region.minY
    let grip = CGRect(x: region.minX, y: y, width: region.width, height: gripH)
    y += gripH
    let chrome = CGRect(x: region.minX, y: y, width: region.width, height: chromeH)
    y += chromeH
    let transcript = CGRect(x: region.minX, y: y, width: region.width, height: transcriptH)
    y += transcriptH
    let composer = CGRect(x: region.minX, y: y, width: region.width, height: composerH)
    return (grip, chrome, transcript, composer)
  }

  private static func controls(grip: CGRect, chrome: CGRect) -> [AskControlFrame] {
    var frames: [AskControlFrame] = []
    if grip.width >= 1, grip.height >= 1 {
      frames.append(AskControlFrame(role: .grip, frame: grip))
    }
    guard chrome.width >= 1, chrome.height >= 1 else { return frames }
    let roles: [AskControlRole] = [.expand, .presentation, .hide]
    let gap: CGFloat = 4
    let inset: CGFloat = 8
    let count = CGFloat(roles.count)
    let available = max(0, chrome.width - inset * 2 - gap * (count - 1))
    let width = min(controlSide, available / count)
    let height = min(controlSide, max(0, chrome.height - 4))
    guard width >= 1, height >= 1 else { return frames }
    var x = chrome.maxX - inset - width
    let y = chrome.midY - height / 2
    for role in roles.reversed() {
      frames.append(
        AskControlFrame(
          role: role, frame: CGRect(x: x, y: y, width: width, height: height)))
      x -= width + gap
    }
    return frames
  }

  private static func clampedAxis(_ origin: CGFloat, length: CGFloat, limit: CGFloat) -> CGFloat {
    guard limit > 0 else { return 0 }
    let span = min(max(length, 0), limit)
    return min(max(origin, 0), max(0, limit - span))
  }
}

struct AskFloatFrame: Equatable, Sendable {
  var origin: CGPoint
  var size: CGSize
}

enum AskControlRole: String, Equatable, Sendable {
  case grip
  case expand
  case presentation
  case hide
}

struct AskControlFrame: Equatable, Sendable {
  var role: AskControlRole
  var frame: CGRect
}

struct AskSurfaceAllocation: Equatable, Sendable {
  var editor: CGRect
  var grip: CGRect
  var chrome: CGRect
  var transcript: CGRect
  var composer: CGRect
  var status: CGRect
  var askRegion: CGRect
  var controls: [AskControlFrame]
}
