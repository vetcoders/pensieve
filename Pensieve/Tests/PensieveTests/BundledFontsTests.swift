import AppKit
import CoreText
import XCTest

@testable import Pensieve

final class BundledFontsTests: XCTestCase {
  /// The bundled fonts must resolve by their CSS family name after
  /// registration. Registration is idempotent, so registering here on top of
  /// the app's own `registerOnce()` (if it ran) is safe. Newsreader/Archivo are
  /// intentionally excluded — their staged static instances carry mangled
  /// family-name records (see `BundledFonts` doc comment).
  func testBundledFamiliesResolveAfterRegistration() {
    let urls = BundledFonts.bundledFontURLs()
    XCTAssertFalse(
      urls.isEmpty,
      "no bundled .ttf located — the Fonts resource directory is missing from the bundle")

    let result = BundledFonts.register(fontURLs: urls)
    XCTAssertTrue(
      result.failed.isEmpty,
      "genuine bundled fonts must all register; failures: \(result.failed)")
    XCTAssertEqual(
      result.registered.count, urls.count,
      "every located face should end up registered")

    let availableFamilies = Set(NSFontManager.shared.availableFontFamilies)
    for family in BundledFonts.expectedResolvableFamilies {
      XCTAssertNotNil(
        NSFont(name: family, size: 12),
        "\(family) must be available as an NSFont after registration")
      XCTAssertTrue(
        availableFamilies.contains(family),
        "\(family) must appear in NSFontManager.availableFontFamilies after registration")
    }
  }

