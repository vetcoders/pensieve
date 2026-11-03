import AppKit
import SwiftUI

enum StreamScrollFollowAction: Equatable, Sendable {
  case none
  case scrollToLiveEdge
}

/// Viewport follow for a streaming transcript. Content growth moves the
/// viewport only while the reader is on the live edge. Scrolling upward
/// pauses follow. Jump to latest is enough to resume it, even when the
/// viewport is still above the tail. Finishing the stream leaves a paused
/// reader where they are.
struct StreamScrollFollowState: Equatable, Sendable {
  enum Event: Equatable, Sendable {
    case contentChanged
    case userScrollBegan
    case userViewportChanged(isAtLiveEdge: Bool)
    case userScrollEnded(isAtLiveEdge: Bool)
    case jumpToLatest
    case threadChanged
    case streamFinished
  }

  private(set) var followingLive = true
  var showsJumpToLatest: Bool { !followingLive }

  static let jumpToLatestTitle = "Jump to latest"

  mutating func handle(_ event: Event) -> StreamScrollFollowAction {
    switch event {
    case .contentChanged:
      return followingLive ? .scrollToLiveEdge : .none
    case .userScrollBegan:
      followingLive = false
      return .none
    case .userViewportChanged:
      return .none
    case .userScrollEnded(let isAtLiveEdge):
      followingLive = isAtLiveEdge
      return .none
    case .jumpToLatest, .threadChanged:
      followingLive = true
      return .scrollToLiveEdge
    case .streamFinished:
      return .none
    }
  }

  static func followTailAfterScroll(
    contentBottom: CGFloat, viewportHeight: CGFloat, slack: CGFloat = 40
  ) -> Bool {
    contentBottom <= viewportHeight + slack
  }
}

enum BubbleTextDisposition: Equatable, Sendable {
  case inline
  case headPreview(headUTF8: Int)

  var sharesListSelectionOverlay: Bool {
    switch self {
    case .inline: return true
    case .headPreview: return false
    }
  }
}

enum OversizedBubblePolicy {
  static let inlineUTF8Cap = 65_536
  static let headPreviewUTF8 = 16_384

  static func disposition(utf8Count: Int) -> BubbleTextDisposition {
    utf8Count <= inlineUTF8Cap ? .inline : .headPreview(headUTF8: headPreviewUTF8)
  }

  static func headPreview(_ source: String, utf8Limit: Int) -> String {
    guard source.utf8.count > utf8Limit else { return source }
    var limit = utf8Limit
    while limit > 0 {
      let end = source.utf8.index(source.utf8.startIndex, offsetBy: limit)
      if let text = String(source.utf8[..<end]) { return text }
      limit -= 1
    }
    return ""
  }
}

/// Pins the scroll document to the viewport. A long token scrolls inside its
/// bubble instead of widening the transcript.
enum AskTranscriptWidthPolicy {
  static let listPadding: CGFloat = 20
  static let minimumReadable: CGFloat = 280

  static func documentWidth(for containerWidth: CGFloat) -> CGFloat {
    max(minimumReadable, containerWidth > 0 ? containerWidth : minimumReadable)
  }

  static func contentWidth(for containerWidth: CGFloat) -> CGFloat {
    max(0, containerWidth - listPadding * 2)
  }
}

struct AskTranscriptWindow: Equatable, Sendable {
  static let pageSize = 120
  var budget: Int = pageSize

  mutating func reset() { budget = Self.pageSize }

  mutating func revealEarlier() { budget += Self.pageSize }

  func visibleCount(total: Int) -> Int { min(max(total, 0), budget) }

  func hiddenCount(total: Int) -> Int { max(0, total - budget) }

  func visibleRange(total: Int) -> Range<Int> {
    let start = max(0, total - visibleCount(total: total))
    return start..<max(total, 0)
  }
}

struct AskTranscriptTurn: Identifiable, Equatable, Sendable {
  var id: String
  var latestSource: String
  var publishedSource: String
  var isStreaming: Bool
  var generation: UInt64
}

struct AskTranscriptRenderedTurn: Identifiable, Equatable, Sendable {
  var id: String
  var document: AskMarkdownDocument
  var isStreaming: Bool
  var disposition: BubbleTextDisposition
  var sharesListSelection: Bool
  var excerpt: String
  /// Who said it ("You" / "Pensieve" / "Dictation"). Empty when the pure
  /// engine produced the turn without scope context.
  var roleLabel: String = ""
}

struct AskTranscriptSnapshot: Equatable, Sendable {
  var turns: [AskTranscriptRenderedTurn]
  var hiddenCount: Int
  var totalCount: Int
  var showsJumpToLatest: Bool
  var jumpTitle: String
  var scrollRequests: Int
}

