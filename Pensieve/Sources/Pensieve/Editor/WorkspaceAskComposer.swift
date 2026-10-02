import SwiftUI

/// Workspace question field. Sibling of document Ask: the same composer chrome,
/// a different question. It does not call the tool host or the FFI bridge.
struct WorkspaceAskComposer: View {
  nonisolated static let placeholder = "Ask about this workspace"
  nonisolated static let accessibilityIdentifier = "pensieve.workspaceAsk.composer"
  nonisolated static let fieldAccessibilityIdentifier = "pensieve.workspaceAsk.field"
  nonisolated static let submitAccessibilityIdentifier = "pensieve.workspaceAsk.submit"

  @State private var draft = ""
  var onSubmit: @MainActor (String) -> Void = { _ in }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      composer
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .accessibilityIdentifier(Self.accessibilityIdentifier)
  }

  private var header: some View {
    Text("Workspace")
      .font(.system(size: 12, weight: .semibold))
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      ZStack(alignment: .topLeading) {
        if draft.isEmpty {
          Text(Self.placeholder)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.top, 1)
            .padding(.leading, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        TextField("", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.callout)
          .lineLimit(2...4)
          .frame(height: 64, alignment: .topLeading)
          .accessibilityLabel(Self.placeholder)
          .accessibilityIdentifier(Self.fieldAccessibilityIdentifier)
          .onSubmit { submit() }
      }
      Button("Ask") {
        submit()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(Self.submission(from: draft) == nil)
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
    guard let text = Self.submission(from: draft) else { return }
    onSubmit(text)
    draft = ""
  }

  /// Whitespace-only input is not a question.
  nonisolated static func submission(from draft: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
