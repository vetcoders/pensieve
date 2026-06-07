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
}
