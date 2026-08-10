import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        if let sourceURL = appState.documentSession.recoverySourceURL {
          RecoveredFileBanner(
            sourceURL: sourceURL,
            saveToOriginal: { controller.saveActiveDocument() },
            saveAs: { saveRecoveredFileAs() }
          )
        }
        EditorPreviewSplit()
        // Deliberately OUTSIDE the buffer gate below: the errors that most need
        // saying (a workspace that will not open, a file that has moved, a
        // recovery draft that could not be written) can all land in a window
        // with nothing open, where the status bar does not exist.
        if case .banner(let error) = WindowErrorSurface.resolve(for: appState.currentError) {
          WindowErrorBanner(error: error) { appState.dismissVisibleError() }
        }
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
    .toolbar { toolbelt }
    // The clipped-items ("»") menu the bridge cannot build on its own. Anchored
    // in the content, not the toolbar: a clipped item leaves the view tree, so a
    // sink living inside the toolbar would stop running exactly when the
    // overflow menu becomes the only way to reach a family.
    .background(ToolbarOverflowSink(families: toolbelt.overflowFamilies))
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
    .onChange(of: providerOnboardingCoordinator.startupRestoreInProgress) {
      _, restoreInProgress in
      if !restoreInProgress {
        evaluateProviderOnboarding()
      }
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

  /// Built once per pass and used twice — as the toolbar's content and as the
  /// source of its overflow menu — so the two can never describe different
  /// toolbars.
  private var toolbelt: EditorToolbelt {
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

  private func saveRecoveredFileAs() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [
      UTType(filenameExtension: "md"),
      UTType(filenameExtension: "markdown"),
      .plainText,
    ].compactMap { $0 }
    panel.canCreateDirectories = true
    panel.directoryURL = appState.documentSession.recoverySourceURL?.deletingLastPathComponent()
    panel.nameFieldStringValue =
      appState.documentSession.recoverySourceURL?.lastPathComponent ?? "Recovered.md"
    panel.prompt = "Save"
    if panel.runModal() == .OK, let url = panel.url {
      controller.saveActiveDocument(as: url)
    }
  }
}

private struct RecoveredFileBanner: View {
  let sourceURL: URL
  let saveToOriginal: () -> Void
  let saveAs: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "lifepreserver")
      VStack(alignment: .leading, spacing: 2) {
        Text("Recovered unsaved changes")
          .font(.callout.weight(.semibold))
        Text(sourceURL.path)
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
        Text("The original file has not been overwritten.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Save to Original", action: saveToOriginal)
      Button("Save As…", action: saveAs)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.orange.opacity(0.12))
    .accessibilityIdentifier("pensieve.recoveredFile.banner")
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
    // Ahead of the empty state, because a staged open is bufferless too and the
    // two must not look the same: one window is idle, the other is working on a
    // file the user just asked for.
    if appState.documentIsLoading {
      DocumentOpeningView(title: appState.documentTitle)
    } else if !appState.documentHasEditableBuffer {
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

      RecoveredDraftsSection(palette: palette)
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
    // The launcher is the only place a crash draft can be reached, so it reads
    // the recovery directory every time it comes back on screen — including
    // after a Close, which is exactly when a draft may have just been retired.
    .onAppear { controller.refreshRecoveredDrafts() }
    .accessibilityIdentifier("pensieve.emptyState")
  }
}

/// The ONE way a crash-recovery draft reaches a window. Nothing adopts a draft
/// automatically any more (W2-D): unsaved work from a crash waits here, in the
/// empty launcher, until the user opens, saves, or discards it.
///
/// Deliberately quiet — it is a footnote under the empty state, and it renders
/// nothing at all when there is no unhandled draft, which is the normal case.
struct RecoveredDraftsPagination: Equatable {
  static let pageSize = 5

  let itemCount: Int
  let pageIndex: Int

  init(itemCount: Int, requestedPageIndex: Int) {
    self.itemCount = max(0, itemCount)
    let lastPageIndex = max(0, Self.pageCount(for: itemCount) - 1)
    self.pageIndex = min(max(0, requestedPageIndex), lastPageIndex)
  }

  var pageCount: Int {
    Self.pageCount(for: itemCount)
  }

