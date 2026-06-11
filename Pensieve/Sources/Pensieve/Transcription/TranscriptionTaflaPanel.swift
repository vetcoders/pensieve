import AppKit
import SwiftUI

@MainActor
final class TranscriptionTaflaPanelController: NSObject, NSWindowDelegate {
  var onVisibilityChanged: (() -> Void)?

  private let service: TranscriptionService
  private let routingState = TranscriptionTaflaRoutingState()
  private let onSend: (TranscriptionSendTarget) -> Bool
  private var panel: NSPanel?
  private var sendEventMonitor: Any?

  init(
    service: TranscriptionService,
    onSend: @escaping (TranscriptionSendTarget) -> Bool = { _ in false }
  ) {
    self.service = service
    self.onSend = onSend
  }

  deinit {
    if let sendEventMonitor {
      NSEvent.removeMonitor(sendEventMonitor)
    }
  }

  var isVisible: Bool {
    panel?.isVisible == true
  }

  func toggle() {
    isVisible ? hide() : show()
  }

  func show() {
    let panel = panel ?? makePanel()
    self.panel = panel
    panel.orderFront(nil)
    installSendEventMonitor()
    onVisibilityChanged?()
  }

  func hide() {
    panel?.orderOut(nil)
    removeSendEventMonitor()
    onVisibilityChanged?()
  }

  func windowWillClose(_ notification: Notification) {
    removeSendEventMonitor()
    onVisibilityChanged?()
  }

  func makePanelForTesting() -> NSPanel {
    makePanel()
  }

  private func makePanel() -> NSPanel {
    let panel = NonActivatingTaflaPanel(
      contentRect: NSRect(x: 160, y: 160, width: 520, height: 360),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = "Tafla"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 360, height: 240)
    panel.backgroundColor = .clear
    panel.isOpaque = false

    let root = TranscriptionTaflaPanelView(
      service: service,
      routingState: routingState,
      onSend: { [weak self] target in self?.sendComposition(target: target) == true },
      onClose: { [weak panel, weak self] in
        panel?.orderOut(nil)
        self?.removeSendEventMonitor()
        self?.onVisibilityChanged?()
      }
    )
    let hostingView = NSHostingView(rootView: root)
    hostingView.setAccessibilityIdentifier("pensieve.tafla.panel")
    panel.contentView = hostingView
    return panel
  }

  private func sendComposition(target: TranscriptionSendTarget) -> Bool {
    onSend(target)
  }

  private func installSendEventMonitor() {
    guard sendEventMonitor == nil else { return }
    sendEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isVisible else { return event }
      guard event.keyCode == 36 else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard flags.contains(.shift) else { return event }
      // Agent dispatch is click-only by design; the hotkey sends only to the editor.
      guard self.routingState.sendTarget == .editor else { return event }
      return self.sendComposition(target: self.routingState.sendTarget) ? nil : event
    }
  }

  private func removeSendEventMonitor() {
    if let sendEventMonitor {
      NSEvent.removeMonitor(sendEventMonitor)
    }
    sendEventMonitor = nil
  }
}

private final class NonActivatingTaflaPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
private final class TranscriptionTaflaRoutingState: ObservableObject {
  @Published var formatMode: TranscriptionFormatMode = .polish
  @Published var sendTarget: TranscriptionSendTarget = .editor
}

private struct TranscriptionTaflaPanelView: View {
  @ObservedObject var service: TranscriptionService
  @ObservedObject var routingState: TranscriptionTaflaRoutingState
  let onSend: (TranscriptionSendTarget) -> Bool
  let onClose: () -> Void

  @State private var controlError: String?
  @State private var isFormatting = false

  var body: some View {
    ZStack {
      TaflaVisualEffect()
      VStack(alignment: .leading, spacing: 12) {
        header
        modeControls
        transcript
        footer
      }
      .padding(16)
    }
    .frame(minWidth: 360, minHeight: 240)
    .accessibilityIdentifier("pensieve.tafla.root")
  }

