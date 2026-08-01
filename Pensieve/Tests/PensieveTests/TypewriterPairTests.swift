import AppKit
import XCTest

@testable import Pensieve

/// Typewriter is the first skin that is neither one fixed palette nor a set of
/// semantic colours: it is a PAIR, two fixed palettes chosen between by the
/// system light/dark setting. Every invariant that shape introduces is pinned
/// here, and the ones that must NOT follow the system — the paper, the export —
/// are pinned twice, once under each setting.
extension XCTestCase {
  /// Drives the real system input rather than a test-only hook: the app's own
  /// appearance is what `SystemAppearance` reads, so setting it exercises the
  /// same path the operator's System Settings toggle does. Restored afterwards,
  /// because it is process-wide state.
  ///
  /// Shared, because more than one suite has to ask a paired skin the same
  /// question under both settings — and a second copy of this would be a second
  /// chance to get "which half am I on" wrong.
  @MainActor
  @discardableResult
  func withSystemAppearance<T>(dark: Bool, _ body: () throws -> T) rethrows -> T {
    let previous = NSApplication.shared.appearance
    NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    defer { NSApplication.shared.appearance = previous }
    XCTAssertEqual(
      SystemAppearance.isDark, dark, "the rig failed to put the app in the requested appearance")
    return try body()
  }
}

final class TypewriterPairTests: XCTestCase {

  // MARK: - The pair itself

  @MainActor
  func testTheSystemSettingChoosesTheHalf() throws {
    let pair = try XCTUnwrap(PensieveTheme.pairedPalettes[.typewriter])
    XCTAssertTrue(PensieveTheme.typewriter.isPaired)

    // Pure resolution, no host involved.
    XCTAssertEqual(
      PensieveTheme.typewriter.tokens(underDarkSystem: true).source.css, pair.dark.source.css)
    XCTAssertEqual(
      PensieveTheme.typewriter.tokens(underDarkSystem: false).source.css, pair.light.source.css)

    // ...and the live accessor every surface actually reads.
    try withSystemAppearance(dark: true) {
      XCTAssertEqual(PensieveTheme.typewriter.tokens.source.css, "#171717")
      XCTAssertEqual(PensieveTheme.typewriter.tokens.text.css, "#d4d4d4")
      XCTAssertEqual(PensieveTheme.typewriter.tokens.mode, .dark)
    }
    try withSystemAppearance(dark: false) {
      XCTAssertEqual(PensieveTheme.typewriter.tokens.source.css, "#ffffff")
      XCTAssertEqual(PensieveTheme.typewriter.tokens.text.css, "#1c1c1c")
      XCTAssertEqual(PensieveTheme.typewriter.tokens.mode, .light)
    }

    // The two halves are genuinely different palettes, not one palette twice —
    // this is what fails first if the pair is ever frozen on one side.
    XCTAssertNotEqual(pair.light.source.css, pair.dark.source.css)
    XCTAssertNotEqual(pair.light.text.css, pair.dark.text.css)
  }

  /// The titlebar backing — the most visible half-dependent surface — follows
  /// the setting through the same chrome recipe the window pass uses.
  @MainActor
  func testTitlebarBackingFollowsTheSystemSetting() throws {
    try withSystemAppearance(dark: true) {
      XCTAssertTrue(
        WindowChromeRecipe.colorsMatch(
          WindowChromeRecipe.titlebarGlassBackingColor(for: .typewriter),
          ColorSpec.nsColor(fromHex: "#171717")))
    }
    try withSystemAppearance(dark: false) {
      XCTAssertTrue(
        WindowChromeRecipe.colorsMatch(
          WindowChromeRecipe.titlebarGlassBackingColor(for: .typewriter),
          ColorSpec.nsColor(fromHex: "#ffffff")))
    }
  }

  // MARK: - What must NOT follow the system

  /// The window tracks the setting (that is how the pair picks its half), but
  /// the paper does not: the sheet is white on both sides, so pinning it light
  /// is what keeps `gfm.css` — and Mermaid, which reads the media query from JS
  /// — from dressing a white page as a dark one.
  ///
  /// The window's half is STATED, not left open. "No preference" tracks the
  /// system just as well until something else resolves the scene on its own —
  /// which is what split the operator's toolbar in half on build 446 (see
  /// `PensieveTheme.appearanceName`). Both spellings agree with the setting;
  /// only this one leaves nothing to be resolved twice.
  @MainActor
  func testTheWindowTakesTheSystemsHalfWhileThePaperStaysLight() throws {
    for dark in [true, false] {
      let wanted: NSAppearance.Name = dark ? .darkAqua : .aqua
      try withSystemAppearance(dark: dark) {
        XCTAssertEqual(
          PensieveTheme.typewriter.appearanceName, wanted,
          "a paired skin must state the half it resolved, not decline to answer")
        XCTAssertEqual(WindowChromeRecipe.windowAppearance(for: .typewriter)?.name, wanted)
        XCTAssertEqual(
          WindowChromeRecipe.preferredColorScheme(for: .typewriter), dark ? .dark : .light,
          "SwiftUI must be handed the same half, or it resolves its own")

        XCTAssertEqual(
          PensieveTheme.typewriter.readingSurfaceAppearanceName, .aqua,
          "the sheet is white in both halves — it must not follow the system into dark")
        XCTAssertEqual(
          WindowChromeRecipe.readingSurfaceAppearance(for: .typewriter)?.name, .aqua)
      }
    }
  }

