import AppKit

/// A single design token: one colour expressed once, resolved to both an
/// `NSColor` (for the AppKit source panel + chrome) and a CSS string (for the
/// WKWebView preview). Keeping hex and `NSColor` behind one type is what lets a
/// theme feed BOTH panels without the two surfaces drifting apart.
///
/// Fixed-palette themes construct specs from hex. `default`/`raw` stay adaptive
/// by wrapping a live semantic `NSColor` (which resolves per appearance at draw
/// time) plus a static CSS fallback.
struct ColorSpec {
  /// Resolved colour for the AppKit panels. For fixed themes this is parsed
  /// once from `css`; for adaptive themes it is a live semantic system colour.
  let nsColor: NSColor
  /// CSS representation for the preview stylesheet.
  let css: String

  init(hex: String) {
    self.css = hex
    self.nsColor = ColorSpec.nsColor(fromHex: hex)
  }

  /// Adaptive spec: a live semantic `NSColor` (resolves per appearance) with a
  /// static CSS fallback for any preview surface that reads the spec directly.
  init(system: NSColor, css: String) {
    self.nsColor = system
    self.css = css
  }

  static func nsColor(fromHex hex: String) -> NSColor {
    var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if string.hasPrefix("#") { string.removeFirst() }

    var value: UInt64 = 0
    Scanner(string: string).scanHexInt64(&value)

    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    if string.count == 8 {
      red = CGFloat((value >> 24) & 0xff) / 255
      green = CGFloat((value >> 16) & 0xff) / 255
      blue = CGFloat((value >> 8) & 0xff) / 255
      alpha = CGFloat(value & 0xff) / 255
    } else {
      red = CGFloat((value >> 16) & 0xff) / 255
      green = CGFloat((value >> 8) & 0xff) / 255
      blue = CGFloat(value & 0xff) / 255
      alpha = 1
    }
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }
}

/// The tokens one theme hands to BOTH reading surfaces.
///
/// In this cut the WKWebView preview is still styled by the verbatim
/// `skinCSS` overlays (they hardcode the same hex values), so `ThemeTokens`
/// drives the AppKit side — the source panel (`SyntaxHighlighter`,
/// `LineNumberGutter`, `MarkdownTextView`) and the titlebar backing colour —
/// plus the appearance `mode` that pins the preview flavour CSS.
///
/// Fields are limited to what those surfaces consume today; the fuller surface
/// palette from the design handoff (page/panel/accent/typography) lands with
/// the later chrome-polish cuts that give those tokens consumers.
struct ThemeTokens {
  enum Mode {
    case light
    case dark
  }

  /// The theme's fixed appearance, or `nil` for the adaptive themes
  /// (`default`/`raw`) that follow the system light/dark setting.
  let mode: Mode?

  // Surfaces
  /// Editor pane background — also the gutter fill and the titlebar backing.
  let source: ColorSpec
  /// Structural hairline: the gutter's right edge and the horizontal rule.
  let border: ColorSpec
  /// Inline-code background in the source panel.
  let codeBackground: ColorSpec

  // Text
  /// Base editor text colour.
  let text: ColorSpec

  // Source-panel syntax tokens (1:1 with SyntaxHighlighter attributes)
  let srcHeading: ColorSpec
  let srcListMarker: ColorSpec
  let srcInlineCode: ColorSpec
  let srcLink: ColorSpec
  let srcQuote: ColorSpec
  let srcStrike: ColorSpec
  /// `==highlight==` wash in the source panel.
  let srcHighlightBackground: ColorSpec
  let srcGutter: ColorSpec
  let srcCurrentLine: ColorSpec
}

