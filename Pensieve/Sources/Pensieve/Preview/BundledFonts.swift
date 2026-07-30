import CoreText
import Foundation

/// Registers the bundled OFL theme fonts into the **current process** font
/// environment at startup.
///
/// Scope is `.process` (not `.persistent`) on purpose: the app runs both as a
/// bare SwiftPM binary and as a bundled `.app`, and a persistent registration
/// would pollute the user's system font environment (it would surface in Font
/// Book and survive after the app quits). Process scope makes the families
/// visible to every AppKit font lookup in *this* process — the source editor's
/// `SyntaxHighlighter`/`LineNumberGutter` and the window chrome — which is where
/// these families are consumed on the native side.
///
/// Registration is idempotent (a one-shot guard, plus already-registered
/// CoreText errors are treated as success) and strictly non-fatal: a missing or
/// unreadable font file is collected into `Result.failed` and never throws,
/// traps, or blocks launch. The skin CSS font-family chains already carry a
/// full system-font fallback for every family, so absence degrades gracefully.
///
/// ## Bundled manifest (family → files, per section 2 of the themes handoff)
///
/// The faces live under `Resources/Fonts/<family-slug>/`, each family's
/// `OFL.txt` alongside its faces. `.copy` in `Package.swift` preserves this tree
/// verbatim into `Pensieve_Pensieve.bundle/Fonts/`.
///
/// 26 faces, 9 families, ~1.72 MiB total (1,802,164 bytes incl. licenses).
///
/// | Family            | Files (weights/styles)                                   |
/// |-------------------|----------------------------------------------------------|
/// | Newsreader        | 400, 500, 600, 400 italic                                |
/// | Sometype Mono     | 400, 700                                                 |
/// | Instrument Sans   | 400, 500, 700                                            |
/// | JetBrains Mono    | 400, 700                                                 |
/// | Literata          | 400, 600, 400 italic                                     |
/// | Archivo           | 600, 700                                                 |
/// | IBM Plex Sans     | 400, 500, 600                                            |
/// | IBM Plex Mono     | 400, 500, 600                                            |
/// | Spline Sans Mono  | 400, 500, 700, 400 italic                               |
///
/// All nine families resolve by their CSS family name after registration.
/// (The Newsreader and Archivo static instances originally shipped with
/// optical-size/weight axes baked into the `name` table — `Newsreader 16pt 16pt`,
/// `Archivo SemiBold` — and were re-staged with a corrected `name` table so
/// `"Newsreader"`/`"Archivo"` resolve; OFL carries no Reserved Font Name clause.)
enum BundledFonts {
  /// Directory name inside the SwiftPM resource bundle where `.copy` lands the
  /// font tree.
  static let fontsDirectoryName = "Fonts"

  /// CSS family names the bundled faces expose after registration — one per
  /// family, matching the family the `skinCSS` font-family chains reference.
  static let expectedResolvableFamilies = [
    "Newsreader",
    "Sometype Mono",
    "Instrument Sans",
    "JetBrains Mono",
    "Literata",
    "Archivo",
    "IBM Plex Sans",
    "IBM Plex Mono",
    "Spline Sans Mono",
  ]

  struct Result {
    /// Font file URLs that are registered in this process after the call
    /// (fresh registrations plus already-registered duplicates).
    let registered: [URL]
    /// Font file URLs that failed to register, with the CoreText error text.
    let failed: [(url: URL, error: String)]
  }

  private static let onceLock = NSLock()
  private static var didRegister = false

  /// Registers the bundled fonts exactly once for the process lifetime.
  /// Subsequent calls are no-ops and return `nil`. Safe to call from app
  /// startup; never blocks launch on failure.
  @discardableResult
  static func registerOnce() -> Result? {
    onceLock.lock()
    defer { onceLock.unlock() }
    guard !didRegister else { return nil }
    didRegister = true
    return register(fontURLs: bundledFontURLs())
  }

