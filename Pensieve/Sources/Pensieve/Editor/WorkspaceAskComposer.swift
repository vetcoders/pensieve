import CodescribeBridge
import SwiftUI

/// Workspace-scope Ask: the sibling wrapper binding the workspace thread to
/// the same shared conversation UI as document Ask. The thread stays the
/// session authority; this view only supplies bindings and callbacks.
struct WorkspaceAskComposer: View {
  nonisolated static let placeholder = "Ask about this workspace"
  nonisolated static let accessibilityIdentifier = "pensieve.workspaceAsk.composer"
  nonisolated static let fieldAccessibilityIdentifier = "pensieve.workspaceAsk.field"
  nonisolated static let submitAccessibilityIdentifier = "pensieve.workspaceAsk.submit"
  nonisolated static let accessibilityPrefix = "pensieve.workspaceAsk"

  @Bindable var thread: WorkspaceAskThread
  /// The shared off-main transcript model, owned by the surface host.
  var conversation: AskConversationModel
  let provider: AskProvider
  let readinessContext: AskEndpointContext?
  var onSubmit: @MainActor (String) async -> Bool
  var openSettings: @MainActor () -> Void = {
    _ = PensieveSettingsWindowController.shared.show(section: .ai)
  }

  /// Standalone rendering stacks both slots; the assembled surface mounts
  /// them separately.
  var body: some View {
    VStack(spacing: 0) {
      transcript
      composer
    }
  }

  /// The transcript slot the surface mounts.
  var transcript: some View {
    AskConversationTranscript(
      model: conversation,
      error: thread.isStreaming ? nil : thread.lastError,
      providerError: nil,
      activity: thread.isPreparing ? "Preparing workspace…" : nil,
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
      isBusy: thread.isBusy,
      canSend: canSend,
      placeholder: Self.placeholder,
      identifierPrefix: Self.accessibilityPrefix,
      draftAccessibilityIdentifier: Self.fieldAccessibilityIdentifier,
      submitAccessibilityIdentifier: Self.submitAccessibilityIdentifier,
      onSend: submit,
      onStop: { thread.cancel() }
    )
    .accessibilityIdentifier(Self.accessibilityIdentifier)
  }

  private var canSend: Bool {
    Self.submission(from: thread.draft) != nil && !thread.isBusy
      && AskReadiness.isReady(provider, context: readinessContext)
  }

  private func submit() {
    guard let text = Self.submission(from: thread.draft), !thread.isBusy else { return }
    Task { _ = await onSubmit(text) }
  }

  /// Whitespace-only input is not a question.
  nonisolated static func submission(from draft: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
