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

  /// The chip and its two axes, named once so the AX contract has a single
  /// source. `scripts/ui-smoke.sh` looks the chip up by `appearanceIdentifier`
  /// on the live app and asserts both pickers are in the menu it opens — the
  /// only place that reachability can be proven, since `NSHostingView`
  /// publishes no accessibility tree in a headless test process (see
  /// `WindowErrorChromeRig`).
  static let appearanceIdentifier = "pensieve.statusbar.appearance"
  static let flavorPickerIdentifier = "pensieve.statusbar.flavorPicker"
  static let skinPickerIdentifier = "pensieve.statusbar.skinPicker"

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
  /// both appearance pickers. The PRIMARY home for either axis — the one in
  /// reach of the document being read — but since 14.08.2026 no longer the only
  /// one. The titlebar's appearance menu was removed when the toolbar ran out of
  /// width, and `Settings ▸ Appearance` now mirrors these two pickers for the
  /// windows this chip does not exist in (a launcher has no status bar) and for
  /// the narrow widths that can clip it. Both surfaces bind straight into the
  /// shared `ThemeManager`, so a change on either re-dresses every panel live
  /// and the two cannot drift apart.
  private var appearanceChip: some View {
    Menu {
      Picker("Flavor", selection: $themeManager.current) {
        ForEach(ThemeManager.Theme.allCases) { theme in
          Text(theme.displayName).tag(theme)
        }
      }
      .pickerStyle(.menu)
      .help("Markdown flavor — plain Markdown or GitHub Flavored")
      .accessibilityIdentifier(Self.flavorPickerIdentifier)

      // Reading-surface skin, orthogonal to the flavor: it re-dresses BOTH the
      // rendered preview and the source editor — surface, typography and syntax
      // tokens — without changing the markdown dialect.
      Picker("Theme", selection: $themeManager.skin) {
        ForEach(PensieveTheme.allCases) { skin in
          Label(skin.displayName, systemImage: skin.systemImage).tag(skin)
        }
      }
      .pickerStyle(.menu)
      .help("Preview theme — the reading surface for the rendered markdown")
      .accessibilityIdentifier(Self.skinPickerIdentifier)
    } label: {
      // Both axes, always, in this order: `EditorStatusBarAppearanceTests`
      // spells this format out rather than calling back into it, so a chip that
      // quietly drops an axis fails a test instead of shipping.
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
    .accessibilityLabel("Preview Appearance")
    // The static label names the ACTION; without a value beside it the control
    // announces only that, and the current pair — which the sighted user reads
    // straight off the chip — reaches nobody else. Since this chip is the only
    // appearance entry point, that left the active skin and flavor discoverable
    // solely by opening both pickers and inspecting their checkmarks. Not
    // pinned in `EditorStatusBarAppearanceTests` on purpose: `NSHostingView`
    // publishes no accessibility tree in a test process (measured, see that
    // file's header), so a pin keyed on this would skip itself into a
    // permanent green. `scripts/ui-smoke.sh` is where it is observable.
    .accessibilityValue(
      "\(themeManager.skin.displayName) / \(themeManager.current.displayName)")
    .accessibilityIdentifier(Self.appearanceIdentifier)
  }
}
