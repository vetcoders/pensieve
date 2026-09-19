import AppKit
import SwiftUI

/// Settings ▸ AI: the Grok (xAI) account Ask can use. Everything shown is
/// either read from the codescribe FFI — signed in, status copy, where Ask is
/// routed — or is the in-flight device-code attempt. Pensieve persists none of
/// it.
struct GrokAccountSection: View {
  @ObservedObject var account: GrokAccount
  let apiKeyProvider: CompletionProviderShape

  var body: some View {
    Section {
      statusRow
      if !account.signInAllowed {
        Text(SandboxCapabilities.accountSignInUnavailableExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pensieve.provider.grok.sandboxed")
      }
      phaseContent
      if let error = account.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pensieve.provider.grok.error")
      }
      if account.hasLoaded {
        askRoutingRow
      }
    } header: {
      Text("Ask with Grok")
    } footer: {
      Text(
        "Grok signs in with an xAI device code you approve on any device. "
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
        Text("Grok account")
        Text(statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("pensieve.provider.grok.status")
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
      .accessibilityIdentifier("pensieve.provider.grok.cancel")
    } else if account.snapshot.isSignedIn {
      Button("Sign Out") {
        Task { await account.signOut() }
      }
      .help("Remove the stored Grok account tokens. API keys are untouched.")
      .accessibilityIdentifier("pensieve.provider.grok.signOut")
    } else {
      Button("Sign In with xAI…") {
        Task { await account.signIn() }
      }
      .disabled(
        !account.signInAllowed || !account.hasLoaded || !account.snapshot.isLoginConfigured
      )
      .accessibilityIdentifier("pensieve.provider.grok.signIn")
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
        Text("Requesting a sign-in code from xAI…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("pensieve.provider.grok.requesting")
    case .awaitingApproval(let code):
      GrokDeviceCodePanel(code: code)
    case .authorized:
      Label("Signed in. Grok can answer Ask.", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
        .accessibilityIdentifier("pensieve.provider.grok.authorized")
    case .failed(let failure):
      Label(failure.message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("pensieve.provider.grok.failed")
    case .cancelled:
      Text("Sign-in cancelled.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("pensieve.provider.grok.cancelled")
    }
  }

  @ViewBuilder private var askRoutingRow: some View {
    let snapshot = account.snapshot
    if snapshot.askUsesGrok {
      HStack {
        Text(
          snapshot.isSignedIn
            ? "Ask uses Grok." : "Ask is set to Grok, but no Grok account is signed in."
        )
        .font(.caption)
        .foregroundStyle(snapshot.isSignedIn ? Color.secondary : Color.orange)
        Spacer()
        Button("Use \(apiKeyProvider.displayName) Instead") {
          Task { await account.useAPIKeyProviderForAsk(apiKeyProvider) }
        }
      }
      .accessibilityIdentifier("pensieve.provider.grok.routing")
    } else if snapshot.isSignedIn {
      HStack {
        Text("Ask uses your \(apiKeyProvider.displayName) API key.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Use Grok for Ask") {
          Task { await account.useGrokForAsk() }
        }
      }
      .accessibilityIdentifier("pensieve.provider.grok.routing")
    }
  }
}

/// The pending half of the device-code flow: the code to confirm and the page
/// to confirm it on — both copyable, so approval can happen on another device.
struct GrokDeviceCodePanel: View {
  let code: GrokDeviceCode

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let userCode = code.userCode {
        Text("Enter this code on the xAI page:")
          .font(.caption)
        HStack(spacing: 10) {
          Text(userCode)
            .font(.title3.monospaced().weight(.semibold))
            .textSelection(.enabled)
            .accessibilityIdentifier("pensieve.provider.grok.userCode")
          Button("Copy Code") {
            Self.copy(userCode)
          }
          .accessibilityIdentifier("pensieve.provider.grok.copyCode")
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
          .accessibilityIdentifier("pensieve.provider.grok.verificationURL")
        Spacer(minLength: 4)
        Button("Open Page") {
          _ = NSWorkspace.shared.open(code.verificationURL)
        }
        .accessibilityIdentifier("pensieve.provider.grok.openPage")
        Button("Copy Link") {
          Self.copy(code.verificationURL.absoluteString)
        }
        .accessibilityIdentifier("pensieve.provider.grok.copyLink")
      }
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Waiting for approval — stops after \(GrokAccount.loginTimeoutSeconds / 60) minutes.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("pensieve.provider.grok.pending")
  }

  private static func copy(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }
}
