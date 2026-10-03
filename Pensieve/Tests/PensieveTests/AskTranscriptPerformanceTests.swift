import XCTest

@testable import Pensieve

final class AskTranscriptPerformanceTests: XCTestCase {
  func testCompletedTurnIsNotReparsedWhileAnotherTurnStreams() {
    var engine = AskTranscriptEngine()
    engine.complete(id: "done", source: "Settled answer\n\n- kept", generation: 1)
    XCTAssertEqual(engine.cache.parseCount(for: "done"), 1)
    let settled = engine.cache.document(id: "done")?.copyableSource

    for index in 0..<50 {
      engine.ingest(
        id: "live",
        text: String(repeating: "n", count: index + 1),
        generation: UInt64(index + 1),
        at: Double(index) * 0.01,
        isFinal: false)
    }

    XCTAssertEqual(engine.cache.parseCount(for: "done"), 1)
    XCTAssertEqual(engine.cache.document(id: "done")?.copyableSource, settled)
    XCTAssertEqual(engine.turns.first { $0.id == "done" }?.latestSource, "Settled answer\n\n- kept")
    XCTAssertLessThanOrEqual(
      engine.cache.parseCount(for: "live"), AskMarkdownStreamScheduler.maxPublicationsPerSecond)
    XCTAssertEqual(engine.turns.first { $0.id == "live" }?.latestSource.count, 50)
  }

  func testStreamingPublishesAtMostTenTimesASecondAndFlushesTheFinalSample() {
    var engine = AskTranscriptEngine()
    for index in 0..<100 {
      engine.ingest(
        id: "live",
        text: "v\(index)",
        generation: UInt64(index + 1),
        at: Double(index) * 0.01,
        isFinal: false)
    }
    let intermediate = engine.scheduler.publications.filter { !$0.isFinal }
    XCTAssertLessThanOrEqual(
      intermediate.count, AskMarkdownStreamScheduler.maxPublicationsPerSecond)
    XCTAssertEqual(intermediate.first?.text, "v0")
    XCTAssertEqual(intermediate.dropFirst().first?.text, "v10")
    XCTAssertFalse(intermediate.contains { $0.text == "v1" })

    let final = engine.ingest(id: "live", text: "FINAL", generation: 1_000, at: 0.95, isFinal: true)
    XCTAssertEqual(final?.text, "FINAL")
    XCTAssertEqual(final?.isFinal, true)
    XCTAssertEqual(engine.cache.document(id: "live")?.copyableSource, "FINAL")
    XCTAssertEqual(engine.turns.first?.latestSource, "FINAL")
    XCTAssertEqual(engine.turns.first?.isStreaming, false)
    XCTAssertLessThanOrEqual(
      engine.scheduler.publications.filter { !$0.isFinal }.count,
      AskMarkdownStreamScheduler.maxPublicationsPerSecond)
  }

  func testStaleGenerationCannotReplaceTheNewerSample() {
    var scheduler = AskMarkdownStreamScheduler()
    XCTAssertNotNil(scheduler.ingest(text: "new", generation: 2, at: 0, isFinal: false))
    XCTAssertNil(scheduler.ingest(text: "old", generation: 1, at: 0.2, isFinal: true))
    XCTAssertEqual(scheduler.publications.map(\.text), ["new"])

    var cache = AskMarkdownCache()
    cache.observe(id: "live", generation: 2)
    XCTAssertNil(cache.finish(id: "live", source: "old", generation: 1))
    XCTAssertEqual(cache.parseCount(for: "live"), 0)
    XCTAssertEqual(cache.finish(id: "live", source: "new", generation: 2)?.copyableSource, "new")
    XCTAssertEqual(cache.parseCount(for: "live"), 1)

    var engine = AskTranscriptEngine()
    engine.ingest(id: "live", text: "current", generation: 4, at: 0, isFinal: false)
    XCTAssertNil(engine.ingest(id: "live", text: "stale", generation: 3, at: 0.4, isFinal: true))
    XCTAssertEqual(engine.cache.document(id: "live")?.copyableSource, "current")
    XCTAssertEqual(engine.turns.first?.latestSource, "current")
  }

