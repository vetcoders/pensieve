import CoreGraphics

/// Geometry for the Ask dock and the native floating panel.
///
/// In docked mode, content size is the owner window's content size. The dock
/// sits above the status bar (26 pt) and is clamped so the editor floor stays
/// at least 160 pt.
///
/// In floating mode, allocation applies to the native panel's own window
/// bounds independently of the editor or status bar.
enum AskSurfaceLayout {
  /// `EditorStatusBar` uses a fixed 26 pt frame.
  static let statusBarHeight: CGFloat = 26
  static let gripHeight: CGFloat = 10
  static let chromeHeight: CGFloat = 36
  static let compactChromeHeight: CGFloat = 62
  static let compactHeaderWidth: CGFloat = 680

  static func usesCompactHeader(width: CGFloat) -> Bool { width < compactHeaderWidth }
  /// Design cap. The composer slot may be shorter when the dock is clamped;
  /// it is never taller than this.
  static let composerMaxHeight: CGFloat = 112
  static let expandedTranscriptFloor: CGFloat = 240
  static let editorFloorAtMinimum: CGFloat = 160
  static let minimumContentHeight: CGFloat = 480
  static let minimumPanelWidth: CGFloat = 360
  static let minimumPanelHeight: CGFloat = 260
  static let defaultPanelSize = CGSize(width: 640, height: 520)
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
        controls: controls(grip: parts.grip, chrome: parts.chrome, mode: .docked))
    case .floating:
      // Native panel owns its own content window and allocates within its own bounds
      let ask = CGRect(origin: .zero, size: content)
      let parts = split(region: ask)
      return AskSurfaceAllocation(
        editor: .zero,
        grip: parts.grip,
        chrome: parts.chrome,
        transcript: parts.transcript,
        composer: parts.composer,
        status: .zero,
        askRegion: ask,
        controls: controls(grip: parts.grip, chrome: parts.chrome, mode: .floating))
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

  private static func split(region: CGRect) -> (
    grip: CGRect, chrome: CGRect, transcript: CGRect, composer: CGRect
  ) {
    var remaining = max(0, region.height)
    let gripH = min(gripHeight, remaining)
    remaining -= gripH
    let chromeH = min(
      usesCompactHeader(width: region.width) ? compactChromeHeight : chromeHeight, remaining)
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

  private static func controls(
    grip: CGRect, chrome: CGRect, mode: AskPresentationMode
  ) -> [AskControlFrame] {
    var frames: [AskControlFrame] = []
    if grip.width >= 1, grip.height >= 1 {
      frames.append(AskControlFrame(role: .grip, frame: grip))
    }
    guard chrome.width >= 1, chrome.height >= 1 else { return frames }
    var roles: [AskControlRole] = [.expand, .presentation, .hide]
    if mode == .floating {
      roles.insert(.alwaysOnTop, at: 0)
    }
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
}

enum AskControlRole: String, Equatable, Sendable {
  case grip
  case alwaysOnTop
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
