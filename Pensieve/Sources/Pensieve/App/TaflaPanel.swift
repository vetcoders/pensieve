import AppKit

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
