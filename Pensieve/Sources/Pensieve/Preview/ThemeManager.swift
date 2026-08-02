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
    didSet { persist(Self.flavorKey, current.rawValue) }
  }

  /// Active reading-surface skin. App-wide like the flavor so every window and
  /// the toolbar picker agree on one selection.
  @Published var skin: PensieveTheme {
    didSet { persist(Self.skinKey, skin.rawValue) }
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

  static let flavorKey = "pensieve.preview.flavor"
  static let skinKey = "pensieve.preview.skin"

  /// Where this preferences container came from, decided once and written down.
  ///
  /// The skin key alone cannot say. `guard let raw else { return .graphite }`
  /// reads a missing `pensieve.preview.skin` as "fresh install, take the new
  /// default" — but the builds before this one resolved that same absence to
  /// `.default`, and `skin`'s `didSet` does not fire during `init`, so an
  /// operator who has been reading on Default since before this build and never
  /// touched the picker has no key either. Left alone, shipping this build would
  /// silently re-theme her to Graphite on first launch.
  ///
  /// So the container is classified instead, once, on the first launch that
  /// knows how to ask.
  enum InstallOrigin: String {
    /// Nothing of Pensieve's was in the container: a genuinely new install,
    /// which takes this build's fresh-install default.
    case fresh
    /// A previous build had already written here. Absent a skin key, that
    /// operator was on Default and never chose otherwise; she keeps it.
    case upgrade

    /// Skin for an install carrying NO `pensieve.preview.skin` key.
    var skinWithoutAChoice: PensieveTheme {
      switch self {
      case .fresh: return .graphite
      case .upgrade: return .default
      }
    }
  }

  /// The one-time marker. Its presence is what makes the classification stable:
  /// once this build starts writing keys of its own, the container stops looking
  /// fresh, and re-deriving the answer on a later launch would flip it.
  static let installOriginKey = "pensieve.install.origin"

  /// Keys a build BEFORE this one could have left behind.
  ///
  /// Not one of them is guaranteed — every single one is written from a `didSet`
  /// or from an explicit action, and Swift skips property observers during
  /// `init`, so this app writes NOTHING on a launch where the operator changes
  /// nothing. The test is therefore "any of these", not "one particular one",
  /// and it still cannot see an install that was launched, never touched, and
  /// never opened a file. That residue is the honest limit of a marker
  /// introduced after the fact: there is no earlier evidence to read.
  static let priorContainerKeys = [
    flavorKey,
    "pensieve.sidebar.tab",
    "Pensieve.sidebarSortOrder",
    "Pensieve.dispatch.lastRunRootPath",
    "Pensieve.workspace.rootBookmarks",
    "Pensieve.workspace.fileBookmarks",
    "Pensieve.openFolder.bookmark",
    "Pensieve.previewAutoReload",
    "Pensieve.tableTidyOnPaste",
    "Pensieve.asciiSafeTables",
    "Pensieve.aiAutocompleteEnabled",
    "Pensieve.scrollSyncEnabled",
    // AppKit's own Open-Recent history, which it writes for us whenever a
    // document is opened — the widest net available for "this install was used".
    "NSRecentDocumentRecords",
  ]

  /// Classifies the container and remembers the answer. Idempotent: after the
  /// first call the marker is read back rather than re-derived.
  @discardableResult
  static func installOrigin(defaults: UserDefaults) -> InstallOrigin {
    if let known = defaults.string(forKey: installOriginKey)
      .flatMap(InstallOrigin.init(rawValue:))
    {
      return known
    }

    let usedBefore =
      defaults.object(forKey: skinKey) != nil
      || priorContainerKeys.contains { defaults.object(forKey: $0) != nil }
    let origin: InstallOrigin = usedBefore ? .upgrade : .fresh
    defaults.set(origin.rawValue, forKey: installOriginKey)
    return origin
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.current =
      defaults.string(forKey: Self.flavorKey)
      .flatMap(Theme.init(rawValue:)) ?? .markdown

    // Classify BEFORE this instance writes anything of its own — the migration
    // write-back below lands in the same container the classification reads.
    let origin = Self.installOrigin(defaults: defaults)
    let persistedSkin = defaults.string(forKey: Self.skinKey)
    let resolvedSkin = PensieveTheme.resolve(
      persistedRawValue: persistedSkin, withoutAChoice: origin.skinWithoutAChoice)
    self.skin = resolvedSkin

    // A migration that only lives in memory is not a migration. `skin`'s
    // `didSet` does not fire for the assignment above — Swift skips property
    // observers during initialisation — so a retired name (`glass` → `ink`)
    // stays in the store until the operator happens to pick a skin by hand:
    // every launch re-migrates the same dead value, and anything else reading
    // the raw key still sees a skin this build no longer has. Settle it where
    // it is resolved. No skin key still means no choice yet — resolving one is
    // not the operator picking one — so an install without a stored skin gets
    // no skin written, whichever way `installOrigin` classified it.
    if let persistedSkin, persistedSkin != resolvedSkin.rawValue {
      persist(Self.skinKey, resolvedSkin.rawValue)
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

  private func persist(_ key: String, _ value: String) {
    defaults.set(value, forKey: key)
  }
}
