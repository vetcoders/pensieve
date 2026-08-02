import AppKit
import SwiftUI

/// Shared chrome for the two "nothing open yet" surfaces (the sidebar's
/// `emptyState` and the detail pane's `DocumentEmptyStateView`), per handoff
/// 5.6: a wordmark, the primary shortcuts rendered as key caps, and the recent
/// documents pulled from `RecentDocumentsStore` (the system Open-Recent
/// authority — no second persisted list). Both host surfaces observe
/// `ThemeManager`, so the accent wordmark and the key-cap hairlines repaint on
/// a live theme switch.

/// The colours the DETAIL-PANE empty state paints with.
///
/// That surface stands in for the document pane — `EditorPreviewSplit` mounts it
/// exactly where `EditorView`/`PreviewView` go — and the host window's titlebar
/// glass is already backed by the same token
/// (`WindowChromeRecipe.titlebarGlassBackingColor` is `tokens.source`). Painting
/// it with `NSColor.windowBackgroundColor` left one unthemed system patch under
/// a themed titlebar: on parchment the strip is cream and everything below it
/// was system grey, and it did not move on a skin switch.
///
/// The sidebar's empty state keeps the system sidebar material, so it does NOT
/// take this palette — the shared chrome pieces stay system-tinted when no
/// palette is handed to them.
struct EmptyStatePalette {
  /// The pane surface: the skin's editor background.
  let background: NSColor
  /// Body text on `background`.
  let primaryText: NSColor
  /// Labels and glyphs on `background`.
  let secondaryText: NSColor
  /// De-emphasised caption (the build identity line).
  let tertiaryText: NSColor
  /// Wordmark tint — the accent, or the theme's body text where the accent
  /// cannot carry text on this surface.
  let wordmark: NSColor
  /// Raised chip surface for the shortcut key caps.
  let keyCapFill: NSColor

  init(theme: PensieveTheme) {
    let tokens = theme.tokens
    let surface = tokens.source.nsColor
    background = surface
    primaryText = tokens.text.nsColor
    secondaryText = tokens.muted.nsColor
    tertiaryText = tokens.muted.nsColor.withAlphaComponent(0.72)
    keyCapFill = tokens.codeBackground.nsColor

    // A fixed palette is free to collide by design: typewriter's accent IS its
    // source surface, because that accent was drawn for the light window chrome.
    // The fallback that guards it lives on `ThemeTokens` now — the sidebar paints
    // the same accent on the same skin, and two copies of this measurement would
    // be two places for it to drift.
    wordmark = tokens.legibleAccent
  }
}

/// The app wordmark, tinted from the theme accent. `size` lets the wide detail
/// pane show it large and the narrow sidebar show it small.
struct EmptyStateWordmark: View {
  @EnvironmentObject private var themeManager: ThemeManager
  var size: CGFloat = 34
  /// Set on the detail pane, where the wordmark sits on the skin's own surface;
  /// `nil` in the sidebar, which keeps the system material.
  var palette: EmptyStatePalette?

  var body: some View {
    let tokens = themeManager.skin.tokens
    let family = tokens.previewHeadingFamily
    Text("Pensieve")
      .font(family.isEmpty ? .system(size: size, weight: .semibold) : .custom(family, size: size))
      // No palette means the SIDEBAR's empty state, which sits on the system
      // sidebar material rather than the skin's pane — and takes the same
      // guarded accent, not the raw token that vanishes on typewriter's dark
      // half.
      .foregroundStyle(Color(palette?.wordmark ?? tokens.legibleAccent))
      .accessibilityIdentifier("pensieve.emptyState.wordmark")
  }
}

/// A keyboard shortcut rendered as a small key cap (⌘N, ⌘⇧O …), outlined in the
/// theme border tint.
struct ShortcutKeyCap: View {
  @EnvironmentObject private var themeManager: ThemeManager
  let symbols: String
  /// See `EmptyStateWordmark.palette`. The cap's label inherits the host's
  /// primary foreground, so its fill has to come from the same place: a system
  /// chip under themed text reads as a light patch on a dark skin's pane.
  var palette: EmptyStatePalette?

