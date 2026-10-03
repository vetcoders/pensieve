import CodescribeBridge
import SwiftUI

/// Document-scope Ask: a thin wrapper that binds the document thread to the
/// ONE shared conversation UI. Session authority stays in `DocumentAskThread`;
/// this view only supplies bindings and callbacks to the assembled surface,
/// so document and workspace Ask render the same transcript, input and chips.
struct AskComposerView: View {
  @ObservedObject var thread: DocumentAskThread
  /// Grok's account and Ask routing, read from Pensieve’s embedded engine and shared
  /// with Settings ▸ AI.
  @ObservedObject var grokAccount: GrokAccount
  @ObservedObject var codexAccount: CodexAccount
  let apiKey: String
  let makeDocumentHost: @MainActor () -> DocumentToolHost
  let apiConfiguration: CsDocumentProvider
  /// The shared off-main transcript model, owned by the surface host so the
  /// parse cache survives scope and presentation switches.
  @ObservedObject var conversation: AskConversationModel
  var openProviderSettings: @MainActor () -> Void = {
    _ = PensieveSettingsWindowController.shared.show(section: .ai)
  }

  static let placeholder = "Ask or edit this document"
  static let accessibilityPrefix = "pensieve.ask"

  var provider: AskProvider {
    if grokAccount.snapshot.askUsesGrok {
      return grokAccount.snapshot.askProvider(apiKey: apiKey)
    }
    return codexAccount.snapshot.askProvider(apiKey: apiKey)
  }

  private var usesAccountProvider: Bool {
    grokAccount.snapshot.askUsesGrok || codexAccount.snapshot.askUsesCodex
  }

  /// The endpoint/model an API-key send is configured with. Account lanes
  /// carry their own credentials, so the loopback rule never applies to them.
  var readinessContext: AskEndpointContext? {
    usesAccountProvider ? nil : AskEndpointContext(configuration: apiConfiguration)
  }

  /// Standalone rendering stacks both slots; the assembled surface mounts
  /// them separately.
  var body: some View {
    VStack(spacing: 0) {
      transcript
      composer
    }
  }

  /// The transcript slot the surface mounts. Observing the thread here (not
  /// in the model) keeps streaming updates flowing into the coalescer.
  var transcript: some View {
    AskConversationTranscript(
      model: conversation,
      error: thread.isStreaming ? nil : thread.lastError,
      providerError: grokAccount.lastError ?? codexAccount.lastError,
      activity: thread.isStreaming ? thread.activity : nil,
      identifierPrefix: Self.accessibilityPrefix
    )
    .onAppear { conversation.observe(turns: thread.turns) }
    .onChange(of: thread.turns) { _, turns in conversation.observe(turns: turns) }
  }

  /// The composer slot the surface mounts.
  var composer: some View {
    AskConversationComposer(
      store: thread.attachmentStore,
      draft: $thread.draft,
      isBusy: thread.isStreaming,
      canSend: canSend,
      placeholder: Self.placeholder,
      identifierPrefix: Self.accessibilityPrefix,
      draftAccessibilityIdentifier: "pensieve.ask.draft",
      submitAccessibilityIdentifier: "pensieve.ask.send",
      onSend: send,
      onStop: { thread.cancel() }
    )
    .accessibilityIdentifier("pensieve.ask.composer")
  }

  private var canSend: Bool {
    !thread.isStreaming
      && !thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && AskReadiness.isReady(provider, context: readinessContext)
  }

  private func send() {
    guard !thread.isStreaming else { return }
    _ = thread.send(
      provider: provider, host: makeDocumentHost(),
      configuration: usesAccountProvider ? nil : apiConfiguration)
  }
}
