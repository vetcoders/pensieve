import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

final class MarkdownFormatterTests: XCTestCase {
  func testLegacyMarkdownFormatterOutputs() {
    XCTAssertEqual(MarkdownFormatter.format("text", as: .bold), "**text**")
    XCTAssertEqual(MarkdownFormatter.format("text", as: .italic), "*text*")
    XCTAssertEqual(MarkdownFormatter.format("text", as: .strike), "~~text~~")
    XCTAssertEqual(MarkdownFormatter.format("text", as: .code), "```\ntext\n```")
    XCTAssertEqual(MarkdownFormatter.format("text", as: .link), "[text](url)")
    XCTAssertEqual(MarkdownFormatter.format("one\ntwo", as: .quote), "> one\n> two\n")
    XCTAssertEqual(MarkdownFormatter.format("one\ntwo", as: .bulletedList), "- one\n- two\n")
    XCTAssertEqual(MarkdownFormatter.format("one\ntwo", as: .numberedList), "1. one\n1. two\n")
  }

  func testTypingReturnContinuesMarkdownListsAndQuotes() {
    let unordered = MarkdownFormatter.autoconversion(
      in: "- alpha",
      range: NSRange(location: 7, length: 0),
      replacement: "\n"
    )
    XCTAssertEqual(unordered?.range, NSRange(location: 7, length: 0))
    XCTAssertEqual(unordered?.replacement, "\n- ")
    XCTAssertEqual(unordered?.selectedRange, NSRange(location: 10, length: 0))

    let ordered = MarkdownFormatter.autoconversion(
      in: "  9. alpha",
      range: NSRange(location: 10, length: 0),
      replacement: "\n"
    )
    XCTAssertEqual(ordered?.replacement, "\n  10. ")

    let task = MarkdownFormatter.autoconversion(
      in: "- [x] done",
      range: NSRange(location: 10, length: 0),
      replacement: "\n"
    )
    XCTAssertEqual(task?.replacement, "\n- [ ] ")

    let quote = MarkdownFormatter.autoconversion(
      in: "> thought",
      range: NSRange(location: 9, length: 0),
      replacement: "\n"
    )
    XCTAssertEqual(quote?.replacement, "\n> ")
  }

  func testTypingReturnOnEmptyMarkdownMarkerExitsTheContainer() {
    let conversion = MarkdownFormatter.autoconversion(
      in: "- ",
      range: NSRange(location: 2, length: 0),
      replacement: "\n"
    )

    XCTAssertEqual(conversion?.range, NSRange(location: 0, length: 2))
    XCTAssertEqual(conversion?.replacement, "")
    XCTAssertEqual(conversion?.selectedRange, NSRange(location: 0, length: 0))
  }

  func testTypingEqualsClosesInlineHighlightWhenRichMarkdownIsEnabled() {
    let conversion = MarkdownFormatter.autoconversion(
      in: "This is ==important",
      range: NSRange(location: 19, length: 0),
      replacement: "="
    )

    XCTAssertEqual(conversion?.range, NSRange(location: 19, length: 0))
    XCTAssertEqual(conversion?.replacement, "==")
    XCTAssertEqual(conversion?.selectedRange, NSRange(location: 21, length: 0))
  }

  func testTypingEqualsDoesNotCloseEmptyOrAlreadyClosedHighlight() {
    let opening = MarkdownFormatter.autoconversion(
      in: "=",
      range: NSRange(location: 1, length: 0),
      replacement: "="
    )
    XCTAssertNil(opening)

    let whitespaceOnly = MarkdownFormatter.autoconversion(
      in: "== ",
      range: NSRange(location: 3, length: 0),
      replacement: "="
    )
    XCTAssertNil(whitespaceOnly)

    let alreadyClosed = MarkdownFormatter.autoconversion(
      in: "==done==",
      range: NSRange(location: 8, length: 0),
      replacement: "="
    )
    XCTAssertNil(alreadyClosed)

    let textAfterClosedHighlight = MarkdownFormatter.autoconversion(
      in: "==done== later",
      range: NSRange(location: 14, length: 0),
      replacement: "="
    )
    XCTAssertNil(textAfterClosedHighlight)
  }