  var itemRange: Range<Int> {
    let lowerBound = pageIndex * Self.pageSize
    let upperBound = min(lowerBound + Self.pageSize, itemCount)
    return lowerBound..<upperBound
  }

  var itemRangeLabel: String {
    guard !itemRange.isEmpty else { return "0 of 0" }
    return "\(itemRange.lowerBound + 1)–\(itemRange.upperBound) of \(itemCount)"
  }

  private static func pageCount(for itemCount: Int) -> Int {
    guard itemCount > 0 else { return 0 }
    return (itemCount + pageSize - 1) / pageSize
  }
}

struct RecoveredDraftsSection: View {
  @EnvironmentObject private var controller: AppController
  @State private var requestedPageIndex = 0
  /// The launcher pane's own skin tokens. The section sits INSIDE the themed
  /// empty state, so a system colour here would reinstate exactly the grey card
  /// on a cream/ink pane the empty-state palette exists to prevent.
  let palette: EmptyStatePalette

  var body: some View {
    // Nothing to recover renders NOTHING — not even a header. An always-visible
    // "0 drafts" row would turn the ordinary launcher into a permanent crash
    // reminder.
    if !controller.recoveredDrafts.isEmpty {
      let pagination = RecoveredDraftsPagination(
        itemCount: controller.recoveredDrafts.count,
        requestedPageIndex: requestedPageIndex)
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Recovered Drafts")
            .font(.headline)
            .foregroundStyle(Color(palette.secondaryText))
          Spacer()
          Text(pagination.itemRangeLabel)
            .font(.caption)
            .foregroundStyle(Color(palette.tertiaryText))
            .accessibilityIdentifier("pensieve.recoveredDrafts.range")
        }

        ForEach(Array(controller.recoveredDrafts[pagination.itemRange])) { draft in
          RecoveredDraftRow(draft: draft, palette: palette)
        }

        if pagination.pageCount > 1 {
          HStack(spacing: 8) {
            Button("Previous") {
              requestedPageIndex = max(0, pagination.pageIndex - 1)
            }
            .disabled(pagination.pageIndex == 0)
            .accessibilityIdentifier("pensieve.recoveredDrafts.previousPage")

            Spacer()

            Text("Page \(pagination.pageIndex + 1) of \(pagination.pageCount)")
              .font(.caption)
              .foregroundStyle(Color(palette.secondaryText))
              .accessibilityIdentifier("pensieve.recoveredDrafts.page")

            Spacer()

            Button("Next") {
              requestedPageIndex = min(
                pagination.pageCount - 1, pagination.pageIndex + 1)
            }
            .disabled(pagination.pageIndex == pagination.pageCount - 1)
            .accessibilityIdentifier("pensieve.recoveredDrafts.nextPage")
          }
          .controlSize(.small)
        }
      }
      .padding(16)
      .frame(maxWidth: 460)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(palette.keyCapFill))
      )
      .accessibilityIdentifier("pensieve.recoveredDrafts")
      .onChange(of: controller.recoveredDrafts.count) { _, count in
        requestedPageIndex =
          RecoveredDraftsPagination(
            itemCount: count, requestedPageIndex: requestedPageIndex
          ).pageIndex
      }
    }
  }
}

private struct RecoveredDraftRow: View {
  @EnvironmentObject private var controller: AppController
  let draft: RecoveryDraft
  let palette: EmptyStatePalette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(draft.displayTitle)
          .font(.callout)
          .foregroundStyle(Color(palette.primaryText))
          .lineLimit(1)
        Text(draft.previewSnippet)
          .font(.caption)
          .foregroundStyle(Color(palette.secondaryText))
          .lineLimit(1)
        Text(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption2)
          .foregroundStyle(Color(palette.tertiaryText))
        if let sourceURL = draft.sourceURL {
          Text(sourceURL.path)
            .font(.caption2)
            .foregroundStyle(Color(palette.tertiaryText))
            .lineLimit(1)
            .truncationMode(.middle)
          Text("Emergency copy — the original file has not been overwritten.")
            .font(.caption2)
            .foregroundStyle(Color(palette.tertiaryText))
        }
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
