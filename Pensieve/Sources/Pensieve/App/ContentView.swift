import AppKit
import CodescribeBridge
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Environment(AppState.self) private var appState
  @EnvironmentObject private var controller: AppController
  @EnvironmentObject private var themeManager: ThemeManager
  @ObservedObject private var providerOnboardingCoordinator: ProviderOnboardingCoordinator
  @StateObject private var providerSettingsTransition: ProviderOnboardingSettingsTransition
  @StateObject private var askThreads: DocumentAskThreadStore
  @State private var lastIngestedDictation = ""
  /// Shared with the status bar's Ask chip and the surface's hide control —
  /// one key, three surfaces. Default visible preserves the pre-toggle behavior.
  @AppStorage("pensieve.ask.visible") private var askVisible = true
  /// The assembled surface's remembered geometry: presentation mode, the
  /// user-resized dock height, and expansion. Hidden is NOT stored here — it
  /// is `pensieve.ask.visible`, synced both ways below.
  @AppStorage("pensieve.ask.presentationMode") private var askModeRaw =
    AskPresentationMode.docked.rawValue
  @AppStorage("pensieve.ask.dockHeight") private var askDockHeight = 0.0
  @AppStorage("pensieve.ask.expanded") private var askExpanded = true
  @State private var askPresentation = AskPresentationState.expandedDefault
  @State private var askPresentationLoaded = false
  @Binding private var hostWindow: NSWindow?
  @ObservedObject private var providerSettings: ProviderSettings

  @MainActor
  init(
    hostWindow: Binding<NSWindow?> = .constant(nil),
    providerSettings: ProviderSettings = .shared,
    providerOnboardingCoordinator: ProviderOnboardingCoordinator? = nil,
    askThreads: DocumentAskThreadStore? = nil
  ) {
    _askThreads = StateObject(wrappedValue: askThreads ?? DocumentAskThreadStore())
    _hostWindow = hostWindow
    _providerSettings = ObservedObject(wrappedValue: providerSettings)
    _providerOnboardingCoordinator = ObservedObject(
      wrappedValue: providerOnboardingCoordinator ?? .shared)
    _providerSettingsTransition = StateObject(
      wrappedValue: ProviderOnboardingSettingsTransition())
  }

  private func makeDocumentHost() -> DocumentToolHost {
    controller.makeAgentDocumentHost()
  }

  /// First-mount restore of the assembled surface: persisted mode, dock
  /// height and expansion, with hidden read from the shared visibility key.
  private func loadAskPresentation() {
    guard !askPresentationLoaded else { return }
    askPresentationLoaded = true
    var state = AskPresentationState.expandedDefault
    state.isExpanded = askExpanded
    if askDockHeight > 0 { state.preferredDockHeight = askDockHeight }
    state.mode =
      askVisible
      ? (AskPresentationMode(rawValue: askModeRaw) ?? .docked) : .hidden
    askPresentation = state
  }

  /// The status-bar chip (or dictation) flipped visibility: move the surface,
  /// remembering the non-hidden mode it returns to.
  private func syncAskVisibility(_ visible: Bool) {
    guard askPresentationLoaded else { return }
    if visible {
      if askPresentation.mode == .hidden {
        askPresentation.mode = AskPresentationMode(rawValue: askModeRaw) ?? .docked
      }
    } else if askPresentation.mode != .hidden {
      askPresentation.mode = .hidden
    }
  }

  /// The surface moved (hide button, float/dock, drag): write visibility back
  /// to the shared key and remember geometry. Guards keep the two stores
  /// from bouncing each other.
  private func persistAskPresentation(_ state: AskPresentationState) {
    guard askPresentationLoaded else { return }
    if state.mode == .hidden, askVisible { askVisible = false }
    if state.mode != .hidden {
      if !askVisible { askVisible = true }
      if askModeRaw != state.mode.rawValue { askModeRaw = state.mode.rawValue }
    }
    if askDockHeight != state.preferredDockHeight {
      askDockHeight = state.preferredDockHeight
    }
    if askExpanded != state.isExpanded { askExpanded = state.isExpanded }
  }

  var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    } detail: {
      GeometryReader { proxy in
        let askEligible =
          appState.documentHasEditableBuffer || !appState.workspaceRoots.isEmpty
        let dockPlaceholder =
          askEligible && askPresentation.mode == .docked
          ? AskSurfaceLayout.displayedDockHeight(
            presentation: askPresentation, content: proxy.size) : 0
        ZStack(alignment: .topLeading) {
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
            // The docked surface draws exactly over this reserved band: both
            // are bottom-anchored against the same 26pt status reserve, with
            // or without banners above. Floating and hidden reserve nothing.
            if dockPlaceholder > 0 {
              Color.clear.frame(height: dockPlaceholder)
            }
            if appState.documentHasEditableBuffer {
              EditorStatusBar()
                .environmentObject(askThreads)
                .opacity(appState.mode == .focus ? 0.45 : 1)
            }
          }
          if askEligible {
            AskSurfaceHost(
              providerSettings: providerSettings,
              askThreads: askThreads,
              presentation: $askPresentation,
              makeDocumentHost: makeDocumentHost)
          }
        }
        .onAppear { loadAskPresentation() }
        .onChange(of: askVisible) { _, visible in
          syncAskVisibility(visible)
        }
        .onChange(of: askPresentation) { _, state in
          persistAskPresentation(state)
        }
      }
    }
    .task(id: appState.documentHasEditableBuffer ? appState.documentSession.askThreadID : nil) {
      if askVisible, appState.documentHasEditableBuffer {
        _ = askThreads.thread(for: appState.documentSession.askThreadID)
      }
    }
    .onChange(of: askVisible) { _, visible in
      if visible, appState.documentHasEditableBuffer {
        _ = askThreads.thread(for: appState.documentSession.askThreadID)
      }
    }
    .onChange(of: appState.documentSession.askThreadID) { oldID, _ in
      askThreads.existingThread(for: oldID)?.cancel()
    }
    .onDisappear { askThreads.cancelAll() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
      notification in
      guard let closing = notification.object as? NSWindow, closing === hostWindow else { return }
      askThreads.cancelAll()
    }
    .navigationTitle(
      DocumentWindowSurface.navigationTitle(
        hasEditableBuffer: appState.documentHasEditableBuffer,
        documentTitle: appState.documentTitle)
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
      ProviderOnboardingView(
        isPresented: onboardingSheetBinding,
        hostWindow: hostWindow,
        settingsTransition: providerSettingsTransition,
        onSettingsTransitionFailure: { failure in
          appState.lastError = failure.userMessage
        },
        onSettingsPresentationFailure: { result in
          if let message = result.userMessage {
            appState.lastError = message
          }
        })
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
    .onReceive(controller.transcriptionService.$committed) { committed in
      ingestDictation(committed)
    }
  }

  /// Built once per pass and used twice — as the toolbar's content and as the
  /// source of its overflow menu — so the two can never describe different
  /// toolbars.
  private var toolbelt: EditorToolbelt {
    EditorToolbelt(
      appState: appState,
      controller: controller,
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

  private func ingestDictation(_ committed: String) {
    guard appState.documentHasEditableBuffer else { return }
    let trimmed = committed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != lastIngestedDictation else { return }
    let utterance: String
    if trimmed.hasPrefix(lastIngestedDictation), !lastIngestedDictation.isEmpty {
      utterance = String(trimmed.dropFirst(lastIngestedDictation.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      utterance = trimmed
    }
    lastIngestedDictation = trimmed
    guard !utterance.isEmpty else { return }
    askThreads.thread(for: appState.documentSession.askThreadID).appendDictation(utterance)
    // Dictation landing in a hidden composer is feedback nobody sees. Reopen it.
    askVisible = true
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
      minHeight: 0, maxHeight: .infinity)
  }

  @ViewBuilder
  private func content(forWidth width: CGFloat) -> some View {
    // The launcher-vs-editor split lives in `DocumentWindowSurface` so the
    // new-tab lifecycle can pin it without building a view tree — a staged open
    // is bufferless too, and must not look like the idle empty state.
    switch DocumentWindowSurface.resolve(
      isLoading: appState.documentIsLoading,
      hasEditableBuffer: appState.documentHasEditableBuffer)
    {
    case .opening:
      DocumentOpeningView(title: appState.documentTitle)
    case .launcher:
      DocumentEmptyStateView()
    case .editor:
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

/// The assembled Ask surface: one dock/float surface whose conversation slots
/// switch between the document and workspace scopes. Threads, drafts and
/// attachments stay in their owning thread objects, so a scope or
/// presentation switch never starts a second session, submits twice, or
/// loses input. The shared `AskConversationModel` keeps its parse cache
/// across both.
private struct AskSurfaceHost: View {
  @Environment(AppState.self) private var appState
  @EnvironmentObject private var controller: AppController
  @ObservedObject var providerSettings: ProviderSettings
  @ObservedObject var askThreads: DocumentAskThreadStore
  @Binding var presentation: AskPresentationState
  let makeDocumentHost: @MainActor () -> DocumentToolHost

  @ObservedObject private var grokAccount = GrokAccount.shared
  @ObservedObject private var codexAccount = CodexAccount.shared
  @StateObject private var conversation = AskConversationModel()
  @AppStorage("pensieve.ask.workspaceSelected") private var workspaceAskSelected = false
  @State private var workspaceThread: WorkspaceAskThread?

  private var hasDocumentBuffer: Bool { appState.documentHasEditableBuffer }
  private var hasWorkspace: Bool { !appState.workspaceRoots.isEmpty }

  private var workspaceScopeActive: Bool {
    hasWorkspace && (workspaceAskSelected || !hasDocumentBuffer)
  }

  private var documentThread: DocumentAskThread? {
    askThreads.existingThread(for: appState.documentSession.askThreadID)
  }

  private var usesAccountProvider: Bool {
    grokAccount.snapshot.askUsesGrok || codexAccount.snapshot.askUsesCodex
  }

  private var provider: AskProvider {
    grokAccount.snapshot.askUsesGrok
      ? grokAccount.snapshot.askProvider(apiKey: providerSettings.apiKey)
      : codexAccount.snapshot.askProvider(apiKey: providerSettings.apiKey)
  }

  private var apiConfiguration: CsDocumentProvider {
    CsDocumentProvider(
      wire: providerSettings.providerShape.rawValue,
      endpoint: providerSettings.providerShape.normalizeEndpoint(providerSettings.endpoint),
      model: providerSettings.model,
      apiKey: providerSettings.apiKey)
  }

  private var readinessContext: AskEndpointContext? {
    usesAccountProvider ? nil : AskEndpointContext(configuration: apiConfiguration)
  }

  private var activeIsBusy: Bool {
    workspaceScopeActive
      ? workspaceThread?.isBusy ?? false
      : documentThread?.isStreaming ?? false
  }

  var body: some View {
    AskSurface(presentation: $presentation) { compact in
      headerSlot(compact: compact)
    } transcript: {
      transcriptSlot
    } composer: {
      composerSlot
    }
    .task(id: appState.workspaceRoots.map(\.url)) {
      await refreshWorkspaceThread()
    }
    .task {
      await grokAccount.refreshIfStale()
      await codexAccount.refreshIfStale()
      await grokAccount.adoptGrokForAskIfSignedIn()
      await codexAccount.adoptCodexForAskIfSignedIn()
    }
    .onChange(of: workspaceScopeActive) { _, _ in conversation.replaceThread() }
    .onChange(of: appState.documentSession.askThreadID) { _, _ in conversation.replaceThread() }
    .onChange(of: workspaceThread?.identity.workspaceID) { _, _ in conversation.replaceThread() }
  }

  @ViewBuilder private func headerSlot(compact: Bool) -> some View {
    if !workspaceScopeActive, let thread = documentThread {
      AskDocumentThreadObservation(thread: thread) { observed in
        providerHeader(isStreaming: observed.isStreaming, compact: compact)
      }
    } else {
      providerHeader(isStreaming: activeIsBusy, compact: compact)
    }
  }

  private func providerHeader(isStreaming: Bool, compact: Bool) -> some View {
    AskProviderHeader(
      showsScopePicker: hasWorkspace,
      workspaceSelected: $workspaceAskSelected,
      documentScopeEnabled: hasDocumentBuffer,
      workspaceScopeEnabled: hasWorkspace,
      grokAccount: grokAccount,
      codexAccount: codexAccount,
      apiKey: providerSettings.apiKey,
      apiKeyProvider: providerSettings.providerShape,
      readinessContext: readinessContext,
      isStreaming: isStreaming,
      compact: compact)
  }

  @ViewBuilder private var transcriptSlot: some View {
    if workspaceScopeActive {
      if let thread = workspaceThread {
        workspaceComposer(thread).transcript
      } else {
        Color.clear
      }
    } else if let thread = documentThread {
      AskDocumentThreadObservation(thread: thread) { observed in
        documentComposer(observed).transcript
      }
    } else {
      Color.clear
    }
  }

  @ViewBuilder private var composerSlot: some View {
    if workspaceScopeActive {
      if let thread = workspaceThread {
        workspaceComposer(thread).composer
      } else {
        Color.clear
      }
    } else if let thread = documentThread {
      AskDocumentThreadObservation(thread: thread) { observed in
        documentComposer(observed).composer
      }
    } else {
      Color.clear
    }
  }

  private func documentComposer(_ thread: DocumentAskThread) -> AskComposerView {
    AskComposerView(
      thread: thread,
      grokAccount: grokAccount,
      codexAccount: codexAccount,
      apiKey: providerSettings.apiKey,
      makeDocumentHost: makeDocumentHost,
      apiConfiguration: apiConfiguration,
      conversation: conversation)
  }

  private func workspaceComposer(_ thread: WorkspaceAskThread) -> WorkspaceAskComposer {
    WorkspaceAskComposer(
      thread: thread,
      conversation: conversation,
      provider: provider,
      readinessContext: readinessContext,
      onSubmit: { prompt in
        await thread.prepareAndSend(
          text: prompt,
          documents: appState.workspaceStore.documents,
          database: .shared,
          provider: provider,
          configuration: usesAccountProvider ? nil : apiConfiguration,
          openDocument: { [weak controller] ref, isActive in
            guard let controller else { throw CsError.Agent(msg: "The window was closed.") }
            workspaceAskSelected = true
            return try await controller.openAgentDocument(ref, isActive: isActive)
          })
      })
  }

  /// Session creation belongs to a root-change task, never a view-body read.
  private func refreshWorkspaceThread() async {
    let roots = appState.workspaceRoots.map(\.url)
    guard !roots.isEmpty else {
      workspaceThread?.cancel()
      workspaceThread = nil
      return
    }
    let bookmark = appState.workspaceStore.bookmarkData
    let identity = await Task.detached {
      WorkspaceIdentity.make(roots: roots, bookmarkData: bookmark)
    }.value
    guard !Task.isCancelled else { return }
    if let workspaceThread, workspaceThread.identity.workspaceID != identity.workspaceID {
      workspaceThread.cancel()
    }
    workspaceThread = WorkspaceAskThreadStore.shared.thread(for: identity)
  }
}
