import Foundation

/// Loads preview CSS bundles from release-safe resource locations and caches them.
///
/// We inline the CSS into the HTML document rather than linking by URL so the
/// preview is robust to SPM bundle path quirks (sandboxing, spaces in paths,
/// renderer security defaults). Memory cost is ~12 KB per theme — trivial.
///
/// Two orthogonal axes drive the preview look:
///
///   * `Theme` (flavor) — the markdown *dialect* stylesheet: plain Markdown vs
///     GitHub Flavored. This is the heavy base CSS bundle (`markdown.css` /
///     `gfm.css`) shipped in Resources.
///   * `PensieveTheme` (skin) — the *reading surface* on top of the flavor: the
///     token palette + typography that dresses BOTH the rendered preview and
///     the source editor. Its `ThemeTokens` feed the source panel and titlebar
///     directly; the preview overlay CSS is composed AFTER the flavor CSS, so a
///     skin never re-implements a flavor — it re-tunes it.
///
/// Keeping the two axes separate is deliberate: a reader can want GitHub
/// Flavored tables *and* a paper-like serif body at the same time.
final class ThemeManager: ObservableObject {
  /// Markdown dialect stylesheet (the heavy base CSS bundle).
  enum Theme: String, CaseIterable, Identifiable {
    case markdown
    case gfm

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .markdown: return "Markdown"
      case .gfm: return "GitHub Flavored"
      }
    }

    fileprivate var resourceName: String { rawValue }
  }

  @Published var current: Theme {
    didSet { persist(\.flavorKey, current.rawValue) }
  }

  /// Active reading-surface skin. App-wide like the flavor so every window and
  /// the toolbar picker agree on one selection.
  @Published var skin: PensieveTheme {
    didSet { persist(\.skinKey, skin.rawValue) }
  }

  private let defaults: UserDefaults
  private var cache: [Theme: String] = [:]

  private let flavorKey = "pensieve.preview.flavor"
  private let skinKey = "pensieve.preview.skin"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.current =
      defaults.string(forKey: "pensieve.preview.flavor")
      .flatMap(Theme.init(rawValue:)) ?? .markdown
    let persistedSkin = defaults.string(forKey: "pensieve.preview.skin")
    let resolvedSkin = PensieveTheme.resolve(persistedRawValue: persistedSkin)
    self.skin = resolvedSkin

    // A migration that only lives in memory is not a migration. `skin`'s
    // `didSet` does not fire for the assignment above — Swift skips property
    // observers during initialisation — so a retired name (`glass` → `ink`)
    // stays in the store until the operator happens to pick a skin by hand:
    // every launch re-migrates the same dead value, and anything else reading
    // the raw key still sees a skin this build no longer has. Settle it where
    // it is resolved. A fresh install writes nothing: no key means no choice
    // yet, and defaulting to graphite is not the operator picking graphite.
    if let persistedSkin, persistedSkin != resolvedSkin.rawValue {
      persist(\.skinKey, resolvedSkin.rawValue)
    }
  }

  func css(for theme: Theme) -> String {
    if let cached = cache[theme] {
      return cached
    }
    let loaded = PreviewResourceLocator.css(named: theme.resourceName) ?? ""
    cache[theme] = loaded
    return loaded
  }

  private func persist(_ key: KeyPath<ThemeManager, String>, _ value: String) {
    defaults.set(value, forKey: self[keyPath: key])
  }
}
