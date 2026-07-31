import AppKit
import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var appState
  @EnvironmentObject private var controller: AppController
  @EnvironmentObject private var themeManager: ThemeManager
  @ObservedObject private var providerOnboardingCoordinator: ProviderOnboardingCoordinator
  @Binding private var hostWindow: NSWindow?
  private let providerSettings: ProviderSettings

  @MainActor
  init(
    hostWindow: Binding<NSWindow?> = .constant(nil),
    providerSettings: ProviderSettings = .shared,
    providerOnboardingCoordinator: ProviderOnboardingCoordinator? = nil
  ) {
    _hostWindow = hostWindow
    self.providerSettings = providerSettings
    _providerOnboardingCoordinator = ObservedObject(
      wrappedValue: providerOnboardingCoordinator ?? .shared)
  }

  var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    } detail: {
      VStack(spacing: 0) {
        EditorPreviewSplit()
        if appState.documentHasEditableBuffer {
          EditorStatusBar()
            .opacity(appState.mode == .focus ? 0.45 : 1)
        }
      }
    }
    .navigationTitle(
      appState.documentHasEditableBuffer
        ? appState.documentTitle : "Pensieve"
    )
    // 5.2: the subtitle carries the document's breadcrumb path; the dirty
    // "Edited" state it used to hold now lives in the status bar's marker.
    .navigationSubtitle(
      appState.documentHasEditableBuffer
        ? EditorToolbelt.breadcrumbSubtitle(
          for: appState.documentURL, workspaceRoots: appState.workspaceRoots)
        : ""
    )
    .toolbar {
      EditorToolbelt(
        appState: appState,
        controller: controller,
        themeManager: themeManager,
        onDispatchToAgent: {
          controller.requestCurrentDocumentDispatch(workflow: "implement", source: .toolbar)
        },
        isDispatchDisabled:
          !appState.documentHasEditableBuffer
          || !SandboxCapabilities.allowsExternalAgentDispatch(),
        dispatchHelp:
          SandboxCapabilities.allowsExternalAgentDispatch()
          ? "Dispatch to Agent"
          : SandboxCapabilities.dispatchUnavailableExplanation)
    }
    // The ONE dispatch surface: every route (toolbar, Agents menu, sidebar)
    // lands as this window's pendingDispatchIntent and presents here, in the
    // window that raised it. `.sheet(item:)` keys presentation on the intent
    // itself, so a fresh request while the sheet is up swaps content instead
    // of queueing a second sheet (W2-G single-presentation discipline).
    .sheet(item: dispatchIntentBinding) { intent in
      DispatchPopover(
        controller: controller,
        intent: intent,
        defaultRoot: controller.defaultDispatchRoot(),
        onRootSelected: { appState.rememberDispatchRoot($0) },
        onClose: { appState.pendingDispatchIntent = nil }
      )
    }
    .sheet(isPresented: onboardingSheetBinding) {
      ProviderOnboardingView(isPresented: onboardingSheetBinding)
    }
    .onAppear {
      evaluateProviderOnboarding()
    }
    .onChange(of: hostWindow?.windowNumber) {
      evaluateProviderOnboarding()
    }
    .onChange(of: appState.aiAutocompleteEnabled) {
      providerOnboardingCoordinator.setAutocompleteEnabled(appState.aiAutocompleteEnabled)
      evaluateProviderOnboarding()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSWindow.didBecomeKeyNotification)
    ) { notification in
      guard let window = notification.object as? NSWindow,
        window === hostWindow
      else {
        return
      }
      evaluateProviderOnboarding()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: .completionProviderSettingsDidChange)
    ) { notification in
      guard let settings = notification.object as? ProviderSettings,
        settings === providerSettings
      else {
        return
      }
      providerOnboardingCoordinator.setProviderConfigured(providerSettings.isConfigured)
      evaluateProviderOnboarding()
    }
  }

  private var dispatchIntentBinding: Binding<DispatchIntent?> {
    Binding(
      get: { appState.pendingDispatchIntent },
      set: { appState.pendingDispatchIntent = $0 }
    )
  }

  private var onboardingSheetBinding: Binding<Bool> {
    Binding(
      get: { providerOnboardingCoordinator.isPresented(in: hostWindowID) },
      set: { isPresented in
        if !isPresented,
          providerOnboardingCoordinator.isPresented(in: hostWindowID)
        {
          providerOnboardingCoordinator.dismiss()
        }
      }
    )
  }

  private var hostWindowID: ObjectIdentifier? {
    hostWindow.map(ObjectIdentifier.init)
  }

  private func evaluateProviderOnboarding() {
    providerOnboardingCoordinator.initializeIfNeeded(
      autocompleteEnabled: appState.aiAutocompleteEnabled,
      providerConfigured: providerSettings.isConfigured)
    providerOnboardingCoordinator.evaluate(
      windowID: hostWindowID,
      isKeyWindow: hostWindow?.isKeyWindow == true)
  }
}

