import AppKit
import CodescribeBridge
import SwiftUI
import UniformTypeIdentifiers

/// The production transcript model behind the assembled Ask UI.
///
/// The thread owns the conversation; this model owns everything expensive
/// about SHOWING it: streaming coalesce (ten publications a second, immediate
/// final flush), Markdown parsing, and the bounded history window. Parsing
/// runs off MainActor through ONE latest-wins worker — a new delta never
/// spawns a new job, it replaces the pending request, and a stale result can
/// never overwrite newer text. Completed turns parse once per revision.
@MainActor
final class AskConversationModel: ObservableObject {
  struct ObservedTurn: Equatable {
    var id: String
    var roleLabel: String
    var text: String
    var isStreaming: Bool
    var revision: UInt64
  }

  @Published private(set) var snapshot = AskTranscriptSnapshot(
    turns: [], hiddenCount: 0, totalCount: 0,
    showsJumpToLatest: false,
    jumpTitle: StreamScrollFollowState.jumpToLatestTitle,
    scrollRequests: 0)
  @Published private(set) var revealedTurnIDs: Set<String> = []

  /// How often the parser actually ran per turn. Diagnostic surface for the
  /// bounded-parse regressions; not read by any view.
  private(set) var parseInvocations: [String: Int] = [:]

  private let clock: () -> TimeInterval
  private let parse: @Sendable (String) -> AskMarkdownDocument

  private var follow = StreamScrollFollowState()
  private var window = AskTranscriptWindow()
  private var turns: [ObservedTurn] = []
  /// Revision memory independent of the visible list. Switching scope empties
  /// `turns`, but a turn that comes back with unchanged text keeps its
  /// revision, so its cached document is reused instead of re-parsed — and a
  /// low restarted revision can never be mistaken for newer text.
  private var observedRevisions: [String: (text: String, isStreaming: Bool, revision: UInt64)] =
    [:]
  private var schedulers: [String: AskMarkdownStreamScheduler] = [:]
  private var documents: [String: AskMarkdownDocument] = [:]
  private var parsedRevisions: [String: UInt64] = [:]
  private var latestRequests: [String: (text: String, revision: UInt64)] = [:]
  private var scrollRequests = 0
  private var worker: Task<Void, Never>?

  init(
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    parse: @escaping @Sendable (String) -> AskMarkdownDocument = { AskMarkdownParser.parse($0) }
  ) {
    self.clock = clock
    self.parse = parse
  }

  func parseCount(for id: String) -> Int { parseInvocations[id] ?? 0 }
  func document(for id: String) -> AskMarkdownDocument? { documents[id] }

  /// Test seam: are there parse requests queued or in flight?
  var hasPendingWork: Bool { !latestRequests.isEmpty || worker != nil }

  /// Test seam: await the current parse worker, if one is running. Pair with
  /// `hasPendingWork` to drain the queue deterministically instead of
  /// sleeping and hoping the worker resumed.
  func awaitParseWorker() async {
    if let worker { await worker.value }
  }

  static func roleLabel(for role: AskTurn.Role) -> String {
    switch role {
    case .user: return "You"
    case .assistant: return "Pensieve"
    case .dictation: return "Dictation"
    }
  }

