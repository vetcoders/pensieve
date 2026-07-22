import AppKit
import SwiftUI

/// The CANONICAL dispatch configuration sheet — the only surface that may turn
/// a `DispatchIntent` into a launch.
///
/// Every route (toolbar ✈, Agents menu, Agents workflow submenu, sidebar file
/// actions) raises an intent; this sheet shows the explicit subject, the
/// preselected workflow, the agent picker, the remembered run root, and a
/// summary — nothing runs until the user presses Dispatch. Dispatch is headless
/// via the canonical uv-core entry (parseable run_id) and confirms IN the sheet
/// ("Dispatched ✓ run: …") so the user always knows whether it fired. Presented
/// as a `.sheet` (not a transient popover) so the "Choose…" NSOpenPanel can run
/// as a sheet-on-sheet without dismissing it and losing the chosen folder.
struct DispatchPopover: View {
  @ObservedObject var controller: AppController
  let intent: DispatchIntent
  let onRootSelected: (URL) -> Void
  let onClose: () -> Void

  @State private var agent: String
  @State private var workflow: String
  @State private var rootURL: URL
  @State private var hostWindow: NSWindow?
  @State private var phase: Phase = .configuring
  /// Swarm-only: the chosen report writer ("" = the workflow's own default,
  /// which launches with NO positional agent). Only offered when the
  /// descriptor declares the positional-synthesizer policy.
  @State private var synthesizer: String = ""
  /// Agent token to observe after a launch; nil for a default swarm run,
  /// which has no single agent to observe.
  @State private var observeAgent: String?

  enum Phase: Equatable {
    case configuring
    case dispatching
    case dispatched(runID: String?, reportPath: String?)
    case failed(String)
  }

  init(
    controller: AppController,
    intent: DispatchIntent,
    defaultRoot: URL,
    onRootSelected: @escaping (URL) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.controller = controller
    self.intent = intent
    self.onRootSelected = onRootSelected
    self.onClose = onClose
    // Agent defaults to codex (the ⇧⌘D default) whenever the fleet offers it;
    // the picker stays fully editable before Dispatch.
    let agents = controller.availableAgents
    self._agent = State(
      initialValue: agents.contains(controller.defaultAgent)
        ? controller.defaultAgent : (agents.first ?? controller.defaultAgent))
    // Workflow preselects whatever the user clicked to get here.
    self._workflow = State(
      initialValue: controller.agentWorkflows.contains(intent.workflow)
        ? intent.workflow : (controller.agentWorkflows.first ?? intent.workflow))
    self._rootURL = State(initialValue: defaultRoot)
  }

  private var isConfiguring: Bool {
    switch phase {
    case .configuring, .failed: return true
    case .dispatching, .dispatched: return false
    }
  }

