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
/// Fields are limited to what those surfaces consume today: the source panel,
/// the titlebar backing, the status bar (`warning`), and — from the chrome
/// polish cut — the SwiftUI sidebar/toolbar/empty-state chrome (`accent`,
/// `chromeAccent`, `muted`, `previewHeadingFamily`). The remaining handoff palette
/// (page/panel/`danger`/`positive`) joins as its consumers land.
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

  // Semantic accents
  /// Structural/link accent — the chrome's active-selection tint and the
  /// sidebar's selected-file colour. Byte-parity with the preview
  /// `--vc-preview-link` so the reading surface and the window chrome agree;
  /// adaptive themes wrap `linkColor` with the GitHub base as CSS fallback.
  let accent: ColorSpec
  /// Prominent-chrome FILL — the toolbar's on-state toggle chips (Rich
  /// Markdown, auto reload, scroll sync, dictation, autocomplete), which the
  /// system otherwise paints in `controlAccentColor` and which read as system
  /// blue against every fixed palette.
  ///
  /// Split from `accent` because that token is tuned as *ink*: text and link
  /// colour on the reading surface. As a filled control several skins' ink
  /// fails — graphite's and ink's are too pale to carry a glyph, and
  /// typewriter's is byte-identical to its own titlebar backing (`source`), so
  /// the chip would vanish. Where the ink survives as a fill (parchment,
  /// porcelain) this token repeats it verbatim. Adaptive skins keep
  /// `controlAccentColor`, so `default`/`raw` still follow the accent the user
  /// picked in System Settings.
  ///
  /// Chrome-only: no preview stylesheet consumes it, so the `css` string is
  /// carried for parity, not emitted.
  let chromeAccent: ColorSpec
  /// Secondary/label text — sidebar section headers, muted row glyphs. Mirrors
  /// the preview `--vc-preview-muted`; adaptive themes wrap `secondaryLabelColor`.
  let muted: ColorSpec

  // Semantic status
  /// Attention colour for transient status — the status bar's dirty "Edited"
  /// marker. Mirrors the preview `--vc-preview-warning` so the chrome and the
  /// rendered surface read the same accent. Only `warning` has a chrome consumer
  /// in this cut; `danger`/`positive` join it when they get one.
  let warning: ColorSpec

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

  // Typography — the bundled family names (see `BundledFonts`) each theme's CSS
  // font-family chains reference. Chrome (the SwiftUI sidebar's row title) reads
  // `previewHeadingFamily`; the strings are empty for the adaptive themes, which
  // carry no bundled family and fall back to the system face. The CSS fallback
  // chains stay on the CSS side; the native side falls back through `font(_:_:)`.
  /// Reading-surface body family (`.markdown-body`).
  let previewFamily: String
  /// Heading / UI-chrome family (sidebar row titles, `.markdown-body h*`).
  let previewHeadingFamily: String
  /// Monospace family (source panel, code).
  let monoFamily: String

  /// Resolves a bundled family name to an `NSFont`, or the system font of the
  /// same size when the name is empty (adaptive themes) or the family did not
  /// register in this process. Keeps native chrome legible without the bundled
  /// face — the same graceful degradation the CSS fallback chains give the
  /// preview. SwiftUI's `Font.custom` degrades the same way for the SwiftUI
  /// surfaces that consume these families directly.
  static func font(_ family: String, _ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    if !family.isEmpty {
      if let named = NSFont(name: family, size: size) { return named }
      if let byFamily = NSFontManager.shared.font(
        withFamily: family, traits: [], weight: 5, size: size)
      {
        return byFamily
      }
    }
    return .systemFont(ofSize: size, weight: weight)
  }
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
  case parchment
  /// Cool desaturated dark, report instrument — the fresh-install default.
  case graphite
  /// Signature dark surface.
  case ink
  /// Clinical light neutral, semantic colour only.
  case porcelain
  /// One mono family everywhere, achromatic.
  case typewriter
  // TEMPORARY — test-build line only, remove after the operator picks.
  //
  // The same skin as `typewriter` down to the byte, except for the ONE thing
  // still undecided: the window chrome mode. `typewriter` pins `.light` (the
  // titlebar draws light controls over the dark backing); this one pins `.dark`
  // and takes the titlebar backing to the mockup's `#171717`. Shipped as a
  // second picker entry so both can be compared live in the same build. Delete
  // this case, its `displayName`/`systemImage` arms, its token table entry and
  // the `skinCSS` fall-through once the decision lands.
  case typewriterDarkChrome = "typewriter-dark-chrome"
  // TEMPORARY — test-build line only, remove after the operator picks.
  //
  // The two candidate shapes for the LIGHT half of the Typewriter pair. The
  // decided direction is one "Maszynopis" paired to the system setting: system
  // dark keeps today's dark-chrome variant 1:1, system light gets one of these.
  // Both carry the same light window and the same light SOURCE panel, so the
  // only thing the operator is choosing between them is the preview:
  //
  //   * `typewriterLightMirror` — the dual-truth reflected. Light frame, light
  //     source, DARK preview: the preview takes over the roles today's DARK
  //     source panel plays (#1c1c1c page, #d4d4d4 body, #f2f2f2 heads).
  //   * `typewriterLightPaper` — one light sheet all the way through. Same light
  //     frame and source, and today's light typewriter preview verbatim.
  //
  // Known demo limitation, deliberately not fixed for a throwaway pair: the
  // mirror pins `.light` for the WINDOW (that is the point of it), and the
  // preview appearance rides the same axis, so Mermaid — which reads
  // `prefers-color-scheme` in JS, out of reach of a CSS overlay — still draws
  // its light diagram theme on the mirror's dark page. The CSS side is complete.
  //
  // Delete both cases, their `displayName`/`systemImage` arms, their token table
  // entries and their `skinCSS` branches once the decision lands; the pair
  // mechanism itself belongs on the themes line, not here.
  case typewriterLightMirror = "typewriter-light-mirror"
  case typewriterLightPaper = "typewriter-light-paper"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .default: return "Default"
    case .raw: return "Raw"
    case .parchment: return "Parchment"
    case .graphite: return "Graphite"
    case .ink: return "Ink"
    case .porcelain: return "Porcelain"
    case .typewriter: return "Typewriter"
    // TEMPORARY — see the case declaration.
    case .typewriterDarkChrome: return "Maszynopis (ciemny chrome)"
    case .typewriterLightMirror: return "Maszynopis jasny — lustro"
    case .typewriterLightPaper: return "Maszynopis jasny — kartka"
    }
  }

  /// SF Symbol for the toolbar picker — keeps the menu legible at a glance.
  var systemImage: String {
    switch self {
    case .default: return "doc.richtext"
    case .raw: return "text.alignleft"
    case .parchment: return "book"
    case .graphite: return "terminal"
    case .ink: return "drop.fill"
    case .porcelain: return "cross.case"
    case .typewriter: return "keyboard"
    // TEMPORARY — see the case declaration.
    case .typewriterDarkChrome: return "keyboard.fill"
    case .typewriterLightMirror: return "circle.lefthalf.filled"
    case .typewriterLightPaper: return "doc.plaintext"
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

  /// Fresh installs default to `graphite`. Known raw values pass through;
  /// legacy values from the pre-consolidation set map to their nearest
  /// survivor; anything else falls back to the GitHub `default`.
  static func resolve(persistedRawValue raw: String?) -> PensieveTheme {
    guard let raw else { return .graphite }
    if let known = PensieveTheme(rawValue: raw) { return known }
    return legacyMigration[raw] ?? .default
  }

  /// Legacy `pensieve.preview.skin` values → their consolidation target.
  static let legacyMigration: [String: PensieveTheme] = [
    "paper": .parchment,
    "mla": .parchment,
    "code": .graphite,
    "vista": .porcelain,
    "notion": .porcelain,
    "vercel": .porcelain,
    "themeable": .porcelain,
    "jamstatic": .porcelain,
    "glass": .ink,
    "pergament": .parchment,
    "klinika": .porcelain,
    "maszynopis": .typewriter,
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
    accent: ColorSpec(system: .linkColor, css: "#0969da"),
    chromeAccent: ColorSpec(system: .controlAccentColor, css: "#0969da"),
    muted: ColorSpec(system: .secondaryLabelColor, css: "#57606a"),
    warning: ColorSpec(system: .systemOrange, css: "#9a6700"),
    srcHeading: ColorSpec(system: .labelColor, css: "#1f2328"),
    srcListMarker: ColorSpec(system: .secondaryLabelColor, css: "#57606a"),
    srcInlineCode: ColorSpec(system: .labelColor, css: "#1f2328"),
    srcLink: ColorSpec(system: .linkColor, css: "#0969da"),
    srcQuote: ColorSpec(system: .secondaryLabelColor, css: "#57606a"),
    srcStrike: ColorSpec(system: .secondaryLabelColor, css: "#57606a"),
    srcHighlightBackground: ColorSpec(
      system: NSColor.systemYellow.withAlphaComponent(0.35), css: "#fff8c5"),
    srcGutter: ColorSpec(system: .tertiaryLabelColor, css: "#8c959f"),
    srcCurrentLine: ColorSpec(system: .labelColor, css: "#1f2328"),
    // Adaptive themes carry no bundled family: empty strings fall back to the
    // system face on both sides (native `font(_:_:)`, SwiftUI `Font.custom`).
    previewFamily: "",
    previewHeadingFamily: "",
    monoFamily: ""
  )

  /// Fixed-palette tokens keyed by theme. Built once (static `let`), so the
  /// per-render `titlebarGlassBackingColor(for:)` and skin-change token pushes
  /// are dictionary lookups, never repeated hex parsing.
  private static let tokenTable: [PensieveTheme: ThemeTokens] = [
    .default: adaptiveTokens,
    .raw: adaptiveTokens,
    .parchment: ThemeTokens(
      mode: .light,
      source: ColorSpec(hex: "#fdfbf4"),
      border: ColorSpec(hex: "#e2d8c2"),
      codeBackground: ColorSpec(hex: "#efe8d6"),
      text: ColorSpec(hex: "#2a251d"),
      accent: ColorSpec(hex: "#9a5b28"),
      // Sienna ink survives as a fill on warm paper: same value as the link.
      chromeAccent: ColorSpec(hex: "#9a5b28"),
      muted: ColorSpec(hex: "#7a7062"),
      warning: ColorSpec(hex: "#8a6a20"),
      srcHeading: ColorSpec(hex: "#4a5a3c"),
      srcListMarker: ColorSpec(hex: "#9a5b28"),
      srcInlineCode: ColorSpec(hex: "#8a4a3a"),
      srcLink: ColorSpec(hex: "#7a6a4a"),
      srcQuote: ColorSpec(hex: "#8b8271"),
      srcStrike: ColorSpec(hex: "#8a7a5a"),
      srcHighlightBackground: ColorSpec(hex: "#e8dcae"),
      srcGutter: ColorSpec(hex: "#b9ad96"),
      srcCurrentLine: ColorSpec(hex: "#4a5a3c"),
      previewFamily: "Newsreader",
      previewHeadingFamily: "Newsreader",
      monoFamily: "Sometype Mono"
    ),
    .graphite: ThemeTokens(
      mode: .dark,
      source: ColorSpec(hex: "#161616"),
      border: ColorSpec(hex: "#2a2a2a"),
      codeBackground: ColorSpec(hex: "#1f1f1f"),
      text: ColorSpec(hex: "#d2d2d2"),
      accent: ColorSpec(hex: "#86b8c4"),
      // The pale slate link would carry no glyph as a fill; deepened along the
      // same hue so a light glyph clears it and it still lifts off #161616.
      chromeAccent: ColorSpec(hex: "#3d6f7d"),
      muted: ColorSpec(hex: "#848484"),
      warning: ColorSpec(hex: "#c49a72"),
      srcHeading: ColorSpec(hex: "#e0e0e0"),
      srcListMarker: ColorSpec(hex: "#6f8fa0"),
      srcInlineCode: ColorSpec(hex: "#c49a72"),
      srcLink: ColorSpec(hex: "#86b8c4"),
      srcQuote: ColorSpec(hex: "#737373"),
      srcStrike: ColorSpec(hex: "#737373"),
      srcHighlightBackground: ColorSpec(hex: "#343434"),
      srcGutter: ColorSpec(hex: "#4f4f4f"),
      srcCurrentLine: ColorSpec(hex: "#e0e0e0"),
      previewFamily: "Instrument Sans",
      previewHeadingFamily: "Instrument Sans",
      monoFamily: "JetBrains Mono"
    ),
    .ink: ThemeTokens(
      mode: .dark,
      source: ColorSpec(hex: "#10141d"),
      border: ColorSpec(hex: "#232a36"),
      codeBackground: ColorSpec(hex: "#1a2130"),
      text: ColorSpec(hex: "#d8dde6"),
      accent: ColorSpec(hex: "#8a7fc8"),
      // Same iris hue, deepened until a light glyph clears the fill.
      chromeAccent: ColorSpec(hex: "#6a5fae"),
      muted: ColorSpec(hex: "#8590a0"),
      warning: ColorSpec(hex: "#c8b07a"),
      srcHeading: ColorSpec(hex: "#b8c4d4"),
      srcListMarker: ColorSpec(hex: "#8a7fc8"),
      srcInlineCode: ColorSpec(hex: "#c9a8d8"),
      srcLink: ColorSpec(hex: "#8a7fc8"),
      srcQuote: ColorSpec(hex: "#7c8798"),
      srcStrike: ColorSpec(hex: "#6a7382"),
      srcHighlightBackground: ColorSpec(hex: "#2b2540"),
      srcGutter: ColorSpec(hex: "#4b5665"),
      srcCurrentLine: ColorSpec(hex: "#b8c4d4"),
      previewFamily: "Literata",
      previewHeadingFamily: "Archivo",
      monoFamily: "JetBrains Mono"
    ),
    .porcelain: ThemeTokens(
      mode: .light,
      source: ColorSpec(hex: "#ffffff"),
      border: ColorSpec(hex: "#e4e8ec"),
      codeBackground: ColorSpec(hex: "#f3f5f7"),
      text: ColorSpec(hex: "#14181c"),
      accent: ColorSpec(hex: "#0f6f6c"),
      // Deep clinical teal is already fill-strength on white: same as the link.
      chromeAccent: ColorSpec(hex: "#0f6f6c"),
      muted: ColorSpec(hex: "#667079"),
      warning: ColorSpec(hex: "#7a4a12"),
      srcHeading: ColorSpec(hex: "#14181c"),
      srcListMarker: ColorSpec(hex: "#0f6f6c"),
      srcInlineCode: ColorSpec(hex: "#7a4a12"),
      srcLink: ColorSpec(hex: "#0f6f6c"),
      srcQuote: ColorSpec(hex: "#667079"),
      srcStrike: ColorSpec(hex: "#667079"),
      srcHighlightBackground: ColorSpec(hex: "#d9ecea"),
      srcGutter: ColorSpec(hex: "#aab3bb"),
      srcCurrentLine: ColorSpec(hex: "#0f6f6c"),
      previewFamily: "IBM Plex Sans",
      previewHeadingFamily: "IBM Plex Sans",
      monoFamily: "IBM Plex Mono"
    ),
    .typewriter: ThemeTokens(
      mode: .light,
      source: ColorSpec(hex: "#1c1c1c"),
      border: ColorSpec(hex: "#e6e6e6"),
      codeBackground: ColorSpec(hex: "#2b2b2b"),
      text: ColorSpec(hex: "#d4d4d4"),
      accent: ColorSpec(hex: "#1c1c1c"),
      // The ink IS this skin's surface (#1c1c1c), so a chip painted with it
      // would be invisible. This skin carries no hue at all — its whole palette
      // is one grey ramp (#e6e6e6 · #a8a8a8 · #6e6e6e · #1c1c1c · #171717) — so
      // the fill is the one ramp step that clears both legibility pins: a white
      // glyph rides it at 5.10:1 and it lifts off the #1c1c1c titlebar backing
      // at 3.34:1. The lighter steps cannot carry the glyph (#a8a8a8 is 2.38:1),
      // the darker ones dissolve into the backing.
      chromeAccent: ColorSpec(hex: "#6e6e6e"),
      muted: ColorSpec(hex: "#6e6e6e"),
      warning: ColorSpec(hex: "#6e6e6e"),
      srcHeading: ColorSpec(hex: "#f2f2f2"),
      srcListMarker: ColorSpec(hex: "#d4d4d4"),
      srcInlineCode: ColorSpec(hex: "#d4d4d4"),
      srcLink: ColorSpec(hex: "#d4d4d4"),
      srcQuote: ColorSpec(hex: "#8a8a8a"),
      srcStrike: ColorSpec(hex: "#8a8a8a"),
      srcHighlightBackground: ColorSpec(hex: "#e6e6e6"),
      srcGutter: ColorSpec(hex: "#525252"),
      srcCurrentLine: ColorSpec(hex: "#e8e8e8"),
      previewFamily: "Spline Sans Mono",
      previewHeadingFamily: "Spline Sans Mono",
      monoFamily: "Spline Sans Mono"
    ),
    // TEMPORARY — test-build line only, remove after the operator picks.
    //
    // Byte-identical to `.typewriter` except for the two values that carry the
    // undecided axis: `mode` flips `.light` → `.dark` (the window and the
    // preview take `darkAqua`, so the titlebar draws dark controls), and
    // `source` — which IS the titlebar backing (`titlebarGlassBackingColor`) —
    // moves to the mockup's `#171717`. Everything else is copied verbatim so
    // the only difference the operator sees is the chrome.
    .typewriterDarkChrome: ThemeTokens(
      mode: .dark,
      source: ColorSpec(hex: "#171717"),
      border: ColorSpec(hex: "#e6e6e6"),
      codeBackground: ColorSpec(hex: "#2b2b2b"),
      text: ColorSpec(hex: "#d4d4d4"),
      accent: ColorSpec(hex: "#1c1c1c"),
      chromeAccent: ColorSpec(hex: "#6e6e6e"),
      muted: ColorSpec(hex: "#6e6e6e"),
      warning: ColorSpec(hex: "#6e6e6e"),
      srcHeading: ColorSpec(hex: "#f2f2f2"),
      srcListMarker: ColorSpec(hex: "#d4d4d4"),
      srcInlineCode: ColorSpec(hex: "#d4d4d4"),
      srcLink: ColorSpec(hex: "#d4d4d4"),
      srcQuote: ColorSpec(hex: "#8a8a8a"),
      srcStrike: ColorSpec(hex: "#8a8a8a"),
      srcHighlightBackground: ColorSpec(hex: "#e6e6e6"),
      srcGutter: ColorSpec(hex: "#525252"),
      srcCurrentLine: ColorSpec(hex: "#e8e8e8"),
      previewFamily: "Spline Sans Mono",
      previewHeadingFamily: "Spline Sans Mono",
      monoFamily: "Spline Sans Mono"
    ),
    // TEMPORARY — test-build line only, remove after the operator picks.
    //
    // The two light candidates carry an IDENTICAL native side: same light
    // window (`mode: .light`, so the titlebar draws dark controls), same white
    // titlebar backing, same light source panel. That is deliberate — with the
    // chrome and the source held fixed, the only thing left to choose between
    // them is the preview, which is what the two `skinCSS` branches differ in.
    //
    // Every value is the same ROLE the dark typewriter source plays, read from
    // the other end of the one grey ramp (`#ffffff · #e6e6e6 · #a8a8a8 ·
    // #6e6e6e · #1c1c1c · #171717`): body ink instead of body paper, a mid-grey
    // gutter instead of a dim one, headings one step past the body instead of
    // one step before it. Zero hue, like the skin it pairs with.
    //
    // `chromeAccent` stays `#6e6e6e` and it is re-measured, not inherited: on
    // this skin the chip sits on a WHITE titlebar backing rather than `#1c1c1c`.
    // The same ramp step happens to clear both pins from the other side —
    // a white glyph rides it at 5.10:1, and it lifts off white at 5.10:1 too.
    // The lighter steps still cannot carry the glyph (`#a8a8a8` is 2.38:1) and
    // the darker ones (`#1c1c1c`, `#171717`) would be near-black chips.
    .typewriterLightMirror: ThemeTokens(
      mode: .light,
      source: ColorSpec(hex: "#ffffff"),
      border: ColorSpec(hex: "#e6e6e6"),
      codeBackground: ColorSpec(hex: "#e6e6e6"),
      text: ColorSpec(hex: "#1c1c1c"),
      accent: ColorSpec(hex: "#1c1c1c"),
      chromeAccent: ColorSpec(hex: "#6e6e6e"),
      muted: ColorSpec(hex: "#6e6e6e"),
      warning: ColorSpec(hex: "#6e6e6e"),
      srcHeading: ColorSpec(hex: "#171717"),
      srcListMarker: ColorSpec(hex: "#1c1c1c"),
      srcInlineCode: ColorSpec(hex: "#1c1c1c"),
      srcLink: ColorSpec(hex: "#1c1c1c"),
      srcQuote: ColorSpec(hex: "#6e6e6e"),
      srcStrike: ColorSpec(hex: "#6e6e6e"),
      srcHighlightBackground: ColorSpec(hex: "#e6e6e6"),
      srcGutter: ColorSpec(hex: "#a8a8a8"),
      srcCurrentLine: ColorSpec(hex: "#1c1c1c"),
      previewFamily: "Spline Sans Mono",
      previewHeadingFamily: "Spline Sans Mono",
      monoFamily: "Spline Sans Mono"
    ),
    // TEMPORARY — see `.typewriterLightMirror`. Byte-identical native side; the
    // pair differs only in the preview stylesheet.
    .typewriterLightPaper: ThemeTokens(
      mode: .light,
      source: ColorSpec(hex: "#ffffff"),
      border: ColorSpec(hex: "#e6e6e6"),
      codeBackground: ColorSpec(hex: "#e6e6e6"),
      text: ColorSpec(hex: "#1c1c1c"),
      accent: ColorSpec(hex: "#1c1c1c"),
      chromeAccent: ColorSpec(hex: "#6e6e6e"),
      muted: ColorSpec(hex: "#6e6e6e"),
      warning: ColorSpec(hex: "#6e6e6e"),
      srcHeading: ColorSpec(hex: "#171717"),
      srcListMarker: ColorSpec(hex: "#1c1c1c"),
      srcInlineCode: ColorSpec(hex: "#1c1c1c"),
      srcLink: ColorSpec(hex: "#1c1c1c"),
      srcQuote: ColorSpec(hex: "#6e6e6e"),
      srcStrike: ColorSpec(hex: "#6e6e6e"),
      srcHighlightBackground: ColorSpec(hex: "#e6e6e6"),
      srcGutter: ColorSpec(hex: "#a8a8a8"),
      srcCurrentLine: ColorSpec(hex: "#1c1c1c"),
      previewFamily: "Spline Sans Mono",
      previewHeadingFamily: "Spline Sans Mono",
      monoFamily: "Spline Sans Mono"
    ),
  ]
}
