import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class AskMessageSelectionTests: XCTestCase {
  func testDisjointMessagesCopyInConversationOrderWithExactMultilineMarkdown() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let model = AskConversationModel()
    let source = "# Żółw 🐢\n\nPierwsza linia.\nDruga linia.\n\n```swift\nlet x = 1\n```"
    model.observe(turns: [
      AskTurn(id: first, role: .user, text: "Pytanie\nDalszy ciąg"),
      AskTurn(id: second, role: .assistant, text: "omitted"),
      AskTurn(id: third, role: .assistant, text: source),
    ])
    var selection = AskMessageSelection()
    selection.begin()
    let order = [first, second, third].map(\.uuidString)
    selection.toggle(third.uuidString, in: order)
    selection.toggle(first.uuidString, in: order)

    let messages = model.selectedMessages(for: selection.ids)
    XCTAssertEqual(messages.map(\.id), [first, third].map(\.uuidString))
    XCTAssertEqual(
      AskMessageCopy.source(messages), "You:\nPytanie\nDalszy ciąg\n\nPensieve:\n" + source)
  }

  func testShiftRangeWorksBackwardAndIgnoresAnUnknownTurn() {
    var selection = AskMessageSelection()
    let order = ["one", "two", "three", "four", "five"]
    selection.begin()
    selection.toggle("four", in: order)
    selection.toggle("two", in: order, extending: true)
    XCTAssertEqual(selection.ids, ["two", "three", "four"])
    selection.toggle("absent", in: order, extending: true)
    XCTAssertEqual(selection.ids, ["two", "three", "four"])
    selection.toggle("three", in: order)
    XCTAssertEqual(selection.ids, ["two", "four"])
  }

  func testExportUsesFullLatestSourceOutsideTheVisibleWindowAndParseCache() {
    let first = UUID()
    let live = UUID()
    let model = AskConversationModel(clock: { 0 })
    let source = String(repeating: "Żółw 🐢\n", count: 12_000) + "FULL END"
    var turns = [AskTurn(id: first, role: .user, text: source)]
    turns += (0..<AskTranscriptWindow.pageSize).map {
      AskTurn(role: .assistant, text: "reply \($0)")
    }
    turns.append(AskTurn(id: live, role: .assistant, text: "first", isStreaming: true))
    model.observe(turns: turns)
    XCTAssertFalse(model.snapshot.turns.contains { $0.id == first.uuidString })
    // A same-clock delta is held by the coalescer, but explicit Copy must
    // still read the most recent canonical text, never the old parse.
    turns[turns.count - 1].text = "first\nlatest **delta**"
    model.observe(turns: turns)
    let messages = model.selectedMessages(for: [first.uuidString, live.uuidString])
    XCTAssertEqual(messages.map(\.text), [source, "first\nlatest **delta**"])
    XCTAssertTrue(AskMessageCopy.source(messages).contains("FULL END"))
  }

  func testThreadReplacementRetiresSelectionWithoutDeletingEitherHistory() {
    let old = AskTurn(role: .user, text: "old document")
    let replacement = AskTurn(role: .user, text: "other document")
    let model = AskConversationModel()
    model.observe(turns: [old])
    var selection = AskMessageSelection()
    selection.begin()
    selection.toggle(old.id.uuidString, in: [old.id.uuidString])
    model.replaceThread()
    model.observe(turns: [replacement])
    selection.retain(Set(model.selectedMessages(for: selection.ids).map(\.id)))
    XCTAssertTrue(selection.ids.isEmpty)
    XCTAssertEqual(model.snapshot.turns.map(\.id), [replacement.id.uuidString])
    XCTAssertEqual(old.text, "old document")
  }

  func testDoneClearsSelectionAndInactiveSelectionCannotChange() {
    var selection = AskMessageSelection()
    selection.begin()
    selection.toggle("one", in: ["one", "two"])
    selection.end()
    selection.toggle("two", in: ["one", "two"])
    XCTAssertFalse(selection.isActive)
    XCTAssertTrue(selection.ids.isEmpty)
  }

  func testCopyWritesExactTextOnlyToItsUnchangedPrivatePasteboard() {
    let pasteboard = NSPasteboard(name: .init("ask-selection-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let source = "You:\nPierwsza\nDruga 🐢\n\nPensieve:\n| a | b |\n|---|---|"
    XCTAssertTrue(AskMessageCopy.write(source, to: pasteboard, expecting: pasteboard.changeCount))
    XCTAssertEqual(pasteboard.string(forType: .string), source)
    let count = pasteboard.changeCount
    pasteboard.clearContents()
    pasteboard.setString("newer user copy", forType: .string)
    XCTAssertFalse(AskMessageCopy.write(source, to: pasteboard, expecting: count))
    XCTAssertEqual(pasteboard.string(forType: .string), "newer user copy")
  }
}