  func testAHeldSamplePublishesWhenTheCoalesceIntervalElapses() {
    var scheduler = AskMarkdownStreamScheduler()
    XCTAssertEqual(scheduler.ingest(text: "a", generation: 1, at: 0, isFinal: false)?.text, "a")
    XCTAssertNil(scheduler.ingest(text: "ab", generation: 2, at: 0.04, isFinal: false))
    XCTAssertEqual(scheduler.pending, "ab")
    XCTAssertNil(scheduler.advance(to: 0.09))
    XCTAssertEqual(scheduler.advance(to: 0.10)?.text, "ab")
    XCTAssertNil(scheduler.pending)
  }

  func testTheSameCompletedSourceIsParsedOnce() {
    var cache = AskMarkdownCache()
    cache.observe(id: "done", generation: 1)
    XCTAssertEqual(cache.finish(id: "done", source: "same", generation: 1)?.copyableSource, "same")
    let repeated = cache.finish(id: "done", source: "same", generation: 1)
    XCTAssertEqual(repeated?.copyableSource, "same")
    XCTAssertFalse(repeated?.blocks.isEmpty ?? true)
    XCTAssertEqual(cache.parseCount(for: "done"), 1)

    var engine = AskTranscriptEngine()
    engine.complete(id: "done", source: "same", generation: 1)
    engine.complete(id: "done", source: "same", generation: 1)
    XCTAssertEqual(engine.cache.parseCount(for: "done"), 1)
    XCTAssertEqual(engine.turns.count, 1)
  }

  func testALongStreamDropsEarlierRevisionsInsteadOfKeepingEveryPrefix() {
    var engine = AskTranscriptEngine()
    let settled = "Settled answer stays one copy"
    engine.complete(id: "done", source: settled, generation: 1)

    let steps = 240
    let stride = 64
    var streamedBytes = 0
    for index in 0..<steps {
      let count = (index + 1) * stride
      streamedBytes += count
      let text = String(repeating: "q", count: count)
      let last = index == steps - 1
      engine.ingest(
        id: "live",
        text: text,
        generation: UInt64(index + 1),
        at: Double(index) * AskMarkdownStreamScheduler.minimumInterval,
        isFinal: last)
    }

    let finalCount = steps * stride
    XCTAssertEqual(engine.turns.first { $0.id == "live" }?.latestSource.utf8.count, finalCount)
    XCTAssertEqual(engine.cache.document(id: "live")?.copyableSource.utf8.count, finalCount)
    XCTAssertEqual(engine.cache.parseCount(for: "done"), 1)
    XCTAssertEqual(engine.cache.document(id: "done")?.copyableSource, settled)
    XCTAssertEqual(
      engine.cache.retainedSourceUTF8, settled.utf8.count + finalCount)
    XCTAssertGreaterThan(streamedBytes, engine.cache.retainedSourceUTF8 * 20)
    XCTAssertLessThanOrEqual(
      engine.cache.revisionSamples(for: "live").count, AskMarkdownCache.revisionSampleLimit)
    XCTAssertLessThan(engine.cache.revisionSamples(for: "live").count, steps)
    XCTAssertEqual(
      engine.cache.revisionSamples(for: "live").last?.utf8Count, finalCount)
    XCTAssertLessThanOrEqual(
      engine.scheduler.publications.count, AskMarkdownStreamScheduler.retainedPublicationLimit)
    XCTAssertLessThan(engine.scheduler.retainedPublicationUTF8, streamedBytes / 2)
    XCTAssertLessThanOrEqual(
      engine.scheduler.retainedPublicationUTF8,
      AskMarkdownStreamScheduler.retainedPublicationLimit * finalCount)
  }
}