struct EditorPreviewSplit: View {
  @Environment(AppState.self) private var appState
  @State private var scrollSyncCoordinator = ScrollSyncCoordinator()

  /// Minimum pane width below which `.split` collapses to a single pane.
  /// Two panes × 260 + ~40 chrome = 560; below that, side-by-side stops
  /// being usable.
  static let narrowSplitThreshold: CGFloat = 580
  static let paneMinWidth: CGFloat = 260

  var body: some View {
    GeometryReader { geo in
      content(forWidth: geo.size.width)
    }
    .frame(
      minWidth: Self.paneMinWidth, maxWidth: .infinity,
      minHeight: 320, maxHeight: .infinity)
  }

  @ViewBuilder
  private func content(forWidth width: CGFloat) -> some View {
    if !appState.documentHasEditableBuffer {
      DocumentEmptyStateView()
    } else {
      switch appState.mode {
      case .source:
        EditorView()
      case .focus:
        FocusedEditorView()
      case .preview:
        PreviewView()
      case .split:
        if width < Self.narrowSplitThreshold {
          // Window is too narrow for a real two-pane view; honor the
          // editor as source-of-truth. User can switch to .preview to
          // see rendered output.
          EditorView()
        } else {
          // Both panes claim an equal ideal share of the window: NSSplitView
          // seeds the divider from the subviews' ideal widths, and without an
          // explicit ideal the editor's and preview's intrinsic sizes fight —
          // whichever wins collapses the other pane to its minimum.
          HSplitView {
            EditorView(scrollSyncCoordinator: scrollSyncCoordinator)
              .frame(minWidth: Self.paneMinWidth, idealWidth: width / 2, maxWidth: .infinity)
            PreviewView(scrollSyncCoordinator: scrollSyncCoordinator)
              .frame(minWidth: Self.paneMinWidth, idealWidth: width / 2, maxWidth: .infinity)
          }
        }
      }
    }
  }
}

private struct FocusedEditorView: View {
  var body: some View {
    EditorView()
      .overlay {
        FocusModeDimmingOverlay()
          .allowsHitTesting(false)
      }
      .accessibilityIdentifier("pensieve.focus.editor")
  }
}

private struct FocusModeDimmingOverlay: View {
  var body: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [Color.black.opacity(0.10), Color.black.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 88)

      Spacer(minLength: 0)

      LinearGradient(
        colors: [Color.black.opacity(0), Color.black.opacity(0.08)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: 96)
    }
    .accessibilityIdentifier("pensieve.focus.dimming")
  }
}

/// Detail-pane placeholder shown when no document session is active. Reached
/// from a fresh launch with no restored selection, after File > Close, or
/// after the workspace is cleared. The window stays alive; this view is the
/// thing the operator sees instead of stale editor/preview state.
struct DocumentEmptyStateView: View {
  @EnvironmentObject private var controller: AppController
  @EnvironmentObject private var themeManager: ThemeManager

  var body: some View {
    // This placeholder occupies the document pane, so it dresses from the active
    // skin's surface — the same token the editor pane and the titlebar glass
    // backing already use. `windowBackgroundColor` painted a system-grey pane
    // that ignored the theme (parchment: cream titlebar, grey body) and stayed
    // put on a skin switch.
    let palette = EmptyStatePalette(theme: themeManager.skin)
    VStack(spacing: 26) {
      EmptyStateWordmark(size: 40, palette: palette)

      EmptyStateShortcuts(palette: palette)

      EmptyStateRecents(store: controller.recentDocuments)

      Text(BuildIdentity.current.conciseLabel)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityIdentifier("pensieve.emptyState.buildIdentity")
    }
    // The hierarchical levels the shared chrome asks for (`.secondary` labels,
    // the `.tertiary` build line) resolve against these, so every glyph on the
    // pane comes from the skin instead of the system label colours — which, on a
    // skin whose surface disagrees with its pinned appearance, land unreadable.
    .foregroundStyle(
      Color(palette.primaryText),
      Color(palette.secondaryText),
      Color(palette.tertiaryText)
    )
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(palette.background).ignoresSafeArea(.container, edges: .top))
    .ignoresSafeArea(.container, edges: .top)
    .accessibilityIdentifier("pensieve.emptyState")
  }
}
