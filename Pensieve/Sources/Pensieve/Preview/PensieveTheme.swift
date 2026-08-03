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

  /// The accent as CHROME must paint it — the one answer every chrome surface
  /// asks for instead of reading `accent` raw.
  ///
  /// A fixed palette is free to pick an accent that collides with its own
  /// surface, and one does on purpose: typewriter's dark half sets
  /// `accent: #1c1c1c` over a `#171717` backing, because that accent is INK for
  /// the white preview sheet the pair keeps on BOTH halves. Painted raw on the
  /// window chrome — the sidebar's selected-file glyph, its selection wash and
  /// its 2 px leading bar, the empty-state wordmark — that ink is invisible.
  ///
  /// So the accent is measured against the surface it will actually be painted
  /// on and demoted to another token from the SAME theme (the body ink) when it
  /// cannot be seen — never to an invented per-theme hex, which is the rule the
  /// source-panel highlighters already follow.
  ///
  /// The surface is `source`, for two reasons rather than convenience. It is the
  /// token this app already backs its own window chrome with
  /// (`WindowChromeRecipe.titlebarGlassBackingColor`), and it is what the
  /// detail-pane empty state paints. The sidebar keeps the system sidebar
  /// MATERIAL instead of this token, but that material follows the appearance
  /// the skin pins (`appearanceName`, itself derived from `mode`), so it lands
  /// within a step or two of `source` on every skin — near enough that a colour
  /// which cannot be seen on one cannot be seen on the other.
  ///
  /// An UNMEASURABLE pair keeps the accent: the adaptive skins' catalog colours
  /// (`linkColor` on `textBackgroundColor`) resolve per appearance at draw time
  /// and cannot be ratioed here, and they are legible by construction.
  var legibleAccent: NSColor {
    let accent = accent.nsColor
    if let ratio = ThemeContrast.ratio(accent, source.nsColor),
      ratio < ThemeContrast.minimumTextContrast
    {
      return text.nsColor
    }
    return accent
  }

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
    }
  }

  /// Explicit appearance to pin on the WINDOW, or `nil` for the themes that
  /// carry no light/dark answer of their own.
  ///
  /// A PAIRED skin pins the half it RESOLVED — it does not return `nil`. The
  /// difference looks academic (the resolved half agrees with the system, so
  /// both spellings paint the same chrome) and is not: `nil` means "no
  /// preference", which leaves SwiftUI to resolve the scene's colour scheme on
  /// its own, INDEPENDENTLY of the token accessor that already read the setting.
  /// Two independent readers of one setting is a fracture waiting for a pass
  /// that only one of them sees, and it shipped as one: on build 446 the
  /// operator's trailing toolbar families came back LIGHT — glyphs, glass and
  /// chip tint — inside a window whose titlebar, sidebar and editor were all
  /// dark. The 445 test build, whose typewriter pinned `.darkAqua` outright
  /// under the same system setting and the same white sheet, showed one
  /// uniformly dark toolbar; the pin was the only difference between them.
  ///
  /// So the pair states its answer instead of declining to. It still follows the
  /// setting — `tokens` is what resolves the half, and `ThemeManager` re-reads
  /// it on every system flip — but every consumer, SwiftUI included, now gets
  /// that ONE answer rather than deriving a second one.
  var appearanceName: NSAppearance.Name? {
    switch tokens.mode {
    case .light: return .aqua
    case .dark: return .darkAqua
    case .none: return nil
    }
  }

  /// Appearance for the READING SURFACE — the preview WebView and anything that
  /// renders the same sheet, export included.
  ///
  /// Split from `appearanceName` for the pair alone, and for a reason the pair
  /// creates: its two palettes dress the WINDOW and the SOURCE panel, but the
  /// sheet is white in BOTH halves. Letting the WebView follow the system would
  /// hand a white page the dark half of `gfm.css` (and the dark Mermaid theme,
  /// which reads `prefers-color-scheme` from JS where no stylesheet can reach
  /// it). Pinning the surface light keeps the paper the same paper in both
  /// halves, which is the decision this skin exists to express.
  ///
  /// Unpaired skins answer exactly as before.
  var readingSurfaceAppearanceName: NSAppearance.Name? {
    guard let pair = Self.pairedPalettes[self] else { return appearanceName }
    switch pair.light.mode {
    case .dark: return .darkAqua
    default: return .aqua
    }
  }

  /// Tokens for the half that is live right now.
  ///
  /// For a paired skin this reads the system setting, which makes it the ONLY
  /// token accessor that is not a pure function of the enum. Everything that
  /// must not depend on the machine's current setting — export above all — goes
  /// through `exportTokens` or `tokens(underDarkSystem:)` instead.
  var tokens: ThemeTokens {
    if let pair = Self.pairedPalettes[self] {
      return SystemAppearance.isDark ? pair.dark : pair.light
    }
    return Self.tokenTable[self] ?? Self.adaptiveTokens
  }

  /// The same resolution, with the system setting passed in rather than read.
  /// Pure, so a test can drive both halves without touching the host.
  func tokens(underDarkSystem isDark: Bool) -> ThemeTokens {
    if let pair = Self.pairedPalettes[self] { return isDark ? pair.dark : pair.light }
    return Self.tokenTable[self] ?? Self.adaptiveTokens
  }

  /// Tokens for an EXPORTED document, which is a sheet of paper and not a
  /// window: a paired skin always exports its light half, whatever the machine
  /// it was exported from was set to. A dark PDF would be a regression, not a
  /// feature — the page is white in both halves of the pair on screen too.
  var exportTokens: ThemeTokens {
    if let pair = Self.pairedPalettes[self] { return pair.light }
    return tokens
  }

  /// Appearance to pin while rendering an export. Same reasoning as
  /// `exportTokens`, applied to the media queries in the flavour bundle.
  var exportAppearanceName: NSAppearance.Name? {
    if Self.pairedPalettes[self] != nil { return .aqua }
    return appearanceName
  }

  /// True when this skin is two fixed palettes paired to the system setting
  /// rather than one palette or a set of semantic colours.
  var isPaired: Bool { Self.pairedPalettes[self] != nil }

  /// Identity of the palette actually PAINTED — which is not the same thing as
  /// the skin the operator picked.
  ///
  /// A paired skin is ONE enum case carrying TWO palettes, so `PensieveTheme`
  /// alone cannot tell "the half changed" from "nothing changed". Any re-theme
  /// memo keyed on the bare enum therefore stops working the moment a pair is
  /// selected: the operator flips the Mac to light, `tokens` starts answering
  /// with the light half, and the memo — still holding `.typewriter` — decides
  /// there is nothing to repaint. That is measured, not theoretical: it left the
  /// source panel black inside an otherwise fully light window.
  ///
  /// Unpaired skins read no system setting, so their identity deliberately
  /// ignores it: they keep memoizing exactly as before and a system flip costs
  /// them no repaint at all.
  var paintedIdentity: PaintedSkin { paintedIdentity(underDarkSystem: SystemAppearance.isDark) }

  /// The same identity with the system setting passed in rather than read, so a
  /// test can walk both halves without touching the host.
  func paintedIdentity(underDarkSystem isDark: Bool) -> PaintedSkin {
    PaintedSkin(skin: self, isDarkHalf: isPaired && isDark)
  }

  // MARK: - Migration

  /// Known raw values pass through; legacy values from the pre-consolidation set
  /// map to their nearest survivor; anything else falls back to the GitHub
  /// `default`.
  ///
  /// NO value is the one case this function cannot answer on its own. It used to
  /// mean "fresh install", and the fresh-install default is `graphite` — but the
  /// shipped builds resolved a missing key to `default`, and `skin`'s `didSet`
  /// does not fire during `init`, so an operator who has been reading on
  /// `Default` since before this build has no key either. Both look identical
  /// from here. `withoutAChoice` is that decision, made by the caller that can
  /// see the whole preferences container (`ThemeManager.installOrigin`); the
  /// `graphite` default keeps this a pure fresh-install answer for callers with
  /// nothing else to go on.
  static func resolve(
    persistedRawValue raw: String?, withoutAChoice fallback: PensieveTheme = .graphite
  ) -> PensieveTheme {
    guard let raw else { return fallback }
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
    // The three throwaway picker entries the test-build line carried while the
    // operator chose the light half by eye. They never shipped as raw values
    // here, but a machine that ran those builds has one of them persisted — and
    // every one of them was a Typewriter, so they land on the pair rather than
    // dropping the operator back on the GitHub default.
    "typewriter-dark-chrome": .typewriter,
    "typewriter-light-mirror": .typewriter,
    "typewriter-light-paper": .typewriter,
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
  ]

  /// Skins that are TWO fixed palettes paired to the system setting instead of
  /// one palette (the other fixed skins) or a set of semantic colours
  /// (`default`/`raw`, which follow the system by never naming a colour).
  ///
  /// This is the third thing a theme can be, and it exists because Typewriter
  /// asks a question the other two shapes cannot answer: the operator wants the
  /// skin to follow her machine, but she does not want the system's colours —
  /// she wants HER two, one per side. So the skin declares a pair, the system
  /// setting picks the half, and every colour is still ours.
  ///
  /// What stays constant across the pair is as deliberate as what changes. The
  /// sheet is white on BOTH sides — that is the decision this skin encodes, and
  /// it is why `readingSurfaceAppearanceName` and `exportTokens` refuse to
  /// follow the system the way the window does. What flips is the window's own
  /// dress: the titlebar backing and the source panel, dark ink on the dark
  /// side, dark ink on white on the light side.
  ///
  /// Both halves are the one grey ramp (`#ffffff · #e6e6e6 · #a8a8a8 · #6e6e6e ·
  /// #1c1c1c · #171717`) and carry no hue at all, which
  /// `testTypewriterPairIsAchromaticOnBothHalves` walks token by token.
  static let pairedPalettes: [PensieveTheme: (light: ThemeTokens, dark: ThemeTokens)] = [
    .typewriter: (
      // System LIGHT — the whole window is the page. White titlebar backing,
      // white source panel, ink body, mid-grey numbers, heads one step past the
      // body: the same ROLES the dark half plays, read from the other end of
      // the ramp.
      light: ThemeTokens(
        mode: .light,
        source: ColorSpec(hex: "#ffffff"),
        border: ColorSpec(hex: "#e6e6e6"),
        codeBackground: ColorSpec(hex: "#e6e6e6"),
        text: ColorSpec(hex: "#1c1c1c"),
        accent: ColorSpec(hex: "#1c1c1c"),
        // Measured against THIS half's backing, not inherited from the other:
        // the chip sits on white here and on `#171717` there. `#6e6e6e` is the
        // one ramp step that clears both pins from both sides — a white glyph
        // rides it at 5.10:1, it lifts off white at 5.10:1 and off `#171717` at
        // 3.52:1. `#a8a8a8` still cannot carry the glyph (2.38:1), and the two
        // darkest steps would be near-black chips on a white titlebar.
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
      // System DARK — the dark chrome the operator compared against and kept,
      // 1:1: `#171717` titlebar backing over a dark source panel, white sheet
      // opposite it.
      dark: ThemeTokens(
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
      )
    )
  ]
}

