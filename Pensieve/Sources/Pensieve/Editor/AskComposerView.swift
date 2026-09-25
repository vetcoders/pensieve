import SwiftUI

/// Multiline Ask composer: informed preflight, then a visible streamed turn.
/// This is the Ask send path — it is not the rewrite one-line alert.
struct AskComposerView: View {
  @ObservedObject var thread: DocumentAskThread
  /// Grok's account and Ask routing, read from the codescribe FFI and shared
  /// with Settings ▸ AI.
  @ObservedObject var grokAccount: GrokAccount
  @ObservedObject var codexAccount: CodexAccount
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
  @EnvironmentObject private var themeManager: ThemeManager

  private var provider: AskProvider {
    if grokAccount.snapshot.askUsesGrok {
      return grokAccount.snapshot.askProvider(apiKey: apiKey)
    }
    return codexAccount.snapshot.askProvider(apiKey: apiKey)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if !thread.turns.isEmpty {
        turnList
      }
      if let preflight = thread.preflight, thread.phase == .awaitingConfirmation {
        preflightPanel(preflight)
      }
      if let error = thread.lastError, !thread.isStreaming {
        Text(error)
          .font(.system(size: 10.5))
          .foregroundStyle(.red)
          .accessibilityIdentifier("pensieve.ask.error")
      }
      if let error = grokAccount.lastError ?? codexAccount.lastError {
        Text(error)
          .font(.system(size: 10.5))
          .foregroundStyle(.red)
          .accessibilityIdentifier("pensieve.ask.providerError")
      }
      composer
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .frame(maxHeight: 280)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityIdentifier("pensieve.ask.composer")
    .task {
      await grokAccount.refreshIfStale()
      await codexAccount.refreshIfStale()
      await grokAccount.adoptGrokForAskIfSignedIn()
      await codexAccount.adoptCodexForAskIfSignedIn()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Ask")
        .font(.system(size: 12, weight: .semibold))
      providerMenu
      Spacer(minLength: 8)
      readinessChip
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
    let grok = grokAccount.snapshot
    let codex = codexAccount.snapshot
    let menuTitle =
      grok.askUsesGrok ? "Grok" : (codex.askUsesCodex ? "Codex" : apiKeyProvider.displayName)
    return Menu {
      Button {
        Task {
          if grok.askUsesGrok {
            await grokAccount.useAPIKeyProviderForAsk(apiKeyProvider)
          } else {
            await codexAccount.useAPIKeyProviderForAsk(apiKeyProvider)
          }
        }
      } label: {
        providerItemLabel(
          "\(apiKeyProvider.displayName) (API key)",
          isSelected: !grok.askUsesGrok && !codex.askUsesCodex)
      }
      Button {
        Task { await grokAccount.useGrokForAsk() }
      } label: {
        providerItemLabel("Grok (xAI account)", isSelected: grok.askUsesGrok)
      }
      .disabled(!grok.isSignedIn)
      Button {
        Task { await codexAccount.useCodexForAsk() }
      } label: {
        providerItemLabel("Codex (OpenAI account)", isSelected: codex.askUsesCodex)
      }
      .disabled(!codex.isSignedIn)
      if !grok.isSignedIn || !codex.isSignedIn {
        Divider()
        if !grok.isSignedIn {
          Button("Sign In to Grok…") { openProviderSettings() }
        }
        if !codex.isSignedIn {
          Button("Sign In to Codex…") { openProviderSettings() }
        }
      }
    } label: {
      Text(menuTitle)
        .font(.system(size: 10.5))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(statusCapsule)
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
      LazyVStack(alignment: .leading, spacing: 4) {
        ForEach(thread.turns) { turn in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(roleLabel(turn.role))
              .font(.system(size: 10.5))
              .foregroundStyle(.secondary)
              .frame(width: 88, alignment: .leading)
              .lineLimit(1)
            Text(turn.text.isEmpty && turn.isStreaming ? "…" : turn.text)
              .font(.callout)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityIdentifier(
            turn.isStreaming ? "pensieve.ask.stream" : "pensieve.ask.turn.\(turn.id.uuidString)")
        }
      }
      .padding(.vertical, 2)
    }
    .frame(maxHeight: 96)
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
      ZStack(alignment: .topLeading) {
        if thread.draft.isEmpty {
          Text("Ask about this document")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.top, 1)
            .padding(.leading, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        TextEditor(text: $thread.draft)
          .font(.callout)
          .scrollContentBackground(.hidden)
          .frame(height: 64)
          .disabled(thread.isStreaming)
          .accessibilityLabel("Ask question")
          .accessibilityIdentifier("pensieve.ask.draft")
      }
      Button(thread.isStreaming ? "Asking…" : "Ask") {
        _ = thread.prepareSend(document: documentText, provider: provider)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(
        thread.isStreaming
          || thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !AskReadiness.isReady(provider)
      )
      .accessibilityIdentifier("pensieve.ask.send")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.quaternary.opacity(0.55))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
    }
  }

  /// Compact status, same hairline capsule as the status-bar chips. The words
  /// still come from `AskReadiness.chipLabel` — ready and not-ready are the
  /// account's truth, not a painted stand-in.
  private var readinessChip: some View {
    let ready = AskReadiness.isReady(provider)
    return Text(AskReadiness.chipLabel(for: provider))
      .font(.system(size: 10.5))
      .foregroundStyle(ready ? AnyShapeStyle(.secondary) : AnyShapeStyle(warningColor))
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .overlay(statusCapsule)
      .help(ready ? "" : AskReadiness.notReadyMessage(for: provider))
      .accessibilityIdentifier("pensieve.ask.ready")
  }

  private var statusCapsule: some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
  }

  private var warningColor: Color {
    Color(themeManager.skin.tokens.warning.nsColor)
  }

  private func roleLabel(_ role: AskTurn.Role) -> String {
    switch role {
    case .user: return "You"
    case .assistant: return thread.isStreaming ? "Pensieve (streaming)" : "Pensieve"
    case .dictation: return "Dictation"
    }
  }
}