  /// Observe the thread's current turns. Diffed by revision: an unchanged
  /// turn costs nothing, a changed one feeds the coalescer or the final
  /// flush. Never parses here.
  func observe(turns newTurns: [AskTurn]) {
    var seen: Set<String> = []
    var changed = false
    for turn in newTurns {
      let id = turn.id.uuidString
      seen.insert(id)
      let memory = observedRevisions[id]
      if memory?.text == turn.text, memory?.isStreaming == turn.isStreaming {
        // Unchanged since the last observation. If a scope switch evicted it
        // from the visible list, put it back with its remembered revision —
        // the cached document still matches, so nothing reparses.
        if let memory, !turns.contains(where: { $0.id == id }) {
          turns.append(
            ObservedTurn(
              id: id,
              roleLabel: Self.roleLabel(for: turn.role),
              text: turn.text,
              isStreaming: turn.isStreaming,
              revision: memory.revision))
          changed = true
        }
        continue
      }
      let revision = (memory?.revision ?? 0) &+ 1
      observedRevisions[id] = (text: turn.text, isStreaming: turn.isStreaming, revision: revision)
      let observed = ObservedTurn(
        id: id,
        roleLabel: Self.roleLabel(for: turn.role),
        text: turn.text,
        isStreaming: turn.isStreaming,
        revision: revision)
      if let index = turns.firstIndex(where: { $0.id == id }) {
        turns[index] = observed
      } else {
        turns.append(observed)
      }
      ingestChange(observed)
      changed = true
    }
    if turns.count != newTurns.count {
      turns.removeAll { !seen.contains($0.id) }
      changed = true
    }
    if changed {
      // The display list follows the thread's order; re-added turns
      // (scope switch) and appends must not scramble it.
      let positions = Dictionary(
        uniqueKeysWithValues: newTurns.enumerated().map { ($0.element.id.uuidString, $0.offset) })
      turns.sort { (positions[$0.id] ?? .max) < (positions[$1.id] ?? .max) }
      publish()
    }
  }

  /// A streaming delta enters the coalescer; only a publication (or the final
  /// flush) requests a parse, so the parser never sees every incoming delta.
  private func ingestChange(_ turn: ObservedTurn) {
    if turn.isStreaming {
      var scheduler = schedulers[turn.id] ?? AskMarkdownStreamScheduler()
      if let publication = scheduler.ingest(
        text: turn.text, generation: turn.revision, at: clock(), isFinal: false)
      {
        requestParse(id: turn.id, text: publication.text, revision: publication.generation)
      }
      schedulers[turn.id] = scheduler
    } else {
      schedulers.removeValue(forKey: turn.id)
      requestParse(id: turn.id, text: turn.text, revision: turn.revision)
    }
    noteContentChanged()
  }

  /// Latest-wins: the pending request for a turn is replaced, never queued.
  private func requestParse(id: String, text: String, revision: UInt64) {
    if parsedRevisions[id] == revision { return }
    latestRequests[id] = (text: text, revision: revision)
    kickWorker()
  }

