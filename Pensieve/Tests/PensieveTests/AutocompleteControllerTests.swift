import AppKit
import Foundation
import XCTest

@testable import Pensieve

@MainActor
final class AutocompleteControllerTests: XCTestCase {
  private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 10_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition() {
      if DispatchTime.now().uptimeNanoseconds >= deadline {
        XCTFail("condition timed out", file: file, line: line)
        return
      }
      try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
  }

  func testTypingPauseYieldsSuggestion() async {
    let engine = MockVistaAutocompleteEngine(completionHandler: { prefix, maxTokens in
      XCTAssertEqual(prefix, "hello")
      XCTAssertEqual(maxTokens, 32)
      return " world"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 20_000_000)

    controller.textDidChange(prefix: "hello")
    XCTAssertNil(controller.suggestion)

    await waitUntil {
      controller.suggestion == " world"
    }

    XCTAssertEqual(controller.suggestion, " world")
    XCTAssertNil(controller.lastError)
  }

  func testNewKeystrokeSuppressesPriorCompletion() async {
    let engine = MockVistaAutocompleteEngine(completionHandler: { prefix, _ in
      if prefix == "alpha" {
        await nonCancellableSleep(nanoseconds: 150_000_000)
        return " stale"
      }
      await nonCancellableSleep(nanoseconds: 10_000_000)
      return " fresh"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "alpha")
    try? await Task.sleep(nanoseconds: 30_000_000)
    controller.textDidChange(prefix: "alpha b")

    try? await Task.sleep(nanoseconds: 260_000_000)

    XCTAssertEqual(controller.suggestion, " fresh")
    XCTAssertNotEqual(controller.suggestion, " stale")
  }

  func testNewKeystrokeCancelsPriorTaskBeforeEngineCompletes() async {
    let staleTaskGate = AsyncGate()
    let staleTaskStarted = expectation(description: "stale completion task started")
    let staleTaskObservedCancellation = expectation(
      description: "stale completion task observed cancellation")
    let engine = MockVistaAutocompleteEngine(completionHandler: { prefix, _ in
      if prefix == "alpha" {
        staleTaskStarted.fulfill()
        await staleTaskGate.wait()
        XCTAssertTrue(Task.isCancelled)
        staleTaskObservedCancellation.fulfill()
        return " stale"
      }
      return " fresh"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)

    controller.textDidChange(prefix: "alpha")
    await fulfillment(of: [staleTaskStarted], timeout: 1.0)
    controller.textDidChange(prefix: "alpha b")
    await staleTaskGate.open()

    await fulfillment(of: [staleTaskObservedCancellation], timeout: 1.0)
    await waitUntil { controller.suggestion == " fresh" }

    XCTAssertEqual(controller.suggestion, " fresh")
    XCTAssertNotEqual(controller.suggestion, " stale")
  }

  func testAcceptAutocompleteInsertsSuggestionOnce() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)

    XCTAssertTrue(surface.acceptAutocompleteSuggestion())

    XCTAssertEqual(surface.textStorage.string, "hello world")
    XCTAssertNil(surface.textView.autocompleteGhostText)
  }

  func testOnlyAppliedSuggestionCommitsDocumentSession() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AutocompleteSessionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DocumentAISessionStore(fileURL: root.appendingPathComponent("sessions.json"))
    let controller = AutocompleteController(
      engine: MockVistaAutocompleteEngine(completionHandler: { _, _ in " world" }),
      debounceNanoseconds: 1,
      sessionStore: store)
    let surface = MarkdownEditorSurface(
      text: "hello",
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: true,
      documentID: "doc-accept",
      autocompleteController: controller)
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    controller.textDidChange(
      context: AutocompleteContext(beforeCursor: "hello", afterCursor: ""),
      replacementRange: NSRange(location: 5, length: 0))
    await waitUntil { controller.suggestion == " world" }
    surface.textView.setAutocompleteGhost(" world", at: 5)

    XCTAssertTrue(surface.acceptAutocompleteSuggestion())
    XCTAssertEqual(store.session(for: "doc-accept").acceptedTurns.map(\.output), [" world"])
  }

