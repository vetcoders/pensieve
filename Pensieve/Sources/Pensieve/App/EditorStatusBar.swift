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

      Divider().frame(height: 12)

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
            .fill(Color.orange)
            .frame(width: 6, height: 6)
          Text("Edited")
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("pensieve.statusbar.dirty")
        Divider().frame(height: 12)
      }

      item("Flavor", themeManager.current.displayName)
      item("Theme", themeManager.skin.displayName)
    }
    .font(.system(size: 11))
    .lineLimit(1)
    .padding(.horizontal, 12)
    .frame(height: 22)
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
}
