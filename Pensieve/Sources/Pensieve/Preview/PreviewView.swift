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
  @Environment(AppState.self) private var appState
  @EnvironmentObject private var themeManager: ThemeManager
  private let scrollSyncCoordinator: ScrollSyncCoordinator?

  init(scrollSyncCoordinator: ScrollSyncCoordinator? = nil) {
    self.scrollSyncCoordinator = scrollSyncCoordinator
  }

  var body: some View {
    PreviewRepresentable(
      markdown: appState.activeDocumentText,
      fontSize: appState.fontSize,
      theme: themeManager.current,
      skin: themeManager.skin,
      themeManager: themeManager,
      documentURL: appState.activeDocumentURL,
      autoReload: appState.previewAutoReload,
      refreshToken: appState.previewRefreshToken,
      scrollSyncCoordinator: scrollSyncCoordinator
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Backdrop behind the transparent WebView. Tied to the theme surface so a
    // dark skin never flashes a light strip before the page paints, matching
    // the titlebar backing colour the recipe feeds the chrome.
    .background(
      Color(WindowChromeRecipe.titlebarGlassBackingColor(for: themeManager.skin))
        .ignoresSafeArea(.container, edges: .top)
    )
    .ignoresSafeArea(.container, edges: .top)
  }
}

// MARK: - NSViewRepresentable bridge

struct PreviewRepresentable: NSViewRepresentable {
  let markdown: String
  let fontSize: CGFloat
  let theme: ThemeManager.Theme
  let skin: PensieveTheme
  let themeManager: ThemeManager
  let documentURL: URL?
  let autoReload: Bool
  let refreshToken: Int
  let scrollSyncCoordinator: ScrollSyncCoordinator?

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
    Coordinator(themeManager: themeManager, scrollSyncCoordinator: scrollSyncCoordinator)
  }

  func makeNSView(context: Context) -> PreviewWebView {
    let view = PreviewWebView(frame: .zero)
    context.coordinator.attach(view: view)
    context.coordinator.submit(request: currentRequest, autoReload: autoReload, initial: true)
    return view
  }

  func updateNSView(_ nsView: PreviewWebView, context: Context) {
    context.coordinator.update(scrollSyncCoordinator: scrollSyncCoordinator)
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
      skin: skin,
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
    private weak var previewView: PreviewWebView?
    private var scrollSyncCoordinator: ScrollSyncCoordinator?
    private var lastAccepted: PreviewRenderRequest?

    init(
      themeManager: ThemeManager,
      scrollSyncCoordinator: ScrollSyncCoordinator? = nil
    ) {
      self.pipeline = PreviewPipeline(themeManager: themeManager)
      self.scrollSyncCoordinator = scrollSyncCoordinator
    }

    func attach(view: PreviewWebView) {
      previewView = view
      pipeline.attach(sink: view)
      scrollSyncCoordinator?.attachPreviewTarget(view)
    }

    func detach() {
      if let previewView {
        scrollSyncCoordinator?.detachPreviewTarget(previewView)
      }
      previewView = nil
      pipeline.detach()
    }

    func update(scrollSyncCoordinator nextCoordinator: ScrollSyncCoordinator?) {
      guard !sameCoordinator(as: nextCoordinator) else { return }
      if let previewView {
        scrollSyncCoordinator?.detachPreviewTarget(previewView)
      }
      scrollSyncCoordinator = nextCoordinator
      if let previewView {
        scrollSyncCoordinator?.attachPreviewTarget(previewView)
      }
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
    /// operator types or scrubs the slider. Theme, skin, documentURL, and
    /// refreshToken are operator-triggered control changes; those always
    /// pass through even when auto-reload is off.
    private func shouldGateUpdate(
      from previous: PreviewRenderRequest, to next: PreviewRenderRequest
    ) -> Bool {
      previous.theme == next.theme
        && previous.skin == next.skin
        && previous.documentURL == next.documentURL
        && previous.refreshToken == next.refreshToken
    }

    private func sameCoordinator(as other: ScrollSyncCoordinator?) -> Bool {
      guard let scrollSyncCoordinator else {
        return other == nil
      }
      guard let other else {
        return false
      }
      return scrollSyncCoordinator === other
    }
  }
}
