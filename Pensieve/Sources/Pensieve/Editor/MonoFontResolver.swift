import AppKit
import CoreText

/// Resolves a theme's monospace family (`ThemeTokens.monoFamily`) into concrete
/// `NSFont`s for the source panel: base text, bold/semibold spans, italic spans,
/// and the line-number gutter.
///
/// ## Why the bundled FILE is consulted before the family name
///
/// The themed families are registered process-wide by
/// `BundledFonts.registerOnce()`, but a family-name lookup is not bundle truth:
///
/// - A user may have the same family INSTALLED system-wide in a different cut.
///   JetBrains Mono ships here as 400 + 700 only, while the installed variable
///   family exposes all 16 members — resolving by name would give the operator's
///   machine a different editor face than a clean one.
/// - Two bundled faces do not even sit in the family the CSS names them by:
///   `ibm-plex-mono-500`/`-600` carry the family names "IBM Plex Mono Medium"
///   and "IBM Plex Mono SemiBold" in their own `name` tables, so
///   `NSFontManager.font(withFamily: "IBM Plex Mono", traits: .bold, …)` finds
///   NO heavier member and porcelain would lose bold entirely.
///
/// So the weight is matched against the bundled face list (the manifest in
/// `BundledFonts`) and the winning face is loaded by its PostScript name. The
/// family-name lookups remain as fallbacks for a family that is not bundled at
/// all, and the last stop is always the system monospaced font — the same
/// graceful degradation the skin CSS fallback chains give the preview.
enum MonoFontResolver {
  /// Slant synthesised for a themed family that ships no italic face (Sometype
  /// Mono, JetBrains Mono and IBM Plex Mono are bundled as upright weights
  /// only). Matches the `.obliqueness` AppKit itself uses for faux italics.
  static let syntheticItalicObliqueness: CGFloat = 0.2

  /// What to fall back to when the theme carries no family (`default`/`raw`) or
  /// the named family cannot be resolved.
  enum SystemFallback: Hashable {
    /// `NSFont.monospacedSystemFont` — SF Mono, the source panel's historical face.
    case mono
    /// `NSFont.monospacedDigitSystemFont` — proportional SF with tabular figures,
    /// the gutter's historical face. Kept distinct so the adaptive themes' line
    /// numbers render in exactly the same figures as before this resolver existed.
    case monoDigits

