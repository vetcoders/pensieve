import SwiftUI

/// Bottom status bar for the editor scene — the Swift counterpart of the
/// `unicode-puzzles-portal` TextForge status bar.
///
/// Structure mirrors the reference (`label` + `value` items, grouped with
/// spacers): edit context on the left, document measurements in the middle,
/// render context on the right. All measurements come from `DocumentMetrics` /
/// `CaretPosition` so the counting semantics are testable and shareable with a
/// future Swift TextForge.
struct EditorStatusBar: View {
  @Environment(AppState.self) private var appState
  @EnvironmentObject private var themeManager: ThemeManager

  private var text: String { appState.activeDocumentText }

  private var metrics: DocumentMetrics { DocumentMetrics.measure(text) }

  private var caret: CaretPosition {
    CaretPosition.resolve(utf16Offset: appState.caretUTF16Offset, in: text)
  }

  /// Selection length in Unicode scalars (code points), resolved from the
  /// UTF-16 range AppKit reported. Zero ⇒ the item is hidden.
  private var selectionCharacters: Int {
    let length = appState.selectionUTF16Length
    guard length > 0 else { return 0 }
    let ns = text as NSString
    let location = min(max(appState.caretUTF16Offset, 0), ns.length)
    let clampedLength = min(length, ns.length - location)
    guard clampedLength > 0 else { return 0 }
    return ns.substring(with: NSRange(location: location, length: clampedLength))
      .unicodeScalars.count
  }

  var body: some View {
    HStack(spacing: 14) {
      item("Mode", appState.mode.label)

      item("Ln", "\(caret.line):\(caret.column)")
      if selectionCharacters > 0 {
        item("Sel", "\(selectionCharacters)")
      }

      Spacer(minLength: 8)

      item("Words", "\(metrics.words)")
      item("Chars", "\(metrics.characters)")
      item("Lines", "\(metrics.lines)")
      item("Bytes", "\(metrics.bytes)")

      Spacer(minLength: 8)

      if appState.documentIsDirty {
        HStack(spacing: 4) {
          Circle()
            .fill(Color(themeManager.skin.tokens.warning.nsColor))
            .frame(width: 5, height: 5)
          Text("Edited")
            .foregroundStyle(Color(themeManager.skin.tokens.warning.nsColor))
        }
        .accessibilityIdentifier("pensieve.statusbar.dirty")
      }

      appearanceChip
    }
    .font(.system(size: 10.5))
    .lineLimit(1)
    .padding(.horizontal, 12)
    .frame(height: 26)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .top) {
      Divider()
    }
    .accessibilityIdentifier("pensieve.statusbar")
  }

  /// A single `label · value` cell, matching the TextForge item shape: a muted
  /// label and a tabular-figure value so digits don't jitter as they change.
  @ViewBuilder
  private func item(_ label: String, _ value: String) -> some View {
    HStack(spacing: 4) {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .foregroundStyle(.primary)
        .monospacedDigit()
    }
    .fixedSize()
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label): \(value)")
  }

  /// The reading-surface chip: `Theme / Flavor` in a hairline capsule that opens
  /// the SAME two appearance pickers as the toolbar's menu. Previously Flavor and
  /// Theme were two inert text cells — the user could read the active theme but
  /// had to travel to the toolbar to change it. Bound straight into the shared
  /// `ThemeManager`, so a change here re-dresses both panels live.
  private var appearanceChip: some View {
    Menu {
      Picker("Flavor", selection: $themeManager.current) {
        ForEach(ThemeManager.Theme.allCases) { theme in
          Text(theme.displayName).tag(theme)
        }
      }
      .pickerStyle(.menu)

      Picker("Theme", selection: $themeManager.skin) {
        ForEach(PensieveTheme.allCases) { skin in
          Label(skin.displayName, systemImage: skin.systemImage).tag(skin)
        }
      }
      .pickerStyle(.menu)
    } label: {
      Text("\(themeManager.skin.displayName) / \(themeManager.current.displayName)")
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Preview appearance — markdown flavor and reading theme")
    .accessibilityIdentifier("pensieve.statusbar.appearance")
  }
}
