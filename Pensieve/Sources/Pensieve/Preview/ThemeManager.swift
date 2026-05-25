import Foundation

/// Loads preview CSS bundles from release-safe resource locations and caches them.
///
/// We inline the CSS into the HTML document rather than linking by URL so the
/// preview is robust to SPM bundle path quirks (sandboxing, spaces in paths,
/// renderer security defaults). Memory cost is ~12 KB per theme — trivial.
final class ThemeManager: ObservableObject {
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

  @Published var current: Theme = .markdown

  private var cache: [Theme: String] = [:]

  func css(for theme: Theme) -> String {
    if let cached = cache[theme] {
      return cached
    }
    let loaded = PreviewResourceLocator.css(named: theme.resourceName) ?? ""
    cache[theme] = loaded
    return loaded
  }
}