  /// One worker for the whole conversation. Each round drains the pending
  /// requests, parses them off MainActor, then applies only results that are
  /// still the newest known revision for their turn.
  private func kickWorker() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      guard let self else { return }
      defer { self.worker = nil }
      while !Task.isCancelled {
        let batch = self.latestRequests
        self.latestRequests.removeAll()
        if batch.isEmpty { return }
        let parse = self.parse
        let results: [(id: String, revision: UInt64, document: AskMarkdownDocument)] =
          await Task.detached(priority: .userInitiated) {
            batch.map { (id, request) in
              (id: id, revision: request.revision, document: parse(request.text))
            }
          }.value
        guard !Task.isCancelled else { return }
        for result in results {
          self.parseInvocations[result.id, default: 0] += 1
          // A request queued while this round parsed is newer; it will be
          // parsed next round, so this stale result drops instead of
          // overwriting newer text.
          if let pending = self.latestRequests[result.id], pending.revision > result.revision {
            continue
          }
          guard result.revision >= (self.parsedRevisions[result.id] ?? 0) else { continue }
          self.documents[result.id] = result.document
          self.parsedRevisions[result.id] = result.revision
        }
        self.publish()
      }
    }
  }

  private func noteContentChanged() {
    if follow.handle(.contentChanged) == .scrollToLiveEdge {
      scrollRequests += 1
    }
  }

  func userViewportChanged(isAtLiveEdge: Bool) {
    _ = follow.handle(.userScrollEnded(isAtLiveEdge: isAtLiveEdge))
    publish()
  }

  func jumpToLatest() {
    if follow.handle(.jumpToLatest) == .scrollToLiveEdge {
      scrollRequests += 1
    }
    publish()
  }

  func revealEarlier() {
    window.revealEarlier()
    publish()
  }

  func revealTurn(_ id: String) {
    revealedTurnIDs.insert(id)
  }

  /// A different conversation now owns the surface: the history window and
  /// follow state restart; parsed documents stay cached by turn id.
  func replaceThread() {
    window.reset()
    schedulers.removeAll()
    if follow.handle(.threadChanged) == .scrollToLiveEdge {
      scrollRequests += 1
    }
    publish()
  }

  private func publish() {
    let range = window.visibleRange(total: turns.count)
    let rendered = turns[range].map { turn -> AskTranscriptRenderedTurn in
      let document = documents[turn.id]
      let source = document?.source ?? turn.text
      let disposition = OversizedBubblePolicy.disposition(utf8Count: source.utf8.count)
      let excerpt: String
      if case .headPreview(let limit) = disposition {
        excerpt = OversizedBubblePolicy.headPreview(source, utf8Limit: limit)
      } else {
        excerpt = source
      }
      return AskTranscriptRenderedTurn(
        id: turn.id,
        document: document ?? AskMarkdownDocument(source: turn.text, blocks: []),
        isStreaming: turn.isStreaming,
        disposition: disposition,
        sharesListSelection: disposition.sharesListSelectionOverlay,
        excerpt: excerpt,
        roleLabel: turn.roleLabel)
    }
    snapshot = AskTranscriptSnapshot(
      turns: rendered,
      hiddenCount: window.hiddenCount(total: turns.count),
      totalCount: turns.count,
      showsJumpToLatest: follow.showsJumpToLatest,
      jumpTitle: StreamScrollFollowState.jumpToLatestTitle,
      scrollRequests: scrollRequests)
  }
}

/// The scrollable transcript slot: the bounded snapshot plus follow-tail
/// wiring, errors and activity. A turn whose first parse has not landed yet
/// shows its plain text; nothing here parses or does I/O.
struct AskConversationTranscript: View {
  @ObservedObject var model: AskConversationModel
  @EnvironmentObject private var themeManager: ThemeManager
  var error: String?
  var providerError: String?
  var activity: String?
  var identifierPrefix: String

  private let liveEdgeID = "pensieve.ask.liveEdge"

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          AskTranscriptView(
            snapshot: model.snapshot,
            tokens: themeManager.skin.tokens,
            containerWidth: 0,
            revealedTurnIDs: model.revealedTurnIDs,
            onRevealEarlier: { model.revealEarlier() },
            onJumpToLatest: { model.jumpToLatest() },
            onRevealTurn: { id in model.revealTurn(id) }
          )
          footer
          Color.clear
            .frame(height: 1)
            .id(liveEdgeID)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
      }
      .onChange(of: model.snapshot.scrollRequests) { _, _ in
        proxy.scrollTo(liveEdgeID, anchor: .bottom)
      }
      .onScrollGeometryChange(
        for: Bool.self,
        of: { geometry in
          StreamScrollFollowState.followTailAfterScroll(
            contentBottom: geometry.contentSize.height - geometry.contentOffset.y,
            viewportHeight: geometry.containerSize.height)
        },
        action: { _, isAtLiveEdge in
          model.userViewportChanged(isAtLiveEdge: isAtLiveEdge)
        }
      )
    }
    .accessibilityIdentifier("\(identifierPrefix).turns")
  }

  @ViewBuilder
  private var footer: some View {
    if let error {
      Text(error)
        .font(.system(size: 10.5))
        .foregroundStyle(.red)
        .accessibilityIdentifier("\(identifierPrefix).error")
    }
    if let providerError {
      Text(providerError)
        .font(.system(size: 10.5))
        .foregroundStyle(.red)
        .accessibilityIdentifier("\(identifierPrefix).providerError")
    }
    if let activity {
      HStack {
        Text(activity).font(.caption).foregroundStyle(.secondary)
        Spacer()
      }
      .accessibilityIdentifier("\(identifierPrefix).activity")
    }
  }
}

