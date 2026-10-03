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
///
/// Three budget rules keep a long or frequently replaced conversation cheap:
/// UI snapshots and follow-tail scrolls are emitted only for structural
/// changes, actual coalesced publications and accepted parse results — never
/// per incoming delta; only the visible history window (plus the live turn)
/// is parsed eagerly, hidden turns wait for reveal; and parsed AST retention
/// is bounded to the window plus a recency budget, so retired threads cannot
/// accumulate stale documents. The owning thread keeps full history and
/// source; nothing here truncates it.
@MainActor
final class AskConversationModel: ObservableObject {
  struct ObservedTurn: Equatable {
    var id: String
    var roleLabel: String
    var text: String
    var isStreaming: Bool
    var revision: UInt64
  }

  /// Parsed documents outlive their turn's visibility only within this
  /// budget. Two window pages cover a scope round-trip without retaining
  /// every previously displayed thread.
  static let retentionBudget = AskTranscriptWindow.pageSize * 2
  private static let recencyTrackingLimit = retentionBudget * 2

  @Published private(set) var snapshot = AskTranscriptSnapshot(
    turns: [], hiddenCount: 0, totalCount: 0,
    showsJumpToLatest: false,
    jumpTitle: StreamScrollFollowState.jumpToLatestTitle,
    scrollRequests: 0)
  @Published private(set) var revealedTurnIDs: Set<String> = []

  /// How often the parser actually ran per turn. Diagnostic surface for the
  /// bounded-parse regressions; not read by any view.
  private(set) var parseInvocations: [String: Int] = [:]
  /// How many snapshots the model emitted. Diagnostic for the publication
  /// budget: a delta burst must not become a snapshot burst.
  private(set) var snapshotEmissions = 0

  private let clock: () -> TimeInterval
  private let parse: @Sendable (String) -> AskMarkdownDocument

  private var follow = StreamScrollFollowState()
  private var window = AskTranscriptWindow()
  private var turns: [ObservedTurn] = []
  /// Revision memory independent of the visible list. A turn that comes back
  /// with unchanged text keeps its revision, so its cached document is reused
  /// instead of re-parsed — and a low restarted revision can never be
  /// mistaken for newer text. Pruned with the same retention budget.
  private var observedRevisions: [String: (text: String, isStreaming: Bool, revision: UInt64)] =
    [:]
  private var schedulers: [String: AskMarkdownStreamScheduler] = [:]
  private var documents: [String: AskMarkdownDocument] = [:]
  private var parsedRevisions: [String: UInt64] = [:]
  private var latestRequests: [String: (text: String, revision: UInt64)] = [:]
  /// Access-ordered turn ids (least → most recent) for bounded retention.
  private var recency: [String] = []
  /// Thread generation. Bumped on `replaceThread`; a parse round that started
  /// before the bump drops its results instead of writing a retired thread's
  /// ASTs back into the cache.
  private var epoch: UInt64 = 0
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
  /// Total parsed documents currently retained (bounded by the budget).
  var retainedDocumentCount: Int { documents.count }

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
  /// turn costs nothing. A snapshot is emitted only for structural changes
  /// (turn added/removed/reordered) or actual visible work — a bare
  /// subinterval delta publishes nothing. Parsing is requested only for the
  /// visible window; hidden history waits for `revealEarlier`.
  func observe(turns newTurns: [AskTurn]) {
    // One index build per pass: with a 10000-turn history, per-turn
    // contains/firstIndex lookups would be O(N²) on the UI actor.
    var indexByID: [String: Int] = [:]
    indexByID.reserveCapacity(turns.count)
    for (index, turn) in turns.enumerated() { indexByID[turn.id] = index }

    var seen: Set<String> = []
    var structural = false
    var visibleWork = false
    for turn in newTurns {
      let id = turn.id.uuidString
      seen.insert(id)
      let memory = observedRevisions[id]
      if memory?.text == turn.text, memory?.isStreaming == turn.isStreaming {
        // Unchanged since the last observation. If a scope switch evicted it
        // from the visible list, put it back with its remembered revision —
        // the cached document still matches, so nothing reparses.
        if let memory, indexByID[id] == nil {
          turns.append(
            ObservedTurn(
              id: id,
              roleLabel: Self.roleLabel(for: turn.role),
              text: turn.text,
              isStreaming: turn.isStreaming,
              revision: memory.revision))
          structural = true
        }
        continue
      }
      let wasStreaming = memory?.isStreaming ?? false
      let revision = (memory?.revision ?? 0) &+ 1
      observedRevisions[id] = (text: turn.text, isStreaming: turn.isStreaming, revision: revision)
      let observed = ObservedTurn(
        id: id,
        roleLabel: Self.roleLabel(for: turn.role),
        text: turn.text,
        isStreaming: turn.isStreaming,
        revision: revision)
      if let index = indexByID[id] {
        turns[index] = observed
      } else {
        turns.append(observed)
        structural = true
      }
      touch(id)
      if ingestChange(observed, wasStreaming: wasStreaming) { visibleWork = true }
    }
    if turns.count != newTurns.count {
      turns.removeAll { !seen.contains($0.id) }
      structural = true
    }
    if structural {
      // The display list follows the thread's order; re-added turns
      // (scope switch) and appends must not scramble it.
      let positions = Dictionary(
        uniqueKeysWithValues: newTurns.enumerated().map { ($0.element.id.uuidString, $0.offset) })
      turns.sort { (positions[$0.id] ?? .max) < (positions[$1.id] ?? .max) }
    }
    // Eager parse is due only for the window the user can actually see.
    requestParsesForVisibleTurns()
    if structural || visibleWork { publish() }
  }