  @MainActor
  func testEditorAutoconversionRunsOnlyWhenRichMarkdownIsEnabled() {
    let richSurface = MarkdownEditorSurface(
      text: "- alpha",
      fontSize: 14,
      syntaxHighlightingEnabled: true
    )
    richSurface.textView.setSelectedRange(NSRange(location: 7, length: 0))

    let didLetAppKitHandleRichReturn =
      richSurface.textView.delegate?.textView?(
        richSurface.textView,
        shouldChangeTextIn: NSRange(location: 7, length: 0),
        replacementString: "\n"
      ) ?? true

    XCTAssertFalse(didLetAppKitHandleRichReturn)
    XCTAssertEqual(richSurface.textStorage.string, "- alpha\n- ")
    XCTAssertEqual(richSurface.textView.selectedRange(), NSRange(location: 10, length: 0))

    let plainSurface = MarkdownEditorSurface(
      text: "- alpha",
      fontSize: 14,
      syntaxHighlightingEnabled: false
    )
    plainSurface.textView.setSelectedRange(NSRange(location: 7, length: 0))

    let didLetAppKitHandlePlainReturn =
      plainSurface.textView.delegate?.textView?(
        plainSurface.textView,
        shouldChangeTextIn: NSRange(location: 7, length: 0),
        replacementString: "\n"
      ) ?? false

    XCTAssertTrue(didLetAppKitHandlePlainReturn)
    XCTAssertEqual(plainSurface.textStorage.string, "- alpha")
  }

  @MainActor
  func testControllerMarkdownFormatCommandAppliesToEditorSelectionAndMarksDirty() {
    var boundText = "alpha beta"
    var isDirty = false
    var didRouteDocumentChange = false
    var findQuery = ""
    var findReplacement = ""
    let appState = AppState()
    let ref = DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-format.md"))
    appState.documentSession = DocumentSession(document: ref, text: boundText)
    let controller = AppController(appState: appState)
    let surface = MarkdownEditorSurface(text: boundText, fontSize: 14)
    surface.onTextChanged = { newText in
      boundText = newText
      isDirty = true
      didRouteDocumentChange = true
    }
    surface.textView.setSelectedRange(NSRange(location: 6, length: 4))

    controller.applyMarkdownFormat(.bold)
    let command = appState.pendingMarkdownFormatCommand
    let representable = EditorRepresentable(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      editorMode: .source,
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      formattingCommand: command,
      findQuery: Binding(get: { findQuery }, set: { findQuery = $0 }),
      findReplacement: Binding(get: { findReplacement }, set: { findReplacement = $0 }),
      findBarVisible: false,
      findCommand: nil,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      isDirty: Binding(get: { isDirty }, set: { isDirty = $0 }),
      onDocumentChanged: {
        didRouteDocumentChange = true
      },
      onCloseFindBar: {
      }
    )
    let coordinator = representable.makeCoordinator()

    coordinator.apply(command, to: surface)

    XCTAssertEqual(surface.textStorage.string, "alpha **beta**")
    XCTAssertEqual(boundText, "alpha **beta**")
    XCTAssertTrue(isDirty)
    XCTAssertTrue(didRouteDocumentChange)
  }