/// The composer slot shared by both scopes: attachment chips, the draft
/// editor with attachment paste routing, the attach control, and Send/Stop.
/// Stop cancels the turn; it never hides the surface.
struct AskConversationComposer: View {
  @ObservedObject var store: AskAttachmentStore
  @Binding var draft: String
  @EnvironmentObject private var themeManager: ThemeManager
  var isBusy: Bool
  var canSend: Bool
  var placeholder: String
  var identifierPrefix: String
  var draftAccessibilityIdentifier: String
  var submitAccessibilityIdentifier: String
  var onSend: () -> Void
  var onStop: () -> Void

  @State private var inputError: String?

  var body: some View {
    let tokens = themeManager.skin.tokens
    VStack(alignment: .leading, spacing: 4) {
      AskAttachmentChipsView(
        store: store, tokens: tokens, identifierPrefix: identifierPrefix)
      if let inputError {
        Text(inputError)
          .font(.system(size: 10.5))
          .foregroundStyle(.red)
          .lineLimit(2)
          .accessibilityIdentifier("\(identifierPrefix).attachmentError")
      }
      HStack(alignment: .bottom, spacing: 8) {
        AskAttachmentMenu(
          store: store, tokens: tokens, identifierPrefix: identifierPrefix,
          onError: { inputError = $0 })
        ZStack(alignment: .topLeading) {
          if draft.isEmpty {
            Text(placeholder)
              .font(.callout)
              .foregroundStyle(.tertiary)
              .padding(.top, 1)
              .padding(.leading, 5)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
          AskDraftEditor(
            text: $draft,
            isEnabled: !isBusy,
            onSubmit: onSend,
            attachmentPasteHandler: { pasteboard in
              AskAttachmentInput.handlePaste(
                pasteboard, store: store, onError: { inputError = $0 })
            },
            accessibilityIdentifier: draftAccessibilityIdentifier
          )
          .font(.callout)
          .scrollContentBackground(.hidden)
          .frame(maxHeight: .infinity)
          .disabled(isBusy)
          .accessibilityLabel(placeholder)
        }
        if isBusy {
          Button("Stop", action: onStop)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("\(identifierPrefix).stop")
        } else {
          Button("Ask", action: onSend)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canSend)
            .accessibilityIdentifier(submitAccessibilityIdentifier)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.quaternary.opacity(0.55))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
      }
    }
    .padding(.horizontal, 12)
    .onDrop(of: [.fileURL, .png, .tiff, .image], isTargeted: nil) { providers in
      handleDrop(providers)
      return true
    }
  }

  /// Drops land here when they miss the draft text view itself. File URLs
  /// keep their identity; raw image data is staged like a paste.
  private func handleDrop(_ providers: [NSItemProvider]) {
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
          guard let url = (reading as? URL) ?? (reading as? NSURL).map({ $0 as URL }) else {
            return
          }
          Task { @MainActor in
            AskAttachmentInput.attach(urls: [url], store: store, onError: { inputError = $0 })
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) {
          data, _ in
          guard let data, !data.isEmpty else { return }
          Task { @MainActor in
            do {
              _ = try await store.stageImage(data: data, fileExtension: "png")
            } catch {
              inputError = error.localizedDescription
            }
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.tiff.identifier) {
          data, _ in
          guard let data, !data.isEmpty else { return }
          Task { @MainActor in
            do {
              _ = try await store.stageImage(data: data, fileExtension: "tiff")
            } catch {
              inputError = error.localizedDescription
            }
          }
        }
      }
    }
  }
}