  /// A streaming delta enters the coalescer; only a publication requests a
  /// parse and a UI refresh, so neither the parser nor SwiftUI sees every
  /// incoming delta. A genuine stream completion (was streaming, now final)
  /// is the terminal flush and publishes immediately. Returns whether
  /// visible work happened.
  private func ingestChange(_ turn: ObservedTurn, wasStreaming: Bool) -> Bool {
    if turn.isStreaming {
      var scheduler = schedulers[turn.id] ?? AskMarkdownStreamScheduler()
      defer { schedulers[turn.id] = scheduler }
      guard
        let publication = scheduler.ingest(
          text: turn.text, generation: turn.revision, at: clock(), isFinal: false)
      else { return false }
      requestParse(id: turn.id, text: publication.text, revision: publication.generation)
      noteContentChanged()
      return true
    }
    schedulers.removeValue(forKey: turn.id)
    // A live turn going final is visible even mid-gesture; a historical
    // completed turn changes nothing on screen by itself.
    guard wasStreaming else { return false }
    noteContentChanged()
    return true
  }

  /// Eager parsing is bounded to the visible history window. Hidden turns
  /// keep only their revision memory; `revealEarlier` pulls their parse.
  private func requestParsesForVisibleTurns() {
    let range = window.visibleRange(total: turns.count)
    guard !turns.isEmpty else { return }
    for turn in turns[range] where !turn.isStreaming {
      requestParse(id: turn.id, text: turn.text, revision: turn.revision)
    }
  }

  /// Latest-wins: the pending request for a turn is replaced, never queued.
  private func requestParse(id: String, text: String, revision: UInt64) {
    if parsedRevisions[id] == revision { return }
    if latestRequests[id]?.revision == revision { return }
    latestRequests[id] = (text: text, revision: revision)
    touch(id)
    kickWorker()
  }