  private var subjectDetail: String {
    switch intent.subject {
    case .savedDocument(let url), .fileURL(let url):
      return url.path
    case .unsavedBuffer:
      return "The draft's text is sent as the prompt."
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Dispatch to Agent")
        .font(.headline)

      VStack(alignment: .leading, spacing: 2) {
        Text("Subject").font(.caption).foregroundStyle(.secondary)
        Text(intent.subjectLabel)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .accessibilityIdentifier("pensieve.dispatch.subject")
        Text(subjectDetail)
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }

      agentSection

      VStack(alignment: .leading, spacing: 4) {
        Text("Path (where to run)").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          Text(rootURL.path)
            .font(.system(size: 11).monospaced())
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Choose…") { chooseRoot() }
            .disabled(!isConfiguring)
            .accessibilityIdentifier("pensieve.dispatch.chooseRoot")
        }
      }

      Picker("Workflow", selection: $workflow) {
        ForEach(controller.agentWorkflows, id: \.self) { Text($0).tag($0) }
      }
      .disabled(!isConfiguring)
      .accessibilityIdentifier("pensieve.dispatch.workflow")

      Divider()

      VStack(alignment: .leading, spacing: 2) {
        Text("Summary").font(.caption).foregroundStyle(.secondary)
        Text("\(workflow) · \(summaryAgentLabel)")
          .font(.system(size: 12, weight: .semibold))
          .accessibilityIdentifier("pensieve.dispatch.summaryAgents")
        Text("subject: \(intent.subjectLabel)")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Text("where: \(rootURL.lastPathComponent)")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }

      Divider()
      actionRow
    }
    .padding(16)
    .frame(width: 380)
    .background(WindowReader { hostWindow = $0 })
    .onAppear {
      controller.discoverAgents()
      // Fresh truth for THIS sheet session: a config edit between two sheet
      // presentations must never serve yesterday's swarm membership.
      controller.refreshWorkflowCapabilities(force: true)
    }
    .onChange(of: workflow) { synthesizer = "" }
  }

  // MARK: - Agent section (capability-truth driven)

  private var plan: WorkflowDispatchPlan {
    controller.dispatchPlan(for: workflow)
  }

  private var summaryAgentLabel: String {
    switch plan {
    case .singleAgent:
      return agent
    case .swarm(let swarm):
      let team = swarm.members.joined(separator: " + ")
      return synthesizer.isEmpty ? team : "\(team) · report: \(synthesizer)"
    case .loading, .unavailable:
      return "—"
    }
  }

  @ViewBuilder private var agentSection: some View {
    switch plan {
    case .singleAgent:
      Picker("Agent", selection: $agent) {
        ForEach(controller.availableAgents, id: \.self) { Text($0).tag($0) }
      }
      .disabled(!isConfiguring)
      .accessibilityIdentifier("pensieve.dispatch.agent")
    case .swarm(let swarm):
      swarmSection(swarm)
    case .loading:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Checking how \(workflow) runs…")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("pensieve.dispatch.capabilitiesLoading")
    case .unavailable(let reason):
      VStack(alignment: .leading, spacing: 4) {
        Text(reason)
          .font(.system(size: 11)).foregroundStyle(.red).lineLimit(4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("pensieve.dispatch.capabilitiesError")
        Button("Retry") { controller.refreshWorkflowCapabilities(force: true) }
          .accessibilityIdentifier("pensieve.dispatch.retryCapabilities")
      }
    }
  }

  private func swarmSection(_ swarm: SwarmDispatchPlan) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Agents").font(.caption).foregroundStyle(.secondary)
      Text(
        "Runs \(swarm.members.count) agents in parallel: "
          + swarm.members.joined(separator: ", ")
      )
      .font(.system(size: 12, weight: .semibold))
      .accessibilityIdentifier("pensieve.dispatch.swarmMembers")
      if let source = swarm.selectionSource, !source.isEmpty {
        Text("Agents set in \(source)")
          .font(.system(size: 10)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.head)
      }
      ForEach(swarm.unsupportedConfigured, id: \.self) { token in
        Label(
          "\(token) is configured but not supported — it won't run.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.system(size: 11)).foregroundStyle(.orange)
        .accessibilityIdentifier("pensieve.dispatch.unsupportedAgent.\(token)")
      }
      if swarm.synthesizerChoices.isEmpty {
        Text("Final report by \(swarm.defaultSynthesizerDescription).")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      } else {
        Picker("Final report by", selection: $synthesizer) {
          Text("Default (\(swarm.defaultSynthesizerDescription))").tag("")
          ForEach(swarm.synthesizerChoices, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!isConfiguring)
        .accessibilityIdentifier("pensieve.dispatch.synthesizer")
      }
    }
  }

  @ViewBuilder private var actionRow: some View {
    switch phase {
    case .configuring, .failed:
      if case .failed(let message) = phase {
        Text(message)
          .font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if intent.subjectIsEmpty {
        Text("This document is empty. Write something before dispatching.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("pensieve.dispatch.emptySubjectNote")
      }
      HStack {
        Spacer()
        Button("Cancel") { onClose() }
          .keyboardShortcut(.cancelAction)
        Button("Dispatch") {
          // Synchronous re-entry guard: flip to .dispatching in the tap handler
          // (not inside the async Task) so a fast double Return/click cannot
          // enqueue two launches before the first re-render hides the button —
          // one user intent must never spawn two agent runs.
          guard isConfiguring else { return }
          phase = .dispatching
          Task { await runDispatch() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(intent.subjectIsEmpty || !plan.isLaunchable)
        .accessibilityIdentifier("pensieve.dispatch.confirm")
      }
    case .dispatching:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Dispatching…").font(.system(size: 12))
        Spacer()
      }
    case .dispatched(let runID, let reportPath):
      VStack(alignment: .leading, spacing: 8) {
        Label(
          runID.map { "Dispatched ✓  run: \($0)" } ?? "Dispatched ✓",
          systemImage: "checkmark.seal.fill"
        )
        .foregroundStyle(.green)
        .font(.system(size: 12, weight: .semibold))
        .textSelection(.enabled)
        .accessibilityIdentifier("pensieve.dispatch.confirmed")
        HStack(spacing: 8) {
          if let reportPath {
            Button("Reveal report") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reportPath)])
            }
          }
          if let runID, let observeAgent {
            Button("Observe in Terminal") {
              controller.observeRunInTerminal(agent: observeAgent, runID: runID)
            }
          }
          Spacer()
          Button("Done") { onClose() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private func runDispatch() async {
    // phase is already .dispatching (set synchronously by the Dispatch button's
    // re-entry guard) before this Task runs.
    let agents: [String]
    switch plan {
    case .singleAgent:
      agents = [agent]
    case .swarm:
      agents = synthesizer.isEmpty ? [] : [synthesizer]
    case .loading, .unavailable:
      // The Dispatch button is disabled for these plans; if a race lands here
      // anyway, refuse in the UI — confirmDispatch would refuse too.
      phase = .failed("This workflow can't be dispatched right now.")
      return
    }
    observeAgent = agents.first
    let outcome = await controller.confirmDispatch(
      intent: intent, workflow: workflow, agents: agents, rootURL: rootURL)
    switch outcome {
    case .success(let runID, let reportPath, _):
      phase = .dispatched(runID: runID, reportPath: reportPath)
    case .failure(let message):
      phase = .failed(message)
    }
  }

  private func chooseRoot() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = rootURL
    panel.prompt = "Use as run root"
    let apply: (NSApplication.ModalResponse) -> Void = { response in
      if response == .OK, let url = panel.url {
        let standardizedURL = url.standardizedFileURL
        onRootSelected(standardizedURL)
        rootURL = standardizedURL
      }
    }
    // Present as a sheet on the dispatch sheet's own window so the dispatch UI is
    // NOT torn down (which would lose the chosen folder). runModal() is only the
    // fallback if the host window hasn't resolved yet.
    if let window = hostWindow {
      panel.beginSheetModal(for: window, completionHandler: apply)
    } else {
      apply(panel.runModal())
    }
  }
}

/// Reports the NSWindow hosting this SwiftUI view (the dispatch sheet's window)
/// so a child NSOpenPanel can be presented via beginSheetModal(for:) instead of
/// an app-modal runModal() that would steal key focus and dismiss the surface.
private struct WindowReader: NSViewRepresentable {
  let onResolve: (NSWindow) -> Void
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { if let window = view.window { onResolve(window) } }
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { if let window = nsView.window { onResolve(window) } }
  }
}