  @MainActor
  func testFormatSelectionMapsWrapperStringsToFormatCommands() {
    // Every wrapper string the Format menu passes must land as the matching
    // typed command in pendingMarkdownFormatCommand (the editor pickup point).
    let expectations: [(wrapper: String, format: MarkdownFormat)] = [
      ("**", .bold), ("*", .italic), ("~~", .strike), (">", .quote),
      ("`", .code), ("[]()", .link), ("-", .bulletedList), ("1.", .numberedList),
    ]

    // Completeness latch: the Format app menu hand-rolls these wrapper strings
    // (Commands.swift), while every other edit surface iterates
    // `MarkdownFormat.allCases`. A new enum case must show up here — and force
    // a conscious Format-menu decision — instead of silently missing coverage.
    XCTAssertEqual(expectations.count, MarkdownFormat.allCases.count)
    XCTAssertEqual(Set(expectations.map(\.format)), Set(MarkdownFormat.allCases))

    for expectation in expectations {
      let appState = AppState()
      let ref = DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-format-selection.md"))
      appState.documentSession = DocumentSession(document: ref, text: "alpha")
      let controller = AppController(appState: appState)

      controller.formatSelection(with: expectation.wrapper)

      XCTAssertEqual(
        appState.pendingMarkdownFormatCommand?.action,
        .format(expectation.format),
        "wrapper \(expectation.wrapper) should map to \(expectation.format)")
    }
  }

  @MainActor
  func testFormatSelectionIgnoresUnknownWrapper() {
    let appState = AppState()
    let ref = DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-format-selection.md"))
    appState.documentSession = DocumentSession(document: ref, text: "alpha")
    let controller = AppController(appState: appState)

    controller.formatSelection(with: "%%")

    XCTAssertNil(appState.pendingMarkdownFormatCommand)
  }

  @MainActor
  func testFormatSelectionRequiresEditableBuffer() {
    // Mirrors the Format menu's disabled predicate: with no editable buffer
    // the command must not enqueue a formatting request.
    let appState = AppState()
    let controller = AppController(appState: appState)

    controller.formatSelection(with: "**")

    XCTAssertNil(appState.pendingMarkdownFormatCommand)
  }

  @MainActor
  func testEmptySelectionFormattingIsLegacyNoOp() {
    var didRouteDocumentChange = false
    let surface = MarkdownEditorSurface(text: "plain", fontSize: 14)
    surface.onTextChanged = { _ in
      didRouteDocumentChange = true
    }
    surface.textView.setSelectedRange(NSRange(location: 0, length: 0))

    let didApply = surface.applyMarkdownFormat(.italic)

    XCTAssertFalse(didApply)
    XCTAssertEqual(surface.textStorage.string, "plain")
    XCTAssertFalse(didRouteDocumentChange)
  }

  @MainActor
  func testWrappingFormatToggleUnwrapsSelectionInsideExistingSpan() {
    let cases: [(format: MarkdownFormat, marked: String, selected: String)] = [
      (.bold, "**Lorem ipsum**", "Lorem"),
      (.italic, "*Lorem ipsum*", "Lorem"),
      (.strike, "~~Lorem ipsum~~", "Lorem"),
      (.code, "```\nLorem ipsum\n```", "Lorem"),
    ]

    for sample in cases {
      let surface = MarkdownEditorSurface(text: sample.marked, fontSize: 14)
      surface.textView.setSelectedRange((sample.marked as NSString).range(of: sample.selected))

      let didApply = surface.applyMarkdownFormat(sample.format)

      XCTAssertTrue(didApply, "\(sample.format) should unwrap from an inner selection")
      XCTAssertEqual(surface.textStorage.string, "Lorem ipsum", "\(sample.format)")
    }
  }

  @MainActor
  func testWrappingFormatToggleUnwrapsExactSpanSelection() {
    let cases: [(format: MarkdownFormat, marked: String)] = [
      (.bold, "**Lorem**"),
      (.italic, "*Lorem*"),
      (.strike, "~~Lorem~~"),
      (.code, "```\nLorem\n```"),
    ]

    for sample in cases {
      let surface = MarkdownEditorSurface(text: sample.marked, fontSize: 14)
      surface.textView.setSelectedRange(
        NSRange(location: 0, length: (sample.marked as NSString).length))

      let didApply = surface.applyMarkdownFormat(sample.format)

      XCTAssertTrue(didApply, "\(sample.format) should unwrap from an exact span selection")
      XCTAssertEqual(surface.textStorage.string, "Lorem", "\(sample.format)")
    }
  }