  /// One worker for the whole conversation. Each round drains the pending
  /// requests, parses them off MainActor, then applies only results that are
  /// still eligible: same thread epoch, the id still observed (live or within
  /// the recency budget), no newer request pending, and the result's revision
  /// still the current one. Retired or stale results are dropped, never
  /// reinserted after a prune. A snapshot is emitted only when an accepted
  /// result actually changed the visible content.
  private func kickWorker() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      guard let self else { return }
      defer { self.worker = nil }
      while !Task.isCancelled {
        let epoch = self.epoch
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
        // A thread replacement while parsing retires the whole round.
        guard self.epoch == epoch else { return }
        var applied = false
        for result in results {
          // A retired/evicted id has no observation left: drop the result
          // instead of reinserting it after the prune.
          guard let current = self.observedRevisions[result.id] else { continue }
          // A request queued while this round parsed is newer; it will be
          // parsed next round, so this stale result drops instead of
          // overwriting newer text.
          if let pending = self.latestRequests[result.id], pending.revision > result.revision {
            continue
          }
          guard result.revision == current.revision else { continue }
          guard result.revision >= (self.parsedRevisions[result.id] ?? 0) else { continue }
          self.parseInvocations[result.id, default: 0] += 1
          self.touch(result.id)
          self.documents[result.id] = result.document
          self.parsedRevisions[result.id] = result.revision
          applied = true
        }
        if applied {
          self.noteContentChanged()
          self.publish()
        }
      }
    }
  }

  private func noteContentChanged() {
    if follow.handle(.contentChanged) == .scrollToLiveEdge {
      scrollRequests += 1
    }
  }

  /// A genuine user gesture began (tracking/interacting/decelerating — never
  /// programmatic animation, content growth or resize).
  func userScrollBegan() {
    _ = follow.handle(.userScrollBegan)
    publish()
  }

  /// A genuine user gesture ended; the settled position decides follow.
  func userScrollEnded(isAtLiveEdge: Bool) {
    _ = follow.handle(.userScrollEnded(isAtLiveEdge: isAtLiveEdge))
    publish()
  }

  func jumpToLatest() {
    if follow.handle(.jumpToLatest) == .scrollToLiveEdge {
      scrollRequests += 1
    }
    requestParsesForVisibleTurns()
    publish()
  }

  /// Revealing hidden history is exactly when its parse becomes due.
  func revealEarlier() {
    window.revealEarlier()
    requestParsesForVisibleTurns()
    publish()
  }

  func revealTurn(_ id: String) {
    revealedTurnIDs.insert(id)
  }

  /// A different conversation now owns the surface: the history window and
  /// follow state restart, retired pending parse work is dropped, and in-flight
  /// results from the old epoch are refused when they land. Parsed documents
  /// stay cached within the retention budget, so a quick scope round-trip
  /// does not re-parse.
  func replaceThread() {
    window.reset()
    schedulers.removeAll()
    latestRequests.removeAll()
    epoch &+= 1
    if follow.handle(.threadChanged) == .scrollToLiveEdge {
      scrollRequests += 1
    }
    publish()
  }

  private func touch(_ id: String) {
    recency.removeAll { $0 == id }
    recency.append(id)
    if recency.count > Self.recencyTrackingLimit {
      recency.removeFirst(recency.count - Self.recencyTrackingLimit)
    }
  }

  /// Bounds AST retention to the live streaming turn plus a recency budget of
  /// actually used parses — never the whole thread. The visible window's
  /// turns are touched when their parse is requested, so ordinary history
  /// stays hot while a fully revealed 10000-turn backlog cannot retain every
  /// admitted AST forever: evicted entries simply re-parse lazily when a
  /// reveal or publication brings their turn back into use. Pending requests
  /// for evicted ids are dropped so retired work leaves nothing behind.
  /// Revision memory is cheap and stays for the live conversation plus the
  /// same recency budget.
  private func pruneRetention() {
    let liveIDs = Set(turns.map(\.id))
    var astKeep: Set<String> = []
    for turn in turns where turn.isStreaming { astKeep.insert(turn.id) }
    var budget = Self.retentionBudget
    var recencyKeep: Set<String> = []
    for id in recency.reversed() where budget > 0 {
      if recencyKeep.contains(id) { continue }
      recencyKeep.insert(id)
      budget -= 1
    }
    astKeep.formUnion(recencyKeep)
    documents = documents.filter { astKeep.contains($0.key) }
    parsedRevisions = parsedRevisions.filter { astKeep.contains($0.key) }
    parseInvocations = parseInvocations.filter { astKeep.contains($0.key) }
    latestRequests = latestRequests.filter { astKeep.contains($0.key) }
    let memoryKeep = liveIDs.union(recencyKeep)
    observedRevisions = observedRevisions.filter { memoryKeep.contains($0.key) }
    schedulers = schedulers.filter { liveIDs.contains($0.key) }
    recency = recency.filter { memoryKeep.contains($0) }
  }

  private func publish() {
    snapshotEmissions += 1
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
    pruneRetention()
  }
}

