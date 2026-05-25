import AppKit
import SwiftUI
import WebKit

// MARK: - SwiftUI surface

/// SwiftUI entry point for the preview pane.
///
/// The full pipeline is wired in `PreviewPipeline`:
///
///     PreviewRenderRequest -> PreviewPipeline (schedule)
///                          -> PreviewDocument (compose)
///                          -> PreviewWebView (sink)
///
/// `PreviewView` only translates `AppState` into render requests; the
/// scheduling and document construction live in `PreviewPipeline`. The
/// `ThemeManager` is owned by `PensieveApp` and injected as an
/// `EnvironmentObject` so the toolbar theme picker, the preview pane, and
/// any future side surfaces all see the same selection.
struct PreviewView: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var themeManager: ThemeManager

  var body: some View {
    PreviewRepresentable(
      markdown: appState.activeDocumentText,
      fontSize: appState.fontSize,
      theme: themeManager.current,
      themeManager: themeManager,
      documentURL: appState.activeDocumentURL,
      autoReload: appState.previewAutoReload,
      refreshToken: appState.previewRefreshToken
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(NSColor.textBackgroundColor))
  }
}

// MARK: - NSViewRepresentable bridge

struct PreviewRepresentable: NSViewRepresentable {
  let markdown: String
  let fontSize: CGFloat
  let theme: ThemeManager.Theme
  let themeManager: ThemeManager
  let documentURL: URL?
  let autoReload: Bool
  let refreshToken: Int

  /// Base URL for relative resource resolution inside the preview WebView.
  /// File-first markdown: relative images/links belong to the note's folder.
  /// Falls back to the preview resource bundle so a fresh app (no document
  /// loaded) is still well-defined without invoking SwiftPM's crash-prone
  /// `Bundle.module` accessor in packaged apps.
  static func resolveBaseURL(for documentURL: URL?) -> URL? {
    if let documentURL {
      return documentURL.deletingLastPathComponent()
    }
    return PreviewResourceLocator.fallbackBaseURL()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(themeManager: themeManager)
  }

  func makeNSView(context: Context) -> PreviewWebView {
    let view = PreviewWebView(frame: .zero)
    context.coordinator.attach(view: view)
    context.coordinator.submit(request: currentRequest, autoReload: autoReload, initial: true)
    return view
  }

  func updateNSView(_ nsView: PreviewWebView, context: Context) {
    context.coordinator.submit(request: currentRequest, autoReload: autoReload, initial: false)
  }

  static func dismantleNSView(_ nsView: PreviewWebView, coordinator: Coordinator) {
    coordinator.detach()
  }

  private var currentRequest: PreviewRenderRequest {
    PreviewRenderRequest(
      markdown: markdown,
      fontSize: fontSize,
      theme: theme,
      documentURL: documentURL,
      refreshToken: refreshToken
    )
  }

  // MARK: - Coordinator

  /// Thin NSViewRepresentable lifecycle adapter. The actual scheduling,
  /// rendering, and document composition live in `PreviewPipeline`. When
  /// auto-reload is off, the coordinator gates new requests so live editor
  /// text mutations no longer reach the pipeline; theme switches, font-size
  /// changes, document switches, and explicit refresh-token bumps always
  /// pass through.
  final class Coordinator {
    let pipeline: PreviewPipeline
    private var lastAccepted: PreviewRenderRequest?

    init(themeManager: ThemeManager) {
      self.pipeline = PreviewPipeline(themeManager: themeManager)
    }

    func attach(view: PreviewWebView) {
      pipeline.attach(sink: view)
    }

    func detach() {
      pipeline.detach()
    }

    func submit(request: PreviewRenderRequest, autoReload: Bool, initial: Bool) {
      if !autoReload, let last = lastAccepted, shouldGateUpdate(from: last, to: request) {
        return
      }
      lastAccepted = request
      pipeline.submit(request, initial: initial)
    }

    /// True when the only difference between `previous` and `next` is the
    /// markdown payload or font size — the parts that live-stream as the
    /// operator types or scrubs the slider. Theme, documentURL, and
    /// refreshToken are operator-triggered control changes; those always
    /// pass through even when auto-reload is off.
    private func shouldGateUpdate(
      from previous: PreviewRenderRequest, to next: PreviewRenderRequest
    ) -> Bool {
      previous.theme == next.theme
        && previous.documentURL == next.documentURL
        && previous.refreshToken == next.refreshToken
    }
  }
}