/// The application theme — the reading surface layered on top of the markdown
/// flavour (`ThemeManager.Theme`). Renamed from `PreviewTheme` because a theme
/// now dresses BOTH panels (rendered preview + source editor), not just the
/// WKWebView preview.
///
/// The `UserDefaults` key stays `pensieve.preview.skin`; legacy stored values
/// from the pre-consolidation set migrate through `resolve(persistedRawValue:)`.
enum PensieveTheme: String, CaseIterable, Identifiable {
  /// GitHub-like surface — the established look; byte-for-byte GitHub preview
  /// (no overlay beyond the base appearance tokens) and an adaptive source
  /// panel.
  case `default`
  /// Raw surface: stripped chrome, monospace, near "view source", adaptive.
  case raw
  /// Warm light paper, serif measure.
  case pergament
  /// Cool desaturated dark, report instrument.
  case graphite
  /// Signature dark surface — the fresh-install default.
  case ink
  /// Clinical light neutral, semantic colour only.
  case klinika
  /// One mono family everywhere, achromatic.
  case maszynopis

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .default: return "Default"
    case .raw: return "Raw"
    case .pergament: return "Pergament"
    case .graphite: return "Graphite"
    case .ink: return "Ink"
    case .klinika: return "Klinika"
    case .maszynopis: return "Maszynopis"
    }
  }

  /// SF Symbol for the toolbar picker — keeps the menu legible at a glance.
  var systemImage: String {
    switch self {
    case .default: return "doc.richtext"
    case .raw: return "text.alignleft"
    case .pergament: return "book"
    case .graphite: return "terminal"
    case .ink: return "drop.fill"
    case .klinika: return "cross.case"
    case .maszynopis: return "keyboard"
    }
  }

  /// Explicit appearance to pin on the preview WebView (and the source panel's
  /// caret), or `nil` for the adaptive themes that follow the system setting.
  /// Single-mode themes carry no `@media (prefers-color-scheme:)` in their CSS,
  /// so the WebView appearance is the only thing that keeps the flavour bundle
  /// (`gfm.css`) from flipping the base the other way.
  var appearanceName: NSAppearance.Name? {
    switch tokens.mode {
    case .light: return .aqua
    case .dark: return .darkAqua
    case .none: return nil
    }
  }

  var tokens: ThemeTokens { Self.tokenTable[self] ?? Self.adaptiveTokens }

  // MARK: - Migration

  /// Fresh installs default to `ink`. Known raw values pass through; legacy
  /// values from the pre-consolidation set map to their nearest survivor;
  /// anything else falls back to the GitHub `default`.
  static func resolve(persistedRawValue raw: String?) -> PensieveTheme {
    guard let raw else { return .ink }
    if let known = PensieveTheme(rawValue: raw) { return known }
    return legacyMigration[raw] ?? .default
  }

  /// Legacy `pensieve.preview.skin` values → their consolidation target.
  static let legacyMigration: [String: PensieveTheme] = [
    "paper": .pergament,
    "mla": .pergament,
    "code": .graphite,
    "vista": .klinika,
    "notion": .klinika,
    "vercel": .klinika,
    "themeable": .klinika,
    "jamstatic": .klinika,
    "glass": .ink,
  ]

  // MARK: - Token tables

  /// Adaptive tokens for `default`/`raw`: live semantic system colours so the
  /// source panel follows the system light/dark setting, with the garish
  /// accent-as-text colours (systemGreen/Pink/Blue/Orange) retired for
  /// restrained semantic ones. Cached CSS fallbacks are the GitHub base values.
  static let adaptiveTokens = ThemeTokens(
    mode: nil,
    source: ColorSpec(system: .textBackgroundColor, css: "#ffffff"),
    border: ColorSpec(system: .separatorColor, css: "#d0d7de"),
    codeBackground: ColorSpec(
      system: NSColor.textBackgroundColor.withSystemEffect(.disabled), css: "#f6f8fa"),
    text: ColorSpec(system: .textColor, css: "#1f2328"),
    srcHeading: ColorSpec(system: .labelColor, css: "#1f2328"),
    srcListMarker: ColorSpec(system: .secondaryLabelColor, css: "#57606a"),
    srcInlineCode: ColorSpec(system: .labelColor, css: "#1f2328"),
    srcLink: ColorSpec(system: .linkColor, css: "#0969da"),
    srcQuote: ColorSpec(system: .secondaryLabelColor, css: "#57606a"),
    srcStrike: ColorSpec(system: .secondaryLabelColor, css: "#57606a"),
    srcHighlightBackground: ColorSpec(
      system: NSColor.systemYellow.withAlphaComponent(0.35), css: "#fff8c5"),
    srcGutter: ColorSpec(system: .tertiaryLabelColor, css: "#8c959f"),
    srcCurrentLine: ColorSpec(system: .labelColor, css: "#1f2328")
  )

  /// Fixed-palette tokens keyed by theme. Built once (static `let`), so the
  /// per-render `titlebarGlassBackingColor(for:)` and skin-change token pushes
  /// are dictionary lookups, never repeated hex parsing.
  private static let tokenTable: [PensieveTheme: ThemeTokens] = [
    .default: adaptiveTokens,
    .raw: adaptiveTokens,
    .pergament: ThemeTokens(
      mode: .light,
      source: ColorSpec(hex: "#fdfbf4"),
      border: ColorSpec(hex: "#e2d8c2"),
      codeBackground: ColorSpec(hex: "#efe8d6"),
      text: ColorSpec(hex: "#2a251d"),
      srcHeading: ColorSpec(hex: "#4a5a3c"),
      srcListMarker: ColorSpec(hex: "#9a5b28"),
      srcInlineCode: ColorSpec(hex: "#8a4a3a"),
      srcLink: ColorSpec(hex: "#7a6a4a"),
      srcQuote: ColorSpec(hex: "#8b8271"),
      srcStrike: ColorSpec(hex: "#8a7a5a"),
      srcHighlightBackground: ColorSpec(hex: "#e8dcae"),
      srcGutter: ColorSpec(hex: "#b9ad96"),
      srcCurrentLine: ColorSpec(hex: "#4a5a3c")
    ),
    .graphite: ThemeTokens(
      mode: .dark,
      source: ColorSpec(hex: "#101318"),
      border: ColorSpec(hex: "#21262e"),
      codeBackground: ColorSpec(hex: "#171b22"),
      text: ColorSpec(hex: "#c9d0d8"),
      srcHeading: ColorSpec(hex: "#a8bcc8"),
      srcListMarker: ColorSpec(hex: "#6f8fa0"),
      srcInlineCode: ColorSpec(hex: "#c49a72"),
      srcLink: ColorSpec(hex: "#86b8c4"),
      srcQuote: ColorSpec(hex: "#6b7480"),
      srcStrike: ColorSpec(hex: "#6b7480"),
      srcHighlightBackground: ColorSpec(hex: "#2a3340"),
      srcGutter: ColorSpec(hex: "#4a535e"),
      srcCurrentLine: ColorSpec(hex: "#a8bcc8")
    ),
    .ink: ThemeTokens(
      mode: .dark,
      source: ColorSpec(hex: "#10141d"),
      border: ColorSpec(hex: "#232a36"),
      codeBackground: ColorSpec(hex: "#1a2130"),
      text: ColorSpec(hex: "#d8dde6"),
      srcHeading: ColorSpec(hex: "#b8c4d4"),
      srcListMarker: ColorSpec(hex: "#8a7fc8"),
      srcInlineCode: ColorSpec(hex: "#c9a8d8"),
      srcLink: ColorSpec(hex: "#8a7fc8"),
      srcQuote: ColorSpec(hex: "#7c8798"),
      srcStrike: ColorSpec(hex: "#6a7382"),
      srcHighlightBackground: ColorSpec(hex: "#2b2540"),
      srcGutter: ColorSpec(hex: "#4b5665"),
      srcCurrentLine: ColorSpec(hex: "#b8c4d4")
    ),
    .klinika: ThemeTokens(
      mode: .light,
      source: ColorSpec(hex: "#ffffff"),
      border: ColorSpec(hex: "#e4e8ec"),
      codeBackground: ColorSpec(hex: "#f3f5f7"),
      text: ColorSpec(hex: "#14181c"),
      srcHeading: ColorSpec(hex: "#14181c"),
      srcListMarker: ColorSpec(hex: "#0f6f6c"),
      srcInlineCode: ColorSpec(hex: "#7a4a12"),
      srcLink: ColorSpec(hex: "#0f6f6c"),
      srcQuote: ColorSpec(hex: "#667079"),
      srcStrike: ColorSpec(hex: "#667079"),
      srcHighlightBackground: ColorSpec(hex: "#d9ecea"),
      srcGutter: ColorSpec(hex: "#aab3bb"),
      srcCurrentLine: ColorSpec(hex: "#0f6f6c")
    ),
    .maszynopis: ThemeTokens(
      mode: .light,
      source: ColorSpec(hex: "#1c1c1c"),
      border: ColorSpec(hex: "#e6e6e6"),
      codeBackground: ColorSpec(hex: "#2b2b2b"),
      text: ColorSpec(hex: "#d4d4d4"),
      srcHeading: ColorSpec(hex: "#f2f2f2"),
      srcListMarker: ColorSpec(hex: "#d4d4d4"),
      srcInlineCode: ColorSpec(hex: "#d4d4d4"),
      srcLink: ColorSpec(hex: "#d4d4d4"),
      srcQuote: ColorSpec(hex: "#8a8a8a"),
      srcStrike: ColorSpec(hex: "#8a8a8a"),
      srcHighlightBackground: ColorSpec(hex: "#e6e6e6"),
      srcGutter: ColorSpec(hex: "#525252"),
      srcCurrentLine: ColorSpec(hex: "#e8e8e8")
    ),
  ]
}
