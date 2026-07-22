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
      contentRect: NSRect(x: 160, y: 160, width: 720, height: 520),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = "Dictation"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 560, height: 420)
    panel.contentMinSize = NSSize(width: 560, height: 420)
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
    // Match CodeScribe's proven floating-panel host: the window owns its size,
    // while an absolute frame sync keeps SwiftUI from exporting changing
    // fitting-size constraints back into the resizable panel.
    hostingView.sizingOptions = []
    hostingView.translatesAutoresizingMaskIntoConstraints = true
    hostingView.autoresizingMask = []
    let contentContainer = TaflaContentContainer(hostingView: hostingView)
    contentContainer.setAccessibilityIdentifier("pensieve.dictation.panel")
    contentContainer.setAccessibilityRole(.group)
    contentContainer.setAccessibilityLabel("Dictation controls")
    contentContainer.setAccessibilityHelp(
      "Record speech, review the transcript, and insert it into the active document."
    )
    panel.contentView = contentContainer
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
  // A non-activating panel can still become key for its own controls. Without
  // this, pickers, selectable transcript text, and buttons present as live but
  // cannot reliably receive keyboard/click interaction.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class TaflaContentContainer: NSView {
  private let hostingView: NSView

  init(hostingView: NSView) {
    self.hostingView = hostingView
    super.init(frame: .zero)
    addSubview(hostingView)
    hostingView.frame = bounds
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    hostingView.frame = bounds
  }

  override func layout() {
    super.layout()
    hostingView.frame = bounds
  }
}

@MainActor
private final class TranscriptionTaflaRoutingState: ObservableObject {
  @Published var language: TranscriptionLanguageChoice = .automatic
  @Published var formatMode: TranscriptionFormatMode = .cleanUp
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
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        modeControls
        transcript
        actionBar
        footer
      }
      .padding(20)
    }
    .frame(minWidth: 520, minHeight: 380)
    .accessibilityIdentifier("pensieve.dictation.root")
  }

  private var modeControls: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Language")
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("Recognition language", selection: $routingState.language) {
          ForEach(TranscriptionLanguageChoice.allCases) { language in
            Text(language.title).tag(language)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(service.isRecording || service.isPreparingRecording)
        .accessibilityIdentifier("pensieve.dictation.language")
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 6) {
        Text("AI action")
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("AI action", selection: $routingState.formatMode) {
          ForEach(TranscriptionFormatMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier("pensieve.dictation.mode")

        Text(routingState.formatMode.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pensieve.dictation.modeDescription")
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 6) {
        Text("Send result to")
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("Send result to", selection: $routingState.sendTarget) {
          ForEach(TranscriptionSendTarget.allCases) { target in
            Text(target.title).tag(target)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier("pensieve.dictation.target")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(12)
    .background {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(NSColor.controlBackgroundColor).opacity(0.62))
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Label(
          "Dictation",
          systemImage: service.isRecording ? "waveform.circle.fill" : "waveform.circle"
        )
        .font(.title3.weight(.semibold))
        .accessibilityIdentifier("pensieve.dictation.title")

        Text("Record speech, clean it up for the editor, or send it to an agent.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 16)

      Button(action: start) {
        HStack(spacing: 6) {
          if service.isPreparingRecording {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "mic.fill")
          }
          Text(service.isPreparingRecording ? "Preparing…" : "Record")
        }
      }
      .buttonStyle(.borderedProminent)
      .frame(minWidth: 92)
      .disabled(service.isRecording || service.isPreparingRecording)
      .help(service.isPreparingRecording ? "Loading speech model…" : "Start Recording")
      .accessibilityIdentifier("pensieve.dictation.start")

      Button(action: stop) {
        Label(service.isPreparingRecording ? "Cancel" : "Stop", systemImage: "stop.fill")
      }
      .buttonStyle(.bordered)
      // Enabled during Preparing too: a slow/hung model load must stay
      // cancellable, otherwise the panel has no control to leave that state.
      .disabled(!service.isRecording && !service.isPreparingRecording)
      .help(service.isPreparingRecording ? "Cancel Preparation" : "Stop Recording")
      .accessibilityIdentifier("pensieve.dictation.stop")

      Divider()
        .frame(height: 24)

      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Hide Dictation")
      .accessibilityIdentifier("pensieve.dictation.close")
    }
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        Group {
          if service.rendered.isEmpty {
            Text("Your live transcript will appear here.")
              .foregroundStyle(.secondary)
          } else {
            Text(service.rendered)
              .foregroundStyle(.primary)
              .textSelection(.enabled)
          }
        }
        .font(.system(.body, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .id("pensieve.dictation.transcript.bottom")
      }
      .background(Color(NSColor.textBackgroundColor).opacity(0.58))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
      .accessibilityIdentifier("pensieve.dictation.transcript")
      .onChange(of: service.rendered) {
        proxy.scrollTo("pensieve.dictation.transcript.bottom", anchor: .bottom)
      }
    }
  }

  private var actionBar: some View {
    HStack(spacing: 10) {
      Button(action: reset) {
        Label("Clear", systemImage: "arrow.counterclockwise")
      }
      .buttonStyle(.bordered)
      .help("Reset Transcript")
      .accessibilityIdentifier("pensieve.dictation.reset")

      Button(action: format) {
        Label(
          isFormatting || service.isFormatting
            ? "Working…" : routingState.formatMode.actionTitle,
          systemImage: formatSystemImageName
        )
      }
      .buttonStyle(.bordered)
      .disabled(
        !service.hasComposedText || !service.isFormattingAvailable || isFormatting
          || service.isFormatting
      )
      .help(formatActionHelp)
      .accessibilityIdentifier("pensieve.dictation.format")

      Button(action: copyTranscript) {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .buttonStyle(.bordered)
      .disabled(!service.hasComposedText)
      .help("Copy Transcript")
      .accessibilityIdentifier("pensieve.dictation.copy")

      Spacer(minLength: 12)

      Button(action: send) {
        Label(
          routingState.sendTarget.actionTitle,
          systemImage: routingState.sendTarget.actionSystemImageName)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!service.hasComposedText)
      .help(routingState.sendTarget.actionHelp)
      .accessibilityIdentifier("pensieve.dictation.send")
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(service.isRecording ? Color.red : Color.secondary.opacity(0.55))
        .frame(width: 8, height: 8)
        .accessibilityIdentifier("pensieve.dictation.recordingIndicator")

      Text(statusText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("pensieve.dictation.status")

      Spacer()

      if let errorText {
        Text(errorText)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier("pensieve.dictation.error")
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

  private var formatActionHelp: String {
    guard service.isFormattingAvailable else {
      return "Configure an AI provider in Settings to use this action."
    }
    return routingState.formatMode.detail
  }

  private func start() {
    // Model init + capture start run in the background; failures surface
    // through service.lastError (already part of errorText).
    service.startRecording(language: routingState.language.engineIdentifier)
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
