import Foundation
import Observation

/// One wrap-lines preference for a document window: editor `NSTextContainer`
/// and preview `pre`/`code` honor the same value.
///
/// Default ON — wrap is the first-launch contract. An absent UserDefaults key
/// is "never chosen", not off: `bool(forKey:)` would silently ship the opposite
/// default. Tests construct this with an ephemeral suite and never read
/// production defaults.
@Observable
@MainActor
final class WrapPreference {
  static let shared = WrapPreference()

  /// First-launch / missing-key default. Exposed so UI and CSS seams never
  /// spell the default out themselves.
  nonisolated static let wrapLinesDefault = true

  /// The single user-facing command title. Exactly one production string.
  nonisolated static let commandTitle = "Wrap lines"

  nonisolated static let didChangeNotification = Notification.Name(
    "pensieve.wrapLines.didChange")
  nonisolated static let wrapLinesUserInfoKey = "wrapLines"

  /// Marker the preview stylesheet always emits so tests can pin the W2 rule
  /// without scraping flavor CSS for an unconditional `nowrap`.
  nonisolated static let previewStylesheetMarker = "W2-01 wrap-toggle"

  private static let wrapLinesKey = "Pensieve.wrapLines"

  private let defaults: UserDefaults

  var wrapLines: Bool {
    didSet {
      defaults.set(wrapLines, forKey: Self.wrapLinesKey)
      NotificationCenter.default.post(
        name: Self.didChangeNotification,
        object: self,
        userInfo: [Self.wrapLinesUserInfoKey: wrapLines]
      )
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if defaults.object(forKey: Self.wrapLinesKey) == nil {
      self.wrapLines = Self.wrapLinesDefault
    } else {
      self.wrapLines = defaults.bool(forKey: Self.wrapLinesKey)
    }
  }

  /// AppKit-free text-container configuration. Tests drive this seam without
  /// allocating an `NSWindow`.
  struct TextContainerConfiguration: Equatable, Sendable {
    var widthTracksTextView: Bool
    var isHorizontallyResizable: Bool
    var autoresizesWidth: Bool
    var hasHorizontalScroller: Bool
  }

  nonisolated static func textContainerConfiguration(wrapLines: Bool)
    -> TextContainerConfiguration
  {
    if wrapLines {
      return TextContainerConfiguration(
        widthTracksTextView: true,
        isHorizontallyResizable: false,
        autoresizesWidth: true,
        hasHorizontalScroller: false
      )
    }
    return TextContainerConfiguration(
      widthTracksTextView: false,
      isHorizontallyResizable: true,
      autoresizesWidth: false,
      hasHorizontalScroller: true
    )
  }

  /// Preview `pre`/`code` rules that win over flavor CSS (`gfm.css` nowrap,
  /// `markdown.css` pre-wrap). Injected last in `appearanceCSS`.
  nonisolated static func previewStylesheet(wrapLines: Bool) -> String {
    if wrapLines {
      return """
        /* \(previewStylesheetMarker) — wrap ON. */
        .markdown-body pre,
        .markdown-body pre code,
        .markdown-body pre tt,
        .markdown-body .highlight pre {
          white-space: pre-wrap !important;
          overflow-wrap: anywhere;
          word-break: break-word;
          overflow-x: hidden;
        }
        """
    }
    return """
      /* \(previewStylesheetMarker) — wrap OFF. */
      .markdown-body pre,
      .markdown-body pre code,
      .markdown-body pre tt,
      .markdown-body .highlight pre {
        white-space: pre !important;
        overflow-wrap: normal;
        word-break: normal;
        overflow-x: auto;
      }
      """
  }
}