    func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
      switch self {
      case .mono: return .monospacedSystemFont(ofSize: size, weight: weight)
      case .monoDigits: return .monospacedDigitSystemFont(ofSize: size, weight: weight)
      }
    }
  }

  /// An italic face plus the slant the caller still has to synthesise itself.
  struct Italic {
    let font: NSFont
    /// `0` when `font` is a real italic face; `syntheticItalicObliqueness` when
    /// the family has none and the caller must slant the glyphs
    /// (`.obliqueness`) to keep `*emphasis*` visually distinct.
    let obliqueness: CGFloat
  }

  static func font(
    family: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    fallback: SystemFallback = .mono
  ) -> NSFont {
    resolved(family: family, size: size, weight: weight, italic: false, fallback: fallback)
  }

  /// The family's italic face, or the closest thing available.
  ///
  /// A theme with no family keeps the pre-existing behaviour exactly — the
  /// `NSFontManager` italic derivation of the system monospaced font, and NO
  /// synthetic slant — so `default` and `raw` render emphasis as they always did.
  static func italicFont(family: String, size: CGFloat, fallback: SystemFallback = .mono) -> Italic
  {
    let font = resolved(
      family: family, size: size, weight: .regular, italic: true, fallback: fallback)
    guard !family.isEmpty else { return Italic(font: font, obliqueness: 0) }
    let isRealItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
    return Italic(font: font, obliqueness: isRealItalic ? 0 : syntheticItalicObliqueness)
  }

  // MARK: - Resolution

  private struct Key: Hashable {
    let family: String
    let size: CGFloat
    let weight: Int
    let italic: Bool
    let fallback: SystemFallback
  }

  /// One lock over both caches. The highlighter resolves fonts per keystroke and
  /// the gutter per scroll repaint, so resolution must never reach CoreText more
  /// than once per (family, size, weight, slant).
  private static let lock = NSLock()
  private static var fontCache: [Key: NSFont] = [:]
  private static var postScriptNameCache: [String: String] = [:]

  /// How many times a font was actually constructed (test seam for the caching
  /// contract above — the highlighter resolves per keystroke and the gutter per
  /// scroll repaint, so this must not grow with either).
  private(set) static var resolutionCount = 0

  private static func resolved(
    family: String, size: CGFloat, weight: NSFont.Weight, italic: Bool, fallback: SystemFallback
  ) -> NSFont {
    let key = Key(
      family: family, size: size, weight: cssWeight(weight), italic: italic, fallback: fallback)
    lock.lock()
    defer { lock.unlock() }
    if let cached = fontCache[key] { return cached }
    let font = build(key: key, appKitWeight: weight)
    resolutionCount += 1
    fontCache[key] = font
    return font
  }

  private static func build(key: Key, appKitWeight: NSFont.Weight) -> NSFont {
    let systemFont = key.fallback.font(size: key.size, weight: appKitWeight)
    guard !key.family.isEmpty else {
      return key.italic ? italicised(systemFont) : systemFont
    }

    // The editor can be built before (or entirely without) the app delegate that
    // registers the bundled tree, and an unregistered face resolves to nothing.
    // Registration is a one-shot guard, so this costs a lock and a Bool.
    BundledFonts.registerOnce()

    if let face = bestBundledFace(family: key.family, weight: key.weight, italic: key.italic),
      let name = postScriptName(at: face.url),
      let font = NSFont(name: name, size: key.size)
    {
      // A family whose italic is only faux still needs the slant the caller adds.
      return key.italic && !face.isItalic ? italicised(font) : font
    }

    // Not bundled (or its file went missing): the family name is all we have.
    var traits: NSFontTraitMask = []
    if key.weight >= 700 { traits.insert(.boldFontMask) }
    if key.italic { traits.insert(.italicFontMask) }
    if let named = NSFontManager.shared.font(
      withFamily: key.family, traits: traits, weight: fontManagerWeight(key.weight),
      size: key.size)
    {
      return named
    }
    if let named = NSFont(name: key.family, size: key.size) {
      return key.italic ? italicised(named) : named
    }
    return key.italic ? italicised(systemFont) : systemFont
  }

  /// `NSFontManager.convert` returns the ORIGINAL font when the family has no
  /// italic sibling, which is exactly the degradation we want here: the caller
  /// checks the resulting traits and synthesises the slant only if needed.
  private static func italicised(_ font: NSFont) -> NSFont {
    NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
  }

  /// The bundled face closest to the requested weight, preferring the requested
  /// slant. Distance is absolute so a family that stops at 600 (IBM Plex Mono)
  /// answers a bold request with its semibold instead of dropping to regular;
  /// ties go to the lighter face.
  private static func bestBundledFace(
    family: String, weight: Int, italic: Bool
  ) -> BundledFonts.Face? {
    let inFamily = BundledFonts.bundledFaces.filter { $0.family == family }
    guard !inFamily.isEmpty else { return nil }
    let matchingSlant = inFamily.filter { $0.isItalic == italic }
    let candidates = matchingSlant.isEmpty ? inFamily.filter { !$0.isItalic } : matchingSlant
    return candidates.min {
      (abs($0.weight - weight), $0.weight) < (abs($1.weight - weight), $1.weight)
    }
  }

  /// PostScript name of the single face inside a bundled `.ttf`, read from the
  /// file itself rather than from any family index. Cached per path (callers
  /// hold `lock`).
  private static func postScriptName(at url: URL) -> String? {
    let path = url.standardizedFileURL.path
    if let cached = postScriptNameCache[path] { return cached }
    guard
      let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
        as? [CTFontDescriptor],
      let descriptor = descriptors.first,
      let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
    else { return nil }
    postScriptNameCache[path] = name
    return name
  }

  /// `NSFont.Weight` → the CSS numeric weight the bundled filenames use.
  private static func cssWeight(_ weight: NSFont.Weight) -> Int {
    switch weight {
    case .ultraLight: return 100
    case .thin: return 200
    case .light: return 300
    case .medium: return 500
    case .semibold: return 600
    case .bold: return 700
    case .heavy: return 800
    case .black: return 900
    default: return 400
    }
  }

  /// CSS numeric weight → `NSFontManager`'s 0…15 scale (regular 5, bold 9).
  private static func fontManagerWeight(_ cssWeight: Int) -> Int {
    switch cssWeight {
    case ..<300: return 2
    case ..<400: return 3
    case ..<500: return 5
    case ..<600: return 6
    case ..<700: return 8
    case ..<800: return 9
    default: return 12
    }
  }
}