  /// An export is paper, not a window. Pinned under BOTH settings, because the
  /// regression this prevents is exactly "exported from a dark Mac".
  @MainActor
  func testExportAlwaysTakesTheLightHalf() throws {
    let pair = try XCTUnwrap(PensieveTheme.pairedPalettes[.typewriter])
    for dark in [true, false] {
      try withSystemAppearance(dark: dark) {
        XCTAssertEqual(
          PensieveTheme.typewriter.exportTokens.source.css, pair.light.source.css,
          "export must take the light half whatever the machine is set to")
        XCTAssertEqual(PensieveTheme.typewriter.exportTokens.text.css, "#1c1c1c")
        XCTAssertEqual(PensieveTheme.typewriter.exportAppearanceName, .aqua)
        XCTAssertEqual(WindowChromeRecipe.exportAppearance(for: .typewriter)?.name, .aqua)
      }
    }

    // An unpinned skin still exports under its own fixed appearance, and the
    // adaptive ones still carry none.
    XCTAssertEqual(PensieveTheme.ink.exportAppearanceName, .darkAqua)
    XCTAssertEqual(PensieveTheme.parchment.exportAppearanceName, .aqua)
    XCTAssertNil(PensieveTheme.default.exportAppearanceName)
  }

  // MARK: - Palette invariants, per half

  /// Zero colour on BOTH sides. Reflects over every token the half declares
  /// rather than a hand-listed subset, so a hue smuggled into either palette
  /// fails here instead of shipping.
  @MainActor
  func testBothHalvesAreAchromatic() throws {
    let pair = try XCTUnwrap(PensieveTheme.pairedPalettes[.typewriter])
    for (half, tokens) in [("light", pair.light), ("dark", pair.dark)] {
      var walked = 0
      for child in Mirror(reflecting: tokens).children {
        // Module-qualified: bare `ColorSpec` collides with the Carbon QuickDraw
        // struct AppKit drags in.
        guard let spec = child.value as? Pensieve.ColorSpec else { continue }
        walked += 1
        let srgb = spec.nsColor.usingColorSpace(.sRGB) ?? spec.nsColor
        let name = child.label ?? "<unlabelled>"
        XCTAssertEqual(
          srgb.redComponent, srgb.greenComponent, accuracy: 0.001,
          "typewriter \(half) token \(name) = \(spec.css) carries a hue; the pair is grey-ramp only"
        )
        XCTAssertEqual(
          srgb.greenComponent, srgb.blueComponent, accuracy: 0.001,
          "typewriter \(half) token \(name) = \(spec.css) carries a hue; the pair is grey-ramp only"
        )
      }
      XCTAssertEqual(walked, 17, "unexpected colour-token count on the \(half) half")
    }
  }

  /// The chip has to survive on BOTH titlebar backings — white and `#171717` —
  /// which is a different measurement per half even though the token value is
  /// the same. Same two thresholds the shipping skins are held to.
  @MainActor
  func testChipStaysLegibleOnBothHalves() throws {
    let pair = try XCTUnwrap(PensieveTheme.pairedPalettes[.typewriter])
    for (half, tokens) in [("light", pair.light), ("dark", pair.dark)] {
      let fill = tokens.chromeAccent.nsColor
      let glyph = Self.contrastRatio(fill, WindowChromeRecipe.toolbarChipGlyphColor)
      XCTAssertGreaterThanOrEqual(
        glyph, 4.5,
        "\(half) half: chip fill \(tokens.chromeAccent.css) cannot carry its glyph "
          + "(contrast \(String(format: "%.2f", glyph)))")

      let backing = Self.contrastRatio(fill, tokens.source.nsColor)
      XCTAssertGreaterThanOrEqual(
        backing, 2.0,
        "\(half) half: chip fill \(tokens.chromeAccent.css) dissolves into its titlebar backing "
          + "\(tokens.source.css) (contrast \(String(format: "%.2f", backing)))")
    }
  }

  // MARK: - The nudge

  /// A system flip changes no `@Published` value on its own — `skin` is still
  /// the same case — so without this the views would keep the palette they
  /// already drew. The counter is that signal, and it stays quiet for a skin
  /// that does not read the system setting at all.
  @MainActor
  func testASystemFlipNudgesThePairAndOnlyThePair() throws {
    let manager = ThemeManager(defaults: makeEphemeralDefaults(prefix: "TypewriterPairTests"))
    let previous = NSApplication.shared.appearance
    defer { NSApplication.shared.appearance = previous }

    manager.skin = .typewriter
    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    settle()
    let before = manager.systemAppearanceGeneration

    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    settle()
    XCTAssertGreaterThan(
      manager.systemAppearanceGeneration, before,
      "a paired skin must be told the system setting moved, or it keeps drawing the other half")

    // An unpaired skin reads no system setting; re-rendering it for one would be
    // work with no output.
    manager.skin = .ink
    let quiet = manager.systemAppearanceGeneration
    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    settle()
    XCTAssertEqual(
      manager.systemAppearanceGeneration, quiet,
      "an unpaired skin must not be re-rendered for a setting it does not read")
  }

  @MainActor
  private func settle(_ seconds: TimeInterval = 0.25) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  /// WCAG relative-luminance contrast, on the same sRGB conversion the palette
  /// pins use.
  private static func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
      let srgb = color.usingColorSpace(.sRGB) ?? color
      func channel(_ value: CGFloat) -> Double {
        let v = Double(value)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * channel(srgb.redComponent) + 0.7152 * channel(srgb.greenComponent)
        + 0.0722 * channel(srgb.blueComponent)
    }
    let a = luminance(lhs)
    let b = luminance(rhs)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}