  var body: some View {
    Text(symbols)
      .font(.system(size: 12, weight: .medium, design: .rounded))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color(palette?.keyCapFill ?? NSColor.controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(Color(themeManager.skin.tokens.border.nsColor), lineWidth: 1)
      )
  }
}

/// The primary shortcuts, each a key cap + label. New File is the always-safe
/// action, so its row is a live button; Open File / Open Folder are hints (their
/// global menu shortcuts still fire). Replaces the single caption sentence the
/// old empty states carried, which nobody read.
struct EmptyStateShortcuts: View {
  @EnvironmentObject private var controller: AppController
  /// Accessibility id for the clickable New File row — lets the sidebar keep the
  /// identifier its empty state exposed before this cut.
  var newFileAccessibilityIdentifier = "pensieve.emptyState.newFile"
  /// See `EmptyStateWordmark.palette` — handed straight to the key caps.
  var palette: EmptyStatePalette?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        controller.createUntitledDocument()
      } label: {
        shortcutRow("⌘N", "New File")
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(newFileAccessibilityIdentifier)

      shortcutRow("⌘O", "Open File")
      shortcutRow("⌘⇧O", "Open Folder")
    }
  }

  private func shortcutRow(_ symbols: String, _ label: String) -> some View {
    HStack(spacing: 8) {
      ShortcutKeyCap(symbols: symbols, palette: palette)
        .frame(width: 44, alignment: .leading)
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

/// Row labels for the recent-documents list.
///
/// The list shows basenames, which is what makes it readable — and ambiguous the
/// moment two of them agree: two `README.md` from different folders were two
/// identical `README` buttons, and the only thing telling them apart was a hover
/// tooltip, which a keyboard or VoiceOver user never gets.
///
/// So the parent folder joins the label, but ONLY on the rows that need it.
/// Suffixing every row would make the ordinary case — six distinct names — noisier
/// for nothing. Uniqueness is judged inside the VISIBLE slice, because that is the
/// set a reader is comparing; a name that repeats further down a history this view
/// never draws is not an ambiguity anyone can see.
enum EmptyStateRecentLabels {
  /// Between the name and the folder that disambiguates it.
  static let separator = " — "

  static func labels(for urls: [URL]) -> [String] {
    let names = urls.map { $0.deletingPathExtension().lastPathComponent }
    var occurrences: [String: Int] = [:]
    for name in names { occurrences[name, default: 0] += 1 }

    return zip(urls, names).map { url, name in
      guard occurrences[name, default: 0] > 1 else { return name }
      // A file at a volume root has no folder name to add; leave it alone
      // rather than append a bare "/".
      let parent = url.deletingLastPathComponent().lastPathComponent
      guard !parent.isEmpty, parent != "/" else { return name }
      return name + separator + parent
    }
  }
}

/// The recent documents list, read from the system Open-Recent authority via
/// `RecentDocumentsStore`. Clicking a row reopens it through the same path as
/// the File ▸ Open Recent menu. Renders nothing when the history is empty.
struct EmptyStateRecents: View {
  @EnvironmentObject private var controller: AppController
  @ObservedObject var store: RecentDocumentsStore
  var limit = 6

  var body: some View {
    let items = Array(store.recentDocuments.prefix(limit))
    let labels = EmptyStateRecentLabels.labels(for: items)
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Recent")
          .font(.system(size: 10, weight: .semibold))
          .textCase(.uppercase)
          .tracking(1)
          .foregroundStyle(.secondary)

        ForEach(Array(items.enumerated()), id: \.element) { index, url in
          Button {
            controller.openRecentDocument(url: url)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
              Text(labels[index])
                .lineLimit(1)
              Spacer(minLength: 4)
            }
          }
          .buttonStyle(.plain)
          .help(RecentDocumentsStore.menuTitle(for: url))
        }
      }
      .frame(maxWidth: 280, alignment: .leading)
      .accessibilityIdentifier("pensieve.emptyState.recents")
    }
  }
}