/// What a surface last PAINTED, as a value that changes whenever the painted
/// colours change — including a paired skin's half, which the enum alone hides.
///
/// This exists to be a memo key. Re-theming a live editor is expensive enough
/// that it must not run on every SwiftUI pass (that cost is what `d721f55` /
/// `ce4397f` settled), so the passes that re-theme are gated on "did the palette
/// change" — and the gate needs an identity that is true to the palette rather
/// than to the menu item.
struct PaintedSkin: Equatable {
  let skin: PensieveTheme
  /// Only ever true for a paired skin. An unpaired skin's palette does not read
  /// the system setting, so recording it would invent a difference that has no
  /// repaint behind it.
  let isDarkHalf: Bool
}

/// Which half of a paired skin the machine is asking for.
///
/// Reads the live `effectiveAppearance` rather than a cached flag, so there is
/// nothing to invalidate and nothing to get stale: a paired skin's tokens are
/// simply a function of the setting at the moment they are read. What still
/// needs a nudge is SwiftUI — a system flip changes no `@Published` value on its
/// own — and that nudge lives in `ThemeManager`, deliberately away from here.
enum SystemAppearance {
  static var isDark: Bool { isDark(NSApplication.shared.effectiveAppearance) }

  /// Split out so a test can ask the same question of an appearance it built
  /// itself, without driving the whole application's setting.
  static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }
}