  @MainActor
  func testWrappingFormatToggleNoOpsPartiallyOverlappingSpan() {
    var didRouteDocumentChange = false
    let text = "pre **Lorem ipsum** post"
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    surface.onTextChanged = { _ in
      didRouteDocumentChange = true
    }
    surface.textView.setSelectedRange((text as NSString).range(of: "pre **Lorem"))

    let didApply = surface.applyMarkdownFormat(.bold)

    XCTAssertFalse(didApply)
    XCTAssertEqual(surface.textStorage.string, text)
    XCTAssertFalse(didRouteDocumentChange)
  }

  @MainActor
  func testCustomFindReplaceAllUsesEditorUndoPath() {
    var changedText = ""
    let surface = MarkdownEditorSurface(text: "Alpha beta alpha", fontSize: 14)
    surface.onTextChanged = { changedText = $0 }

    surface.replaceAllFindMatches(query: "alpha", replacement: "omega")

    XCTAssertEqual(surface.textStorage.string, "omega beta omega")
    XCTAssertEqual(changedText, "omega beta omega")
  }

  @MainActor
  func testUseSelectionForFindFeedsRepresentableBinding() {
    var boundText = "find needle now"
    var findQuery = ""
    var findReplacement = ""
    var isDirty = false
    let command = FindBarCommand(action: .useSelection)
    let representable = EditorRepresentable(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      editorMode: .source,
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      formattingCommand: nil,
      findQuery: Binding(get: { findQuery }, set: { findQuery = $0 }),
      findReplacement: Binding(get: { findReplacement }, set: { findReplacement = $0 }),
      findBarVisible: true,
      findCommand: command,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      isDirty: Binding(get: { isDirty }, set: { isDirty = $0 }),
      onDocumentChanged: {},
      onCloseFindBar: {}
    )
    let coordinator = representable.makeCoordinator()
    let surface = MarkdownEditorSurface(text: boundText, fontSize: 14)
    surface.textView.setSelectedRange((boundText as NSString).range(of: "needle"))

    let selectedText = coordinator.applyFind(
      command,
      to: surface,
      query: findQuery,
      replacement: findReplacement
    )

    XCTAssertEqual(selectedText, "needle")
  }

  @MainActor
  func testTidyTableCommandAppliesToSelectionAndMarksDirty() {
    var boundText = "before\n| a | b |\n| c | d |\nafter"
    var isDirty = false
    var didRouteDocumentChange = false
    var findQuery = ""
    var findReplacement = ""
    let appState = AppState()
    let ref = DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-table.md"))
    appState.documentSession = DocumentSession(document: ref, text: boundText)
    let controller = AppController(appState: appState)
    let surface = MarkdownEditorSurface(text: boundText, fontSize: 14)
    surface.onTextChanged = { newText in
      boundText = newText
      isDirty = true
      didRouteDocumentChange = true
    }
    let selection = (boundText as NSString).range(of: "| a | b |\n| c | d |")
    surface.textView.setSelectedRange(selection)

    controller.tidyTable()
    let command = appState.pendingMarkdownFormatCommand
    let representable = EditorRepresentable(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      editorMode: .source,
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      formattingCommand: command,
      findQuery: Binding(get: { findQuery }, set: { findQuery = $0 }),
      findReplacement: Binding(get: { findReplacement }, set: { findReplacement = $0 }),
      findBarVisible: false,
      findCommand: nil,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      isDirty: Binding(get: { isDirty }, set: { isDirty = $0 }),
      onDocumentChanged: {
        didRouteDocumentChange = true
      },
      onCloseFindBar: {
      }
    )
    let coordinator = representable.makeCoordinator()

    coordinator.apply(command, to: surface)

    XCTAssertEqual(surface.textStorage.string, "before\n| a | b |\n|---|---|\n| c | d |\nafter")
    XCTAssertEqual(boundText, "before\n| a | b |\n|---|---|\n| c | d |\nafter")
    XCTAssertTrue(isDirty)
    XCTAssertTrue(didRouteDocumentChange)
  }

