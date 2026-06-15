import AppKit
import SwiftUI

/// Dispatch configuration popover for the toolbar ✈ button.
///
/// Flow (operator spec): Agent (discovered) → Path (WHERE to run) → Workflow
/// (from the vibecrafted deck) → summary → confirm. The PLAN is always the
/// currently-open document; `rootURL` only chooses WHERE the agent runs.
struct DispatchPopover: View {
  @ObservedObject var controller: AppController
  @Binding var isPresented: Bool
  let documentTitle: String

  @State private var agent: String
  @State private var workflow: String
  @State private var rootURL: URL

  init(
    controller: AppController,
    isPresented: Binding<Bool>,
    documentTitle: String,
    defaultRoot: URL
  ) {
    self.controller = controller
    self._isPresented = isPresented
    self.documentTitle = documentTitle
    self._agent = State(initialValue: controller.availableAgents.first ?? "codex")
    self._workflow = State(initialValue: controller.agentWorkflows.contains("implement")
      ? "implement" : (controller.agentWorkflows.first ?? "implement"))
    self._rootURL = State(initialValue: defaultRoot)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Dispatch to Agent")
        .font(.headline)

      Picker("Agent", selection: $agent) {
        ForEach(controller.availableAgents, id: \.self) { Text($0).tag($0) }
      }
      .accessibilityIdentifier("pensieve.dispatch.agent")

      VStack(alignment: .leading, spacing: 4) {
        Text("Path (where to run)").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          Text(rootURL.path)
            .font(.system(size: 11).monospaced())
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Choose…") { chooseRoot() }
            .accessibilityIdentifier("pensieve.dispatch.chooseRoot")
        }
      }

      Picker("Workflow", selection: $workflow) {
        ForEach(controller.agentWorkflows, id: \.self) { Text($0).tag($0) }
      }
      .accessibilityIdentifier("pensieve.dispatch.workflow")

      Divider()

      // Confirmation summary.
      VStack(alignment: .leading, spacing: 2) {
        Text("Summary").font(.caption).foregroundStyle(.secondary)
        Text("\(workflow) · \(agent)")
          .font(.system(size: 12, weight: .semibold))
        Text("plan: \(documentTitle)")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Text("where: \(rootURL.lastPathComponent)")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }

      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
          .keyboardShortcut(.cancelAction)
        Button("Dispatch") {
          controller.dispatchOpenDocumentViaTerminal(
            workflow: workflow, agent: agent, rootURL: rootURL)
          isPresented = false
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("pensieve.dispatch.confirm")
      }
    }
    .padding(16)
    .frame(width: 380)
    .onAppear { controller.discoverAgents() }
  }

  private func chooseRoot() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = rootURL
    panel.prompt = "Use as run root"
    if panel.runModal() == .OK, let url = panel.url {
      rootURL = url
    }
  }
}