/// Scope switcher, provider menu and readiness chip — the ONE header row the
/// assembled surface carries, so document and workspace Ask no longer stack
/// two competing headers. All three read the same account truth as the
/// status bar and Settings ▸ AI.
struct AskProviderHeader: View {
  var showsScopePicker: Bool
  @Binding var workspaceSelected: Bool
  var documentScopeEnabled: Bool
  var workspaceScopeEnabled: Bool
  @ObservedObject var grokAccount: GrokAccount
  @ObservedObject var codexAccount: CodexAccount
  var apiKey: String
  var apiKeyProvider: CompletionProviderShape
  var readinessContext: AskEndpointContext?
  var isStreaming: Bool
  var openProviderSettings: @MainActor () -> Void = {
    _ = PensieveSettingsWindowController.shared.show(section: .ai)
  }
  @EnvironmentObject private var themeManager: ThemeManager

  private var provider: AskProvider {
    if grokAccount.snapshot.askUsesGrok {
      return grokAccount.snapshot.askProvider(apiKey: apiKey)
    }
    return codexAccount.snapshot.askProvider(apiKey: apiKey)
  }

  var body: some View {
    if showsScopePicker {
      HStack(spacing: 4) {
        Button("Document") { workspaceSelected = false }
          .disabled(!workspaceSelected || !documentScopeEnabled)
        Button("Workspace") { workspaceSelected = true }
          .disabled(workspaceSelected || !workspaceScopeEnabled)
      }
      .controlSize(.small)
      .accessibilityIdentifier("pensieve.ask.scope")
    }
    providerMenu
    readinessChip
  }

  private var providerMenu: some View {
    let grok = grokAccount.snapshot
    let codex = codexAccount.snapshot
    let menuTitle =
      grok.askUsesGrok ? "Grok" : (codex.askUsesCodex ? "Codex" : apiKeyProvider.displayName)
    return Menu {
      Button {
        Task {
          if grok.askUsesGrok {
            await grokAccount.useAPIKeyProviderForAsk(apiKeyProvider)
          } else {
            await codexAccount.useAPIKeyProviderForAsk(apiKeyProvider)
          }
        }
      } label: {
        providerItemLabel(
          "\(apiKeyProvider.displayName) (API key)",
          isSelected: !grok.askUsesGrok && !codex.askUsesCodex)
      }
      Button {
        Task { await grokAccount.useGrokForAsk() }
      } label: {
        providerItemLabel("Grok (xAI account)", isSelected: grok.askUsesGrok)
      }
      .disabled(!grok.isSignedIn)
      Button {
        Task { await codexAccount.useCodexForAsk() }
      } label: {
        providerItemLabel("Codex (OpenAI account)", isSelected: codex.askUsesCodex)
      }
      .disabled(!codex.isSignedIn)
      if !grok.isSignedIn || !codex.isSignedIn {
        Divider()
        if !grok.isSignedIn {
          Button("Sign In to Grok…") { openProviderSettings() }
        }
        if !codex.isSignedIn {
          Button("Sign In to Codex…") { openProviderSettings() }
        }
      }
    } label: {
      Text(menuTitle)
        .font(.system(size: 10.5))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(statusCapsule)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(isStreaming)
    .help("Choose which provider answers Ask")
    .accessibilityIdentifier("pensieve.ask.provider")
  }

  @ViewBuilder
  private func providerItemLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  private var readinessChip: some View {
    let ready = AskReadiness.isReady(provider, context: readinessContext)
    return Text(AskReadiness.chipLabel(for: provider, context: readinessContext))
      .font(.system(size: 10.5))
      .foregroundStyle(ready ? AnyShapeStyle(.secondary) : AnyShapeStyle(warningColor))
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .overlay(statusCapsule)
      .help(ready ? "" : AskReadiness.notReadyMessage(for: provider))
      .accessibilityIdentifier("pensieve.ask.ready")
  }

  private var statusCapsule: some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
  }

  private var warningColor: Color {
    Color(themeManager.skin.tokens.warning.nsColor)
  }
}