/// Transcript policies that do not belong in a view body: coalesce, cache,
/// follow-tail and the bounded render window. Every turn stays in `turns`.
struct AskTranscriptEngine: Equatable, Sendable {
  private(set) var cache = AskMarkdownCache()
  private(set) var scheduler = AskMarkdownStreamScheduler()
  private(set) var follow = StreamScrollFollowState()
  private(set) var window = AskTranscriptWindow()
  private(set) var turns: [AskTranscriptTurn] = []
  private(set) var scrollRequests = 0
  private var streamingID: String?

  mutating func complete(id: String, source: String, generation: UInt64) {
    cache.observe(id: id, generation: generation)
    _ = cache.finish(id: id, source: source, generation: generation)
    upsert(
      AskTranscriptTurn(
        id: id,
        latestSource: source,
        publishedSource: source,
        isStreaming: false,
        generation: generation))
  }

  @discardableResult
  mutating func ingest(
    id: String, text: String, generation: UInt64, at time: TimeInterval, isFinal: Bool
  ) -> AskStreamPublication? {
    if streamingID != id {
      flushPendingPublication()
      scheduler = AskMarkdownStreamScheduler()
      streamingID = id
    }
    cache.observe(id: id, generation: generation)
    guard
      let publication = scheduler.ingest(
        text: text, generation: generation, at: time, isFinal: isFinal)
    else {
      guard generation == scheduler.acceptedGeneration else { return nil }
      if let index = turns.firstIndex(where: { $0.id == id }) {
        turns[index].latestSource = text
        turns[index].generation = generation
        turns[index].isStreaming = !isFinal
      } else {
        turns.append(
          AskTranscriptTurn(
            id: id,
            latestSource: text,
            publishedSource: "",
            isStreaming: !isFinal,
            generation: generation))
      }
      return nil
    }
    _ = cache.finish(id: id, source: publication.text, generation: publication.generation)
    upsert(
      AskTranscriptTurn(
        id: id,
        latestSource: text,
        publishedSource: publication.text,
        isStreaming: !publication.isFinal,
        generation: publication.generation))
    noteContentChanged()
    return publication
  }

  @discardableResult
  mutating func advanceScheduler(to time: TimeInterval, id: String) -> AskStreamPublication? {
    guard let publication = scheduler.advance(to: time) else { return nil }
    _ = cache.finish(id: id, source: publication.text, generation: publication.generation)
    if let index = turns.firstIndex(where: { $0.id == id }) {
      turns[index].publishedSource = publication.text
    }
    noteContentChanged()
    return publication
  }

  mutating func userScrolledUp() {
    _ = follow.handle(.userScrollBegan)
  }

  mutating func userScrollEnded(isAtLiveEdge: Bool) {
    _ = follow.handle(.userScrollEnded(isAtLiveEdge: isAtLiveEdge))
  }

  mutating func jumpToLatest() {
    if follow.handle(.jumpToLatest) == .scrollToLiveEdge {
      scrollRequests += 1
    }
  }

  mutating func streamFinished() {
    _ = follow.handle(.streamFinished)
  }

  mutating func revealEarlier() {
    window.revealEarlier()
  }

  mutating func replaceThread() {
    window.reset()
    if follow.handle(.threadChanged) == .scrollToLiveEdge {
      scrollRequests += 1
    }
  }

  func snapshot() -> AskTranscriptSnapshot {
    let range = window.visibleRange(total: turns.count)
    let visible = turns[range].map { turn in
      let document =
        cache.document(id: turn.id)
        ?? AskMarkdownDocument(source: turn.publishedSource, blocks: [])
      let disposition = OversizedBubblePolicy.disposition(utf8Count: document.source.utf8.count)
      let excerpt: String
      if case .headPreview(let limit) = disposition {
        excerpt = OversizedBubblePolicy.headPreview(document.source, utf8Limit: limit)
      } else {
        excerpt = document.source
      }
      return AskTranscriptRenderedTurn(
        id: turn.id,
        document: document,
        isStreaming: turn.isStreaming,
        disposition: disposition,
        sharesListSelection: disposition.sharesListSelectionOverlay,
        excerpt: excerpt)
    }
    return AskTranscriptSnapshot(
      turns: visible,
      hiddenCount: window.hiddenCount(total: turns.count),
      totalCount: turns.count,
      showsJumpToLatest: follow.showsJumpToLatest,
      jumpTitle: StreamScrollFollowState.jumpToLatestTitle,
      scrollRequests: scrollRequests)
  }

