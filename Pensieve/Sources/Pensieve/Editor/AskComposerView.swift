import SwiftUI

/// Slot reads happen inside a mounted Observation tracking body.
struct AskThreadObservation<Content: View>: View {
  var thread: AskThread
  @ViewBuilder var content: (AskThread) -> Content
  var body: some View { content(thread) }
}

/// One composer for every immutable thread context.
struct AskComposerView: View {
  @Bindable var thread: AskThread
  @ObservedObject var conversation: AskConversationModel
  let provider: AskProvider
  let readinessContext: AskEndpointContext?
  var providerError: String? = nil
  var historyError: String? = nil
  var onSubmit: @MainActor (String) async -> Bool

  nonisolated static let placeholder = "Ask a question"
  nonisolated static let accessibilityPrefix = "pensieve.ask"
  nonisolated static let fieldAccessibilityIdentifier = "pensieve.ask.draft"
  nonisolated static let submitAccessibilityIdentifier = "pensieve.ask.send"

  var body: some View {
    VStack(spacing: 0) {
      transcript
      composer
    }
  }

  var transcript: some View {
    AskConversationTranscript(
      model: conversation,
      error: thread.isBusy ? historyError : (thread.lastError ?? historyError),
      providerError: providerError,
      activity: thread.isPreparing ? "Preparing context…" : thread.activity,
      identifierPrefix: Self.accessibilityPrefix
    )
    .onAppear { conversation.observe(turns: thread.turns) }
    .onChange(of: thread.turns) { _, turns in conversation.observe(turns: turns) }
  }

  var composer: some View {
    AskConversationComposer(
      store: thread.attachmentStore,
      draft: $thread.draft,
      isBusy: thread.isBusy,
      canSend: Self.submission(from: thread.draft) != nil && !thread.isBusy
        && AskReadiness.isReady(provider, context: readinessContext),
      placeholder: Self.placeholder,
      identifierPrefix: Self.accessibilityPrefix,
      draftAccessibilityIdentifier: Self.fieldAccessibilityIdentifier,
      submitAccessibilityIdentifier: Self.submitAccessibilityIdentifier,
      onSend: submit,
      onStop: { thread.cancel() }
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pensieve.ask.composer")
  }

  private func submit() {
    guard let text = Self.submission(from: thread.draft), !thread.isBusy else { return }
    Task { _ = await onSubmit(text) }
  }

  nonisolated static func submission(from draft: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
