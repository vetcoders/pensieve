import AppKit
import XCTest

@testable import Pensieve

/// The viewport must keep showing the same text while the user edits with the
/// Find Bar open.
///
/// Taking find highlights down used to strip `.backgroundColor` across the WHOLE
/// document on every keystroke. TextKit 2 lays out the viewport lazily and
/// estimates the rest, so a document-wide attribute edit re-estimates every
/// fragment height: the scroll origin never moves, but a different part of the
/// text slides under it. The origin is therefore NOT the oracle here — it does
/// not shift by a pixel while the bug is live. The oracle is the character
/// actually sitting at the top of the viewport.
///
/// The harness deliberately never calls `ensureLayout(for: documentRange)`. The
/// live app lays out a viewport, not a document; pre-laying the whole document
/// replaces every estimate with a real height and hides exactly this class of
/// jump.
final class FindViewportStabilityTests: XCTestCase {

  // MARK: - Harness

  /// A document big enough that TextKit 2 must estimate most of it, with the
  /// query occurring near the top and the caret parked far below. Plain prose
  /// only: no inline code and no highlight syntax, so every `.backgroundColor`
  /// run in the storage is a find wash and nothing else.
  private func longDocument(matchLine: Int = 12, lines lineCount: Int = 1550) -> String {
    (1...lineCount).map { index in
      index == matchLine
        ? "To jest twoje zdanie z trafieniem \(index)."
        : "Linia \(index): zdanie o umiarkowanej dlugosci, ktore zajmuje troche miejsca."
    }.joined(separator: "\n")
  }

  @MainActor
  private func makeHostedSurface(text: String) -> (MarkdownEditorSurface, NSWindow) {
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    settleViewport(surface)
    surface.typewriterScrollEnabled = false
    return (surface, window)
  }

  /// Character offset of the text at the top-left of the viewport — what the
  /// user actually sees, as opposed to the scroll origin.
  ///
  /// The probe is clamped below the text container's top inset: at scroll origin
  /// zero a point four points down still sits in the inset, outside any laid-out
  /// text, and `characterIndexForInsertion` answers such points with the END of
  /// the document. Clamping keeps the probe on real text at every scroll
  /// position without changing what it measures.
  @MainActor
  private func characterAtViewportTop(_ surface: MarkdownEditorSurface) -> Int {
    let visible = surface.scrollView.contentView.bounds
    let y = max(visible.minY + 4, surface.textView.textContainerInset.height + 4)
    return surface.textView.characterIndexForInsertion(
      at: NSPoint(x: visible.minX + 4, y: y))
  }

  /// Run the layout the live app runs after the viewport moves.
  ///
  /// `layoutSubtreeIfNeeded` settles AppKit but never asks TextKit 2 to lay the
  /// text out at the new origin, so a hit test straight after a long jump falls
  /// through to the end of the document. This is the VIEWPORT pass the scroll
  /// machinery performs — deliberately not `ensureLayout(for: documentRange)`,
  /// which would pre-lay the whole document and hide the estimate-driven jump
  /// these pins exist to catch.
  @MainActor
  private func settleViewport(_ surface: MarkdownEditorSurface) {
    surface.scrollView.layoutSubtreeIfNeeded()
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    surface.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
  }

  @MainActor
  private func parkViewport(_ surface: MarkdownEditorSurface, caret: Int) {
    surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
    surface.textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
    settleViewport(surface)
  }

  /// Widest single attribute/text edit transaction the storage reported.
  @MainActor
  private func widestEditedRange(
    of textStorage: NSTextStorage, during work: () -> Void
  ) -> Int {
    var widest = 0
    let observer = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification,
      object: textStorage,
      queue: nil
    ) { note in
      guard let storage = note.object as? NSTextStorage else { return }
      widest = max(widest, storage.editedRange.length)
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    work()
    return widest
  }

  /// Every range currently carrying a find wash.
  @MainActor
  private func washedRanges(_ surface: MarkdownEditorSurface) -> [NSRange] {
    var ranges: [NSRange] = []
    surface.textStorage.enumerateAttribute(
      .backgroundColor,
      in: NSRange(location: 0, length: surface.textStorage.length),
      options: []
    ) { value, range, _ in
      if value != nil { ranges.append(range) }
    }
    return ranges
  }

