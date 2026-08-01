import AppKit
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

  /// Bumped when the system light/dark setting flips.
  ///
  /// A PAIRED skin resolves its tokens from that setting, and nothing else in
  /// the app changes when the setting does: `skin` is still the same case, so no
  /// `@Published` fires and every view holding this object keeps the palette it
  /// already drew. This counter is that missing signal — one published bump, and
  /// the ordinary update path re-reads the tokens exactly the way it does after
  /// the operator picks a skin by hand.
  ///
  /// It is a COUNTER rather than a stored appearance so there is no second copy
  /// of the system setting to go stale; `SystemAppearance.isDark` stays the only
  /// place that answer is read.
  @Published private(set) var systemAppearanceGeneration: Int = 0

  private let defaults: UserDefaults
  private var cache: [Theme: String] = [:]
  private var appearanceObservation: NSKeyValueObservation?

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

    observeSystemAppearance()
  }

  /// Watches the system light/dark setting for the paired skins.
  ///
  /// Two things this deliberately does NOT do, both of them lessons already paid
  /// for on this surface:
  ///
  ///   * It writes NOTHING that feeds the property it observes. The reaction is
  ///     a counter bump; the chrome pass downstream writes the resolved half to
  ///     the WINDOW and never touches `NSApp.appearance`, which is the only
  ///     property `effectiveAppearance` here is derived from. That separation is
  ///     what makes the pin safe: a paired skin now answers `.aqua`/`.darkAqua`
  ///     rather than `nil`, and it still cannot re-trigger its own observation.
  ///     So the appearance loop that `7908bfd` fixed cannot form here — and the
  ///     edge-triggered `assertedAppearances` table still guards the write.
  ///   * It repaints nothing synchronously inside the callback. The bump is
  ///     dispatched onto the next main-queue turn and the ordinary SwiftUI
  ///     update path does the work, which is the same shape `d721f55`/`ce4397f`
  ///     settled for a live skin switch: a re-theme that runs through the normal
  ///     cycle instead of walking every surface from inside a notification.
  ///
  /// Unpaired skins read no system setting, so they are filtered out before the
  /// bump rather than being re-rendered for a change that cannot affect them.
  private func observeSystemAppearance() {
    appearanceObservation = NSApplication.shared.observe(
      \.effectiveAppearance, options: [.new]
    ) { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self, self.skin.isPaired else { return }
        self.systemAppearanceGeneration &+= 1
      }
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