/// What the transcript's scroll routing may tell the model. Only a real user
/// gesture produces these; geometry alone never does.
enum AskScrollIntent: Equatable, Sendable {
  case userScrollBegan
  case userScrollEnded(isAtLiveEdge: Bool)
}

/// Scroll phases with SwiftUI's `ScrollPhase` mapped into three truth values:
/// user-driven movement, programmatic animation, and rest.
enum AskScrollPhase: Equatable, Sendable {
  case userActive
  case programmatic
  case idle

  init(_ phase: ScrollPhase) {
    switch phase {
    case .idle: self = .idle
    case .tracking, .interacting, .decelerating: self = .userActive
    case .animating: self = .programmatic
    @unknown default: self = .programmatic
    }
  }
}

/// Genuine-user scroll routing for the production transcript. Programmatic
/// `scrollTo`, content growth during streaming and window resize all move the
/// scroll geometry; none of them is user intent. Geometry is remembered so a
/// gesture's END can be judged, but only phase transitions emit intents — a
/// manually paused follow stays paused through streams and resizes, and
/// Jump to latest stays the only automatic resume.
struct AskScrollIntentRouter: Equatable, Sendable {
  private(set) var userDriven = false
  private(set) var atLiveEdge = true

  mutating func phaseChanged(to phase: AskScrollPhase) -> [AskScrollIntent] {
    switch phase {
    case .userActive:
      userDriven = true
      return [.userScrollBegan]
    case .idle:
      guard userDriven else { return [] }
      userDriven = false
      return [.userScrollEnded(isAtLiveEdge: atLiveEdge)]
    case .programmatic:
      return []
    }
  }

  mutating func geometryChanged(isAtLiveEdge: Bool) -> [AskScrollIntent] {
    atLiveEdge = isAtLiveEdge
    return []
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
  /// The one horizontal inset of the transcript column; the markdown layout
  /// width is the slot width minus exactly this, so the readable column and
  /// the code/table viewports always see real geometry.
  static let horizontalPadding: CGFloat = 12
  @State private var scrollIntent = AskScrollIntentRouter()

  var body: some View {
    GeometryReader { outer in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            AskTranscriptView(
              snapshot: model.snapshot,
              tokens: themeManager.skin.tokens,
              containerWidth: max(0, outer.size.width - Self.horizontalPadding * 2),
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
          .padding(.horizontal, Self.horizontalPadding)
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
            // Geometry alone is not user intent: programmatic scrolls, content
            // growth and resize only inform the router's position memory.
            for intent in scrollIntent.geometryChanged(isAtLiveEdge: isAtLiveEdge) {
              apply(intent)
            }
          }
        )
        .onScrollPhaseChange { _, phase in
          for intent in scrollIntent.phaseChanged(to: AskScrollPhase(phase)) {
            apply(intent)
          }
        }
      }
    }
    .accessibilityIdentifier("\(identifierPrefix).turns")
  }

  private func apply(_ intent: AskScrollIntent) {
    switch intent {
    case .userScrollBegan:
      model.userScrollBegan()
    case .userScrollEnded(let isAtLiveEdge):
      model.userScrollEnded(isAtLiveEdge: isAtLiveEdge)
    }
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