  // MARK: - Pin 1 — starting a find session does not move the text under the viewport

  @MainActor
  func testStartingAFindSessionWithMatchesKeepsTheSameTextAtTheViewportTop() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    parkViewport(surface, caret: surface.textStorage.length - 4000)
    let before = characterAtViewportTop(surface)
    let originBefore = surface.scrollView.contentView.bounds.origin.y

    surface.updateFind(query: "twoje", visible: true)
    settleViewport(surface)

    let after = characterAtViewportTop(surface)
    let originAfter = surface.scrollView.contentView.bounds.origin.y

    XCTAssertEqual(
      originBefore, originAfter, accuracy: 0.5,
      "precondition: the scroll origin is expected to stay put — this bug moves "
        + "the text, not the origin")
    XCTAssertEqual(
      before, after,
      "opening a find session with a live match slid the document under a fixed "
        + "scroll origin: the viewport showed character \(before) and now shows "
        + "\(after)")
  }

  // MARK: - Pin 2 — editing with the Find Bar open does not drift the viewport

  @MainActor
  func testEditingWithTheFindBarOpenDoesNotDriftTheViewport() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    let caret = surface.textStorage.length - 4000
    parkViewport(surface, caret: caret)
    surface.updateFind(query: "twoje", visible: true)
    settleViewport(surface)

    let before = characterAtViewportTop(surface)
    for _ in 0..<12 {
      surface.textView.insertText("x", replacementRange: surface.textView.selectedRange())
    }
    settleViewport(surface)
    let after = characterAtViewportTop(surface)

    XCTAssertEqual(
      before, after,
      "a burst of 12 keystrokes with the find bar open drifted the viewport by "
        + "\(after - before) UTF-16 units of document content while the caret "
        + "never left its paragraph")
  }

  /// Control: the same burst with no find session must be equally stable, so a
  /// failure above can only be blamed on the find path.
  @MainActor
  func testEditingWithTheFindBarClosedDoesNotDriftTheViewport() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    let caret = surface.textStorage.length - 4000
    parkViewport(surface, caret: caret)
    surface.updateFind(query: "", visible: false)
    settleViewport(surface)

    let before = characterAtViewportTop(surface)
    for _ in 0..<12 {
      surface.textView.insertText("x", replacementRange: surface.textView.selectedRange())
    }
    settleViewport(surface)
    let after = characterAtViewportTop(surface)

    XCTAssertEqual(before, after, "control: editing without a find session must not drift")
  }

  // MARK: - Pin 3 — a keystroke must not widen its blast radius because find is open

  @MainActor
  func testAKeystrokeDoesNotWidenItsEditRangeBecauseTheFindBarIsOpen() throws {
    let text = longDocument()

    let (closedSurface, closedWindow) = makeHostedSurface(text: text)
    defer { closedWindow.contentView = nil }
    let closedCaret = closedSurface.textStorage.length - 4000
    parkViewport(closedSurface, caret: closedCaret)
    closedSurface.updateFind(query: "", visible: false)
    let widestClosed = widestEditedRange(of: closedSurface.textStorage) {
      closedSurface.textView.insertText(
        "x", replacementRange: NSRange(location: closedCaret, length: 0))
    }

    let (openSurface, openWindow) = makeHostedSurface(text: text)
    defer { openWindow.contentView = nil }
    let openCaret = openSurface.textStorage.length - 4000
    parkViewport(openSurface, caret: openCaret)
    openSurface.updateFind(query: "twoje", visible: true)
    let widestOpen = widestEditedRange(of: openSurface.textStorage) {
      openSurface.textView.insertText(
        "x", replacementRange: NSRange(location: openCaret, length: 0))
    }

    // Self-calibrating: the find session may legitimately repaint its own match
    // ranges, which are tiny. It may not repaint the document.
    let budget = max(widestClosed * 4, 2000)
    XCTAssertLessThanOrEqual(
      widestOpen, budget,
      "one keystroke mutated attributes over \(widestOpen) UTF-16 units with the "
        + "find bar open versus \(widestClosed) with it closed (document is "
        + "\(openSurface.textStorage.length)) — the find teardown is repainting "
        + "the whole document per keystroke")
  }

  // MARK: - Pin 4 — overshoot guard: explicit Next/Previous still scrolls

  @MainActor
  func testExplicitNextAndPreviousStillScrollToTheMatch() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    parkViewport(surface, caret: surface.textStorage.length - 4000)
    surface.updateFind(query: "twoje", visible: true)
    settleViewport(surface)
    let parkedTop = characterAtViewportTop(surface)

    surface.selectFindMatch(direction: .forward)
    settleViewport(surface)

    let matchLocation = (surface.textStorage.string as NSString).range(of: "twoje").location
    XCTAssertNotEqual(
      matchLocation, NSNotFound, "precondition: the query must occur in the document")
    XCTAssertEqual(
      surface.textView.selectedRange().location, matchLocation,
      "Find Next must select the match")
    XCTAssertNotEqual(
      characterAtViewportTop(surface), parkedTop,
      "Find Next selected the match but never scrolled the viewport to it — the "
        + "fix has over-reached and killed deliberate scrolling")
    XCTAssertLessThan(
      abs(characterAtViewportTop(surface) - matchLocation), 4000,
      "Find Next scrolled somewhere, but not to the match")
  }

  // MARK: - Pin 5 — overshoot guard: an offscreen caret is still revealed

  @MainActor
  func testTypingAtAnOffscreenCaretStillScrollsItIntoViewWithFindOpen() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    surface.updateFind(query: "twoje", visible: true)
    // Park the caret deep in the document, then scroll the viewport back to the
    // top so the caret is far offscreen.
    let caret = surface.textStorage.length - 4000
    surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
    surface.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    settleViewport(surface)

    surface.textView.insertText("x", replacementRange: NSRange(location: caret, length: 0))
    settleViewport(surface)

    let top = characterAtViewportTop(surface)
    XCTAssertGreaterThan(
      top, caret / 2,
      "typing at an offscreen caret with the find bar open left the viewport at "
        + "character \(top) while the caret is at \(caret) — the caret was never "
        + "revealed")
  }

  // MARK: - Pin 6 — no orphan washes when the query changes

  /// The teardown must be driven by what was actually painted, never derived
  /// from the CURRENT match set: `applyFindHighlights` takes the old washes down
  /// AFTER `findMatches` has already been replaced, so a derived teardown would
  /// leave the previous query's washes stranded on screen.
  @MainActor
  func testChangingTheQueryLeavesNoWashOutsideTheNewMatches() throws {
    let (surface, window) = makeHostedSurface(
      text: "alpha bravo charlie\nalpha delta echo\nfoxtrot golf hotel\n")
    defer { window.contentView = nil }

    surface.updateFind(query: "alpha", visible: true)
    XCTAssertEqual(washedRanges(surface).count, 2, "precondition: both `alpha` hits are washed")

    surface.updateFind(query: "foxtrot", visible: true)

    let expected = (surface.textStorage.string as NSString).range(of: "foxtrot")
    XCTAssertEqual(
      washedRanges(surface), [expected],
      "changing the query left washes behind: \(washedRanges(surface).map(NSStringFromRange)) "
        + "instead of only \(NSStringFromRange(expected))")
  }

  /// Ending the session must take every wash down, not merely the ones the
  /// current match set happens to name.
  @MainActor
  func testEndingTheSessionRemovesEveryWash() throws {
    let (surface, window) = makeHostedSurface(
      text: "alpha bravo charlie\nalpha delta echo\nfoxtrot golf hotel\n")
    defer { window.contentView = nil }

    surface.updateFind(query: "alpha", visible: true)
    XCTAssertFalse(washedRanges(surface).isEmpty, "precondition: washes are painted")

    surface.updateFind(query: "", visible: false)

    XCTAssertEqual(
      washedRanges(surface), [],
      "ending the find session left washes at "
        + "\(washedRanges(surface).map(NSStringFromRange))")
  }

  // MARK: - Pin 8 — the operator's scenario, driven by real key events

  /// A document with MANY live matches, edited the way the operator edits: real
  /// `NSEvent` key downs through the responder chain, continuous typing followed
  /// by a held Backspace with its repeat flag set.
  ///
  /// This is the closest deterministic stand-in for a GUI runtime proof. An
  /// accessibility-driven one cannot type into this editor at all — AX keystrokes
  /// aimed at it are a silent no-op — so `keyDown(with:)` is what exercises the
  /// real path end to end: `interpretKeyEvents` -> `insertText`/`deleteBackward`
  /// -> `didChangeText` -> `textDidChange` -> `refreshFindMatches` -> the find
  /// highlight pass under test.
  ///
  /// The assertion is PARITY, not zero. Editing a long document nudges the
  /// viewport by about a line all by itself, with no find session anywhere near
  /// it; demanding zero would pin a TextKit 2 behaviour this fix neither causes
  /// nor owns. What the Find Bar must not do is make editing any less stable
  /// than it already is.
  @MainActor
  func testHeldBackspaceAndTypingWithManyMatchesIsAsStableAsWithNoFindSession() throws {
    // Every tenth line carries the query: 155 live matches, the same order of
    // magnitude as the operator's session.
    let text = (1...1550).map { index in
      index % 10 == 0
        ? "To jest twoje zdanie z trafieniem \(index)."
        : "Linia \(index): zdanie o umiarkowanej dlugosci, ktore zajmuje troche miejsca."
    }.joined(separator: "\n")

    /// Type and hold Backspace on a freshly hosted surface; report how far the
    /// viewport's content drifted and the widest attribute edit it took.
    @MainActor
    func runScenario(findOpen: Bool) -> (drift: Int, widestEdit: Int, documentLength: Int) {
      let (surface, window) = makeHostedSurface(text: text)
      defer { window.contentView = nil }
      XCTAssertTrue(
        window.makeFirstResponder(surface.textView), "precondition: editor is focused")

      parkViewport(surface, caret: surface.textStorage.length - 4000)
      surface.updateFind(query: findOpen ? "twoje" : "", visible: findOpen)
      settleViewport(surface)

      let before = characterAtViewportTop(surface)
      let originBefore = surface.scrollView.contentView.bounds.origin.y

      func send(_ characters: String, keyCode: UInt16, isARepeat: Bool) {
        guard
          let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: keyCode)
        else {
          XCTFail("could not synthesise a key event")
          return
        }
        surface.textView.keyDown(with: event)
      }

      let widest = widestEditedRange(of: surface.textStorage) {
        // Continuous typing.
        for character in Array("zdanie testowe") {
          send(String(character), keyCode: 0, isARepeat: false)
        }
        // Backspace held down: the first press is not a repeat, the rest are.
        for index in 0..<30 {
          send("\u{8}", keyCode: 51, isARepeat: index > 0)
        }
      }
      settleViewport(surface)

      XCTAssertEqual(
        originBefore, surface.scrollView.contentView.bounds.origin.y, accuracy: 0.5,
        "precondition: nothing here scrolls deliberately, so the origin must hold "
          + "and any movement is the document sliding underneath it")
      return (
        characterAtViewportTop(surface) - before, widest, surface.textStorage.length
      )
    }

    let open = runScenario(findOpen: true)
    let closed = runScenario(findOpen: false)

    XCTAssertEqual(
      open.drift, closed.drift,
      "typing and holding Backspace on a \(open.documentLength)-unit document with "
        + "155 live find matches drifted the viewport by \(open.drift) UTF-16 units "
        + "of content, against \(closed.drift) for the very same edit with no find "
        + "session — the find bar is costing the reader their place")
    XCTAssertLessThanOrEqual(
      open.widestEdit, max(closed.widestEdit * 4, 8000),
      "the widest attribute edit was \(open.widestEdit) of \(open.documentLength) "
        + "units with the find bar open against \(closed.widestEdit) with it closed "
        + "— the find pass is still repainting far more than it changed")
  }
}