  func testDismissedSuggestionDoesNotCommitDocumentSession() async {
    let store = DocumentAISessionStore(
      fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("dismissed-\(UUID().uuidString).json"))
    let controller = AutocompleteController(
      engine: MockVistaAutocompleteEngine(completionHandler: { _, _ in " world" }),
      debounceNanoseconds: 1,
      sessionStore: store)
    controller.configureDocument(id: "doc-dismiss")
    controller.textDidChange(
      context: AutocompleteContext(beforeCursor: "hello", afterCursor: ""),
      replacementRange: NSRange(location: 5, length: 0))
    await waitUntil { controller.suggestion == " world" }

    controller.cancel()

    XCTAssertTrue(store.session(for: "doc-dismiss").acceptedTurns.isEmpty)
  }

  func testNativeUndoRestoresExactBytesAndInvalidatesOpaqueContinuation() {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("undo-session-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = DocumentAISessionStore(fileURL: file)
    store.save(
      DocumentAISession(
        documentID: "doc-undo",
        providerFingerprint: ProviderFingerprint(
          shape: .openAIResponses,
          endpoint: "https://api.openai.com/v1/responses",
          model: "gpt-test"),
        acceptedTurns: [AcceptedAITurn(input: "hello", output: " world")],
        continuation: .openAI(previousResponseID: "resp-committed")))
    let controller = AutocompleteController(
      engine: MockVistaAutocompleteEngine(), debounceNanoseconds: 1, sessionStore: store)
    let surface = MarkdownEditorSurface(
      text: "hello world",
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      documentID: "doc-undo",
      autocompleteController: controller)
    surface.textView.setSelectedRange(NSRange(location: 11, length: 0))

    surface.textView.insertText("!", replacementRange: NSRange(location: 11, length: 0))
    XCTAssertEqual(surface.textStorage.string, "hello world!")
    surface.textView.undoManager?.undo()

    XCTAssertEqual(surface.textStorage.string, "hello world")
    XCTAssertEqual(store.session(for: "doc-undo").continuation, .none)
  }

  func testDismissAutocompleteDoesNotMutateTextStorage() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)

    XCTAssertTrue(surface.dismissAutocompleteSuggestion())

