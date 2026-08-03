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

/// Click affordance for the empty state's ACTION rows — the ⌘N shortcut row and
/// every Recent entry.
///
/// Both were live buttons carrying `.buttonStyle(.plain)` and nothing else: no
/// hover wash, no cursor change, and not even the dimming a plain button
/// normally shows while pressed, because the detail-pane host imposes its own
/// `foregroundStyle` hierarchy over the whole surface and that is the channel
/// `.plain` presses through. So a row that reopens a document looked exactly
/// like the caption text beside it, and the only way to discover it was
/// clickable was to click it.
///
/// The wash is the sidebar's row selection one step quieter — same accent, same
/// 6 pt radius — so a hover here reads as the same gesture as a hover in the
/// file tree. `legibleAccent` rather than the raw token for the reason the
/// sidebar takes it too: these rows can sit on a skin whose accent cannot carry
/// itself on this surface.
///
/// Deliberately layout-neutral. The wash is drawn by a background inset with
/// NEGATIVE padding rather than by padding the label, so adopting the style
/// moves no row by a point — the empty state is a centred stack whose width is
/// its widest child, and a style that grew its rows would re-centre the whole
/// composition.
struct EmptyStateRowButtonStyle: ButtonStyle {
  /// Wash strength for a row's current interaction state. Static so the pin can
  /// state the affordance contract — a resting row paints nothing, hover and
  /// pressed are visibly distinct — without rendering SwiftUI.
  static func fillOpacity(isHovering: Bool, isPressed: Bool) -> Double {
    if isPressed { return 0.24 }
    return isHovering ? 0.12 : 0
  }

  func makeBody(configuration: Configuration) -> some View {
    RowBody(configuration: configuration)
  }

  /// The style's body lives in a nested VIEW because a `ButtonStyle` is not one:
  /// `@EnvironmentObject` (the theme the wash is tinted from) and `@State` (the
  /// hover flag) only resolve inside the view tree.
  private struct RowBody: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
      let accent = Color(SidebarView.chromeAccentColor(for: themeManager.skin.tokens))
      configuration.label
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
              accent.opacity(
                EmptyStateRowButtonStyle.fillOpacity(
                  isHovering: isHovering, isPressed: configuration.isPressed))
            )
            .padding(EdgeInsets(top: -3, leading: -6, bottom: -3, trailing: -6))
        )
        .onHover { hovering in
          guard hovering != isHovering else { return }
          isHovering = hovering
          // AppKit owns the cursor; SwiftUI changes it for no button style on
          // its own. Push/pop is balanced by the equality guard above plus the
          // disappear hook below — a row torn down while hovered (a skin
          // switch rebuilding the stack, a document opening under the pointer)
          // would otherwise leave the pointing hand stuck app-wide.
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
        .onDisappear {
          guard isHovering else { return }
          isHovering = false
          NSCursor.pop()
        }
    }
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
      .buttonStyle(EmptyStateRowButtonStyle())
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
/// So the path joins the label, but ONLY on the rows that need it and only as
/// much of it as they need. Suffixing every row would make the ordinary case —
/// six distinct names — noisier for nothing. Uniqueness is judged inside the
/// VISIBLE slice, because that is the set a reader is comparing; a name that
/// repeats further down a history this view never draws is not an ambiguity
/// anyone can see.
///
/// One parent is not always enough, which is what the first cut of this helper
/// assumed. `/a/project/README.md` and `/b/project/README.md` both answered
/// "README — project" and stayed exactly as indistinguishable as the bare
/// basenames they replaced. So the suffix GROWS — one path component at a time,
/// per colliding name — until the rows differ.
enum EmptyStateRecentLabels {
  /// Between the name and the path that disambiguates it.
  static let separator = " — "

  static func labels(for urls: [URL]) -> [String] {
    let names = urls.map { $0.deletingPathExtension().lastPathComponent }
    var rowsByName: [String: [Int]] = [:]
    for (index, name) in names.enumerated() { rowsByName[name, default: []].append(index) }

    // Parent components, root first, with the volume root itself dropped: it is
    // not a folder name anyone reads, and a file sitting at the root has no
    // disambiguator to offer at all.
    let parents = urls.map { url in
      url.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
    }

    var labels = names
    for (name, rows) in rowsByName where rows.count > 1 {
      let depth = separatingDepth(for: rows.map { parents[$0] })
      for row in rows {
        let suffix = parents[row].suffix(depth).joined(separator: "/")
        labels[row] = suffix.isEmpty ? name : name + separator + suffix
      }
    }
    return labels
  }

  /// How many trailing path components the colliding rows need in order to read
  /// as different rows.
  ///
  /// Every depth is measured, and the SHORTEST one that reached the highest
  /// distinct count wins. Only one thing ends the scan early: every row is
  /// already distinct, which no longer suffix can improve on.
  ///
  /// It deliberately does NOT stop at a depth that added nothing. Shared
  /// ancestry comes in plateaus — `/a/shared/project/README.md` and
  /// `/b/shared/project/README.md` are identical at one component AND at two,
  /// and differ only at three — so reading a flat step as "no ancestor can ever
  /// separate these" left both rows rendering "README — project", exactly the
  /// ambiguity this helper exists to remove. Distinctness can arrive later, so
  /// the search runs to the deepest parent; `deepest` bounds it, which is what
  /// makes it terminate on paths that agree all the way to the volume root.
  private static func separatingDepth(for parents: [[String]]) -> Int {
    let deepest = parents.map(\.count).max() ?? 0
    guard deepest > 0 else { return 0 }

    var best = 1
    var bestDistinct = 0
    for depth in 1...deepest {
      let distinct = Set(parents.map { $0.suffix(depth).joined(separator: "/") }).count
      guard distinct > bestDistinct else { continue }
      best = depth
      bestDistinct = distinct
      if distinct == parents.count { break }
    }
    return best
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
          .buttonStyle(EmptyStateRowButtonStyle())
          .help(RecentDocumentsStore.menuTitle(for: url))
        }
      }
      .frame(maxWidth: 280, alignment: .leading)
      .accessibilityIdentifier("pensieve.emptyState.recents")
    }
  }
}
