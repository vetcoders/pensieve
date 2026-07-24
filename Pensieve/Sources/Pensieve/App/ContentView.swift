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
    .navigationSubtitle(appState.documentIsDirty ? "Edited" : "")
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
      DocumentEmptyStateView(
        hasWorkspace: appState.hasWorkspaceContent
      )
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
  let hasWorkspace: Bool

  var body: some View {
    VStack(spacing: 18) {
      VStack(spacing: 12) {
        Image(systemName: "doc.text")
          .font(.system(size: 48, weight: .light))
          .foregroundStyle(.tertiary)

        Text("No Document Open")
          .font(.title2)
          .foregroundStyle(.secondary)

        Text(secondaryMessage)
          .font(.callout)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
          .accessibilityIdentifier("pensieve.emptyState.message")

        Text(BuildIdentity.current.conciseLabel)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .accessibilityIdentifier("pensieve.emptyState.buildIdentity")
      }

      RecoveredDraftsSection()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea(.container, edges: .top))
    .ignoresSafeArea(.container, edges: .top)
    // The launcher is the only place a crash draft can be reached, so it reads
    // the recovery directory every time it comes back on screen — including
    // after a Close, which is exactly when a draft may have just been retired.
    .onAppear { controller.refreshRecoveredDrafts() }
    .accessibilityIdentifier("pensieve.emptyState")
  }

  private var secondaryMessage: String {
    if hasWorkspace {
      return "Pick a note in the sidebar, or open a Markdown file from File ▸ Open."
    }
    return "Open a Markdown file or folder from the File menu to get started."
  }
}

/// The ONE way a crash-recovery draft reaches a window. Nothing adopts a draft
/// automatically any more (W2-D): unsaved work from a crash waits here, in the
/// empty launcher, until the user opens, saves, or discards it.
///
/// Deliberately quiet — it is a footnote under the empty state, and it renders
/// nothing at all when there is no unhandled draft, which is the normal case.
struct RecoveredDraftsSection: View {
  @EnvironmentObject private var controller: AppController

  var body: some View {
    // Nothing to recover renders NOTHING — not even a header. An always-visible
    // "0 drafts" row would turn the ordinary launcher into a permanent crash
    // reminder.
    if !controller.recoveredDrafts.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Recovered Drafts")
          .font(.headline)
          .foregroundStyle(.secondary)

        ForEach(controller.recoveredDrafts) { draft in
          RecoveredDraftRow(draft: draft)
        }
      }
      .padding(16)
      .frame(maxWidth: 460)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(NSColor.controlBackgroundColor))
      )
      .accessibilityIdentifier("pensieve.recoveredDrafts")
    }
  }
}

private struct RecoveredDraftRow: View {
  @EnvironmentObject private var controller: AppController
  let draft: RecoveryDraft

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(draft.title)
          .font(.callout)
          .lineLimit(1)
        Text(draft.previewSnippet)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 6) {
        Button("Open") { controller.openRecoveredDraft(draft) }
        Button("Save As…") { controller.saveRecoveredDraftAs(draft) }
        Button("Discard") { controller.discardRecoveredDraft(draft) }
      }
      .controlSize(.small)
    }
    .accessibilityIdentifier("pensieve.recoveredDrafts.row")
  }
}
