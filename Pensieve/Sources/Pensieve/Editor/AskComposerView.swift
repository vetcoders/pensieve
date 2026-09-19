import SwiftUI

/// Multiline Ask composer: informed preflight, then a visible streamed turn.
/// This is the Ask send path — it is not the rewrite one-line alert.
struct AskComposerView: View {
  @ObservedObject var thread: DocumentAskThread
  /// Grok's account and Ask routing, read from the codescribe FFI and shared
  /// with Settings ▸ AI.
  @ObservedObject var grokAccount: GrokAccount
  let documentText: String
  let apiKey: String
  /// The API-key provider Ask falls back to when it is not routed to Grok.
  var apiKeyProvider: CompletionProviderShape = .openAIResponses
  var openProviderSettings: @MainActor () -> Void = {
    _ = PensieveSettingsWindowController.shared.show(section: .ai)
  }

  /// Persisted across launches and shared with the status bar's Ask chip —
  /// one key, two surfaces, no drift. Hidden while streaming still shows
  /// activity on the chip, so an in-flight Ask is never invisible.
  @AppStorage("pensieve.ask.visible") private var isVisible = true

  private var provider: AskProvider {
    grokAccount.snapshot.askProvider(apiKey: apiKey)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      turnList
      if let preflight = thread.preflight, thread.phase == .awaitingConfirmation {
        preflightPanel(preflight)
      }
      if let error = thread.lastError, !thread.isStreaming {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("pensieve.ask.error")
      }
      if let error = grokAccount.lastError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("pensieve.ask.providerError")
      }
      composer
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(minHeight: 140, maxHeight: 280)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityIdentifier("pensieve.ask.composer")
    .task { await grokAccount.refreshIfStale() }
  }

  private var header: some View {
    HStack {
      Text("Ask")
        .font(.callout.weight(.semibold))
      providerMenu
      Spacer()
      Text(AskReadiness.chipLabel(for: provider))
        .font(.caption)
        .foregroundStyle(AskReadiness.isReady(provider) ? Color.secondary : Color.orange)
        .help(AskReadiness.isReady(provider) ? "" : AskReadiness.notReadyMessage(for: provider))
        .accessibilityIdentifier("pensieve.ask.ready")
      Button {
        isVisible = false
      } label: {
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Hide Ask — bring it back from the status bar")
      .accessibilityIdentifier("pensieve.ask.toggle")
      .accessibilityLabel("Hide Ask panel")
    }
  }

  /// Which provider answers. Grok is selectable only once its account is
  /// authorized; choosing either one reroutes codescribe's assistive lane, so
  /// the menu, the chip and the next send all read the same truth.
  private var providerMenu: some View {
    let snapshot = grokAccount.snapshot
    return Menu {
      Button {
        Task { await grokAccount.useAPIKeyProviderForAsk(apiKeyProvider) }
      } label: {
        providerItemLabel(
          "\(apiKeyProvider.displayName) (API key)", isSelected: !snapshot.askUsesGrok)
      }
      Button {
        Task { await grokAccount.useGrokForAsk() }
      } label: {
        providerItemLabel("Grok (xAI account)", isSelected: snapshot.askUsesGrok)
      }
      .disabled(!snapshot.isSignedIn)
      if !snapshot.isSignedIn {
        Divider()
        Button("Sign In to Grok…") {
          openProviderSettings()
        }
      }
    } label: {
      Text(snapshot.askUsesGrok ? "Grok" : apiKeyProvider.displayName)
        .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(thread.isStreaming)
    .help("Choose which provider answers Ask")
    .accessibilityIdentifier("pensieve.ask.provider")
  }

  @ViewBuilder
  private func providerItemLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  private var turnList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 6) {
        ForEach(thread.turns) { turn in
          VStack(alignment: .leading, spacing: 2) {
            Text(roleLabel(turn.role))
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text(turn.text.isEmpty && turn.isStreaming ? "…" : turn.text)
              .font(.callout)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(8)
          .background(turnBackground(turn), in: RoundedRectangle(cornerRadius: 6))
          .accessibilityIdentifier(
            turn.isStreaming ? "pensieve.ask.stream" : "pensieve.ask.turn.\(turn.id.uuidString)")
        }
      }
    }
    .frame(maxHeight: 120)
    .accessibilityIdentifier("pensieve.ask.turns")
  }

  private func preflightPanel(_ preflight: AskPreflight) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Before sending")
        .font(.caption.weight(.semibold))
      Text(preflight.summary)
        .font(.caption)
        .textSelection(.enabled)
      HStack {
        Button("Cancel") {
          thread.cancelPreflight()
        }
        .accessibilityIdentifier("pensieve.ask.cancel")
        Button("Send \(preflight.totalCharacters) characters") {
          _ = thread.confirmAndSend(document: documentText, provider: provider)
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("pensieve.ask.confirm")
      }
    }
    .padding(8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    .accessibilityIdentifier("pensieve.ask.preflight")
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextEditor(text: $thread.draft)
        .font(.body)
        .frame(minHeight: 48, maxHeight: 96)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.separator, lineWidth: 1)
        )
        .disabled(thread.isStreaming)
        .accessibilityLabel("Ask question")
        .accessibilityIdentifier("pensieve.ask.draft")

      Button(thread.isStreaming ? "Asking…" : "Ask") {
        _ = thread.prepareSend(document: documentText, provider: provider)
      }
      .disabled(
        thread.isStreaming
          || thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !AskReadiness.isReady(provider)
      )
      .accessibilityIdentifier("pensieve.ask.send")
    }
  }

  private func roleLabel(_ role: AskTurn.Role) -> String {
    switch role {
    case .user: return "You"
    case .assistant: return thread.isStreaming ? "Pensieve (streaming)" : "Pensieve"
    case .dictation: return "Dictation"
    }
  }

  private func turnBackground(_ turn: AskTurn) -> Color {
    switch turn.role {
    case .assistant: return Color.accentColor.opacity(0.08)
    case .dictation: return Color.orange.opacity(0.08)
    case .user: return Color.secondary.opacity(0.08)
    }
  }
}
