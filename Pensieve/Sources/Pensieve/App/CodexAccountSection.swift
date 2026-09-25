import AppKit
import SwiftUI

/// Settings ▸ AI: the Codex (OpenAI account) Ask can use. Parallel to
/// "Ask with Grok" — a separate section, not a second mode of that control.
struct CodexAccountSection: View {
  @ObservedObject var account: CodexAccount
  let apiKeyProvider: CompletionProviderShape

  var body: some View {
    Section {
      statusRow
      if !account.signInAllowed {
        Text(SandboxCapabilities.accountSignInUnavailableExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pensieve.provider.codex.sandboxed")
      }
      phaseContent
      if let error = account.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pensieve.provider.codex.error")
      }
      if account.hasLoaded {
        askRoutingRow
      }
    } header: {
      Text("Ask with Codex")
    } footer: {
      Text(
        "Codex signs in with the OpenAI/Codex device code you approve. "
          + "Changes apply at once — Save is only for the autocomplete provider."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var statusRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Circle()
        .fill(account.snapshot.isSignedIn ? Color.green : Color.secondary.opacity(0.5))
        .frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 2) {
        Text("Codex account")
        Text(statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pensieve.provider.codex.status")
      }
      Spacer()
      actionButton
    }
  }

  private var statusText: String {
    guard account.hasLoaded else { return "Checking…" }
    let message = account.snapshot.statusMessage
    return message.isEmpty ? "Not available in this build" : message
  }

  @ViewBuilder private var actionButton: some View {
    if account.phase.isInFlight {
      Button("Cancel") {
        account.cancelSignIn()
      }
      .accessibilityIdentifier("pensieve.provider.codex.cancel")
    } else if account.snapshot.isSignedIn {
      Button("Sign Out") {
        Task { await account.signOut() }
      }
      .help("Remove the stored Codex account tokens. API keys are untouched.")
      .accessibilityIdentifier("pensieve.provider.codex.signOut")
    } else {
      Button("Sign In with OpenAI…") {
        Task { await account.signIn() }
      }
      .disabled(
        !account.signInAllowed || !account.hasLoaded || !account.snapshot.isLoginConfigured
      )
      .accessibilityIdentifier("pensieve.provider.codex.signIn")
    }
  }

  @ViewBuilder private var phaseContent: some View {
    switch account.phase {
    case .idle:
      EmptyView()
    case .requestingCode:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Requesting a sign-in code from OpenAI…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("pensieve.provider.codex.requesting")
    case .awaitingApproval(let code):
      CodexDeviceCodePanel(code: code)
    case .authorized:
      Label("Signed in. Codex can answer Ask.", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
        .accessibilityIdentifier("pensieve.provider.codex.authorized")
    case .failed(let failure):
      Label(failure.message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("pensieve.provider.codex.failed")
    case .cancelled:
      Text("Sign-in cancelled.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("pensieve.provider.codex.cancelled")
    }
  }

  @ViewBuilder private var askRoutingRow: some View {
    let snapshot = account.snapshot
    if snapshot.askUsesCodex {
      HStack {
        Text("Ask uses Codex.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Use \(apiKeyProvider.displayName) Instead") {
          Task { await account.useAPIKeyProviderForAsk(apiKeyProvider) }
        }
      }
      .accessibilityIdentifier("pensieve.provider.codex.routing")
    } else if snapshot.isSignedIn {
      HStack {
        Text(laneSentence)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Use Codex for Ask") {
          Task { await account.useCodexForAsk() }
        }
      }
      .accessibilityIdentifier("pensieve.provider.codex.routing")
    }
  }

  private var laneSentence: String {
    if account.snapshot.assistiveProviderID == GrokAccount.providerID {
      return "Ask uses Grok."
    }
    return "Ask uses your \(apiKeyProvider.displayName) API key."
  }
}

struct CodexDeviceCodePanel: View {
  let code: CodexDeviceCode

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let userCode = code.userCode {
        Text("Enter this code on the OpenAI page:")
          .font(.caption)
        HStack(spacing: 10) {
          Text(userCode)
            .font(.title3.monospaced().weight(.semibold))
            .textSelection(.enabled)
            .accessibilityIdentifier("pensieve.provider.codex.userCode")
          Button("Copy Code") {
            Self.copy(userCode)
          }
          .accessibilityIdentifier("pensieve.provider.codex.copyCode")
        }
      } else {
        Text(code.instructions)
          .font(.caption)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        Text(code.verificationURL.absoluteString)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier("pensieve.provider.codex.verificationURL")
        Spacer(minLength: 4)
        Button("Open Page") {
          _ = NSWorkspace.shared.open(code.verificationURL)
        }
        .accessibilityIdentifier("pensieve.provider.codex.openPage")
        Button("Copy Link") {
          Self.copy(code.verificationURL.absoluteString)
        }
        .accessibilityIdentifier("pensieve.provider.codex.copyLink")
      }
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Waiting for approval — stops after \(CodexAccount.loginTimeoutSeconds / 60) minutes.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("pensieve.provider.codex.pending")
  }

  private static func copy(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }
}