  /// A missing/unreadable font file must be non-fatal: registration collects the
  /// failure and never throws or traps, so startup survives an absent font.
  func testRegistrationIsNonFatalWhenFontFileIsAbsent() {
    let absent = FileManager.default.temporaryDirectory
      .appendingPathComponent("pensieve-missing-\(UUID().uuidString).ttf")
    XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))

    // Must not throw/trap — the whole point of the non-fatal contract.
    let result = BundledFonts.register(fontURLs: [absent])

    XCTAssertTrue(result.registered.isEmpty, "a missing file cannot be registered")
    XCTAssertEqual(result.failed.count, 1, "the missing file must be reported as a failure")
    XCTAssertEqual(result.failed.first?.url, absent)
  }

  /// An empty candidate set yields no work and no crash — the degraded path when
  /// no bundled `Fonts` directory exists at all.
  func testNoFontsDirectoryIsNonFatal() {
    let none = BundledFonts.bundledFontURLs(fontsDirectories: [])
    XCTAssertTrue(none.isEmpty)
    let result = BundledFonts.register(fontURLs: none)
    XCTAssertTrue(result.registered.isEmpty)
    XCTAssertTrue(result.failed.isEmpty)
  }

  // MARK: - @font-face delivery (WKWebView)

  /// All 26 faces across 9 families parse out of the bundled filenames, with the
  /// weight and italic flag recovered from the `<slug>-<weight>-<style>` name.
  func testFacesParseAllBundledFiles() {
    let faces = BundledFonts.faces()
    XCTAssertEqual(faces.count, 26, "expected 26 bundled faces")
    XCTAssertEqual(
      Set(faces.map(\.family)), Set(BundledFonts.familyBySlug.values),
      "every family should be represented")
    // Spot-check the two italic families and a specific weight.
    XCTAssertTrue(
      faces.contains(
        BundledFonts.Face(
          url: faces.first { $0.family == "Literata" && $0.isItalic }!.url,
          family: "Literata", weight: 400, isItalic: true)),
      "Literata 400 italic should parse")
    XCTAssertTrue(
      faces.contains { $0.family == "IBM Plex Sans" && $0.weight == 600 && !$0.isItalic },
      "IBM Plex Sans 600 should parse")
  }

  /// Each themed skin's @font-face payload covers exactly the families that skin's
  /// font-family chains reference (independent oracle from the handoff manifest),
  /// and every rule carries an inline base64 data URI.
  func testFontFaceCSSScopesToActiveSkinFamilies() {
    let expected: [PensieveTheme: Set<String>] = [
      .parchment: ["Newsreader", "Sometype Mono"],
      .graphite: ["Instrument Sans", "JetBrains Mono"],
      .ink: ["Literata", "Archivo", "JetBrains Mono"],
      .porcelain: ["IBM Plex Sans", "IBM Plex Mono"],
      .typewriter: ["Spline Sans Mono"],
    ]
    for (skin, families) in expected {
      let css = BundledFonts.fontFaceCSS(referencedIn: PreviewWebView.skinCSS(for: skin))
      XCTAssertTrue(
        css.contains("src: url(\"data:font/ttf;base64,"),
        "\(skin) must inline base64 font data")
      for family in families {
        XCTAssertTrue(
          css.contains("font-family: \"\(family)\";"),
          "\(skin) must ship @font-face for \(family)")
      }
      // No family outside the skin's own reference set leaks into the payload.
      let unexpected = Set(BundledFonts.familyBySlug.values).subtracting(families)
      for family in unexpected {
        XCTAssertFalse(
          css.contains("font-family: \"\(family)\";"),
          "\(skin) must NOT ship @font-face for unreferenced \(family)")
      }
    }
  }

  /// `default` and `raw` reference no bundled family, so they carry zero font
  /// payload — the byte-for-byte GitHub surface stays untouched.
  func testDefaultAndRawEmitNoFontPayload() {
    for skin in [PensieveTheme.default, .raw] {
      XCTAssertEqual(
        BundledFonts.fontFaceCSS(referencedIn: PreviewWebView.skinCSS(for: skin)), "",
        "\(skin) must emit no @font-face payload")
    }
  }

  /// A skin's `@font-face` payload is a process constant (the bundle cannot
  /// change at runtime) and an expensive one — 0.2–0.8 MB of base64 plus a
  /// directory rescan. It must be assembled at most once per skin, not on every
  /// `appearanceCSS` call, which rides every debounced keystroke.
  func testFontFaceCSSIsAssembledOncePerSkin() {
    // Warm the skin so the assertion does not race the first (legitimate) build.
    _ = PreviewWebView.appearanceCSS(fontSize: 14, skin: .ink)
    let assembliesBefore = PreviewWebView.fontFaceCSSAssemblyCount

    let small = PreviewWebView.appearanceCSS(fontSize: 14, skin: .ink)
    let large = PreviewWebView.appearanceCSS(fontSize: 22, skin: .ink)

    XCTAssertEqual(
      PreviewWebView.fontFaceCSSAssemblyCount, assembliesBefore,
      "the @font-face payload was rebuilt for an already-seen skin")
    // The cache is keyed on the skin alone: font size must not invalidate it,
    // and both stylesheets must still carry the same faces.
    XCTAssertTrue(small.contains("@font-face"))
    XCTAssertTrue(large.contains("@font-face"))
    XCTAssertEqual(
      small.components(separatedBy: "@font-face").count,
      large.components(separatedBy: "@font-face").count)
  }

  /// Faces are parsed from the bundle once per process — the `faces()` default
  /// argument used to rescan the `Fonts` directory on every CSS assembly.
  func testBundledFacesAreParsedOncePerProcess() {
    XCTAssertEqual(BundledFonts.bundledFaces.count, 26)
    XCTAssertEqual(BundledFonts.bundledFaces, BundledFonts.faces())
  }

  /// The assembled preview stylesheet carries the @font-face block for a themed
  /// skin and none for `default` — proving the injection point is wired.
  func testAppearanceCSSInjectsFontFacesForThemedSkinOnly() {
    XCTAssertTrue(
      PreviewWebView.appearanceCSS(fontSize: 16, skin: .ink).contains("@font-face"),
      "ink appearance CSS must include @font-face")
    XCTAssertFalse(
      PreviewWebView.appearanceCSS(fontSize: 16, skin: .default).contains("@font-face"),
      "default appearance CSS must not include @font-face")
  }
}
