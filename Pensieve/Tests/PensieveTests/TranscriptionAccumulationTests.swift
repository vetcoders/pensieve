import XCTest

@testable import Pensieve

@MainActor
final class TranscriptionAccumulationTests: XCTestCase {
  func testPreviewTailReplacesWithoutDroppingCommittedText() {
    let service = TranscriptionService()

    service.receivePreview("opening thought")
    XCTAssertEqual(service.rendered, "opening thought")

    service.receiveFinal("opening thought", language: "en")
    XCTAssertEqual(service.committed, "opening thought")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "opening thought")

    service.receivePreview("second utterance")
    XCTAssertEqual(service.rendered, "opening thought\nsecond utterance")

    service.receivePreview("second utterance extended")
    XCTAssertEqual(service.committed, "opening thought")
    XCTAssertEqual(service.preview, "second utterance extended")
    XCTAssertEqual(service.rendered, "opening thought\nsecond utterance extended")
  }

  func testSparseFinalContinuousSpeechCadenceAccumulatesEveryFinal() {
    let service = TranscriptionService()

    service.receivePreview("monologue part one")
    service.receivePreview("monologue part one growing")
    service.receivePreview("monologue part one growing still")
    service.receiveFinal("monologue part one growing still", language: "en")

    service.receivePreview("monologue part two")
    service.receivePreview("monologue part two keeps going")
    service.receiveFinal("monologue part two keeps going", language: "en")

    XCTAssertEqual(
      service.committed,
      """
      monologue part one growing still
      monologue part two keeps going
      """
    )
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, service.committed)
    XCTAssertEqual(service.lastLanguage, "en")
  }

  func testVistaEventListenerCallbacksMarshalIntoAccumulationState() async {
    let service = TranscriptionService()

    service.onTranscriptionPreview(text: "preview window")
    await Task.yield()
    XCTAssertEqual(service.rendered, "preview window")

    service.onTranscriptionPreview(text: "preview window rewritten")
    service.onTranscriptionFinal(text: "preview window rewritten", language: "en")
    await Task.yield()
    await Task.yield()

    XCTAssertEqual(service.committed, "preview window rewritten")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "preview window rewritten")
  }

  func testEmptyFinalClearsPreviewWithoutCommittingBlankUtterance() {
    let service = TranscriptionService()

    service.receivePreview("draft tail")
    service.receiveFinal("  \n", language: "en")

    XCTAssertEqual(service.committed, "")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "")
  }

  func testFinalUtterancesAccumulateInArrivalOrderWithTrimmedBoundaries() {
    let service = TranscriptionService()

    service.receiveFinal(" first utterance\n", language: "en")
    service.receiveFinal("\tsecond utterance", language: "pl")
    service.receiveFinal("third utterance  ", language: "de")

    XCTAssertEqual(
      service.committed,
      """
      first utterance
      second utterance
      third utterance
      """
    )
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, service.committed)
    XCTAssertEqual(service.lastLanguage, "de")
  }

  func testFinalFlushReplacesPreviewTailAndClearsBuffer() {
    let service = TranscriptionService()

    service.receivePreview("draft phrase")
    XCTAssertEqual(service.rendered, "draft phrase")

    service.receiveFinal("confirmed phrase", language: "en")

    XCTAssertEqual(service.committed, "confirmed phrase")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "confirmed phrase")
  }

  func testResetTranscriptClearsBuffersAndAllowsFreshAccumulation() {
    let service = TranscriptionService()

    service.receiveFinal("stale utterance", language: "en")
    service.receivePreview("stale preview")
    service.resetTranscript()

    XCTAssertEqual(service.committed, "")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "")
    XCTAssertNil(service.lastLanguage)
    XCTAssertNil(service.lastError)

    service.receivePreview("fresh preview")
    service.receiveFinal("fresh final", language: "es")

    XCTAssertEqual(service.committed, "fresh final")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "fresh final")
    XCTAssertEqual(service.lastLanguage, "es")
  }

  func testBlankPreviewAndBlankFinalKeepCommittedTextStable() {
    let service = TranscriptionService()

    service.receiveFinal("kept utterance", language: "en")
    service.receivePreview("")
    service.receiveFinal("", language: "en")

    XCTAssertEqual(service.committed, "kept utterance")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "kept utterance")
    XCTAssertEqual(service.lastLanguage, "en")
  }
}
