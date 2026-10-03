import CodescribeBridge
import SwiftUI

/// Workspace question field. Sibling of document Ask: the same composer chrome,
/// a different question. It does not call the tool host or the FFI bridge.
struct WorkspaceAskComposer: View {
  nonisolated static let placeholder = "Ask about this workspace"
  nonisolated static let accessibilityIdentifier = "pensieve.workspaceAsk.composer"
  nonisolated static let fieldAccessibilityIdentifier = "pensieve.workspaceAsk.field"
  nonisolated static let submitAccessibilityIdentifier = "pensieve.workspaceAsk.submit"

  @Bindable var thread: WorkspaceAskThread
  let providerName: String
  let readiness: String
  var onSubmit: @MainActor (String) async -> Bool
  var openSettings: @MainActor () -> Void = {
    _ = PensieveSettingsWindowController.shared.show(section: .ai)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if !thread.turns.isEmpty {
        WorkspaceAskTranscript(thread: thread)
      }
      if let error = thread.lastError {
        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
      }
      composer
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .frame(height: thread.turns.isEmpty && thread.lastError == nil ? 120 : 280, alignment: .top)
    .fixedSize(horizontal: false, vertical: true)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityIdentifier(Self.accessibilityIdentifier)
  }

  private var header: some View {
    HStack {
      Text("Workspace").font(.system(size: 12, weight: .semibold))
      Button(providerName, action: openSettings)
        .buttonStyle(.borderless)
        .help("Choose the Ask provider in Settings")
      Spacer()
      Text(readiness).font(.caption).foregroundStyle(.secondary)
      if thread.isStreaming {
        Button("Stop") { thread.cancel() }
          .accessibilityIdentifier("pensieve.workspaceAsk.stop")
      }
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      ZStack(alignment: .topLeading) {
        if thread.draft.isEmpty {
          Text(Self.placeholder)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.top, 1)
            .padding(.leading, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        AskDraftEditor(text: $thread.draft, isEnabled: !thread.isBusy) { submit() }
          .font(.callout)
          .scrollContentBackground(.hidden)
          .frame(height: 64, alignment: .topLeading)
          .accessibilityLabel(Self.placeholder)
          .accessibilityIdentifier(Self.fieldAccessibilityIdentifier)
      }
      Button("Ask") {
        submit()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(Self.submission(from: thread.draft) == nil || thread.isBusy)
      .accessibilityIdentifier(Self.submitAccessibilityIdentifier)
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

/// Streaming observation stays in this bounded transcript, away from the editor.
private struct WorkspaceAskTranscript: View {
  let thread: WorkspaceAskThread

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(thread.turns) { turn in
          VStack(alignment: .leading, spacing: 2) {
            Text(turn.role == .user ? "You" : "Pensieve")
              .font(.caption).foregroundStyle(.secondary)
            Text(turn.text.isEmpty && turn.isStreaming ? "…" : turn.text)
              .font(.callout).textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(height: 120)
    .accessibilityIdentifier("pensieve.workspaceAsk.turns")
  }
}

/// Session creation belongs to a root-change task, never a view-body read.
struct WorkspaceAskPanel: View {
  let workspace: WorkspaceStore
  @ObservedObject var providerSettings: ProviderSettings
  let openDocument:
    @MainActor @Sendable (DocumentRef, @escaping @Sendable () -> Bool) async throws ->
      DocumentToolHost
  @ObservedObject private var grokAccount = GrokAccount.shared
  @ObservedObject private var codexAccount = CodexAccount.shared
  @State private var thread: WorkspaceAskThread?

  private var provider: AskProvider {
    grokAccount.snapshot.askUsesGrok
      ? grokAccount.snapshot.askProvider(apiKey: providerSettings.apiKey)
      : codexAccount.snapshot.askProvider(apiKey: providerSettings.apiKey)
  }

  var body: some View {
    Group {
      if let thread {
        WorkspaceAskComposer(
          thread: thread,
          providerName: grokAccount.snapshot.askUsesGrok
            ? "Grok"
            : (codexAccount.snapshot.askUsesCodex
              ? "Codex" : providerSettings.providerShape.displayName),
          readiness: AskReadiness.chipLabel(for: provider),
          onSubmit: { prompt in
            let accountProvider =
              grokAccount.snapshot.askUsesGrok || codexAccount.snapshot.askUsesCodex
            return await thread.prepareAndSend(
              text: prompt,
              documents: workspace.documents, database: .shared,
              provider: provider,
              configuration: accountProvider
                ? nil
                : CsDocumentProvider(
                  wire: providerSettings.providerShape.rawValue,
                  endpoint: providerSettings.providerShape.normalizeEndpoint(
                    providerSettings.endpoint),
                  model: providerSettings.model, apiKey: providerSettings.apiKey),
              openDocument: openDocument)
          })
      }
    }
    .task(id: workspace.workspaceRoots.map(\.url)) {
      let roots = workspace.workspaceRoots.map(\.url)
      guard !roots.isEmpty else {
        thread?.cancel()
        thread = nil
        return
      }
      let bookmark = workspace.bookmarkData
      let identity = await Task.detached {
        WorkspaceIdentity.make(roots: roots, bookmarkData: bookmark)
      }.value
      guard !Task.isCancelled else { return }
      if let thread, thread.identity.workspaceID != identity.workspaceID { thread.cancel() }
      thread = WorkspaceAskThreadStore.shared.thread(for: identity)
    }
    .task {
      await grokAccount.refreshIfStale()
      await codexAccount.refreshIfStale()
    }
  }
}