  private mutating func flushPendingPublication() {
    guard let streamingID, let pending = scheduler.pending else { return }
    let generation = scheduler.acceptedGeneration
    cache.observe(id: streamingID, generation: generation)
    _ = cache.finish(id: streamingID, source: pending, generation: generation)
    if let index = turns.firstIndex(where: { $0.id == streamingID }) {
      turns[index].publishedSource = pending
      turns[index].latestSource = pending
    }
  }

  private mutating func noteContentChanged() {
    if follow.handle(.contentChanged) == .scrollToLiveEdge {
      scrollRequests += 1
    }
  }

  private mutating func upsert(_ turn: AskTranscriptTurn) {
    if let index = turns.firstIndex(where: { $0.id == turn.id }) {
      turns[index] = turn
    } else {
      turns.append(turn)
    }
  }
}

struct AskTranscriptView: View {
  var snapshot: AskTranscriptSnapshot
  var tokens: ThemeTokens
  var containerWidth: CGFloat
  var revealedTurnIDs: Set<String> = []
  var onRevealEarlier: () -> Void = {}
  var onJumpToLatest: () -> Void = {}
  var onRevealTurn: (String) -> Void = { _ in }

  var body: some View {
    // Lazy inside the caller's scroll view. The snapshot is already a bounded
    // window; this stack does not materialize the hidden history.
    LazyVStack(alignment: .leading, spacing: 12) {
      if snapshot.hiddenCount > 0 {
        Button(action: onRevealEarlier) {
          Text(earlierTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: tokens.muted.nsColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show earlier messages")
      }
      ForEach(snapshot.turns) { turn in
        turnBody(turn)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(
      maxWidth: AskTranscriptWidthPolicy.documentWidth(for: containerWidth), alignment: .topLeading
    )
    .clipped()
    .overlay(alignment: .bottom) {
      if snapshot.showsJumpToLatest {
        Button(action: onJumpToLatest) {
          Text(snapshot.jumpTitle)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(nsColor: tokens.text.nsColor))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: tokens.source.nsColor))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot.jumpTitle)
        .padding(.bottom, 8)
      }
    }
  }

  private var earlierTitle: String {
    let count = snapshot.hiddenCount
    return "Show earlier · \(count) turn\(count == 1 ? "" : "s")"
  }

  @ViewBuilder
  private func turnBody(_ turn: AskTranscriptRenderedTurn) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      if !turn.roleLabel.isEmpty {
        Text(turn.roleLabel)
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(Color(nsColor: tokens.muted.nsColor))
          .accessibilityAddTraits(.isHeader)
      }
      turnContent(turn)
    }
    .accessibilityIdentifier(
      turn.isStreaming ? "pensieve.ask.stream" : "pensieve.ask.turn.\(turn.id)")
  }

  @ViewBuilder
  private func turnContent(_ turn: AskTranscriptRenderedTurn) -> some View {
    if turn.document.blocks.isEmpty {
      // The first off-main parse for this revision has not landed yet (or the
      // text is genuinely block-free); show the bounded plain text instead
      // of parsing here or rendering blank.
      plainFallback(turn)
    } else {
      switch turn.disposition {
      case .inline:
        AskMarkdownView(
          document: turn.document,
          tokens: tokens,
          containerWidth: AskTranscriptWidthPolicy.contentWidth(for: containerWidth),
          showsCaret: turn.isStreaming)
      case .headPreview:
        if revealedTurnIDs.contains(turn.id) {
          AskMarkdownView(
            document: turn.document,
            tokens: tokens,
            containerWidth: AskTranscriptWidthPolicy.contentWidth(for: containerWidth),
            showsCaret: turn.isStreaming)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            Text(turn.excerpt)
              .font(.system(size: 13))
              .foregroundStyle(Color(nsColor: tokens.text.nsColor))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show full message") { onRevealTurn(turn.id) }
              .buttonStyle(.plain)
              .foregroundStyle(Color(nsColor: tokens.accent.nsColor))
          }
        }
      }
    }
  }

  private func plainFallback(_ turn: AskTranscriptRenderedTurn) -> some View {
    HStack(alignment: .bottom, spacing: 2) {
      Text(turn.excerpt.isEmpty && turn.isStreaming ? "…" : turn.excerpt)
        .font(.system(size: 13))
        .foregroundStyle(Color(nsColor: tokens.text.nsColor))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if turn.isStreaming {
        Rectangle()
          .fill(Color(nsColor: tokens.warning.nsColor))
          .frame(width: 7, height: 15)
          .accessibilityLabel("Streaming")
      }
    }
  }
}
