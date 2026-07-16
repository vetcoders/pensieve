import AppKit
import SwiftUI

/// Dispatch configuration SHEET for the toolbar ✈ button.
///
/// Flow (operator spec): Agent (discovered) → Path (WHERE to run) → Workflow →
/// summary → Dispatch. The PLAN is always the currently-open document; `rootURL`
/// only chooses WHERE the agent runs. Dispatch is headless via the canonical
/// uv-core entry (parseable run_id) and confirms IN the sheet ("Dispatched ✓
/// run: …") so the user always knows whether it fired. Presented as a `.sheet`
/// (not a transient popover) so the "Choose…" NSOpenPanel can run as a
/// sheet-on-sheet without dismissing it and losing the chosen folder.
struct DispatchPopover: View {
  @ObservedObject var controller: AppController
  @Binding var isPresented: Bool
  let documentTitle: String
  let onRootSelected: (URL) -> Void

  @State private var agent: String
  @State private var workflow: String
  @State private var rootURL: URL
  @State private var hostWindow: NSWindow?
  @State private var phase: Phase = .configuring

  enum Phase: Equatable {
    case configuring
    case dispatching
    case dispatched(runID: String?, reportPath: String?)
    case failed(String)
  }

  init(
    controller: AppController,
    isPresented: Binding<Bool>,
    documentTitle: String,
    defaultRoot: URL,
    onRootSelected: @escaping (URL) -> Void
  ) {
    self.controller = controller
    self._isPresented = isPresented
    self.documentTitle = documentTitle
    self.onRootSelected = onRootSelected
    self._agent = State(initialValue: controller.availableAgents.first ?? "codex")
    self._workflow = State(
      initialValue: controller.agentWorkflows.contains("implement")
        ? "implement" : (controller.agentWorkflows.first ?? "implement"))
    self._rootURL = State(initialValue: defaultRoot)
  }

  private var isConfiguring: Bool {
    switch phase {
    case .configuring, .failed: return true
    case .dispatching, .dispatched: return false
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Dispatch to Agent")
        .font(.headline)

      Picker("Agent", selection: $agent) {
        ForEach(controller.availableAgents, id: \.self) { Text($0).tag($0) }
      }
      .disabled(!isConfiguring)
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
        Text("\(workflow) · \(agent)")
          .font(.system(size: 12, weight: .semibold))
        Text("plan: \(documentTitle)")
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
    .onAppear { controller.discoverAgents() }
  }

  @ViewBuilder private var actionRow: some View {
    switch phase {
    case .configuring, .failed:
      if case .failed(let message) = phase {
        Text(message)
          .font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
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
          if let runID {
            Button("Observe in Terminal") {
              controller.observeRunInTerminal(agent: agent, runID: runID)
            }
          }
          Spacer()
          Button("Done") { isPresented = false }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private func runDispatch() async {
    // phase is already .dispatching (set synchronously by the Dispatch button's
    // re-entry guard) before this Task runs.
    let outcome = await controller.dispatchOpenDocument(
      workflow: workflow, agent: agent, rootURL: rootURL)
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
