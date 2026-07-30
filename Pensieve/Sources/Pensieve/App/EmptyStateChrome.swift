import AppKit
import SwiftUI

/// Shared chrome for the two "nothing open yet" surfaces (the sidebar's
/// `emptyState` and the detail pane's `DocumentEmptyStateView`), per handoff
/// 5.6: a wordmark, the primary shortcuts rendered as key caps, and the recent
/// documents pulled from `RecentDocumentsStore` (the system Open-Recent
/// authority — no second persisted list). Both host surfaces observe
/// `ThemeManager`, so the accent wordmark and the key-cap hairlines repaint on
/// a live theme switch.

/// The app wordmark, tinted from the theme accent. `size` lets the wide detail
/// pane show it large and the narrow sidebar show it small.
struct EmptyStateWordmark: View {
  @EnvironmentObject private var themeManager: ThemeManager
  var size: CGFloat = 34

  var body: some View {
    let family = themeManager.skin.tokens.previewHeadingFamily
    Text("Pensieve")
      .font(family.isEmpty ? .system(size: size, weight: .semibold) : .custom(family, size: size))
      .foregroundStyle(Color(themeManager.skin.tokens.accent.nsColor))
      .accessibilityIdentifier("pensieve.emptyState.wordmark")
  }
}

/// A keyboard shortcut rendered as a small key cap (⌘N, ⌘⇧O …), outlined in the
/// theme border tint.
struct ShortcutKeyCap: View {
  @EnvironmentObject private var themeManager: ThemeManager
  let symbols: String

  var body: some View {
    Text(symbols)
      .font(.system(size: 12, weight: .medium, design: .rounded))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color(NSColor.controlBackgroundColor))
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
      ShortcutKeyCap(symbols: symbols)
        .frame(width: 44, alignment: .leading)
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
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
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Recent")
          .font(.system(size: 10, weight: .semibold))
          .textCase(.uppercase)
          .tracking(1)
          .foregroundStyle(.secondary)

        ForEach(items, id: \.self) { url in
          Button {
            controller.openRecentDocument(url: url)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
              Text(url.deletingPathExtension().lastPathComponent)
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