  /// Registers an explicit list of font file URLs (process scope). Non-fatal:
  /// every failure is collected, nothing throws. Exposed for testing.
  static func register(fontURLs: [URL]) -> Result {
    var registered: [URL] = []
    var failed: [(url: URL, error: String)] = []
    for url in fontURLs {
      var cfError: Unmanaged<CFError>?
      if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError) {
        registered.append(url)
        continue
      }
      let error = cfError?.takeRetainedValue()
      // Registering a URL that is already registered in this process is a
      // benign no-op — treat it as success so the path stays idempotent.
      if let error, CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
        registered.append(url)
      } else {
        let message = error.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
        failed.append((url, message))
      }
    }
    return Result(registered: registered, failed: failed)
  }

  /// Every `.ttf` under the first existing bundled `Fonts` directory, sorted for
  /// deterministic ordering. Empty when no bundled font directory is present
  /// (registration then becomes a no-op — non-fatal by construction).
  static func bundledFontURLs(fontsDirectories: [URL] = defaultFontsDirectories()) -> [URL] {
    let fileManager = FileManager.default
    for directory in fontsDirectories {
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil)
      else { continue }
      let fonts =
        enumerator
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension.lowercased() == "ttf" }
        .sorted { $0.path < $1.path }
      if !fonts.isEmpty { return fonts }
    }
    return []
  }

  /// Candidate `Fonts` directories, derived from the same bundle-layout probing
  /// `PreviewResourceLocator` uses for CSS/JS so the manually assembled release
  /// `.app` and the dev SwiftPM bundle both resolve without `Bundle.module`.
  static func defaultFontsDirectories() -> [URL] {
    PreviewResourceLocator.defaultCandidateDirectories()
      .map { $0.appendingPathComponent(fontsDirectoryName) }
  }

  // MARK: - WKWebView delivery (@font-face data URIs)

  /// Process-scope `CTFontManager` registration is invisible to the WKWebView
  /// WebContent process (proven: a process-registered family renders as its CSS
  /// fallback inside WebContent, while an installed system font does not). So the
  /// preview receives the bundled families a second way: `@font-face` rules whose
  /// `src` is a `data:font/ttf;base64,…` URI, inlined into the preview stylesheet
  /// during CSS assembly. This is CSP-safe (no external host, no file access) and
  /// leaves the skin CSS font-family fallback chains untouched — the `@font-face`
  /// only makes the first-choice family resolve.

  /// A single bundled face parsed from its `<slug>-<weight>-<style>.ttf` name.
  struct Face: Equatable {
    let url: URL
    let family: String
    let weight: Int
    let isItalic: Bool
  }

  /// Slug (font directory / filename stem) → CSS family name used by `skinCSS`.
  static let familyBySlug: [String: String] = [
    "newsreader": "Newsreader",
    "sometype-mono": "Sometype Mono",
    "instrument-sans": "Instrument Sans",
    "jetbrains-mono": "JetBrains Mono",
    "literata": "Literata",
    "archivo": "Archivo",
    "ibm-plex-sans": "IBM Plex Sans",
    "ibm-plex-mono": "IBM Plex Mono",
    "spline-sans-mono": "Spline Sans Mono",
  ]

  /// Parses the bundled `.ttf` URLs into faces. Filenames follow
  /// `<slug>-<weight>-<regular|italic>.ttf`; the slug may itself contain hyphens
  /// (`spline-sans-mono-400-italic.ttf`), so the weight is located as the first
  /// all-digit component and the slug is everything before it.
  static func faces(from urls: [URL] = bundledFontURLs()) -> [Face] {
    urls.compactMap { url in
      let stem = url.deletingPathExtension().lastPathComponent
      let parts = stem.split(separator: "-").map(String.init)
      guard let weightIndex = parts.firstIndex(where: { $0.allSatisfy(\.isNumber) && !$0.isEmpty }),
        let weight = Int(parts[weightIndex])
      else { return nil }
      let slug = parts[..<weightIndex].joined(separator: "-")
      guard let family = familyBySlug[slug] else { return nil }
      let isItalic = parts[(weightIndex + 1)...].contains("italic")
      return Face(url: url, family: family, weight: weight, isItalic: isItalic)
    }
  }

  private static let base64Lock = NSLock()
  private static var base64Cache: [String: String] = [:]

  /// Base64 of a face's bytes, computed once per file path per process. Returns
  /// `nil` when the file cannot be read (non-fatal — that face is skipped).
  static func base64EncodedFace(at url: URL) -> String? {
    let key = url.standardizedFileURL.path
    base64Lock.lock()
    defer { base64Lock.unlock() }
    if let cached = base64Cache[key] { return cached }
    guard let data = try? Data(contentsOf: url) else { return nil }
    let encoded = data.base64EncodedString()
    base64Cache[key] = encoded
    return encoded
  }

  /// `@font-face` rules for exactly the bundled families whose CSS family name is
  /// referenced in `css` (i.e. the active skin's font-family chains). Families the
  /// skin does not use contribute nothing, so `default`/`raw` emit an empty string
  /// and carry zero font payload. A face whose bytes can't be read is skipped —
  /// its family still degrades to the CSS fallback chain.
  static func fontFaceCSS(referencedIn css: String, faces: [Face] = faces()) -> String {
    let referenced = faces.filter { css.contains("\"\($0.family)\"") }
    guard !referenced.isEmpty else { return "" }
    return referenced.compactMap { face -> String? in
      guard let base64 = base64EncodedFace(at: face.url) else { return nil }
      return """
        @font-face {
          font-family: "\(face.family)";
          font-style: \(face.isItalic ? "italic" : "normal");
          font-weight: \(face.weight);
          font-display: swap;
          src: url("data:font/ttf;base64,\(base64)") format("truetype");
        }
        """
    }.joined(separator: "\n")
  }
}
