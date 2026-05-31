import AppKit
import SwiftUI

struct FindBar: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    HStack(spacing: 6) {
      NativeSearchField(
        text: $appState.findQuery,
        placeholder: "Find",
        focusToken: appState.findFocusToken,
        accessibilityIdentifier: "pensieve.find.query"
      ) {
        appState.pendingFindCommand = FindBarCommand(action: .next)
      }
      .frame(minWidth: 180)

      if appState.findReplaceMode {
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
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color(NSColor.controlBackgroundColor))
    .overlay(alignment: .bottom) {
      Divider()
    }
    .accessibilityIdentifier("pensieve.find.bar")
  }
}
