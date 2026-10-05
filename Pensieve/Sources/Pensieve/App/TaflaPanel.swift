import AppKit
import Combine
import SwiftUI

/// Floating surfaces use their in-content close/drag controls. AppKit's
/// transparent full-size title bar must not leave a second, detached row.
@MainActor
enum TaflaPanelChrome {
  static func configure(_ panel: NSPanel) {
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(kind)?.isHidden = true
    }
  }

  static func applyTheme(_ theme: PensieveTheme, to panel: NSPanel) {
    let appearance = WindowChromeRecipe.windowAppearance(for: theme)
    if panel.appearance?.name != appearance?.name { panel.appearance = appearance }
  }
}

/// AppKit-owned panels do not inherit the document scene's appearance.
/// Observe only the theme edges, and never write NSApp's appearance.
@MainActor
final class TaflaPanelThemeBinding {
  private var observation: AnyCancellable?

  init(panel: NSPanel, themeManager: ThemeManager) {
    observation = themeManager.$skin.combineLatest(themeManager.$systemAppearanceGeneration)
      .sink { [weak panel] theme, _ in
        guard let panel else { return }
        TaflaPanelChrome.applyTheme(theme, to: panel)
      }
  }
}

struct TaflaSurfaceBackground: View {
  let theme: PensieveTheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let backing = Color(nsColor: theme.tokens.source.nsColor)
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    if reduceTransparency {
      shape.fill(backing)
    } else if #available(macOS 26, *) {
      backing.opacity(0.35)
        .glassEffect(.regular.tint(backing.opacity(0.55)), in: shape)
    } else {
      shape.fill(.regularMaterial)
        .overlay { shape.fill(backing.opacity(0.35)) }
    }
  }
}

/// Shared non-activating floating panel recipe used by Pensieve's Tafla windows
/// (Dictation, Ask native panel).
///
/// A non-activating panel can still become key for its own controls (pickers,
/// text inputs, buttons, scroll views) but never steals `isMainWindow` status from
/// the document editor.
class NonActivatingTaflaPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Pins a hosted SwiftUI view tree to the bounds of the panel or dock container,
/// preventing fitting-size constraints from collapsing or mutating the window frame.
final class TaflaContentContainer: NSView {
  private let hostingView: NSView

  init(hostingView: NSView) {
    self.hostingView = hostingView
    super.init(frame: .zero)
    addSubview(hostingView)
    hostingView.frame = bounds
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    hostingView.frame = bounds
  }

  override func layout() {
    super.layout()
    hostingView.frame = bounds
  }
}
