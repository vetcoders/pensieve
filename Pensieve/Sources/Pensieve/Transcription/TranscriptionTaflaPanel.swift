import AppKit
import SwiftUI

@MainActor
final class TranscriptionTaflaPanelController: NSObject, NSWindowDelegate {
  var onVisibilityChanged: (() -> Void)?

  private let service: TranscriptionService
  private var panel: NSPanel?

  init(service: TranscriptionService) {
    self.service = service
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
    panel.orderFrontRegardless()
    onVisibilityChanged?()
  }

  func hide() {
    panel?.orderOut(nil)
    onVisibilityChanged?()
  }

  func windowWillClose(_ notification: Notification) {
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
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.minSize = NSSize(width: 360, height: 240)
    panel.backgroundColor = .clear
    panel.isOpaque = false

    let root = TranscriptionTaflaPanelView(
      service: service,
      onClose: { [weak panel, weak self] in
        panel?.orderOut(nil)
        self?.onVisibilityChanged?()
      }
    )
    let hostingView = NSHostingView(rootView: root)
    hostingView.setAccessibilityIdentifier("pensieve.tafla.panel")
    panel.contentView = hostingView
    return panel
  }
}

private final class NonActivatingTaflaPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private struct TranscriptionTaflaPanelView: View {
  @ObservedObject var service: TranscriptionService
  let onClose: () -> Void

  @State private var controlError: String?

  var body: some View {
    ZStack {
      TaflaVisualEffect()
      VStack(alignment: .leading, spacing: 12) {
        header
        transcript
        footer
      }
      .padding(16)
    }
    .frame(minWidth: 360, minHeight: 240)
    .accessibilityIdentifier("pensieve.tafla.root")
  }

  private var header: some View {
    HStack(spacing: 10) {
      Label("Tafla", systemImage: service.isRecording ? "waveform.circle.fill" : "waveform.circle")
        .font(.headline)
        .accessibilityIdentifier("pensieve.tafla.title")

      Spacer()

      Button(action: start) {
        Image(systemName: "mic.fill")
      }
      .buttonStyle(.borderedProminent)
      .disabled(service.isRecording)
      .help("Start Recording")
      .accessibilityIdentifier("pensieve.tafla.start")

      Button(action: stop) {
        Image(systemName: "stop.fill")
      }
      .buttonStyle(.bordered)
      .disabled(!service.isRecording)
      .help("Stop Recording")
      .accessibilityIdentifier("pensieve.tafla.stop")

      Button(action: reset) {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(.bordered)
      .help("Reset Transcript")
      .accessibilityIdentifier("pensieve.tafla.reset")

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
    let recordingState = service.isRecording ? "Recording" : "Idle"
    guard let lastStatus = service.lastStatus else { return recordingState }
    return "\(recordingState) - \(lastStatus.label)"
  }

  private var errorText: String? {
    controlError ?? service.lastError
  }

  private func start() {
    do {
      try service.startRecording()
      controlError = nil
    } catch {
      controlError = error.localizedDescription
    }
  }

  private func stop() {
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
