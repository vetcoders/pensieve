import CoreGraphics
import XCTest

@testable import Pensieve

final class AskScrollFollowTests: XCTestCase {
  func testScrollingUpPausesFollowAndJumpToLatestResumesIt() {
    var engine = AskTranscriptEngine()
    engine.complete(id: "seed", source: "already there", generation: 1)
    let before = engine.scrollRequests

    engine.userScrolledUp()
    engine.ingest(id: "live", text: "growing", generation: 1, at: 0, isFinal: false)

    XCTAssertFalse(engine.follow.followingLive)
    XCTAssertEqual(engine.scrollRequests, before)
    XCTAssertTrue(engine.snapshot().showsJumpToLatest)
    XCTAssertEqual(engine.snapshot().jumpTitle, "Jump to latest")
    XCTAssertEqual(engine.snapshot().jumpTitle, StreamScrollFollowState.jumpToLatestTitle)

    engine.userScrollEnded(isAtLiveEdge: false)
    XCTAssertFalse(engine.follow.followingLive)

    engine.jumpToLatest()
    XCTAssertTrue(engine.follow.followingLive)
    XCTAssertFalse(engine.snapshot().showsJumpToLatest)
    XCTAssertGreaterThan(engine.scrollRequests, before)

    engine.ingest(id: "live", text: "growing more", generation: 2, at: 0.2, isFinal: false)
    XCTAssertGreaterThan(engine.scrollRequests, before + 1)
  }

  func testFinishingTheStreamDoesNotStealAPausedReader() {
    var engine = AskTranscriptEngine()
    engine.userScrolledUp()
    engine.ingest(id: "live", text: "partial", generation: 1, at: 0, isFinal: true)
    engine.streamFinished()
    XCTAssertFalse(engine.follow.followingLive)
    XCTAssertTrue(engine.snapshot().showsJumpToLatest)

    engine.userScrollEnded(isAtLiveEdge: true)
    XCTAssertTrue(engine.follow.followingLive)
    engine.ingest(id: "next", text: "tail", generation: 1, at: 0, isFinal: false)
    XCTAssertEqual(engine.scrollRequests, 1)
  }

  func testLargeHistoryKeepsEveryTurnBehindABoundedWindow() {
    var engine = AskTranscriptEngine()
    for index in 0..<300 {
      engine.complete(id: "t\(index)", source: "body \(index)", generation: 1)
    }
    let first = engine.snapshot()
    XCTAssertEqual(engine.turns.count, 300)
    XCTAssertEqual(first.totalCount, 300)
    XCTAssertEqual(first.turns.count, AskTranscriptWindow.pageSize)
    XCTAssertEqual(first.hiddenCount, 180)
    XCTAssertEqual(first.turns.first?.id, "t180")
    XCTAssertEqual(first.turns.last?.id, "t299")
    XCTAssertEqual(first.turns.last?.document.copyableSource, "body 299")

    engine.revealEarlier()
    let revealed = engine.snapshot()
    XCTAssertEqual(engine.turns.count, 300)
    XCTAssertEqual(revealed.turns.count, 240)
    XCTAssertEqual(revealed.hiddenCount, 60)
    XCTAssertEqual(revealed.turns.first?.id, "t60")
    XCTAssertEqual(engine.turns.map(\.id), (0..<300).map { "t\($0)" })

    engine.replaceThread()
    XCTAssertEqual(engine.turns.count, 300)
    XCTAssertEqual(engine.snapshot().turns.count, AskTranscriptWindow.pageSize)
  }

  func testOversizedTurnsPreviewAHeadWithoutDroppingTheSource() {
    let source = String(repeating: "a", count: 70_000)
    XCTAssertEqual(OversizedBubblePolicy.disposition(utf8Count: 100), .inline)
    XCTAssertEqual(
      OversizedBubblePolicy.disposition(utf8Count: source.utf8.count),
      .headPreview(headUTF8: OversizedBubblePolicy.headPreviewUTF8))

    var engine = AskTranscriptEngine()
    engine.complete(id: "huge", source: source, generation: 1)
    let turn = engine.snapshot().turns[0]
    XCTAssertEqual(turn.document.copyableSource, source)
    XCTAssertEqual(turn.excerpt.utf8.count, OversizedBubblePolicy.headPreviewUTF8)
    XCTAssertFalse(turn.sharesListSelection)
    XCTAssertLessThan(turn.excerpt.count, source.count)
  }

  func testTheTranscriptWidthStaysPinnedToTheViewport() {
    XCTAssertEqual(AskTranscriptWidthPolicy.documentWidth(for: 640), 640)
    XCTAssertTrue(
      StreamScrollFollowState.followTailAfterScroll(contentBottom: 100, viewportHeight: 100))
    XCTAssertFalse(
      StreamScrollFollowState.followTailAfterScroll(contentBottom: 200, viewportHeight: 100))

    let plan = AskMarkdownOverflow.plan(
      containerWidth: 640, codeCharacters: 4_000, tableColumns: 30)
    XCTAssertLessThanOrEqual(plan.proseWidth, AskTranscriptWidthPolicy.documentWidth(for: 640))
    XCTAssertLessThanOrEqual(plan.tableViewportWidth, plan.proseWidth)
    XCTAssertGreaterThan(plan.tableContentWidth, plan.tableViewportWidth)
  }
}
