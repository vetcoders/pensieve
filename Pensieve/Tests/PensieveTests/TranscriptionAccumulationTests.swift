import AppKit
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

  func testCadenceCommitPromotesSparsePreviewWithoutDuplicatingCumulativeEngineText() {
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)

    service.receivePreview("alpha")
    service.commitActivePreviewForCadence()

    XCTAssertEqual(service.committed, "alpha")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "alpha")

    service.receivePreview("alpha beta")
    XCTAssertEqual(service.rendered, "alpha\nbeta")
    service.commitActivePreviewForCadence()

    XCTAssertEqual(service.committed, "alpha\nbeta")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "alpha\nbeta")

    service.receivePreview("alpha beta gamma")
    XCTAssertEqual(service.rendered, "alpha\nbeta\ngamma")
    service.receiveFinal("alpha beta gamma", language: "en")

    XCTAssertEqual(service.committed, "alpha\nbeta\ngamma")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "alpha\nbeta\ngamma")
  }

  func testCadenceCommitLeavesTailPreviewCadenceGrowing() {
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)

    service.receivePreview("alpha")
    service.commitActivePreviewForCadence()
    service.receivePreview("beta")
    service.commitActivePreviewForCadence()
    service.receivePreview("gamma")

    XCTAssertEqual(service.committed, "alpha\nbeta")
    XCTAssertEqual(service.preview, "gamma")
    XCTAssertEqual(service.rendered, "alpha\nbeta\ngamma")
  }

  func testFormatCompositionUsesVistaEngineFormatterWhenAvailable() async {
    let engine = MockVistaAutocompleteEngine(
      formattingAvailable: true,
      formattingHandler: { text, assistive in
        XCTAssertFalse(assistive)
        return "formatted: \(text)"
      }
    )
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.receivePreview("raw transcript")
    let formatted = await service.formatComposition()

    XCTAssertEqual(formatted, "formatted: raw transcript")
    XCTAssertEqual(service.committed, "formatted: raw transcript")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "formatted: raw transcript")
    XCTAssertFalse(service.isFormatting)
    XCTAssertNil(service.lastError)
  }

  func testFormatCompositionFallsBackToRawTextWhenFormatterUnavailable() async {
    let engine = MockVistaAutocompleteEngine(formattingAvailable: false)
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.receivePreview("raw transcript")
    let formatted = await service.formatComposition()

    XCTAssertEqual(formatted, "raw transcript")
    XCTAssertEqual(service.committed, "")
    XCTAssertEqual(service.preview, "raw transcript")
    XCTAssertEqual(service.rendered, "raw transcript")
    XCTAssertFalse(service.isFormatting)
    XCTAssertNil(service.lastError)
  }

  func testMarkdownTextViewInsertsSentTranscriptionAtCaret() {
    let surface = MarkdownEditorSurface(text: "hello world", fontSize: 14)
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))

    XCTAssertTrue(surface.textView.insertTextAtSelection(" tafla"))
    XCTAssertEqual(surface.textStorage.string, "hello tafla world")
    XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 11, length: 0))
  }

  func testAppControllerSendsCompositionToProvidedActiveEditorAndClearsTafla() {
    let appState = AppState()
    appState.documentSession.createUntitled()
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service
    )
    let surface = MarkdownEditorSurface(text: "target", fontSize: 14)
    surface.textView.setSelectedRange(NSRange(location: 6, length: 0))

    service.receiveFinal("tafla text", language: "en")

    XCTAssertTrue(controller.sendTranscriptionToActiveEditor(activeTextView: surface.textView))
    XCTAssertEqual(surface.textStorage.string, "targettafla text")
    XCTAssertEqual(service.rendered, "")
    XCTAssertNil(appState.lastError)
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