  @MainActor
  func testTidyTableCommandUsesWholeDocumentWhenSelectionIsEmpty() {
    let surface = MarkdownEditorSurface(text: "| a | b |\n| c | d |", fontSize: 14)
    surface.textView.setSelectedRange(NSRange(location: 0, length: 0))

    let didApply = surface.tidyTable(asciiSafe: false)

    XCTAssertTrue(didApply)
    XCTAssertEqual(surface.textStorage.string, "| a | b |\n|---|---|\n| c | d |")
  }

  @MainActor
  func testTidyTableCommandNoOpsWithoutTableSmell() {
    var didRouteDocumentChange = false
    let surface = MarkdownEditorSurface(text: "plain", fontSize: 14)
    surface.onTextChanged = { _ in
      didRouteDocumentChange = true
    }

    let didApply = surface.tidyTable(asciiSafe: false)

    XCTAssertFalse(didApply)
    XCTAssertEqual(surface.textStorage.string, "plain")
    XCTAssertFalse(didRouteDocumentChange)
  }

  @MainActor
  func testSmartPasteNormalizesTableAndFirstUndoRestoresRawPaste() {
    let surface = MarkdownEditorSurface(text: "prefix\n", fontSize: 14)
    surface.textView.setSelectedRange(NSRange(location: 7, length: 0))
    surface.textView.tableTidyOnPaste = true
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("PensieveTablePaste-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("| a | b |\n| c | d |", forType: .string)

    let didPaste = surface.textView.pasteTableIfNeeded(from: pasteboard)

    XCTAssertTrue(didPaste)
    XCTAssertEqual(surface.textStorage.string, "prefix\n| a | b |\n|---|---|\n| c | d |")

    surface.textView.undoManager?.undo()

    XCTAssertEqual(surface.textStorage.string, "prefix\n| a | b |\n| c | d |")
  }

  @MainActor
  func testSmartPasteFallsBackWhenToggleIsOffOrPasteHasNoTableSmell() {
    let surface = MarkdownEditorSurface(text: "", fontSize: 14)
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("PensievePlainPaste-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("plain", forType: .string)

    XCTAssertFalse(surface.textView.pasteTableIfNeeded(from: pasteboard))

    pasteboard.clearContents()
    pasteboard.setString("| a | b |\n| c | d |", forType: .string)
    surface.textView.tableTidyOnPaste = false

    XCTAssertFalse(surface.textView.pasteTableIfNeeded(from: pasteboard))
    XCTAssertEqual(surface.textStorage.string, "")
  }

  func testTypewriterScrollCentersCaretAndClampsToDocumentBounds() {
    XCTAssertEqual(
      MarkdownEditorSurface.centeredScrollY(
        caretMidY: 500,
        visibleHeight: 200,
        documentHeight: 1200
      ),
      400
    )
    XCTAssertEqual(
      MarkdownEditorSurface.centeredScrollY(
        caretMidY: 40,
        visibleHeight: 200,
        documentHeight: 1200
      ),
      0
    )
    XCTAssertEqual(
      MarkdownEditorSurface.centeredScrollY(
        caretMidY: 1180,
        visibleHeight: 200,
        documentHeight: 1200
      ),
      1000
    )
    XCTAssertEqual(
      MarkdownEditorSurface.centeredScrollY(
        caretMidY: 500,
        visibleHeight: 300,
        documentHeight: 250
      ),
      0
    )
  }
}
