import AppKit
import XCTest

@testable import Pensieve

/// The sidebar is painted on the window CHROME — the system sidebar material —
/// not on the reading surface the skins tune their `accent` for. Typewriter's
/// dark half sets `accent: #1c1c1c` deliberately, because that accent is ink for
/// the white preview sheet the pair keeps on both halves; painted raw on a dark
/// sidebar it disappears, and it took four consumers with it (the selected-file
/// glyph, the selection wash, the 2 px leading bar, the selected Open Files row)
/// plus the sidebar's empty-state wordmark.
final class SidebarChromeAccentTests: XCTestCase {
  /// The system sidebar material under a dark appearance, as reported on the
  /// operator's machine. Kept here rather than in the product because nothing
  /// PAINTS with it — the sidebar keeps the material — it only bounds the
  /// surface the accent has to survive on. The product measures against
  /// `tokens.source`, which is the app's own chrome backing; this leg proves the
  /// two answers agree where it matters.
  private static let darkChromeSurfaceBand = [
    ColorSpec.nsColor(fromHex: "#1e1e1e"),
    ColorSpec.nsColor(fromHex: "#252525"),
  ]

  /// Every skin, both halves of every pair: the accent the sidebar is HANDED
  /// clears the non-text contrast threshold on the surface it lands on.
  ///
  /// Red before the fix on typewriter's dark half alone (`#1c1c1c` on `#171717`
  /// measures 1.03:1 against a 3:1 floor), green on every other skin — which is
  /// the point: a guard that fired everywhere would be discarding colours the
  /// operator chose.
  func testSidebarAccentClearsChromeContrastOnEverySkinAndHalf() {
    for theme in PensieveTheme.allCases {
      for isDark in [false, true] {
        let tokens = theme.tokens(underDarkSystem: isDark)
        let half = theme.isPaired ? (isDark ? " (dark half)" : " (light half)") : ""
        let resolved = SidebarView.chromeAccentColor(for: tokens)

        // Adaptive skins carry catalog colours that resolve per appearance at
        // draw time; they cannot be ratioed and are legible by construction.
        guard ThemeContrast.ratio(resolved, tokens.source.nsColor) != nil else {
          XCTAssertNil(
            tokens.mode, "\(theme.rawValue)\(half): only an adaptive skin may be unmeasurable")
          continue
        }

        XCTAssertTrue(
          ThemeContrast.isLegible(resolved, on: tokens.source.nsColor),
          "\(theme.rawValue)\(half): the sidebar accent must carry on the chrome backing")

        // …and on the system material the sidebar actually shows, which is a
        // shade or two off that backing on the dark side.
        if tokens.mode == .dark {
          for surface in Self.darkChromeSurfaceBand {
            XCTAssertTrue(
              ThemeContrast.isLegible(resolved, on: surface),
              "\(theme.rawValue)\(half): the sidebar accent must carry on the dark chrome material"
            )
          }
        }
      }
    }
  }

  /// The demotion is real on the half that needs it, and the raw token it
  /// replaces really is the invisible one.
  func testTypewriterDarkHalfDemotesTheInkAccent() {
    let dark = PensieveTheme.typewriter.tokens(underDarkSystem: true)

    XCTAssertLessThan(
      ThemeContrast.ratio(dark.accent.nsColor, dark.source.nsColor) ?? .infinity,
      ThemeContrast.minimumTextContrast,
      "precondition: the dark half's raw accent is the unreadable case this guards")
    XCTAssertTrue(
      WindowChromeRecipe.colorsMatch(
        SidebarView.chromeAccentColor(for: dark), dark.text.nsColor),
      "the sidebar must fall back to the theme's own body ink, not an invented hex")
  }

  /// CONTROL: a skin whose accent reads fine on the chrome keeps it, on both
  /// halves of the pair and on the adaptive skins' catalog colours. Without this
  /// leg the fix could over-apply and quietly retire every accent in the sidebar.
  func testSidebarKeepsALegibleAccent() {
    let keepers: [(PensieveTheme, Bool)] = [
      (.parchment, false), (.parchment, true),
      (.graphite, false), (.graphite, true),
      (.ink, false), (.ink, true),
      (.porcelain, false), (.porcelain, true),
      (.typewriter, false),
      (.default, false), (.default, true),
      (.raw, false), (.raw, true),
    ]
    for (theme, isDark) in keepers {
      let tokens = theme.tokens(underDarkSystem: isDark)
      XCTAssertTrue(
        WindowChromeRecipe.colorsMatch(
          SidebarView.chromeAccentColor(for: tokens), tokens.accent.nsColor),
        "\(theme.rawValue) (isDark: \(isDark)): a legible accent must survive the guard")
    }
  }

  /// The sidebar and the detail-pane empty state must not drift: one helper
  /// answers for both, so the two surfaces cannot end up on different accents
  /// for the same skin.
  @MainActor
  func testSidebarAndDetailPaneResolveTheSameAccent() {
    let previous = NSApplication.shared.appearance
    defer { NSApplication.shared.appearance = previous }

    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      NSApplication.shared.appearance = NSAppearance(named: appearance)
      for theme in PensieveTheme.allCases {
        XCTAssertTrue(
          WindowChromeRecipe.colorsMatch(
            SidebarView.chromeAccentColor(for: theme.tokens),
            EmptyStatePalette(theme: theme).wordmark),
          "\(theme.rawValue) under \(appearance.rawValue): both empty states take one accent")
      }
    }
  }
}