    XCTAssertEqual(surface.textStorage.string, "hello")
    XCTAssertNil(surface.textView.autocompleteGhostText)
  }

  func testInvalidateAutocompleteClearsGhostOnly() {
    let surface = makeSurface(text: "hello")
    surface.textView.setAutocompleteGhost(" world", at: 5)

    surface.invalidateAutocomplete()

    XCTAssertEqual(surface.textStorage.string, "hello")
    XCTAssertFalse(surface.textView.hasAutocompleteGhost)
  }

  func testStaleAutocompleteAnchorDoesNotInsertAfterCaretMove() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)
    surface.textView.setSelectedRange(NSRange(location: 0, length: 0))

    XCTAssertFalse(surface.acceptAutocompleteSuggestion())

    XCTAssertEqual(surface.textStorage.string, "hello")
    XCTAssertFalse(surface.textView.hasAutocompleteGhost)
  }

  func testEditInvalidatesAutocompleteAndPreventsStaleInsert() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)

    XCTAssertTrue(surface.textView.insertTextAtSelection("!"))
    XCTAssertFalse(surface.acceptAutocompleteSuggestion())

    XCTAssertEqual(surface.textStorage.string, "hello!")
    XCTAssertFalse(surface.textView.hasAutocompleteGhost)
  }

  func testDefaultControllerWithoutEngineSurfacesUnavailableError() {
    let controller = AutocompleteController(debounceNanoseconds: 1)

    controller.textDidChange(prefix: "hello")

    XCTAssertNil(controller.suggestion)
    XCTAssertEqual(controller.lastError, AutocompleteController.engineUnavailableMessage)
  }

  func testCompletionPathNeverTouchesSttModelInit() async {
    // complete() is an HTTP call to the LLM endpoint; initModel() loads the
    // whisper STT model. The completion path must not couple to STT: with the
    // model "not loaded", a suggestion must still arrive and init must never run.
    let engine = MockVistaAutocompleteEngine(
      completionHandler: { _, _ in " suggestion" },
      modelLoaded: false,
      initModelHandler: {
        XCTFail("completion path must not init the STT model")
      })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)

    controller.textDidChange(prefix: "hello")
    for _ in 0..<200 where controller.suggestion == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(controller.suggestion, " suggestion")
    XCTAssertNil(controller.lastError)
  }

  func testEngineFactoryIsInvokedLazilyAndOnce() async {
    let factoryCalls = AttemptCounter()
    let controller = AutocompleteController(
      engineFactory: {
        factoryCalls.increment()
        return MockVistaAutocompleteEngine(completionHandler: { _, _ in " world" })
      },
      debounceNanoseconds: 10_000_000)

    XCTAssertEqual(factoryCalls.value, 0, "the factory must not run at construction time")

    controller.textDidChange(prefix: "hello")
    await waitUntil { controller.suggestion == " world" }
    XCTAssertEqual(controller.suggestion, " world")

    controller.textDidChange(prefix: "hello w")
    await waitUntil { factoryCalls.value == 1 }

    XCTAssertEqual(factoryCalls.value, 1, "the resolved engine must be cached across requests")
  }

  func testProductionDefaultSurfaceHasEngineSource() {
    // Guards the EditorView wiring: the default MarkdownEditorSurface (the
    // production path through EditorRepresentable.makeNSView) must own a
    // controller with a real engine source. The factory is lazy, so this
    // never constructs a VistaEngine.
    let surface = MarkdownEditorSurface(text: "hello", fontSize: 14)
    XCTAssertTrue(surface.autocompleteController.hasEngineSource)
  }

  func testTypedUnavailableLatchesAcrossKeystrokes() async {
    let attempts = AttemptCounter()
    let unavailable = VistaError.ModelError(
      msg: "completion LLM unavailable: set LLM_ENDPOINT, LLM_ASSISTIVE_ENDPOINT, "
        + "or LLM_FORMATTING_ENDPOINT")
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      attempts.increment()
      throw unavailable
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    await waitUntil {
      attempts.value == 1
        && controller.lastError == AutocompleteController.completionProviderUnavailableMessage
    }

    XCTAssertEqual(attempts.value, 1)
    XCTAssertEqual(
      controller.lastError, AutocompleteController.completionProviderUnavailableMessage)

    controller.textDidChange(prefix: "hello a")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(
      attempts.value, 1, "typed unavailable must not be retried per keystroke")
    XCTAssertEqual(
      controller.lastError, AutocompleteController.completionProviderUnavailableMessage)
    XCTAssertNil(controller.suggestion)
  }

  func testTransientCompletionErrorDoesNotLatch() async {
    let attempts = AttemptCounter()
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      attempts.increment()
      throw VistaError.ModelError(msg: "completion request failed: connection reset")
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(controller.lastError, "AI autocomplete failed: connection reset")

    controller.textDidChange(prefix: "hello a")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(
      attempts.value, 2,
      "a transient failure must not kill autocomplete; the debounce is the storm guard")
  }

  func testCancelResetsUnavailableLatch() async {
    let attempts = AttemptCounter()
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      attempts.increment()
      throw VistaError.ModelError(msg: "completion LLM unavailable: set LLM_ENDPOINT")
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(attempts.value, 1)

    controller.cancel()
    controller.textDidChange(prefix: "hello again")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(attempts.value, 2, "cancel() must re-open the deliberate retry path")
  }

  func testCancelIgnoresUnavailableErrorFromCancelledRequest() async {
    let attempts = AttemptCounter()
    let firstRequestStarted = expectation(description: "first request reached the engine")
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      attempts.increment()
      if attempts.value == 1 {
        firstRequestStarted.fulfill()
        await nonCancellableSleep(nanoseconds: 100_000_000)
        throw VistaError.ModelError(
          msg: "completion LLM unavailable: set LLM_ENDPOINT")
      }
      return " fresh"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)

    controller.textDidChange(prefix: "hello")
    await fulfillment(of: [firstRequestStarted], timeout: 1.0)
    controller.cancel()
    try? await Task.sleep(nanoseconds: 150_000_000)

    XCTAssertNil(
      controller.lastError,
      "a cancelled request must not restore an error or unavailable latch")

    controller.textDidChange(prefix: "hello again")
    await waitUntil {
      controller.suggestion == " fresh"
    }

    XCTAssertEqual(attempts.value, 2, "cancel() must keep the explicit retry path open")
  }

  func testControllerDeinitCancelsInFlightRequest() async {
    let requestStarted = expectation(description: "request reached the engine")
    let requestCancelled = expectation(description: "deinit cancelled the request")
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      requestStarted.fulfill()
      do {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return " should not complete"
      } catch is CancellationError {
        requestCancelled.fulfill()
        throw CancellationError()
      }
    })
    var controller: AutocompleteController? = AutocompleteController(
      engine: engine, debounceNanoseconds: 1)
    weak let weakController = controller

    controller?.textDidChange(prefix: "hello")
    await fulfillment(of: [requestStarted], timeout: 1.0)
    controller = nil

    await fulfillment(of: [requestCancelled], timeout: 1.0)
    XCTAssertNil(weakController, "the completion task must not retain its controller")
  }

  func testCompositionCancelsInFlightRequestAndSuppressesProviderState() async {
    let attempts = AttemptCounter()
    let firstRequestStarted = expectation(description: "first request reached the engine")
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      attempts.increment()
      if attempts.value == 1 {
        firstRequestStarted.fulfill()
        await nonCancellableSleep(nanoseconds: 100_000_000)
        return " stale"
      }
      return " fresh"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)

    controller.textDidChange(prefix: "hello")
    await fulfillment(of: [firstRequestStarted], timeout: 1.0)
    controller.textDidChange(prefix: "helloに", isComposing: true)
    try? await Task.sleep(nanoseconds: 150_000_000)

    XCTAssertNil(controller.suggestion)
    XCTAssertNil(controller.lastError)
    XCTAssertEqual(attempts.value, 1, "composition updates must not reach the provider")

    controller.textDidChange(prefix: "hello日本")
    await waitUntil {
      controller.suggestion == " fresh"
    }
    XCTAssertEqual(attempts.value, 2)
  }

  func testInitEnabledFlagSurvivesToTypingPath() async {
    // The trailing update() inside init defaults aiAutocompleteEnabled to
    // false; before the pass-through fix it silently disabled autocomplete on
    // every surface built with init(aiAutocompleteEnabled: true).
    let attempts = AttemptCounter()
    let surface = MarkdownEditorSurface(
      text: "hello",
      fontSize: 14,
      aiAutocompleteEnabled: true,
      autocompleteController: AutocompleteController(
        engine: MockVistaAutocompleteEngine(completionHandler: { _, _ in
          attempts.increment()
          return " world"
        }),
        debounceNanoseconds: 1
      )
    )
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textDidChange(
      Notification(name: NSText.didChangeNotification, object: surface.textView))

    for _ in 0..<200 where attempts.value == 0 {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(
      attempts.value, 1,
      "init(aiAutocompleteEnabled: true) must survive the trailing update() defaults")
  }

  func testMarkedTextSuppressesCompletionRequest() async {
    // IME composition must not fire LLM requests: textDidChange fires per
    // candidate update, and half-composed characters are not a prompt.
    let attempts = AttemptCounter()
    let surface = MarkdownEditorSurface(
      text: "hello",
      fontSize: 14,
      aiAutocompleteEnabled: true,
      autocompleteController: AutocompleteController(
        engine: MockVistaAutocompleteEngine(completionHandler: { _, _ in
          attempts.increment()
          return " world"
        }),
        debounceNanoseconds: 1
      )
    )
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setMarkedText(
      "に", selectedRange: NSRange(location: 0, length: 1),
      replacementRange: NSRange(location: 5, length: 0))
    XCTAssertTrue(surface.textView.hasMarkedText())

    surface.textDidChange(
      Notification(name: NSText.didChangeNotification, object: surface.textView))
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(attempts.value, 0, "composition keystrokes must not reach the engine")
    XCTAssertFalse(surface.textView.hasAutocompleteGhost)
  }

  func testSuggestionArrivingMidCompositionDoesNotRenderGhost() async {
    // Models a completion that slips past the request-side marked-text skip
    // (fired straight at the controller): when it publishes while composition
    // is active and the selection has been stable since the capture, the
    // render path itself must refuse to paint a ghost into the marked range.
    let surface = MarkdownEditorSurface(
      text: "hello",
      fontSize: 14,
      aiAutocompleteEnabled: true,
      autocompleteController: AutocompleteController(
        engine: MockVistaAutocompleteEngine(completionHandler: { _, _ in " world" }),
        debounceNanoseconds: 1
      )
    )
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    // Caret AFTER the composed character (zero-length selection): the render
    // path's selection-length guard must not be what saves us here.
    surface.textView.setMarkedText(
      "に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 5, length: 0))
    XCTAssertTrue(surface.textView.hasMarkedText())
    XCTAssertEqual(surface.textView.selectedRange().length, 0)

    surface.autocompleteController.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 250_000_000)

    XCTAssertEqual(surface.autocompleteController.suggestion, " world")
    XCTAssertFalse(
      surface.textView.hasAutocompleteGhost,
      "a ghost must never render inside an active IME composition")
  }

  func testAcceptRefusedDuringComposition() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)
    surface.textView.setMarkedText(
      "に", selectedRange: NSRange(location: 0, length: 1),
      replacementRange: NSRange(location: 5, length: 0))
    XCTAssertTrue(surface.textView.hasMarkedText())

    XCTAssertFalse(surface.acceptAutocompleteSuggestion())

    XCTAssertFalse(surface.textStorage.string.contains("world"))
    XCTAssertFalse(surface.textView.hasAutocompleteGhost)
  }

  func testBoundedAutocompletePrefixCapsTail() {
    let cap = MarkdownEditorSurface.autocompletePrefixMaxUTF16
    let text = String(repeating: "a", count: cap + 1000) as NSString

    let bounded = MarkdownEditorSurface.boundedAutocompletePrefix(text, caret: text.length)
    XCTAssertEqual(bounded.utf16.count, cap)
    XCTAssertTrue(bounded.allSatisfy { $0 == "a" })

    // Short documents pass through untouched.
    let short = "hello" as NSString
    XCTAssertEqual(MarkdownEditorSurface.boundedAutocompletePrefix(short, caret: 5), "hello")
    // Caret clamped into bounds.
    XCTAssertEqual(MarkdownEditorSurface.boundedAutocompletePrefix(short, caret: 99), "hello")
  }

  func testBoundedAutocompletePrefixNeverSplitsSurrogatePair() {
    let cap = MarkdownEditorSurface.autocompletePrefixMaxUTF16
    // Layout: cap UTF-16 units of emoji, one 'x', then 10 more emoji.
    // caret-at-end puts the raw window start at an ODD offset inside the
    // leading emoji run — mid-surrogate-pair without the boundary snap.
    let text =
      (String(repeating: "😀", count: cap / 2) + "x"
      + String(repeating: "😀", count: 10)) as NSString
    let caret = text.length

    let bounded = MarkdownEditorSurface.boundedAutocompletePrefix(text, caret: caret)

    XCTAssertLessThanOrEqual(bounded.utf16.count, cap + 1)
    XCTAssertTrue(bounded.hasPrefix("😀"), "window start must snap to a composed boundary")
    XCTAssertTrue(bounded.hasSuffix("😀"))
  }

  func testBoundedAutocompleteContextPreservesBothSidesOfCaret() {
    let text = "Przed kursorem?Po kursorze." as NSString
    let caret = ("Przed kursorem?" as NSString).length

    let context = MarkdownEditorSurface.boundedAutocompleteContext(
      text, caret: caret, beforeMaxUTF16: 9, afterMaxUTF16: 11)

    XCTAssertEqual(context.beforeCursor, "kursorem?")
    XCTAssertEqual(context.afterCursor, "Po kursorze")
  }

  func testBoundedAutocompleteContextDoesNotSplitSuffixEmoji() {
    let text = "start😀middle" as NSString
    let caret = ("start" as NSString).length

    let context = MarkdownEditorSurface.boundedAutocompleteContext(
      text, caret: caret, beforeMaxUTF16: 20, afterMaxUTF16: 1)

    XCTAssertEqual(context.beforeCursor, "start")
    XCTAssertEqual(context.afterCursor, "😀")
  }

  func testTypingPathSendsBoundedPrefix() async {
    let cap = MarkdownEditorSurface.autocompletePrefixMaxUTF16
    let capturedLength = AttemptCounter()
    let surface = MarkdownEditorSurface(
      text: String(repeating: "a", count: cap + 2000),
      fontSize: 14,
      aiAutocompleteEnabled: true,
      autocompleteController: AutocompleteController(
        engine: MockVistaAutocompleteEngine(completionHandler: { prefix, _ in
          capturedLength.record(prefix.utf16.count)
          return " world"
        }),
        debounceNanoseconds: 1
      )
    )
    surface.textView.setSelectedRange(NSRange(location: cap + 2000, length: 0))
    surface.textDidChange(
      Notification(name: NSText.didChangeNotification, object: surface.textView))

    for _ in 0..<200 where capturedLength.value == 0 {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(
      capturedLength.value, cap,
      "the live typing path must cap the prompt payload at the prefix window")
  }

  func testOnlyPlainTabAcceptsAutocomplete() {
    // Shift-Tab is backtab (outdent / focus navigation); Ctrl/Option/Command
    // chords carry their own meanings. None of them may swallow a visible
    // ghost and insert text the user asked nothing about.
    XCTAssertTrue(
      MarkdownTextView.isAutocompleteAcceptKeyEvent(keyCode: 48, modifierFlags: []))
    // Caps Lock / device-state bits do not change what Tab means.
    XCTAssertTrue(
      MarkdownTextView.isAutocompleteAcceptKeyEvent(keyCode: 48, modifierFlags: [.capsLock]))
    for chord: NSEvent.ModifierFlags in [.shift, .control, .option, .command, [.shift, .option]] {
      XCTAssertFalse(
        MarkdownTextView.isAutocompleteAcceptKeyEvent(keyCode: 48, modifierFlags: chord),
        "Tab + \(chord) must not accept the ghost")
    }
    // Any other key is never the accept chord, ghost or not.
    XCTAssertFalse(MarkdownTextView.isAutocompleteAcceptKeyEvent(keyCode: 36, modifierFlags: []))
  }

  func testShiftTabKeyDownDoesNotInsertGhost() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)

    guard
      let backtab = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\u{19}",
        charactersIgnoringModifiers: "\u{9}", isARepeat: false, keyCode: 48)
    else {
      XCTFail("could not synthesize a Shift-Tab key event")
      return
    }
    surface.textView.keyDown(with: backtab)

    // The chord falls through to AppKit (which may handle it natively); the
    // contract under test is that the ghost suggestion is NOT inserted.
    XCTAssertFalse(surface.textStorage.string.contains("world"))
  }

  func testMultilineCompletionIsCappedAtFirstLine() {
    // The ghost renderer is a single-line field at the caret: what it shows
    // must be exactly what accept inserts, so the published suggestion stops
    // at the first non-empty line.
    XCTAssertEqual(
      AutocompleteController.singleLineSuggestion(from: " world\nand more\nlines"), " world")
    XCTAssertEqual(
      AutocompleteController.singleLineSuggestion(from: "\n\nlate start\ntail"), "late start")
    XCTAssertEqual(
      AutocompleteController.singleLineSuggestion(from: " \t\n  useful continuation\ntail"),
      "  useful continuation")
    XCTAssertEqual(AutocompleteController.singleLineSuggestion(from: " world"), " world")
    XCTAssertEqual(AutocompleteController.singleLineSuggestion(from: "hello\n"), "hello")
    XCTAssertNil(AutocompleteController.singleLineSuggestion(from: "\n\n"))
    XCTAssertNil(AutocompleteController.singleLineSuggestion(from: " \t\n  \n"))
    XCTAssertNil(AutocompleteController.singleLineSuggestion(from: ""))
  }

  func testUnavailableErrorsUseProviderWordingWithoutKernelDetails() async {
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      throw VistaError.ModelError(
        msg: "completion LLM unavailable: set LLM_ENDPOINT or LLM_ASSISTIVE_ENDPOINT")
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)

    controller.textDidChange(prefix: "hello")
    await waitUntil {
      controller.lastError != nil
    }

    XCTAssertEqual(
      controller.lastError, AutocompleteController.completionProviderUnavailableMessage)
    XCTAssertFalse(controller.lastError?.localizedCaseInsensitiveContains("vista") == true)
    XCTAssertFalse(controller.lastError?.contains("LLM_ENDPOINT") == true)
  }

  func testEditorSurfacePublishesAutocompleteFailureToProductStatusSink() async {
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      throw VistaError.ModelError(msg: "completion request failed: provider offline")
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)
    let surface = MarkdownEditorSurface(
      text: "hello",
      fontSize: 14,
      aiAutocompleteEnabled: true,
      autocompleteController: controller
    )
    var observedError: String?
    surface.onAutocompleteErrorChanged = { observedError = $0 }

    controller.textDidChange(prefix: "hello")
    await waitUntil { observedError != nil }

    XCTAssertEqual(observedError, "AI autocomplete failed: provider offline")
  }

  func testMultilineCompletionPublishesOnlyFirstLine() async {
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      " world\nnever shown by the single-line ghost"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(controller.suggestion, " world")
  }

  func testAIAutocompleteSettingDefaultsOffAndPersists() {
    let suiteName = "AutocompleteControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = DocumentWindowModel(defaults: defaults)
    XCTAssertFalse(model.aiAutocompleteEnabled)

    model.aiAutocompleteEnabled = true
    let reloaded = DocumentWindowModel(defaults: defaults)
    XCTAssertTrue(reloaded.aiAutocompleteEnabled)
  }
}

private final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func record(_ newValue: Int) {
    lock.lock()
    count = newValue
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private func nonCancellableSleep(nanoseconds: UInt64) async {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
      continuation.resume()
    }
  }
}

private actor AsyncGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private func makeSurface(text: String) -> MarkdownEditorSurface {
  MarkdownEditorSurface(
    text: text,
    fontSize: 14,
    syntaxHighlightingEnabled: true,
    tableTidyOnPaste: true,
    asciiSafeTables: false,
    aiAutocompleteEnabled: true,
    autocompleteController: AutocompleteController(
      engine: MockVistaAutocompleteEngine(),
      debounceNanoseconds: 1
    )
  )
}