  private var modeControls: some View {
    HStack(spacing: 12) {
      Picker("Format", selection: $routingState.formatMode) {
        ForEach(TranscriptionFormatMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 168)
      .accessibilityIdentifier("pensieve.tafla.mode")

      Picker("Target", selection: $routingState.sendTarget) {
        ForEach(TranscriptionSendTarget.allCases) { target in
          Text(target.title).tag(target)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 244)
      .accessibilityIdentifier("pensieve.tafla.target")

      Spacer()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Label("Tafla", systemImage: service.isRecording ? "waveform.circle.fill" : "waveform.circle")
        .font(.headline)
        .accessibilityIdentifier("pensieve.tafla.title")

      Spacer()

      Button(action: start) {
        if service.isPreparingRecording {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "mic.fill")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(service.isRecording || service.isPreparingRecording)
      .help(service.isPreparingRecording ? "Loading speech model…" : "Start Recording")
      .accessibilityIdentifier("pensieve.tafla.start")

      Button(action: stop) {
        Image(systemName: "stop.fill")
      }
      .buttonStyle(.bordered)
      // Enabled during Preparing too: a slow/hung model load must stay
      // cancellable, otherwise the panel has no control to leave that state.
      .disabled(!service.isRecording && !service.isPreparingRecording)
      .help(service.isPreparingRecording ? "Cancel Preparation" : "Stop Recording")
      .accessibilityIdentifier("pensieve.tafla.stop")

      Button(action: reset) {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(.bordered)
      .help("Reset Transcript")
      .accessibilityIdentifier("pensieve.tafla.reset")

      Button(action: format) {
        Image(systemName: formatSystemImageName)
      }
      .buttonStyle(.bordered)
      .disabled(!service.hasComposedText || isFormatting || service.isFormatting)
      .help("Format Transcript")
      .accessibilityIdentifier("pensieve.tafla.format")

      Button(action: copyTranscript) {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(.bordered)
      .disabled(!service.hasComposedText)
      .help("Copy Transcript")
      .accessibilityIdentifier("pensieve.tafla.copy")

      Button(action: send) {
        Image(systemName: "paperplane.fill")
      }
      .buttonStyle(.borderedProminent)
      .disabled(!service.hasComposedText)
      .help("Send Transcript")
      .accessibilityIdentifier("pensieve.tafla.send")

      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Hide Tafla")
      .accessibilityIdentifier("pensieve.tafla.close")
    }
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Text(service.rendered)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)
          .id("pensieve.tafla.transcript.bottom")
      }
      .background(Color(NSColor.textBackgroundColor).opacity(0.58))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
      .accessibilityIdentifier("pensieve.tafla.transcript")
      .onChange(of: service.rendered) { _ in
        proxy.scrollTo("pensieve.tafla.transcript.bottom", anchor: .bottom)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(service.isRecording ? Color.red : Color.secondary.opacity(0.55))
        .frame(width: 8, height: 8)
        .accessibilityIdentifier("pensieve.tafla.recordingIndicator")

      Text(statusText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("pensieve.tafla.status")

      Spacer()

      if let errorText {
        Text(errorText)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier("pensieve.tafla.error")
      }
    }
  }

  private var statusText: String {
    if let dispatchStatus = service.dispatchStatus {
      return dispatchStatus
    }
    let recordingState =
      service.isPreparingRecording ? "Preparing" : (service.isRecording ? "Recording" : "Idle")
    guard let lastStatus = service.lastStatus else { return recordingState }
    return "\(recordingState) - \(lastStatus.label)"
  }

  private var errorText: String? {
    controlError ?? service.lastError
  }

  private var formatSystemImageName: String {
    isFormatting || service.isFormatting ? "wand.and.stars.inverse" : "wand.and.stars"
  }

  private func start() {
    // Model init + capture start run in the background; failures surface
    // through service.lastError (already part of errorText).
    service.startRecording()
    controlError = nil
  }

  private func stop() {
    if service.isPreparingRecording {
      service.cancelPreparation()
      controlError = nil
      return
    }
    do {
      _ = try service.stopRecording()
      controlError = nil
    } catch {
      controlError = error.localizedDescription
    }
  }

  private func reset() {
    service.resetTranscript()
    controlError = nil
  }

  private func format() {
    isFormatting = true
    Task {
      _ = await service.formatComposition(mode: routingState.formatMode)
      isFormatting = false
      controlError = service.lastError
    }
  }

  private func copyTranscript() {
    let text = service.rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    controlError = nil
  }

  private func send() {
    if onSend(routingState.sendTarget) {
      controlError = nil
    } else {
      controlError = routingState.sendTarget.failureMessage
    }
  }
}

private struct TaflaVisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension VistaStatusSignal {
  fileprivate var label: String {
    switch self {
    case .thinking:
      return "Thinking"
    case .error:
      return "Error"
    }
  }
}
