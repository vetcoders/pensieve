import AppKit
import SwiftUI

struct FindBar: View {
  @Environment(AppState.self) private var appState
  @EnvironmentObject private var themeManager: ThemeManager

  // "3 of 12" while navigating, "12 found" before the first jump, "No results"
  // when the query matches nothing — shown inline in the bar's search area.
  private var findCountLabel: String {
    let total = appState.findMatchCount
    if total == 0 { return "No results" }
    if let active = appState.findActiveMatchIndex {
      return "\(active + 1) of \(total)"
    }
    return "\(total) found"
  }

  var body: some View {
    @Bindable var appState = appState
    return VStack(spacing: 6) {
      HStack(spacing: 6) {
        // Disclosure toggle next to the search field: reveals/hides the Replace
        // row inline so Replace is discoverable from the bar itself, not only via
        // the ⌘⌥F menu shortcut.
        Button {
          appState.findReplaceMode.toggle()
        } label: {
          Image(systemName: appState.findReplaceMode ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(appState.findReplaceMode ? "Hide Replace" : "Show Replace")
        .accessibilityIdentifier("pensieve.find.toggleReplace")

        NativeSearchField(
          text: $appState.findQuery,
          placeholder: "Find",
          focusToken: appState.findFocusToken,
          focusOnAppear: true,
          accessibilityIdentifier: "pensieve.find.query"
        ) {
          appState.pendingFindCommand = FindBarCommand(action: .next)
        }
        .frame(minWidth: 180)

        Toggle(isOn: $appState.findOptions.matchCase) {
          Text("Aa")
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
              appState.findOptions.matchCase
                ? Color(themeManager.skin.tokens.legibleAccent).opacity(0.16) : .clear,
              in: RoundedRectangle(cornerRadius: 4))
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .help("Match Case")
        .accessibilityLabel("Match Case")
        .accessibilityIdentifier("pensieve.find.matchCase")

        Toggle(isOn: $appState.findOptions.wholeWords) {
          Text("Word")
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
              appState.findOptions.wholeWords
                ? Color(themeManager.skin.tokens.legibleAccent).opacity(0.16) : .clear,
              in: RoundedRectangle(cornerRadius: 4))
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .help("Whole Words")
        .accessibilityLabel("Whole Words")
        .accessibilityIdentifier("pensieve.find.wholeWords")

        if !appState.findQuery.isEmpty {
          Text(findCountLabel)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 64, alignment: .trailing)
            .accessibilityIdentifier("pensieve.find.count")
        }

        Button {
          appState.pendingFindCommand = FindBarCommand(action: .previous)
        } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(appState.findQuery.isEmpty)
        .help("Find Previous")
        .accessibilityIdentifier("pensieve.find.previous")

        Button {
          appState.pendingFindCommand = FindBarCommand(action: .next)
        } label: {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(appState.findQuery.isEmpty)
        .help("Find Next")
        .accessibilityIdentifier("pensieve.find.next")

        Button("Done") {
          appState.findBarVisible = false
          appState.pendingFindCommand = FindBarCommand(action: .clear)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("pensieve.find.done")
      }
      if appState.findReplaceMode {
        FindReplacementRow()
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .tint(Color(themeManager.skin.tokens.legibleAccent))
    // Native find-bar material (Safari / TextEdit style): an opaque, blurred bar
    // instead of a flat fill. `controlBackgroundColor` was letting the document
    // text bleed through behind the search field; `.bar` blurs whatever is under
    // it so the bar reads as a real macOS find bar, not a translucent overlay.
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .accessibilityIdentifier("pensieve.find.bar")
  }
}

private struct FindReplacementRow: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    @Bindable var appState = appState
    return HStack(spacing: 6) {
      NativeSearchField(
        text: $appState.findReplaceQuery,
        placeholder: "Replace",
        accessibilityIdentifier: "pensieve.find.replace"
      )
      .frame(minWidth: 160)

      Button("Replace") {
        appState.pendingFindCommand = FindBarCommand(action: .replace)
      }
      .buttonStyle(.borderless)
      .disabled(appState.findQuery.isEmpty)
      .accessibilityIdentifier("pensieve.find.replaceOne")

      Button("All") {
        appState.pendingFindCommand = FindBarCommand(action: .replaceAll)
      }
      .buttonStyle(.borderless)
      .disabled(appState.findQuery.isEmpty)
      .accessibilityIdentifier("pensieve.find.replaceAll")
    }
  }
}
