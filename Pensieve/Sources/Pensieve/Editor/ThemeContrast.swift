import AppKit

/// WCAG relative-luminance contrast for theme tokens.
///
/// A fixed palette is free to pick tokens that collide: typewriter's accent IS
/// its source surface, and its `==highlight==` wash sits one step from its body
/// text. Both collisions are correct where the tokens were designed to be read
/// (chrome on the light window surface) and invisible in the source panel. The
/// highlighters therefore measure a token against the surface it will actually
/// be painted on and fall back to another token from the SAME theme when it
/// cannot carry text — never to an invented per-theme hex.
enum ThemeContrast {
  /// Below this ratio a colour cannot carry text on the given surface. WCAG's
  /// large-text / non-text threshold; every fixed palette's tokens clear it
  /// comfortably except a deliberate collision.
  static let minimumTextContrast: CGFloat = 3

  /// Contrast ratio between two colours, or `nil` when either cannot be
  /// expressed in sRGB (pattern/catalog colours) and so cannot be measured.
  /// Callers treat an unmeasurable pair as "not proven legible" and take their
  /// fallback token; only fixed palettes (plain sRGB hex) reach this code, so
  /// that branch is defensive.
  static func ratio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat? {
    guard let left = relativeLuminance(lhs), let right = relativeLuminance(rhs) else {
      return nil
    }
    return (max(left, right) + 0.05) / (min(left, right) + 0.05)
  }

  /// True when `foreground` is measurably legible on `background`.
  static func isLegible(_ foreground: NSColor, on background: NSColor) -> Bool {
    guard let ratio = ratio(foreground, background) else { return false }
    return ratio >= minimumTextContrast
  }

  private static func relativeLuminance(_ color: NSColor) -> CGFloat? {
    guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
    func channel(_ value: CGFloat) -> CGFloat {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(srgb.redComponent)
      + 0.7152 * channel(srgb.greenComponent)
      + 0.0722 * channel(srgb.blueComponent)
  }
}
