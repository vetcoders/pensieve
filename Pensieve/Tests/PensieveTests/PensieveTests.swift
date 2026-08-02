import AppKit
import GRDB
import SwiftUI
import XCTest

@testable import Pensieve

final class PensieveSmokeTests: XCTestCase {
  func testEditorModeRawValues() {
    XCTAssertEqual(EditorMode.source.rawValue, 1)
    XCTAssertEqual(EditorMode.split.rawValue, 2)
    XCTAssertEqual(EditorMode.preview.rawValue, 3)
    XCTAssertEqual(EditorMode.focus.rawValue, 4)
  }

  func testEditorModeLabels() {
    XCTAssertEqual(EditorMode.source.label, "Source")
    XCTAssertEqual(EditorMode.split.label, "Split")
    XCTAssertEqual(EditorMode.preview.label, "Preview")
    XCTAssertEqual(EditorMode.focus.label, "Focus")
  }

  @MainActor
  func testMarkdownEditorSurfaceLoadsAndUpdatesDocumentText() {
    let loadedText = "# Loaded\n\nThe editor must show this text."
    let surface = MarkdownEditorSurface(text: loadedText, fontSize: 14)

    XCTAssertTrue(surface.scrollView.documentView === surface.textView)
    XCTAssertEqual((surface.scrollView.documentView as? NSTextView)?.string, loadedText)
    XCTAssertEqual(surface.textStorage.string, loadedText)
    XCTAssertNotNil(surface.textView.gutter)
    XCTAssertNotNil(surface.textStorage.attribute(.font, at: 0, effectiveRange: nil))

    let updatedText = "## Updated\n\nBinding changes must reach AppKit."
    surface.update(
      text: updatedText,
      fontSize: 18,
      syntaxHighlightingEnabled: true,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      findQuery: "",
      findBarVisible: false
    )

    XCTAssertEqual(surface.textView.string, updatedText)
    XCTAssertEqual(surface.textView.gutter?.fontSize, 18)
  }

  @MainActor
  func testMarkdownEditorSurfaceAppliesSyntaxColorsToRenderedTextViewStorage() {
    let text = """
      # Heading

      `code`

      [link](https://example.com)
      """
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let storage = surface.textView.textStorage ?? surface.textStorage
    let nsText = storage.string as NSString

    let codeRange = nsText.range(of: "`code`")
    let linkRange = nsText.range(of: "[link](https://example.com)")

    // Default (adaptive) theme tokens: heading + inline code are neutral
    // labelColor, links follow the linkColor token — the retired garish accents
    // (systemGreen/Pink/controlAccentColor) no longer appear.
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
      NSColor.labelColor)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor,
      NSColor.labelColor)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? NSColor,
      NSColor.linkColor)
    XCTAssertEqual(
      storage.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue)
  }

  @MainActor
  func testMarkdownEditorSurfaceHighlightsCommonMarkdownGaps() {
    let text = """
      - unordered
      1. ordered
      - [x] done
      ~~removed~~
      ---
      """
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let storage = surface.textView.textStorage ?? surface.textStorage
    let nsText = storage.string as NSString

    let unorderedMarker = nsText.range(of: "- unordered")
    let orderedMarker = nsText.range(of: "1. ordered")
    let taskMarker = nsText.range(of: "- [x]")
    let strikeRange = nsText.range(of: "~~removed~~")

    // Default (adaptive) theme: list markers/checkboxes share the srcListMarker
    // token (secondaryLabelColor), not systemBlue.
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: unorderedMarker.location, effectiveRange: nil)
        as? NSColor,
      NSColor.secondaryLabelColor)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: orderedMarker.location, effectiveRange: nil)
        as? NSColor,
      NSColor.secondaryLabelColor)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: taskMarker.location, effectiveRange: nil)
        as? NSColor,
      NSColor.secondaryLabelColor)
    XCTAssertEqual(
      storage.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue)
  }

  @MainActor
  func testMarkdownTextStorageScopesTypingHighlightRefreshToEditedParagraph() {
    let text = """
      edit this line

      # Far Heading

      **far bold**
      """
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let storage = surface.textView.textStorage ?? surface.textStorage
    let nsText = storage.string as NSString
    let editRange = nsText.range(of: "edit this line")
    let farHeadingRange = nsText.range(of: "# Far Heading")

    storage.addAttribute(.backgroundColor, value: NSColor.systemYellow, range: farHeadingRange)
    storage.replaceCharacters(in: editRange, with: "# Edited line")
    waitForHighlightingDebounce()

    let updatedText = storage.string as NSString
    let editedHeadingRange = updatedText.range(of: "# Edited line")
    let updatedFarHeadingRange = updatedText.range(of: "# Far Heading")
    let farBoldRange = updatedText.range(of: "**far bold**")

    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: editedHeadingRange.location, effectiveRange: nil)
        as? NSColor,
      NSColor.labelColor)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: updatedFarHeadingRange.location, effectiveRange: nil)
        as? NSColor,
      NSColor.labelColor)
    XCTAssertEqual(
      storage.attribute(.backgroundColor, at: updatedFarHeadingRange.location, effectiveRange: nil)
        as? NSColor,
      NSColor.systemYellow)
    XCTAssertNotNil(storage.attribute(.font, at: farBoldRange.location, effectiveRange: nil))
  }

  @MainActor
  func testMarkdownTextStorageExtendsScopedRefreshToContainingFencedCodeBlock() {
    let text = """
      intro

      ```swift
      let value = "before"
      return value
      ```

      after
      """
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let storage = surface.textView.textStorage ?? surface.textStorage
    let nsText = storage.string as NSString
    let editRange = nsText.range(of: "\"before\"")

    storage.replaceCharacters(in: editRange, with: "\"after\"")
    waitForHighlightingDebounce()

    let updatedText = storage.string as NSString
    let letRange = updatedText.range(of: "let value")
    let returnRange = updatedText.range(of: "return value")
    let stringRange = updatedText.range(of: "\"after\"")

    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? NSColor,
      PensieveTheme.default.tokens.accent.nsColor)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: returnRange.location, effectiveRange: nil)
        as? NSColor,
      PensieveTheme.default.tokens.accent.nsColor)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: stringRange.location, effectiveRange: nil)
        as? NSColor,
      PensieveTheme.default.tokens.srcInlineCode.nsColor)
  }

  @MainActor
  func testMarkdownTextStorageFallsBackToFullRefreshWhenFenceToggleClosesCodeBlock() {
    let text = """
      ```swift
      let value = "one"
      plain after
      """
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let storage = surface.textView.textStorage ?? surface.textStorage
    let nsText = storage.string as NSString
    let insertLocation = nsText.range(of: "plain after").location

    storage.replaceCharacters(in: NSRange(location: insertLocation, length: 0), with: "```\n")
    waitForHighlightingDebounce()

    let updatedText = storage.string as NSString
    let letRange = updatedText.range(of: "let value")
    let plainRange = updatedText.range(of: "plain after")

    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? NSColor,
      PensieveTheme.default.tokens.accent.nsColor)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: plainRange.location, effectiveRange: nil) as? NSColor,
      NSColor.textColor)
  }

  /// Invariant 1: consecutive plain-text keystrokes inside a fenced code block
  /// keep re-highlighting the whole enclosing block. Pins the fence-cache reuse
  /// path — the cache survives across non-fence edits and the bounded
  /// `codeBlockAwareRange` lookup still extends to the full block each time.
  @MainActor
  func testMarkdownTextStorageReusesFenceCacheAcrossRepeatedInBlockEdits() {
    let text = """
      intro paragraph

      ```swift
      let alpha = 1
      let beta = 2
      let gamma = 3
      ```

      after
      """
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let storage = surface.textView.textStorage ?? surface.textStorage

    // Three separate single-character edits on three different in-block lines,
    // none of which touch a fence. None should trigger requiresFullRefresh, so
    // the fence cache is reused — yet each must still extend to the full block.
    for token in ["= 1", "= 2", "= 3"] {
      let nsText = storage.string as NSString
      let target = nsText.range(of: token)
      storage.replaceCharacters(
        in: NSRange(location: NSMaxRange(target), length: 0), with: "0")
      waitForHighlightingDebounce()
    }

    let updatedText = storage.string as NSString
    for token in ["let alpha", "let beta", "let gamma"] {
      let range = updatedText.range(of: token)
      XCTAssertEqual(
        storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor,
        PensieveTheme.default.tokens.accent.nsColor,
        "in-block line \(token) must stay code-highlighted across cached edits")
    }
  }

  /// Invariant 2: an edit OUTSIDE any code block must not over-extend the
  /// highlight range into a distant block. The paragraph above a far-away
  /// fenced block stays plain after editing a paragraph far from the fences.
  @MainActor
  func testMarkdownTextStorageDoesNotOverExtendForEditOutsideAnyBlock() {
    let text = """
      first plain paragraph here

      second plain paragraph here

      ```swift
      let inside = 1
      ```
      """
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let storage = surface.textView.textStorage ?? surface.textStorage
    let nsText = storage.string as NSString
    let editRange = nsText.range(of: "first plain paragraph here")

    storage.replaceCharacters(
      in: NSRange(location: NSMaxRange(editRange), length: 0), with: "!")
    waitForHighlightingDebounce()

    let updatedText = storage.string as NSString
    // The edited paragraph stays plain (no code color leaked onto it).
    let editedRange = updatedText.range(of: "first plain paragraph here!")
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: editedRange.location, effectiveRange: nil)
        as? NSColor,
      NSColor.textColor)
    // The code block, untouched by this edit, retains its code highlighting.
    let insideRange = updatedText.range(of: "let inside")
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: insideRange.location, effectiveRange: nil)
        as? NSColor,
      PensieveTheme.default.tokens.accent.nsColor)
  }

  /// Invariant 3: deleting a ``` fence line takes the full-refresh path and the
  /// previously-fenced text reverts to plain rendering afterward.
  @MainActor
  func testMarkdownTextStorageFullRefreshWhenOpeningFenceDeleted() {
    let text = """
      ```swift
      let value = "x"
      ```
      tail
      """
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let storage = surface.textView.textStorage ?? surface.textStorage
    var nsText = storage.string as NSString

    // Sanity: the line is code-highlighted before the fence is removed.
    XCTAssertEqual(
      storage.attribute(
        .foregroundColor, at: nsText.range(of: "let value").location, effectiveRange: nil)
        as? NSColor,
      PensieveTheme.default.tokens.accent.nsColor)

    // Delete the opening fence line (including its trailing newline).
    let openingLine = nsText.range(of: "```swift\n")
    storage.replaceCharacters(in: openingLine, with: "")
    waitForHighlightingDebounce()

    nsText = storage.string as NSString
    let letRange = nsText.range(of: "let value")
    XCTAssertNotNil(
      storage.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil))
    XCTAssertNotEqual(
      storage.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? NSColor,
      PensieveTheme.default.tokens.accent.nsColor,
      "removing the opening fence must drop code highlighting from the former block body")
  }

  @MainActor
  func testMarkdownEditorSurfaceCanDisableSyntaxColors() {
    let surface = MarkdownEditorSurface(
      text: "# Heading\n\n`code`", fontSize: 14, syntaxHighlightingEnabled: false)
    let storage = surface.textView.textStorage ?? surface.textStorage
    let nsText = storage.string as NSString
    let codeRange = nsText.range(of: "`code`")

    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor,
      NSColor.textColor)

    surface.update(
      text: storage.string,
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      findQuery: "",
      findBarVisible: false
    )

    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor,
      NSColor.labelColor)
  }

  @MainActor
  func testPreviewAutoReloadDefaultsOffButPreservesStoredPreference() {
    let defaults = makeEphemeralDefaults(prefix: "PensievePreviewDefaultsTests")

    XCTAssertFalse(AppState(defaults: defaults).previewAutoReload)
    XCTAssertTrue(AppState(defaults: defaults).tableTidyOnPaste)
    XCTAssertFalse(AppState(defaults: defaults).asciiSafeTables)

    defaults.set(true, forKey: "Pensieve.previewAutoReload")
    defaults.set(false, forKey: "Pensieve.tableTidyOnPaste")
    defaults.set(true, forKey: "Pensieve.asciiSafeTables")

    XCTAssertTrue(AppState(defaults: defaults).previewAutoReload)
    XCTAssertFalse(AppState(defaults: defaults).tableTidyOnPaste)
    XCTAssertTrue(AppState(defaults: defaults).asciiSafeTables)
  }

  @MainActor
  func testWorkspaceSortKeepsFoldersBeforeFilesInNameModes() {
    let appState = AppState()
    appState.workspaceTree = [
      WorkspaceNode(
        id: "file-alpha",
        name: "Alpha.md",
        kind: .document,
        url: URL(fileURLWithPath: "/tmp/Alpha.md")
      ),
      WorkspaceNode(
        id: "folder-zulu",
        name: "Zulu",
        kind: .folder,
        url: URL(fileURLWithPath: "/tmp/Zulu"),
        children: []
      ),
    ]

    appState.sidebarSortOrder = .nameAscending
    XCTAssertEqual(appState.sortedWorkspaceTree.map(\.id), ["folder-zulu", "file-alpha"])

    appState.sidebarSortOrder = .nameDescending
    XCTAssertEqual(appState.sortedWorkspaceTree.map(\.id), ["folder-zulu", "file-alpha"])
  }

  @MainActor
  func testSidebarSortOrderPersistsToDefaults() {
    let defaults = makeEphemeralDefaults(prefix: "PensieveSidebarSortTests")

    let appState = AppState(defaults: defaults)
    appState.sidebarSortOrder = .nameDescending

    XCTAssertEqual(AppState(defaults: defaults).sidebarSortOrder, .nameDescending)
  }

  @MainActor
  func testPreviewAutoReloadOffGatesTypingUpdatesFromPipeline() {
    let themeManager = ThemeManager()
    let coordinator = PreviewRepresentable.Coordinator(themeManager: themeManager)
    let sink = RecordingPreviewSink()
    coordinator.pipeline.attach(sink: sink)

    let initial = PreviewRenderRequest(
      markdown: "before",
      fontSize: 14,
      theme: .markdown,
      documentURL: nil
    )
    let typed = PreviewRenderRequest(
      markdown: "after typing",
      fontSize: 14,
      theme: .markdown,
      documentURL: nil
    )

    coordinator.submit(request: initial, autoReload: false, initial: true)
    coordinator.submit(request: typed, autoReload: false, initial: false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    XCTAssertEqual(coordinator.pipeline.lastApplied?.markdown, "before")
    XCTAssertEqual(sink.loadedDocuments.count, 1)
  }

  @MainActor
  func testPreviewAutoReloadOnAppliesTypingUpdatesAfterDebounce() {
    let themeManager = ThemeManager()
    let coordinator = PreviewRepresentable.Coordinator(themeManager: themeManager)
    let sink = RecordingPreviewSink()
    coordinator.pipeline.attach(sink: sink)

    let initial = PreviewRenderRequest(
      markdown: "before",
      fontSize: 14,
      theme: .markdown,
      documentURL: nil
    )
    let typed = PreviewRenderRequest(
      markdown: "after typing",
      fontSize: 14,
      theme: .markdown,
      documentURL: nil
    )

    coordinator.submit(request: initial, autoReload: true, initial: true)
    coordinator.submit(request: typed, autoReload: true, initial: false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.55))

    XCTAssertEqual(coordinator.pipeline.lastApplied?.markdown, "after typing")
    XCTAssertEqual(sink.loadedDocuments.count, 2)
  }

  @MainActor
  func testMarkdownEditorTypingMarksDirtyAndRoutesDocumentChanged() {
    var boundText = "before"
    var isDirty = false
    var didRouteDocumentChange = false
    var findQuery = ""
    var findReplacement = ""
    let representable = EditorRepresentable(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      editorMode: .source,
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      formattingCommand: nil,
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
    let surface = MarkdownEditorSurface(text: boundText, fontSize: 14)
    surface.onTextChanged = { newText in
      boundText = newText
      isDirty = true
      didRouteDocumentChange = true
    }
    coordinator.surface = surface

    surface.textView.string = "typed edit"
    surface.textDidChange(
      Notification(name: NSText.didChangeNotification, object: surface.textView))

    XCTAssertEqual(boundText, "typed edit")
    XCTAssertTrue(isDirty)
    XCTAssertTrue(didRouteDocumentChange)
  }

  func testFileWatcherReportsDirectoryChanges() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWatcherTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let changed = expectation(description: "folder change detected")
    let watcher = FileWatcher()
    try watcher.start(watching: folder) {
      changed.fulfill()
    }

    try "watched".write(
      to: folder.appendingPathComponent("watched.md"),
      atomically: true,
      encoding: .utf8
    )

    wait(for: [changed], timeout: 2.0)
    watcher.stop()
  }

  @MainActor
  func testFolderOpenAndAutosaveWriteThrough() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveStorageTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("alpha.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    appState.workspaceSearchQuery = "changed"
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let autosaver = Autosaver(saveDelayMilliseconds: 50, indexDelayMilliseconds: 120)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()),
      documentStore: makeTestDocumentStore(autosaver: autosaver, indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    controller.openFolder(url: folder)

    XCTAssertEqual(
      appState.documents.map { $0.url.resolvingSymlinksInPath() },
      [noteURL.resolvingSymlinksInPath()]
    )
    selectDocument(at: noteURL, in: appState)

    XCTAssertEqual(
      appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
    XCTAssertEqual(appState.activeDocumentText, "initial")
    XCTAssertFalse(appState.activeDocumentDirty)

    appState.activeDocumentText = "changed"
    appState.activeDocumentDirty = true
    controller.documentDidChange()

    try await waitUntil {
      try String(contentsOf: noteURL, encoding: .utf8) == "changed"
    }
    try await waitUntil {
      await indexDatabase.waitForPendingReindex()
      return appState.workspaceSearchResults.map(\.document.id) == [noteURL.standardizedFileURL]
    }

    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "changed")
    XCTAssertFalse(appState.activeDocumentDirty)
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id),
      [noteURL.standardizedFileURL]
    )

    BookmarkStore.shared.clear(into: appState)
  }

  @MainActor
  func testBurstTypingCoalescesAutosaveAndIndexUpdate() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveBurstAutosaveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("burst.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let ref = DocumentRef(id: noteURL.standardizedFileURL)
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "initial")

    var saveCount = 0
    var indexCount = 0
    let autosaver = Autosaver(saveDelayMilliseconds: 50, indexDelayMilliseconds: 140)
    let store = makeTestDocumentStore(
      autosaver: autosaver,
      indexDatabase: temporaryIndexDatabase(in: folder),
      writeDocument: { text, url in
        saveCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      },
      indexDocument: { _, _, _ in
        indexCount += 1
      }
    )

    for character in ["a", "b", "c", "d", "e"] {
      appState.activeDocumentText += character
      store.documentDidChange(appState: appState)
    }

    try await waitUntil {
      saveCount == 1 && indexCount == 1
    }
    // Give a stale cancelled task enough time to betray duplicate work. The
    // assertion is about coalescence, not scheduler ordering between two timers.
    try await Task.sleep(nanoseconds: 180_000_000)
    XCTAssertEqual(saveCount, 1)
    XCTAssertEqual(indexCount, 1)
  }

  @MainActor
  func testDirtyUntitledAutosavesRecoveryDraftAndRestoresIt() async throws {
    let recoveryDirectory = temporaryApplicationSupportDirectory()
      .appendingPathComponent("Recovery", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: recoveryDirectory.deletingLastPathComponent())
    }

    let recoveryStore = RecoveryStore(directoryURL: recoveryDirectory)
    let autosaver = Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 100)
    let appState = AppState()
    let documentStore = makeTestDocumentStore(
      autosaver: autosaver,
      indexDatabase: temporaryIndexDatabase(in: recoveryDirectory),
      recoveryStore: recoveryStore
    )

    appState.documentSession.createUntitled(title: "Untitled.md")
    appState.activeDocumentText = "keep this crash draft"
    documentStore.documentDidChange(appState: appState)

    try await waitUntil {
      recoveryStore.loadDrafts().first?.text == "keep this crash draft"
    }

    let draft = try XCTUnwrap(recoveryStore.loadDrafts().first)
    // The buffer that wrote the draft is gone — in production the crash takes
    // the whole process (and with it the in-process open-draft claim) before
    // anything can offer the draft again. A draft still held by a live buffer
    // is deliberately unadoptable; see `RecoveredDraftsTests`.
    recoveryStore.markDraftClosed(id: appState.documentSession.recoveryID)
    let restoredState = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: restoredState))
    XCTAssertTrue(restoredState.documentSession.isUntitled)
    XCTAssertTrue(restoredState.activeDocumentDirty)
    XCTAssertEqual(restoredState.activeDocumentText, "keep this crash draft")
  }

  /// A window opened FOR a specific document (`start(intent:
  /// .explicitDocument)` — new document tab, explicit file launch) must show
  /// that document. Restoring the pending recovery draft into every such window
  /// hijacked the fresh buffer, and the now-dirty untitled session then
  /// blocked the requested file's load — every new tab displayed "Recovered
  /// Untitled" instead of the opened file.
  @MainActor
  func testDocumentWindowStartDoesNotHijackWithPendingRecoveryDraft() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRecoveryHijackTests-\(UUID().uuidString)", isDirectory: true)
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let documentURL = folder.appendingPathComponent("target.md")
    try "the requested document".write(to: documentURL, atomically: true, encoding: .utf8)

    // A crash draft is pending in the recovery store.
    let recoveryStore = RecoveryStore(directoryURL: recoveryDirectory)
    let seedState = AppState()
    let seedStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 100),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore
    )
    seedState.documentSession.createUntitled(title: "Untitled.md")
    seedState.activeDocumentText = "crash draft"
    seedStore.documentDidChange(appState: seedState)
    try await waitUntil { recoveryStore.loadDrafts().first?.text == "crash draft" }

    // A fresh window starts to show a specific document (new tab semantics).
    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()
      ),
      documentStore: makeTestDocumentStore(
        autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 100),
        indexDatabase: indexDatabase,
        recoveryStore: recoveryStore
      ),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    controller.start(intent: .explicitDocument)

    XCTAssertFalse(
      appState.documentSession.hasEditableBuffer,
      "start(intent: .explicitDocument) adopted the pending recovery draft — "
        + "the dirty untitled session then blocks the document this window "
        + "was opened for (and re-prompts on every new tab)")

    controller.openFileInCurrentWindow(url: documentURL)
    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL, documentURL.standardizedFileURL,
      "document window shows the recovery draft instead of the document it was opened for")
    XCTAssertEqual(appState.activeDocumentText, "the requested document")
  }

  /// One crash draft, MANY restoring windows: state restoration re-creates
  /// every scene from the previous run. Their startup must leave the draft
  /// alone — the "Untitled, Untitled 2, …" flood came from windows adopting it
  /// on their own, and W2-D removed that route entirely. The draft survives
  /// every restoring window and waits in the launcher instead.
  @MainActor
  func testRestoringWindowsLeaveThePendingRecoveryDraftOnDisk() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSingleRestoreTests-\(UUID().uuidString)", isDirectory: true)
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let recoveryStore = RecoveryStore(directoryURL: recoveryDirectory)
    let seedState = AppState()
    let seedStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 100),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore
    )
    seedState.documentSession.createUntitled(title: "Untitled.md")
    seedState.activeDocumentText = "the one crash draft"
    seedStore.documentDidChange(appState: seedState)
    try await waitUntil { recoveryStore.loadDrafts().first?.text == "the one crash draft" }

    // Two windows restore (own DocumentStore each, shared recovery store —
    // the production topology). NEITHER may take the draft.
    let indexDatabase = temporaryIndexDatabase(in: folder)
    for intent: LaunchIntent in [.coldLaunch, .dockReopen] {
      let windowState = AppState()
      let controller = AppController(
        appState: windowState,
        folderManager: FolderManager(
          metadataStore: temporaryMetadataStore(),
          indexDatabase: indexDatabase,
          bookmarkStore: temporaryBookmarkStore()
        ),
        documentStore: makeTestDocumentStore(
          autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 100),
          indexDatabase: indexDatabase,
          recoveryStore: recoveryStore
        ),
        indexDatabase: indexDatabase,
        importsFoldersInBackground: true
      )

      controller.start(intent: intent)

      XCTAssertFalse(
        windowState.documentSession.hasEditableBuffer,
        "\(intent) adopted the crash draft — that is the Untitled flood coming back")
    }

    XCTAssertEqual(
      recoveryStore.loadDrafts().map(\.text), ["the one crash draft"],
      "a restoring window consumed the draft the launcher is supposed to offer")
  }

  @MainActor
  func testSaveAsDeletesUntitledRecoveryDraft() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRecoverySaveAsTests-\(UUID().uuidString)", isDirectory: true)
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let recoveryStore = RecoveryStore(directoryURL: recoveryDirectory)
    let autosaver = Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 100)
    let appState = AppState()
    let documentStore = makeTestDocumentStore(
      autosaver: autosaver,
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      recoveryStore: recoveryStore
    )

    appState.documentSession.createUntitled(title: "Untitled.md")
    appState.activeDocumentText = "draft before save"
    documentStore.documentDidChange(appState: appState)
    try await waitUntil {
      !recoveryStore.loadDrafts().isEmpty
    }

    let savedURL = folder.appendingPathComponent("saved.md")
    XCTAssertTrue(documentStore.saveAs(appState: appState, to: savedURL))
    XCTAssertTrue(recoveryStore.loadDrafts().isEmpty)
  }

  /// Save-on-close guard: closing a window/tab within the autosave debounce
  /// window (≤1.5s of the last edit) must NOT drop the unsaved change. The
  /// debounce here is set to a minute so the scheduled autosave cannot have
  /// fired — the only path that reaches disk is the synchronous close-flush.
  @MainActor
  func testSavePendingChangesOnCloseFlushesTitledDocumentBeforeDebounce() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseFlushTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("close.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let ref = DocumentRef(id: noteURL.standardizedFileURL)
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "initial")

    let autosaver = Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000)
    let store = makeTestDocumentStore(
      autosaver: autosaver,
      indexDatabase: temporaryIndexDatabase(in: folder)
    )

    appState.activeDocumentText = "edited within the debounce window"
    store.documentDidChange(appState: appState)
    XCTAssertTrue(appState.activeDocumentDirty)
    // The debounced write has NOT fired yet — disk still holds the old text.
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "initial")

    XCTAssertTrue(store.savePendingChangesOnClose(appState: appState))

    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "edited within the debounce window")
    XCTAssertFalse(appState.activeDocumentDirty)
  }

  /// An untitled buffer closed inside the debounce window keeps its content as a
  /// recovery draft — exactly what the pending autosave would have written.
  @MainActor
  func testSavePendingChangesOnCloseWritesRecoveryDraftForUntitled() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveCloseFlushUntitledTests-\(UUID().uuidString)", isDirectory: true)
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let recoveryStore = RecoveryStore(directoryURL: recoveryDirectory)
    let autosaver = Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000)
    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: autosaver,
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore
    )

    appState.documentSession.createUntitled(title: "Untitled.md")
    appState.activeDocumentText = "unsaved draft in a fast-closed window"
    store.documentDidChange(appState: appState)
    // Debounced recovery write has NOT fired yet.
    XCTAssertTrue(recoveryStore.loadDrafts().isEmpty)

    XCTAssertTrue(store.savePendingChangesOnClose(appState: appState))

    XCTAssertEqual(
      recoveryStore.loadDrafts().first?.text, "unsaved draft in a fast-closed window")
  }

  /// A clean (non-dirty) buffer must not be re-written on close — the guard is a
  /// no-op so closing pristine windows never churns disk or the index.
  @MainActor
  func testSavePendingChangesOnCloseIsNoOpWhenClean() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveCloseFlushCleanTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("clean.md")
    try "pristine".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let ref = DocumentRef(id: noteURL.standardizedFileURL)
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "pristine")

    var writeCount = 0
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      writeDocument: { text, url in
        writeCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      }
    )

    XCTAssertFalse(store.savePendingChangesOnClose(appState: appState))
    XCTAssertEqual(writeCount, 0)
  }

  @MainActor
  func testFolderOpenImportsMarkdownRecursivelyAndSkipsDefaultNoise() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveRecursiveImportTests-\(UUID().uuidString)", isDirectory: true)
    let nested = folder.appendingPathComponent("Nested", isDirectory: true)
    let nodeModules = folder.appendingPathComponent("node_modules", isDirectory: true)
    let git = folder.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = nested.appendingPathComponent("beta.markdown")
    let textURL = nested.appendingPathComponent("plain.txt")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)
    try "plain".write(to: textURL, atomically: true, encoding: .utf8)
    try "package".write(
      to: nodeModules.appendingPathComponent("package.md"), atomically: true, encoding: .utf8)
    try "git".write(to: git.appendingPathComponent("config.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder))
    manager.open(url: folder, into: appState)

    XCTAssertEqual(
      Set(appState.documents.map { $0.url.resolvingSymlinksInPath() }),
      Set([
        alphaURL.resolvingSymlinksInPath(),
        betaURL.resolvingSymlinksInPath(),
        textURL.resolvingSymlinksInPath(),
      ])
    )
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
    XCTAssertEqual(appState.workspaceTree.first?.name, folder.lastPathComponent)
    XCTAssertTrue(
      appState.workspaceTree.first?.children?.contains(where: { $0.name == "Nested" }) == true)
  }

  @MainActor
  func testWorkspaceScannerSkipsDotfilesAndDefaultNoiseDirectories() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDefaultNoiseTests-\(UUID().uuidString)", isDirectory: true)
    let nodeModules = folder.appendingPathComponent("node_modules", isDirectory: true)
    let dotFolder = folder.appendingPathComponent(".hidden", isDirectory: true)
    try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dotFolder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let keepURL = folder.appendingPathComponent("keep.md")
    try "keep".write(to: keepURL, atomically: true, encoding: .utf8)
    try "package".write(
      to: nodeModules.appendingPathComponent("package.md"), atomically: true, encoding: .utf8)
    try "dotfile".write(
      to: folder.appendingPathComponent(".env.md"), atomically: true, encoding: .utf8)
    try "hidden".write(
      to: dotFolder.appendingPathComponent("hidden.md"), atomically: true, encoding: .utf8)

    let scans = WorkspaceScanner.build(rootURLs: [folder], exclusions: [])

    XCTAssertEqual(scans.flatMap(\.documents).map(\.url), [keepURL.standardizedFileURL])
  }

  @MainActor
  func testWorkspaceScannerHonorsGitIgnoreRules() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveGitIgnoreTests-\(UUID().uuidString)", isDirectory: true)
    let nested = folder.appendingPathComponent("nested", isDirectory: true)
    let ignoredDirectory = folder.appendingPathComponent("ignored-dir", isDirectory: true)
    let nestedIgnoredDirectory = nested.appendingPathComponent("subignored", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: nestedIgnoredDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    try """
    *.scratch.md
    !keep.scratch.md
    /root-only.md
    ignored-dir/
    """.write(to: folder.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try """
    local-*.md
    !local-keep.md
    subignored/
    """.write(to: nested.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

    let keepURL = folder.appendingPathComponent("keep.md")
    let keepScratchURL = folder.appendingPathComponent("keep.scratch.md")
    let nestedRootOnlyURL = nested.appendingPathComponent("root-only.md")
    let nestedKeepURL = nested.appendingPathComponent("local-keep.md")
    try "keep".write(to: keepURL, atomically: true, encoding: .utf8)
    try "kept scratch".write(to: keepScratchURL, atomically: true, encoding: .utf8)
    try "drop scratch".write(
      to: folder.appendingPathComponent("drop.scratch.md"), atomically: true, encoding: .utf8)
    try "root anchored".write(
      to: folder.appendingPathComponent("root-only.md"), atomically: true, encoding: .utf8)
    try "nested root".write(to: nestedRootOnlyURL, atomically: true, encoding: .utf8)
    try "nested drop".write(
      to: nested.appendingPathComponent("local-drop.md"), atomically: true, encoding: .utf8)
    try "nested keep".write(to: nestedKeepURL, atomically: true, encoding: .utf8)
    try "ignored".write(
      to: ignoredDirectory.appendingPathComponent("child.md"), atomically: true, encoding: .utf8)
    try "nested ignored".write(
      to: nestedIgnoredDirectory.appendingPathComponent("child.md"),
      atomically: true,
      encoding: .utf8
    )

    let scans = WorkspaceScanner.build(rootURLs: [folder], exclusions: [])

    XCTAssertEqual(
      Set(scans.flatMap(\.documents).map(\.url)),
      Set([
        keepURL.standardizedFileURL,
        keepScratchURL.standardizedFileURL,
        nestedRootOnlyURL.standardizedFileURL,
        nestedKeepURL.standardizedFileURL,
      ])
    )
  }

  @MainActor
  func testOpenFilesWorkingSetIsBoundedToRecentFiles() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveWorkingSetBoundTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore()
    )
    var openedURLs: [URL] = []
    for index in 0..<20 {
      let url = folder.appendingPathComponent("ad-hoc-\(index).md")
      try "doc \(index)".write(to: url, atomically: true, encoding: .utf8)
      openedURLs.append(url.standardizedFileURL)
      manager.openFile(url: url, into: appState)
    }

    XCTAssertEqual(appState.openFiles.count, WorkspaceStore.maxOpenFiles)
    XCTAssertEqual(
      appState.openFiles.map(\.url),
      Array(openedURLs.suffix(WorkspaceStore.maxOpenFiles))
    )
  }

  @MainActor
  func testWorkspaceScannerSortsFoldersBeforeDocumentsWithStableNames() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveScannerSortTests-\(UUID().uuidString)", isDirectory: true)
    let zeta = folder.appendingPathComponent("Zeta", isDirectory: true)
    let alpha = folder.appendingPathComponent("Alpha", isDirectory: true)
    try FileManager.default.createDirectory(at: zeta, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    try "alpha child".write(
      to: alpha.appendingPathComponent("child.md"), atomically: true, encoding: .utf8)
    try "zeta child".write(
      to: zeta.appendingPathComponent("child.md"), atomically: true, encoding: .utf8)
    try "ten".write(to: folder.appendingPathComponent("10.md"), atomically: true, encoding: .utf8)
    try "two".write(to: folder.appendingPathComponent("2.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder))

    manager.open(url: folder, into: appState)

    let children = try XCTUnwrap(appState.workspaceTree.first?.children)
    XCTAssertEqual(children.map(\.name), ["Alpha", "Zeta", "2", "10"])
    XCTAssertEqual(children.map(\.kind), [.folder, .folder, .document, .document])
  }

  @MainActor
  func testRestoreLastFolderInBackgroundPublishesShellBeforeScanAndEventuallyIndexesSearch()
    async throws
  {
    let defaults = makeEphemeralDefaults(prefix: "PensieveAsyncRestoreTests")

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveAsyncRestoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("restore.md")
    try "launch-search-token".write(to: noteURL, atomically: true, encoding: .utf8)

    let bookmarkStore = BookmarkStore(defaults: defaults)
    let seedState = AppState()
    try bookmarkStore.persistRoot(url: folder, into: seedState)

    let scanStarted = DispatchSemaphore(value: 0)
    let releaseScan = DispatchSemaphore(value: 0)
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      scanStarted.signal()
      _ = releaseScan.wait(timeout: .now() + 2)
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    appState.workspaceSearchQuery = "launch-search-token"
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: builder
    )

    manager.restoreLastFolderInBackground(into: appState)

    XCTAssertEqual(scanStarted.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
    XCTAssertTrue(appState.documents.isEmpty)
    XCTAssertNil(appState.selectedDocumentID)

    releaseScan.signal()
    await manager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])
    XCTAssertNil(
      appState.selectedDocumentID,
      "the restore publishes the tree and indexes it; opening a document is the user's move")
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [noteURL.standardizedFileURL])

    selectDocument(at: noteURL, in: appState)
    XCTAssertEqual(appState.activeDocumentText, "launch-search-token")
    bookmarkStore.clear(into: appState)
  }

  @MainActor
  func testBackgroundFolderImportPublishesProgressAndClearsWhenDone() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveBackgroundImportProgressTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("progress.md")
    try "progress body".write(to: noteURL, atomically: true, encoding: .utf8)

    let scanStarted = DispatchSemaphore(value: 0)
    let releaseScan = DispatchSemaphore(value: 0)
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      scanStarted.signal()
      _ = releaseScan.wait(timeout: .now() + 2)
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      workspaceBuilder: builder
    )
    let controller = AppController(
      appState: appState,
      folderManager: manager,
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )

    controller.openFolder(url: folder)

    XCTAssertEqual(scanStarted.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
    // Cut 4-1: DURING the walk the open flow does not yet know whether an import is
    // coming, so it presents the honest `.opening` state — never "Importing Workspace".
    XCTAssertEqual(appState.workspaceActivity?.title, "Opening Workspace")
    XCTAssertTrue(appState.workspaceActivity?.detail.contains(folder.lastPathComponent) == true)
    XCTAssertNotNil(appState.workspaceActivity?.progress)

    releaseScan.signal()
    await manager.waitForPendingWorkspaceBuild()

    XCTAssertNil(appState.workspaceActivity)
    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])
  }

  @MainActor
  func testRefreshSkipsRebuildWhenMarkdownUnchanged() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveReindexGateTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let noteURL = folder.appendingPathComponent("note.md")
    try "body".write(to: noteURL, atomically: true, encoding: .utf8)

    let calls = BuilderCallCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      calls.count += 1
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let recorder = BatchSizeRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      workspaceBuilder: builder,
      // Exact scan counts around manually driven reconciles: a live FSEvents stream on the
      // fixture root would add machine-timing-dependent scans for the same mutations.
      watcher: FileWatcher(sourceFactory: { @Sendable in InertWatcherEventSource() })
    )

    manager.open(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    let afterOpen = calls.count
    let recordsAfterOpen = recorder.values.reduce(0, +)
    XCTAssertGreaterThan(afterOpen, 0, "open must scan once")
    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])
    let treeAfterOpen = appState.workspaceTree

    // 1) refresh, nothing changed -> exactly one off-main scan, no tree or FTS delivery
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    XCTAssertEqual(calls.count, afterOpen + 1, "refresh reconciles through exactly one scan")
    XCTAssertEqual(appState.workspaceTree, treeAfterOpen, "unchanged .md must skip tree delivery")
    XCTAssertEqual(
      recorder.values.reduce(0, +), recordsAfterOpen, "unchanged .md must skip the FTS write")

    // 2) add a non-markdown file (e.g. screenshot/.DS_Store) -> scan runs, still no delivery
    try Data().write(to: folder.appendingPathComponent("shot.png"))
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    XCTAssertEqual(calls.count, afterOpen + 2, "refresh reconciles through exactly one scan")
    XCTAssertEqual(appState.workspaceTree, treeAfterOpen, "non-.md change must skip tree delivery")
    XCTAssertEqual(
      recorder.values.reduce(0, +), recordsAfterOpen, "non-.md change must skip the FTS write")

    // 3) change .md content (size differs -> fingerprint changes even within same second)
    //    -> one incremental FTS row lands while the tree stays untouched
    try "changed-token body noticeably longer".write(to: noteURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    XCTAssertEqual(calls.count, afterOpen + 3, "refresh reconciles through exactly one scan")
    XCTAssertEqual(
      recorder.values.reduce(0, +), recordsAfterOpen + 1,
      ".md content change must write exactly one incremental FTS row")
    XCTAssertEqual(
      indexDatabase.search(query: "changed-token", documents: appState.allDocuments)
        .map(\.document.url.lastPathComponent),
      ["note.md"], ".md content change must be searchable after the incremental write")
  }

  /// Reference-typed call counter so the @Sendable workspace builder closure can tally
  /// invocations without capturing a mutable var (Swift 6 SendableClosureCaptures).
  private final class BuilderCallCounter: @unchecked Sendable {
    var count = 0
  }

  // MARK: - RC-2: debounced, off-main watcher refresh

  /// RC-2 invariant (2): a real `.md` change drives exactly one rebuild through the debounced
  /// off-main watcher path. The debounce interval is injected small and driven deterministically
  /// by awaiting the in-flight task (no sleep-based assertion).
  @MainActor
  func testScheduleWatcherRefreshRebuildsOnceForMarkdownChange() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWatcherRefreshTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let noteURL = folder.appendingPathComponent("note.md")
    try "body".write(to: noteURL, atomically: true, encoding: .utf8)

    let calls = BuilderCallCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      calls.count += 1
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      workspaceBuilder: builder,
      watcher: FileWatcher(sourceFactory: { @Sendable in InertWatcherEventSource() }),
      watcherDebounceMilliseconds: 10
    )

    manager.open(url: folder, into: appState)
    let afterOpen = calls.count
    XCTAssertGreaterThan(afterOpen, 0, "open must scan once")

    try "body changed and noticeably longer".write(to: noteURL, atomically: true, encoding: .utf8)
    manager.scheduleWatcherRefresh(into: appState)
    await manager.waitForPendingWatcherRefresh()
    await manager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(calls.count, afterOpen + 1, ".md change must trigger exactly one rebuild")
  }

  /// RC-2 invariant (1): a foreign change to a NON-`.md` file does NOT trigger a rebuild/reindex
  /// when the `.md` set is unchanged. Under the one-scan/two-signature contract the watcher path
  /// still reconciles through exactly one off-main scan; both signatures match, so neither the
  /// tree nor the FTS index is delivered to.
  @MainActor
  func testScheduleWatcherRefreshSkipsRebuildForNonMarkdownChange() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWatcherSkipTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let noteURL = folder.appendingPathComponent("note.md")
    try "body".write(to: noteURL, atomically: true, encoding: .utf8)

    let calls = BuilderCallCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      calls.count += 1
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let recorder = BatchSizeRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      workspaceBuilder: builder,
      watcher: FileWatcher(sourceFactory: { @Sendable in InertWatcherEventSource() }),
      watcherDebounceMilliseconds: 10
    )

    manager.open(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    let afterOpen = calls.count
    let recordsAfterOpen = recorder.values.reduce(0, +)
    let treeAfterOpen = appState.workspaceTree

    // Foreign churn: a screenshot / .DS_Store sibling write leaves the .md set untouched.
    try Data().write(to: folder.appendingPathComponent("shot.png"))
    manager.scheduleWatcherRefresh(into: appState)
    await manager.waitForPendingWatcherRefresh()
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    XCTAssertEqual(calls.count, afterOpen + 1, "the watcher reconciles through exactly one scan")
    XCTAssertEqual(
      appState.workspaceTree, treeAfterOpen, "non-.md change must not republish the tree")
    XCTAssertEqual(
      recorder.values.reduce(0, +), recordsAfterOpen, "non-.md change must not write the FTS index")
  }

  /// RC-2 invariant (3): a burst of N rapid watcher events collapses to a single rebuild. Each
  /// `scheduleWatcherRefresh` cancels the prior in-flight debounce/scan, so only the last one
  /// survives to rebuild.
  @MainActor
  func testScheduleWatcherRefreshCoalescesBurstIntoSingleRebuild() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWatcherBurstTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let noteURL = folder.appendingPathComponent("note.md")
    try "body".write(to: noteURL, atomically: true, encoding: .utf8)

    let calls = BuilderCallCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      calls.count += 1
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      workspaceBuilder: builder,
      watcher: FileWatcher(sourceFactory: { @Sendable in InertWatcherEventSource() }),
      watcherDebounceMilliseconds: 30
    )

    manager.open(url: folder, into: appState)
    let afterOpen = calls.count

    // Real .md change, then a storm of watcher events before the debounce elapses.
    try "body changed and noticeably longer".write(to: noteURL, atomically: true, encoding: .utf8)
    for _ in 0..<20 {
      manager.scheduleWatcherRefresh(into: appState)
    }
    await manager.waitForPendingWatcherRefresh()
    await manager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      calls.count, afterOpen + 1, "a burst of N watcher events must collapse to one rebuild")
  }

  /// RC-2 invariant (4): an external `.md` change delivered through the debounced watcher path
  /// must NOT clobber an unsaved dirty editor buffer.
  @MainActor
  func testScheduleWatcherRefreshProtectsDirtySession() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWatcherDirtyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let noteURL = folder.appendingPathComponent("note.md")
    try "clean original".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      watcher: FileWatcher(sourceFactory: { @Sendable in InertWatcherEventSource() }),
      watcherDebounceMilliseconds: 10
    )

    manager.open(url: folder, into: appState)
    selectDocument(at: noteURL, in: appState)
    XCTAssertEqual(appState.documentSession.text, "clean original")

    appState.activeDocumentText = "dirty local edit"
    appState.activeDocumentDirty = true
    try "dirty external longer body".write(to: noteURL, atomically: true, encoding: .utf8)

    manager.scheduleWatcherRefresh(into: appState)
    await manager.waitForPendingWatcherRefresh()
    await manager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(appState.documentSession.text, "dirty local edit", "dirty buffer preserved")
    XCTAssertTrue(appState.documentSession.isDirty, "dirty flag preserved")
  }

  // MARK: - Stage A: incremental delta reindex

  /// Delta computation is the pure, testable core of the scan-diff. Direct unit coverage of
  /// added / modified / removed plus the documented edge cases (same path same mtime different
  /// size; same-second mtime change; unicode path). No filesystem, no DB.
  func testWorkspaceSignatureDeltaClassifiesAddedModifiedRemoved() {
    let old = WorkspaceSignature(entries: [
      "/ws/kept.md": FileSignature(mtime: 100, size: 10),
      "/ws/changed.md": FileSignature(mtime: 100, size: 10),
      "/ws/gone.md": FileSignature(mtime: 100, size: 10),
    ])
    let new = WorkspaceSignature(entries: [
      "/ws/kept.md": FileSignature(mtime: 100, size: 10),
      "/ws/changed.md": FileSignature(mtime: 200, size: 10),
      "/ws/fresh.md": FileSignature(mtime: 300, size: 5),
    ])

    let delta = WorkspaceSignature.delta(from: old, to: new)
    XCTAssertEqual(delta.added, ["/ws/fresh.md"])
    XCTAssertEqual(delta.modified, ["/ws/changed.md"])
    XCTAssertEqual(delta.removed, ["/ws/gone.md"])
    XCTAssertEqual(delta.upsertedPaths, ["/ws/fresh.md", "/ws/changed.md"])
    XCTAssertFalse(delta.isEmpty)
  }

  func testWorkspaceSignatureDeltaEmptyWhenIdentical() {
    let signature = WorkspaceSignature(entries: [
      "/ws/a.md": FileSignature(mtime: 100, size: 10),
      "/ws/b.md": FileSignature(mtime: 200, size: 20),
    ])
    let delta = WorkspaceSignature.delta(from: signature, to: signature)
    XCTAssertTrue(delta.isEmpty)
  }

  func testWorkspaceSignatureDeltaEdgeCases() {
    // Same path, SAME mtime, DIFFERENT size -> modified (size alone is enough).
    let sizeOnly = WorkspaceSignature.delta(
      from: WorkspaceSignature(entries: ["/ws/x.md": FileSignature(mtime: 100, size: 10)]),
      to: WorkspaceSignature(entries: ["/ws/x.md": FileSignature(mtime: 100, size: 11)]))
    XCTAssertEqual(sizeOnly.modified, ["/ws/x.md"])

    // Same-second mtime change (full-precision mtime is preserved) -> modified even with
    // identical size. A whole-second fingerprint would have MISSED this.
    let subSecond = WorkspaceSignature.delta(
      from: WorkspaceSignature(entries: ["/ws/x.md": FileSignature(mtime: 100.0, size: 10)]),
      to: WorkspaceSignature(entries: ["/ws/x.md": FileSignature(mtime: 100.4, size: 10)]))
    XCTAssertEqual(subSecond.modified, ["/ws/x.md"])

    // Unicode path round-trips through the diff as a normal key.
    let unicodePath = "/ws/zażółć-gęślą-jaźń-日本語.md"
    let unicode = WorkspaceSignature.delta(
      from: WorkspaceSignature(entries: [:]),
      to: WorkspaceSignature(entries: [unicodePath: FileSignature(mtime: 1, size: 1)]))
    XCTAssertEqual(unicode.added, [unicodePath])
  }

  /// Invariant 1: adding one `.md` to an existing indexed workspace upserts ONLY that file
  /// into FTS — the batch recorder proves exactly one record was inserted (not the whole
  /// workspace) — while existing docs remain searchable.
  @MainActor
  func testIncrementalRefreshUpsertsOnlyAddedFile() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDeltaAddTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<5 {
      try "alpha-token body \(index)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let recorder = BatchSizeRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())

    manager.open(url: folder, into: appState)
    await manager.waitForPendingIndexUpdate()
    let recordsAfterColdOpen = recorder.values.reduce(0, +)
    XCTAssertEqual(recordsAfterColdOpen, 5, "cold open full-indexes all five docs")

    // Add a sixth file, then refresh: the delta must upsert ONLY the new file.
    try "beta-token brand new".write(
      to: folder.appendingPathComponent("note-new.md"), atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()

    let recordsAfterAdd = recorder.values.reduce(0, +) - recordsAfterColdOpen
    XCTAssertEqual(recordsAfterAdd, 1, "adding one .md must upsert exactly one FTS record")

    let refs = appState.allDocuments
    XCTAssertEqual(
      indexDatabase.search(query: "beta-token", documents: refs)
        .map(\.document.url.lastPathComponent),
      ["note-new.md"], "the added file is searchable")
    XCTAssertEqual(
      indexDatabase.search(query: "alpha-token", documents: refs).count, 5,
      "all pre-existing docs remain searchable (their rows were not dropped)")
  }

  /// Invariant 2: modifying one `.md` re-upserts only that file; its new content is
  /// searchable and the old content is gone.
  @MainActor
  func testIncrementalRefreshReupsertsOnlyModifiedFile() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDeltaModifyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let targetURL = folder.appendingPathComponent("target.md")
    try "before-token original content".write(to: targetURL, atomically: true, encoding: .utf8)
    try "stable-token untouched".write(
      to: folder.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)

    let recorder = BatchSizeRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())

    manager.open(url: folder, into: appState)
    await manager.waitForPendingIndexUpdate()
    let afterColdOpen = recorder.values.reduce(0, +)

    try "after-token replacement content noticeably longer".write(
      to: targetURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()

    let upsertedOnModify = recorder.values.reduce(0, +) - afterColdOpen
    XCTAssertEqual(upsertedOnModify, 1, "modifying one .md must re-upsert exactly one record")

    let refs = appState.allDocuments
    XCTAssertEqual(
      indexDatabase.search(query: "after-token", documents: refs)
        .map(\.document.url.lastPathComponent),
      ["target.md"], "new content is searchable")
    XCTAssertTrue(
      indexDatabase.search(query: "before-token", documents: refs).isEmpty,
      "old content is gone")
    XCTAssertEqual(
      indexDatabase.search(query: "stable-token", documents: refs).count, 1,
      "the untouched doc is unaffected")
  }

  // MARK: - Persisted cold-open `.md` signature (cross-launch reindex avoidance)

  /// SUBAGENT_08 / Invariant 1: a SECOND cold open of an UNCHANGED workspace with a populated
  /// index + a persisted signature must SKIP the reindex entirely — 0 records written on relaunch.
  @MainActor
  func testColdOpenSkipsReindexWhenSignatureUnchangedAndIndexPopulated() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSigSkipTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<5 {
      try "skip-token body \(index)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let indexURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let recorder = BatchSizeRecorder()

    // One IndexDatabase (one pool) across both opens; the cross-launch survivor is the PERSISTED
    // `.md` signature on disk read through the shared substrate cache.
    let indexDatabase = IndexDatabase(
      databaseURL: indexURL, searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })

    // First launch: full reindex (no persisted signature) + persists the signature.
    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    firstManager.open(url: folder, into: firstState)
    await firstManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    XCTAssertEqual(recorder.values.reduce(0, +), 5, "first launch full-indexes all five docs")
    firstManager.closeWorkspace(into: firstState)  // simulate app quit between launches

    // Second launch: same files, populated index, persisted signature → SKIP.
    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    secondManager.open(url: folder, into: secondState)
    await secondManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    XCTAssertEqual(
      recorder.values.reduce(0, +), 5,
      "second open of an unchanged, already-indexed workspace writes ZERO new records (skip)")
    XCTAssertEqual(
      indexDatabase.search(query: "skip-token", documents: secondState.allDocuments).count, 5,
      "the pre-existing index is reused — all docs still searchable after the skip")
  }

  /// SUBAGENT_08 / Invariant 2: relaunch after a few `.md` changed → only the changed files are
  /// upserted (INCREMENTAL), not a full reindex of the whole workspace.
  @MainActor
  func testColdOpenIncrementalWhenSomeMarkdownChangedAcrossLaunch() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSigDeltaTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<5 {
      try "orig-token body \(index)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let indexURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let recorder = BatchSizeRecorder()

    // One IndexDatabase instance (one DatabasePool) across both opens. A real relaunch keeps a
    // single pool on `index.db`; the cross-launch survivor is the PERSISTED `.md` signature on
    // disk, which the second open reads via the shared substrate cache. (Two pools on one file is
    // a test artifact that races SQLite WAL.)
    let indexDatabase = IndexDatabase(
      databaseURL: indexURL, searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })

    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    firstManager.open(url: folder, into: firstState)
    await firstManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    let afterFirstLaunch = recorder.values.reduce(0, +)
    XCTAssertEqual(afterFirstLaunch, 5, "first launch full-indexes all five docs")

    // Simulate quitting the app between launches so the first session's watcher stops reacting
    // to the edits below (otherwise it would re-persist a 6-file signature and the relaunch would
    // skip). closeWorkspace stops the watcher; the persisted signature survives the close.
    firstManager.closeWorkspace(into: firstState)

    // Between launches the operator edits ONE file and adds ONE file.
    try "changed-token modified content noticeably longer than before".write(
      to: folder.appendingPathComponent("note-1.md"), atomically: true, encoding: .utf8)
    try "added-token brand new file".write(
      to: folder.appendingPathComponent("note-added.md"), atomically: true, encoding: .utf8)

    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    secondManager.open(url: folder, into: secondState)
    await secondManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    let upsertedOnRelaunch = recorder.values.reduce(0, +) - afterFirstLaunch
    XCTAssertEqual(
      upsertedOnRelaunch, 2,
      "relaunch upserts ONLY the 1 modified + 1 added file (incremental), not all 6")

    let refs = secondState.allDocuments
    XCTAssertEqual(
      indexDatabase.search(query: "changed-token", documents: refs)
        .map(\.document.url.lastPathComponent),
      ["note-1.md"], "the modified file's new content is searchable")
    XCTAssertTrue(
      indexDatabase.search(query: "orig-token", documents: refs)
        .allSatisfy { $0.document.url.lastPathComponent != "note-1.md" },
      "the modified file's stale content is gone")
    XCTAssertEqual(
      indexDatabase.search(query: "added-token", documents: refs)
        .map(\.document.url.lastPathComponent),
      ["note-added.md"], "the added file is searchable")
  }

  // MARK: - Stage 2: cheap file add / remove (no full-workspace re-commit / FTS storm)

  /// STAGE 2 / file-add cheapness: a cold open that finds ONE extra `.md` since the last launch
  /// must upsert ONLY that one `documents` row — never re-commit all N. A redundant
  /// `ON CONFLICT DO UPDATE` on an unchanged row both bumps its `indexed_at` AND fires the
  /// `documents` AU trigger that re-tokenizes the whole external-content FTS (the "Indexing N"
  /// storm). We snapshot each row's `indexed_at` before and after the second open, with a >1s
  /// real-time gap so a re-upsert lands a STRICTLY greater whole-second timestamp and is therefore
  /// observable. DISCRIMINATING: the prior full-recommit re-upserted every pre-existing row (all
  /// five `indexed_at` advance); the incremental upsert leaves all five untouched.
  @MainActor
  func testColdOpenFileAddUpsertsOnlyAddedDocumentNotEntireWorkspace() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveS2AddTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<5 {
      try "addcheap body \(index)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let indexURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let recorder = BatchSizeRecorder()

    // One IndexDatabase (one pool) across both opens; the cross-launch survivor is the PERSISTED
    // `.md` signature read via the shared substrate cache.
    let indexDatabase = IndexDatabase(
      databaseURL: indexURL, searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })

    // First launch: full reindex of all five + persists signature + documents rows.
    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    // Background open serializes the manifest commit (`upsertWorkspace`) + stats writes inside the
    // build task, so awaiting it leaves the index quiescent for the raw-DB read below.
    firstManager.openInBackground(url: folder, into: firstState)
    await firstManager.waitForPendingWorkspaceBuild()
    await indexDatabase.waitForPendingReindex()
    XCTAssertEqual(recorder.values.reduce(0, +), 5, "first launch full-indexes all five docs")
    firstManager.closeWorkspace(into: firstState)  // simulate app quit + stop the watcher

    let before = try readDocumentsIndexedAt(at: indexURL)
    XCTAssertEqual(before.count, 5, "five documents rows after the first full index")

    // Force a STRICTLY greater whole-second timestamp for any second-open write, so a re-upsert of
    // an unchanged row is detectable (`indexed_at` is whole-second `Int(Date()...)`).
    try await Task.sleep(nanoseconds: 1_100_000_000)

    // Operator adds ONE file between launches.
    try "addcheap brandnew added file".write(
      to: folder.appendingPathComponent("note-added.md"), atomically: true, encoding: .utf8)

    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    secondManager.openInBackground(url: folder, into: secondState)
    await secondManager.waitForPendingWorkspaceBuild()
    await indexDatabase.waitForPendingReindex()

    let after = try readDocumentsIndexedAt(at: indexURL)
    let rewrittenOriginals = (0..<5)
      .map { "note-\($0).md" }
      .filter { after[$0] != before[$0] }
    XCTAssertEqual(
      rewrittenOriginals, [],
      "a file add upserts ONLY the added row — no pre-existing row is re-written (the prior "
        + "full-recommit re-upserted all five and re-synced the whole FTS)")
    XCTAssertNotNil(after["note-added.md"], "the added file is indexed")

    // FTS reflects the change AND every original stays searchable (originals were tokenized on the
    // first launch and never re-tokenized; the added file was tokenized incrementally).
    let refs = secondState.allDocuments
    XCTAssertEqual(
      indexDatabase.search(query: "brandnew", documents: refs)
        .map(\.document.url.lastPathComponent),
      ["note-added.md"], "the added file is searchable")
    XCTAssertEqual(
      indexDatabase.search(query: "addcheap", documents: refs).count, 6,
      "originals + added all remain searchable")
  }

  /// STAGE 2 / file-remove cheapness: a cold open that finds ONE fewer `.md` must tombstone ONLY
  /// the removed row and leave every remaining row untouched. DISCRIMINATING: the prior
  /// full-recommit re-upserted all surviving rows (their `indexed_at` advances); the incremental
  /// path writes none of them.
  @MainActor
  func testColdOpenFileRemoveTombstonesOnlyRemovedDocumentNotReupsertingRest() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveS2RemoveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<5 {
      let unique = index == 2 ? " vanishtoken" : ""
      try "tombcheap body \(index)\(unique)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let indexURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let recorder = BatchSizeRecorder()

    let indexDatabase = IndexDatabase(
      databaseURL: indexURL, searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })

    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    firstManager.openInBackground(url: folder, into: firstState)
    await firstManager.waitForPendingWorkspaceBuild()
    await indexDatabase.waitForPendingReindex()
    XCTAssertEqual(recorder.values.reduce(0, +), 5, "first launch full-indexes all five docs")
    firstManager.closeWorkspace(into: firstState)

    let before = try readDocumentsIndexedAt(at: indexURL)
    XCTAssertEqual(before.count, 5, "five documents rows after the first full index")

    try await Task.sleep(nanoseconds: 1_100_000_000)

    // Operator removes ONE file between launches.
    try FileManager.default.removeItem(at: folder.appendingPathComponent("note-2.md"))

    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    secondManager.openInBackground(url: folder, into: secondState)
    await secondManager.waitForPendingWorkspaceBuild()
    await indexDatabase.waitForPendingReindex()

    let after = try readDocumentsIndexedAt(at: indexURL)
    XCTAssertNil(after["note-2.md"], "the removed file's documents row is tombstoned")
    XCTAssertEqual(after.count, 4, "exactly the four surviving rows remain")
    let rewrittenSurvivors = [0, 1, 3, 4]
      .map { "note-\($0).md" }
      .filter { after[$0] != before[$0] }
    XCTAssertEqual(
      rewrittenSurvivors, [],
      "a file remove tombstones ONLY the removed row — no surviving row is re-written (the prior "
        + "full-recommit re-upserted all four)")

    let refs = secondState.allDocuments
    XCTAssertTrue(
      indexDatabase.search(query: "vanishtoken", documents: refs).isEmpty,
      "the removed file's content is gone from the FTS")
    XCTAssertEqual(
      indexDatabase.search(query: "tombcheap", documents: refs).count, 4,
      "the four surviving docs remain searchable")
  }

  /// Reads `path -> indexed_at` for every `documents` row via a separate read-only connection
  /// (safe in WAL while the IndexDatabase pool is open — same pattern as the other DB-inspecting
  /// suites).
  private func readDocumentsIndexedAt(at databaseURL: URL) throws -> [String: Int] {
    let queue = try DatabaseQueue(path: databaseURL.path)
    defer { try? queue.close() }
    return try queue.read { db in
      var result: [String: Int] = [:]
      for row in try Row.fetchAll(db, sql: "SELECT path, indexed_at FROM documents") {
        result[row["path"]] = row["indexed_at"]
      }
      return result
    }
  }

  /// SUBAGENT_08 / Invariant 3 + empty-index guard: a cold open with NO persisted signature does
  /// a FULL reindex and persists. AND even with a persisted signature, if the on-disk index is
  /// EMPTY (operator nuked Application Support), the open must NOT skip — it must full-reindex.
  @MainActor
  func testColdOpenFullReindexWhenNoSignatureThenSkipGuardOnEmptyIndex() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSigEmptyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<4 {
      try "full-token body \(index)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let firstIndexURL = folder.appendingPathComponent("index.db", isDirectory: false)
    // Separate recorders: the second launch points at a DIFFERENT index file (nuke simulation),
    // so isolating the recorders keeps the first index's lingering manifest writes out of the
    // second's record count.
    let firstRecorder = BatchSizeRecorder()
    let secondRecorder = BatchSizeRecorder()

    // First launch: NO persisted signature → FULL reindex + persists signature.
    let firstIndex = IndexDatabase(
      databaseURL: firstIndexURL, searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in firstRecorder.record(size) })
    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: firstIndex,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    firstManager.open(url: folder, into: firstState)
    await firstManager.waitForPendingIndexUpdate()
    await firstIndex.waitForPendingReindex()
    XCTAssertEqual(
      firstRecorder.values.reduce(0, +), 4, "first launch with no signature full-indexes")

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: nil)
    XCTAssertNotNil(
      substrate.store.readSearchSignature(for: identity),
      "the signature is persisted after the first full reindex")
    firstManager.closeWorkspace(into: firstState)  // simulate app quit between launches

    // Second launch points at a BRAND-NEW (empty) index.db but the persisted signature still
    // matches the files. The empty-index guard must force a FULL reindex, never a skip.
    let secondIndexURL = folder.appendingPathComponent("index-2.db", isDirectory: false)
    let secondIndex = IndexDatabase(
      databaseURL: secondIndexURL, searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in secondRecorder.record(size) })
    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: secondIndex,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    secondManager.open(url: folder, into: secondState)
    await secondManager.waitForPendingIndexUpdate()
    await secondIndex.waitForPendingReindex()

    XCTAssertEqual(
      secondRecorder.values.reduce(0, +), 4,
      "empty index + matching signature must FULL-reindex (never skip an empty index)")
    XCTAssertEqual(
      secondIndex.search(query: "full-token", documents: secondState.allDocuments).count, 4,
      "all docs searchable after the guarded full reindex into the fresh index")
  }

  /// SUBAGENT_10 / P1 (silent-failure fix): a cold-open reindex whose FTS write FAILS must NOT
  /// persist the new `.md` signature. Without the fix the signature is written unconditionally
  /// right after the `await`, so a relaunch sees signature==current over a stale/partial index and
  /// the skip-gate silently skips a broken index. With the fix the persist is gated on the write's
  /// `Bool` result, so the PRIOR signature survives unchanged and the next launch re-attempts a
  /// full reindex.
  ///
  /// Failure is injected DETERMINISTICALLY without fighting a live pool's WAL lock: the FIRST
  /// launch (real `index.db`) persists the 5-file signature to the substrate cache. The SECOND
  /// launch points a SEPARATE `IndexDatabase` at a path whose parent is a regular FILE, not a
  /// directory — so `IndexDatabase.open` cannot create the database (`createDirectory` /
  /// `DatabasePool` both fail), `ensureOpen` returns nil, and `reindexInBackground` returns `false`
  /// for EVERY launch deterministically (no SQLite, no chmod, no second connection on the live
  /// file). The substrate-cache signature is independent of `index.db`, so the persisted 5-file
  /// signature from launch one is what the assertion inspects after the failed launch two.
  ///
  /// This test FAILS against the pre-fix code (which persists the new 6-file signature regardless
  /// of the write outcome) and PASSES after the fix (prior 5-file signature retained).
  @MainActor
  func testColdOpenDoesNotPersistSignatureWhenReindexWriteFails() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSigFailTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<5 {
      try "fail-token body \(index)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: nil)

    // ---- First launch: full reindex succeeds → persists the 5-file signature to the substrate.
    let firstIndexURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let firstIndex = IndexDatabase(databaseURL: firstIndexURL, searchIndexBatchSize: 1)
    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: firstIndex,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    firstManager.open(url: folder, into: firstState)
    await firstManager.waitForPendingIndexUpdate()
    await firstIndex.waitForPendingReindex()

    let persistedAfterFirstLaunch = substrate.store.readSearchSignature(for: identity)
    XCTAssertEqual(
      persistedAfterFirstLaunch?.entries.count, 5,
      "first launch persists a 5-file signature after the successful full reindex")
    firstManager.closeWorkspace(into: firstState)  // simulate app quit between launches

    // Between launches the operator adds a 6th file, so the would-be-current signature differs
    // (6 entries) from the persisted one (5 entries).
    try "added-after-quit body".write(
      to: folder.appendingPathComponent("note-added.md"), atomically: true, encoding: .utf8)

    // ---- Deterministic write-failure injection: a db path whose PARENT is a regular file. Both
    // `createDirectory` and `DatabasePool(path:)` fail in `open()` → `databasePool` stays nil →
    // `ensureOpen` returns nil → every write (`reindexInBackground`) returns false.
    let blockerFile = folder.appendingPathComponent("blocker", isDirectory: false)
    try Data().write(to: blockerFile)  // a FILE where the second index expects a DIRECTORY
    let unwritableIndexURL = blockerFile.appendingPathComponent("index.db", isDirectory: false)
    let secondIndex = IndexDatabase(databaseURL: unwritableIndexURL, searchIndexBatchSize: 1)

    // ---- Second launch: the index cannot open → cold path takes the FULL-reindex branch (no
    // persisted-index rows visible) and `reindexInBackground` returns false → persist gated.
    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: secondIndex,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    secondManager.open(url: folder, into: secondState)
    await secondManager.waitForPendingIndexUpdate()
    await secondIndex.waitForPendingReindex()

    // The user-visible error report is preserved (the fix keeps `report(...)`); the failing index
    // open itself reports an error, so `lastError` is non-nil either way.
    XCTAssertNotNil(secondState.lastError, "a failed index open/reindex still reports an error")

    // CORE ASSERTION: the persisted signature was NOT advanced to the new 6-file value. It must
    // still be the prior 5-file signature, proving the failed write did not poison the skip-gate.
    let persistedAfterFailedWrite = substrate.store.readSearchSignature(for: identity)
    XCTAssertEqual(
      persistedAfterFailedWrite, persistedAfterFirstLaunch,
      "a FAILED reindex must NOT persist the new signature — the prior signature is retained")
    XCTAssertEqual(
      persistedAfterFailedWrite?.entries.count, 5,
      "the persisted signature still maps the original 5 files, not the post-quit 6")
  }

  /// SUBAGENT_08 / Invariant 4: the persisted signature round-trips through Codable and is keyed
  /// by workspace identity (a different root => a different key => nil).
  func testPersistedSignatureRoundTripsAndIsKeyedByIdentity() throws {
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSigCodableTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDir) }
    let store = WorkspaceCacheStore(baseDirectory: cacheDir)

    let rootA = URL(fileURLWithPath: "/tmp/pensieve-sig-root-a")
    let rootB = URL(fileURLWithPath: "/tmp/pensieve-sig-root-b")
    let identityA = WorkspaceIdentity.make(rootURL: rootA, bookmarkData: nil)
    let identityB = WorkspaceIdentity.make(rootURL: rootB, bookmarkData: nil)

    let signature = WorkspaceSignature(entries: [
      "/tmp/pensieve-sig-root-a/one.md": FileSignature(mtime: 1234.5, size: 42),
      "/tmp/pensieve-sig-root-a/two.md": FileSignature(mtime: 6789.0, size: 7),
    ])
    try store.writeSearchSignature(signature, for: identityA)

    let roundTripped = store.readSearchSignature(for: identityA)
    XCTAssertEqual(roundTripped, signature, "the signature round-trips losslessly through Codable")
    XCTAssertNil(
      store.readSearchSignature(for: identityB),
      "a different identity has no persisted signature — keying is per workspace identity")
  }

  /// Invariant 3: removing one `.md` deletes only its FTS row; it leaves search results, and
  /// the others remain. No upsert happens for a pure removal.
  @MainActor
  func testIncrementalRefreshDeletesOnlyRemovedFile() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDeltaRemoveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let goneURL = folder.appendingPathComponent("gone.md")
    try "doomed-token will be removed".write(to: goneURL, atomically: true, encoding: .utf8)
    try "survivor-token stays".write(
      to: folder.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)

    let recorder = BatchSizeRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())

    manager.open(url: folder, into: appState)
    await manager.waitForPendingIndexUpdate()
    let afterColdOpen = recorder.values.reduce(0, +)

    try FileManager.default.removeItem(at: goneURL)
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()

    let upsertedOnRemove = recorder.values.reduce(0, +) - afterColdOpen
    XCTAssertEqual(upsertedOnRemove, 0, "a pure removal must not upsert anything")

    let refs = appState.allDocuments
    XCTAssertTrue(
      indexDatabase.search(query: "doomed-token", documents: refs).isEmpty,
      "the removed file is no longer searchable")
    XCTAssertEqual(
      indexDatabase.search(query: "survivor-token", documents: refs).count, 1,
      "the surviving doc remains searchable")
  }

  /// Invariant 4: cold open (no prior baseline) full-indexes everything and search works.
  @MainActor
  func testColdOpenFullIndexesEntireWorkspace() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveColdOpenTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<4 {
      try "gamma-token entry \(index)".write(
        to: folder.appendingPathComponent("doc-\(index).md"), atomically: true, encoding: .utf8)
    }

    let recorder = BatchSizeRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())

    manager.open(url: folder, into: appState)
    await manager.waitForPendingIndexUpdate()

    XCTAssertEqual(recorder.values.reduce(0, +), 4, "cold open indexes all docs")
    XCTAssertEqual(
      indexDatabase.search(query: "gamma-token", documents: appState.allDocuments).count, 4,
      "every cold-indexed doc is searchable")
  }

  /// Invariant 5: when the `.md` set is identical (non-.md churn) the refresh still reconciles
  /// through exactly one off-main scan, but the matching search signature skips the FTS upsert.
  @MainActor
  func testRefreshSkipsAndDoesNotReindexWhenMarkdownUnchanged() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDeltaSkipTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    try "delta-token sole note".write(
      to: folder.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

    let recorder = BatchSizeRecorder()
    let calls = BuilderCallCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      calls.count += 1
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceBuilder: builder,
      watcher: FileWatcher(sourceFactory: { @Sendable in InertWatcherEventSource() }))

    manager.open(url: folder, into: appState)
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    let scansAfterOpen = calls.count
    let recordsAfterOpen = recorder.values.reduce(0, +)

    // Non-.md churn: a screenshot leaves the .md set untouched.
    try Data().write(to: folder.appendingPathComponent("shot.png"))
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    XCTAssertEqual(
      calls.count, scansAfterOpen + 1, "the refresh reconciles through exactly one scan")
    XCTAssertEqual(
      recorder.values.reduce(0, +), recordsAfterOpen, "skip path must not touch the FTS index")
  }

  // MARK: - Stage A1: off-main index write (rebuildWorkspace)

  /// A refresh does NOT block the main actor: `refresh` returns synchronously having scheduled
  /// ONE off-main scan (no enumeration/stat walk on the main actor — proven by the builder
  /// thread probe). After awaiting the reconcile the tree reflects the change, and only after
  /// `waitForPendingIndexUpdate()`/`waitForPendingReindex()` does the FTS index reflect it —
  /// the index write stays OFF the main actor behind its own sync point.
  @MainActor
  func testRebuildIndexWriteIsOffMainTreeObservableBeforeIndex() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveOffMainTreeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    try "seed-token original".write(
      to: folder.appendingPathComponent("seed.md"), atomically: true, encoding: .utf8)

    let scanThreads = ScanThreadRecorder()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      scanThreads.record(isMainThread: Thread.isMainThread)
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceBuilder: builder,
      watcher: FileWatcher(sourceFactory: { @Sendable in InertWatcherEventSource() }))

    manager.open(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingIndexUpdate()
    let scansAfterOpen = scanThreads.count

    // Add a new file, then refresh. The refresh returns synchronously; the scan and the index
    // write are launched off-main and are NOT awaited by `refresh` itself.
    let freshURL = folder.appendingPathComponent("fresh.md")
    try "fresh-token freshly added".write(to: freshURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    XCTAssertFalse(
      appState.allDocuments.contains(where: {
        $0.url.standardizedFileURL == freshURL.standardizedFileURL
      }),
      "refresh must not walk the workspace on the main actor before the off-main reconcile")

    // After the reconcile the tree reflects the new file; the scan ran off the main thread.
    await manager.waitForPendingForcedRefresh()
    XCTAssertTrue(
      appState.allDocuments.contains(where: {
        $0.url.standardizedFileURL == freshURL.standardizedFileURL
      }),
      "the document tree sees the new file once the off-main reconcile publishes")
    XCTAssertEqual(
      scanThreads.samples(after: scansAfterOpen), [false],
      "the refresh scan must run off the main thread")

    // Only after awaiting the off-main write does the FTS index reflect the change.
    await manager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    XCTAssertEqual(
      indexDatabase.search(query: "fresh-token", documents: appState.allDocuments)
        .map(\.document.url.lastPathComponent),
      ["fresh.md"], "the new file is searchable after the off-main write completes")
  }

  /// A LARGE delta — a batch of `.md` files dropped at once — goes through the off-main
  /// background path and the index is correct after awaiting. The cold open establishes a
  /// baseline so the subsequent refresh is an incremental delta (not a full reindex).
  @MainActor
  func testLargeDeltaGoesThroughBackgroundPathAndIsCorrect() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveLargeDeltaTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    try "anchor-token baseline note".write(
      to: folder.appendingPathComponent("anchor.md"), atomically: true, encoding: .utf8)

    let recorder = BatchSizeRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in recorder.record(size) })
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())

    manager.open(url: folder, into: appState)
    await manager.waitForPendingIndexUpdate()
    let recordsAfterColdOpen = recorder.values.reduce(0, +)
    XCTAssertEqual(recordsAfterColdOpen, 1, "cold open indexes the single baseline note")

    // Drop a batch of 25 new .md files at once, then refresh once. The delta must upsert
    // exactly the 25 new files through the background path.
    for index in 0..<25 {
      try "batch-token member \(index)".write(
        to: folder.appendingPathComponent("batch-\(index).md"), atomically: true, encoding: .utf8)
    }
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()

    let recordsAfterBatch = recorder.values.reduce(0, +) - recordsAfterColdOpen
    XCTAssertEqual(recordsAfterBatch, 25, "a large delta upserts exactly the 25 added files")
    XCTAssertEqual(
      indexDatabase.search(query: "batch-token", documents: appState.allDocuments).count, 25,
      "all batch-added files are searchable after the off-main write")
    XCTAssertEqual(
      indexDatabase.search(query: "anchor-token", documents: appState.allDocuments).count, 1,
      "the pre-existing baseline note remains searchable")
  }

  /// The cold / fallback (no baseline) FULL reindex also runs off-main: after `open` returns and
  /// the tree is observable synchronously, the FTS index is correct only after awaiting. Proven
  /// by the tree-before-index ordering plus correct search after the await.
  @MainActor
  func testColdFallbackReindexRunsOffMain() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveColdOffMainTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<6 {
      try "delta-cold-token entry \(index)".write(
        to: folder.appendingPathComponent("cold-\(index).md"), atomically: true, encoding: .utf8)
    }

    let indexDatabase = temporaryIndexDatabase(in: folder)
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())

    // `open` is the cold path (no baseline) → rebuildWorkspace takes the FULL reindex branch.
    manager.open(url: folder, into: appState)

    // Tree is fully populated synchronously, before the off-main full reindex completes.
    XCTAssertEqual(appState.allDocuments.count, 6, "cold open populates the tree synchronously")

    await manager.waitForPendingIndexUpdate()
    XCTAssertEqual(
      indexDatabase.search(query: "delta-cold-token", documents: appState.allDocuments).count, 6,
      "the cold full reindex indexed every doc off-main and they are all searchable")
  }

  /// `closeWorkspace` cancels a pending index task without leaving the index half-written. The
  /// underlying `pool.write` is a single transaction, so even if the close races the write the
  /// index is whole. After close the workspace state is cleared and no further index work is
  /// pending. This drives the close immediately after launching the rebuild's off-main write.
  @MainActor
  func testCloseWorkspaceCancelsPendingIndexTaskCleanly() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseIndexTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<8 {
      try "close-token entry \(index)".write(
        to: folder.appendingPathComponent("doc-\(index).md"), atomically: true, encoding: .utf8)
    }

    let indexDatabase = temporaryIndexDatabase(in: folder)
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())

    // Cold open launches an off-main full reindex; close immediately, racing the write.
    manager.open(url: folder, into: appState)
    manager.closeWorkspace(into: appState)

    // Workspace state is cleared regardless of the in-flight index write.
    XCTAssertTrue(appState.workspaceRoots.isEmpty, "roots cleared on close")
    XCTAssertTrue(appState.documents.isEmpty, "documents cleared on close")
    XCTAssertFalse(appState.hasWorkspaceContent, "no workspace content after close")

    // Let any in-flight single-transaction write settle. The index is never half-written: the
    // FTS table is either empty (cancelled before commit) or holds exactly the 8 whole docs
    // (committed before cancel) — never a torn partial. Search must not crash and the count
    // must be one of the two whole states.
    await indexDatabase.waitForPendingReindex()
    await manager.waitForPendingIndexUpdate()
    let refs = (0..<8).map {
      DocumentRef(id: folder.appendingPathComponent("doc-\($0).md").standardizedFileURL)
    }
    let indexedCount = indexDatabase.search(query: "close-token", documents: refs).count
    XCTAssertTrue(
      indexedCount == 0 || indexedCount == 8,
      "the index is whole — either nothing committed or all 8 docs, never a torn partial "
        + "(got \(indexedCount))")
  }

  /// Invariant 6 (self-write suppression + dirty protection): a self-write within the
  /// suppression window is gated so the watcher path is not even scheduled, and a dirty
  /// editor buffer survives an external delta refresh.
  @MainActor
  func testIncrementalRefreshPreservesDirtySessionOnExternalModify() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDeltaDirtyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let noteURL = folder.appendingPathComponent("note.md")
    try "clean original".write(to: noteURL, atomically: true, encoding: .utf8)

    let indexDatabase = temporaryIndexDatabase(in: folder)
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      watcherDebounceMilliseconds: 10)

    manager.open(url: folder, into: appState)
    selectDocument(at: noteURL, in: appState)
    XCTAssertEqual(appState.documentSession.text, "clean original")

    appState.activeDocumentText = "dirty local edit"
    appState.activeDocumentDirty = true
    try "external rewrite token noticeably longer".write(
      to: noteURL, atomically: true, encoding: .utf8)

    manager.scheduleWatcherRefresh(into: appState)
    await manager.waitForPendingWatcherRefresh()
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingIndexUpdate()

    XCTAssertEqual(
      appState.documentSession.text, "dirty local edit", "dirty buffer preserved through delta")
    XCTAssertTrue(appState.documentSession.isDirty, "dirty flag preserved")
    // The external change is still applied to the index (searchable) even though the buffer
    // was left dirty.
    XCTAssertEqual(
      indexDatabase.search(query: "external rewrite token", documents: appState.allDocuments)
        .map(\.document.url.lastPathComponent),
      ["note.md"])
  }

  @MainActor
  func testCloseWorkspaceClearsWorkspaceAndProtectsDirtyDocument() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let noteURL = folder.appendingPathComponent("note.md")
    try "body".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore()
    )

    manager.open(url: folder, into: appState)
    XCTAssertFalse(appState.workspaceRoots.isEmpty)
    XCTAssertFalse(appState.documents.isEmpty)
    XCTAssertTrue(appState.hasWorkspaceContent)

    // Clean document -> close clears the entire workspace.
    manager.closeWorkspace(into: appState)
    XCTAssertTrue(appState.workspaceRoots.isEmpty, "roots cleared")
    XCTAssertTrue(appState.workspaceTree.isEmpty, "tree cleared")
    XCTAssertTrue(appState.documents.isEmpty, "documents cleared")
    XCTAssertFalse(appState.hasWorkspaceContent, "no workspace content after close")
    XCTAssertNil(appState.selectedDocumentID)

    // Dirty document -> close still clears the workspace but preserves the unsaved editor.
    manager.open(url: folder, into: appState)
    appState.activeDocumentText = "unsaved local edit"
    appState.activeDocumentDirty = true
    manager.closeWorkspace(into: appState)
    XCTAssertTrue(appState.workspaceRoots.isEmpty, "roots cleared even with a dirty document")
    XCTAssertTrue(appState.documentSession.isDirty, "dirty session preserved (no data loss)")
    XCTAssertEqual(
      appState.documentSession.text, "unsaved local edit", "unsaved text preserved")
  }

  @MainActor
  func testFolderManagerHotReopenSkipsScannerWhenCacheValid() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveHotReopenTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("cached.md")
    try "cached body".write(to: noteURL, atomically: true, encoding: .utf8)

    let buildCounter = BuildCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      buildCounter.increment()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceBuilder: builder,
      workspaceSubstrate: WorkspaceSubstrate(store: store)
    )

    manager.open(url: folder, into: appState)
    XCTAssertEqual(buildCounter.value, 1)
    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])

    manager.open(url: folder, into: appState)

    XCTAssertEqual(buildCounter.value, 1)
    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])
    XCTAssertNil(appState.workspaceActivity)
  }

  @MainActor
  func testFolderManagerColdStartWithManifestPerformsSingleBuilderCall() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveColdStartManifestTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("cold.md")
    try "cold-start body".write(to: noteURL, atomically: true, encoding: .utf8)

    let buildCounter = BuildCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      buildCounter.increment()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceBuilder: builder,
      workspaceSubstrate: substrate
    )

    // Warm-up: first open does the initial cold scan and commits a manifest.
    // After this the manifest is on disk but the in-memory workspace state is
    // populated.
    manager.open(url: folder, into: appState)
    XCTAssertEqual(buildCounter.value, 1)
    let identity = WorkspaceIdentity.make(
      rootURL: folder, bookmarkData: appState.bookmarkData)
    XCTAssertNotNil(try store.readManifest(for: identity))

    // Simulate cold start: in-memory workspace is gone but the manifest stays
    // on disk (mirrors process relaunch with cache present). bookmarkData stays
    // so identity round-trips.
    appState.workspaceTree = []
    appState.workspaceRoots = []
    appState.documents = []
    appState.openFiles = []
    appState.selectedDocumentID = nil
    let warmupBuilderCount = buildCounter.value

    // Second open: with the cold-start guard ordered before workspaceSubstrate.open,
    // the empty tree short-circuits the cache fast-path and hands the single
    // tree walk to the cold scanner. Pins STAB-R01 / B-01: cold start always
    // performs exactly one builder walk, even when a manifest already exists.
    manager.open(url: folder, into: appState)

    XCTAssertEqual(
      buildCounter.value - warmupBuilderCount, 1,
      "cold start with existing manifest must take the cold-scan path exactly once")
    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])
    XCTAssertFalse(appState.workspaceTree.isEmpty)
    let postManifest = try XCTUnwrap(try store.readManifest(for: identity))
    let currentFingerprint = try TreeFingerprint.compute(rootURL: folder, exclusions: [])
    XCTAssertEqual(postManifest.workspaceID, identity.workspaceID)
    XCTAssertEqual(postManifest.treeFingerprint.treeHash, currentFingerprint.treeHash)
    XCTAssertNil(appState.workspaceActivity)
  }

  @MainActor
  func testFolderManagerCommitsManifestAfterColdScan() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveColdManifestTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    try "manifest body".write(
      to: folder.appendingPathComponent("manifest.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: store)
    )

    manager.open(url: folder, into: appState)

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let manifest = try XCTUnwrap(try store.readManifest(for: identity))
    let current = try TreeFingerprint.compute(rootURL: folder, exclusions: [])
    XCTAssertEqual(manifest.workspaceID, identity.workspaceID)
    XCTAssertEqual(manifest.treeFingerprint.treeHash, current.treeHash)
  }

  @MainActor
  func testFolderManagerFallsBackToColdScanOnFileEvidenceChange() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveFileEvidenceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("evidence.md")
    try "before".write(
      to: noteURL, atomically: true, encoding: .utf8)

    let buildCounter = BuildCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      buildCounter.increment()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      workspaceBuilder: builder,
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory()))
    )

    manager.open(url: folder, into: appState)
    try "after with more bytes".write(to: noteURL, atomically: true, encoding: .utf8)
    manager.open(url: folder, into: appState)

    XCTAssertEqual(buildCounter.value, 2)
  }

  @MainActor
  func testFolderManagerFallsBackToColdScanOnExclusionsChange() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveExclusionReopenTests-\(UUID().uuidString)", isDirectory: true
      )
    let drafts = folder.appendingPathComponent("Drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    try "keep".write(
      to: folder.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
    try "skip".write(
      to: drafts.appendingPathComponent("skip.md"), atomically: true, encoding: .utf8)

    let buildCounter = BuildCounter()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      buildCounter.increment()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    let metadataStore = temporaryMetadataStore()
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let manager = FolderManager(
      metadataStore: metadataStore,
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      workspaceBuilder: builder,
      workspaceSubstrate: WorkspaceSubstrate(store: store)
    )

    manager.open(url: folder, into: appState)
    try metadataStore.save(WorkspaceMetadata(excludedPaths: ["Drafts"]))
    manager.open(url: folder, into: appState)

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let manifest = try XCTUnwrap(try store.readManifest(for: identity))
    XCTAssertEqual(buildCounter.value, 2)
    XCTAssertEqual(manifest.exclusions, ["Drafts"])
    XCTAssertEqual(appState.documents.map(\.relativePath), ["keep.md"])
  }

  @MainActor
  func testFolderManagerColdScansAllRootsWhenMultipleFoldersAdded() throws {
    let firstRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveMultiRootOne-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveMultiRootTwo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
    }

    try "one".write(
      to: firstRoot.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
    try "two".write(
      to: secondRoot.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: firstRoot),
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory()))
    )

    manager.open(url: firstRoot, into: appState)
    manager.open(url: secondRoot, into: appState)

    // Multi-root falls back to the cold scan path (cache fast-path is single-root
    // only), so adding a second folder must keep BOTH roots and import both files —
    // not block with a multi-root error (that was the B-1b regression we hit).
    XCTAssertNil(appState.lastError)
    XCTAssertEqual(
      Set(appState.workspaceRoots.map(\.url)),
      Set([firstRoot.standardizedFileURL, secondRoot.standardizedFileURL]))
    XCTAssertEqual(
      Set(appState.documents.map(\.relativePath)), Set(["one.md", "two.md"]))
  }

  @MainActor
  func testWorkspaceExclusionsPersistAndFilterImportedPaths() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveExclusionTests-\(UUID().uuidString)", isDirectory: true)
    let drafts = folder.appendingPathComponent("Drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let keepURL = folder.appendingPathComponent("keep.md")
    let skipURL = drafts.appendingPathComponent("skip.md")
    try "keep".write(to: keepURL, atomically: true, encoding: .utf8)
    try "skip".write(to: skipURL, atomically: true, encoding: .utf8)

    let metadataStore = temporaryMetadataStore()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let appState = AppState()
    let manager = FolderManager(metadataStore: metadataStore, indexDatabase: indexDatabase)
    manager.open(url: folder, into: appState)
    XCTAssertEqual(appState.documents.count, 2)

    manager.addExcludedURLs([drafts], into: appState)
    await manager.waitForPendingForcedRefresh()
    await manager.waitForPendingIndexUpdate()
    await manager.waitForPendingWorkspaceIndexWrite()

    let expectedExclusion = try XCTUnwrap(
      WorkspaceExclusion.scopedKey(for: drafts, roots: [folder])
    )
    XCTAssertEqual(appState.excludedWorkspacePaths, Set([expectedExclusion]))
    XCTAssertEqual(
      appState.documents.map { $0.url.resolvingSymlinksInPath() },
      [keepURL.resolvingSymlinksInPath()])
    XCTAssertEqual(metadataStore.load().excludedPaths, [expectedExclusion])
    XCTAssertFalse(appState.documents.contains(where: { $0.url == skipURL.standardizedFileURL }))

    let relaunchedState = AppState()
    let relaunchedManager = FolderManager(
      metadataStore: metadataStore, indexDatabase: indexDatabase)
    relaunchedManager.open(url: folder, into: relaunchedState)
    await relaunchedManager.waitForPendingIndexUpdate()
    await relaunchedManager.waitForPendingWorkspaceIndexWrite()
    XCTAssertEqual(
      relaunchedState.documents.map { $0.url.resolvingSymlinksInPath() },
      [keepURL.resolvingSymlinksInPath()])
  }

  @MainActor
  func testOpenSingleMarkdownFileLoadsWithoutWorkspaceFolder() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveOpenFileTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("single.md")
    try "# Single".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    let recoveryStore = RecoveryStore(directoryURL: recoveryDirectory)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: DocumentStore(indexDatabase: indexDatabase, recoveryStore: recoveryStore),
      indexDatabase: indexDatabase
    )
    controller.openFile(url: noteURL)

    XCTAssertNil(appState.folderURL)
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
    XCTAssertTrue(appState.documents.isEmpty)
    XCTAssertEqual(
      appState.openFiles.map { $0.url.resolvingSymlinksInPath() },
      [noteURL.resolvingSymlinksInPath()])
    XCTAssertEqual(
      appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
    XCTAssertEqual(appState.activeDocumentText, "# Single")
  }

  @MainActor
  func testLaunchFileIntentLoadsBeforeRestoredWorkspaceCanScan() async throws {
    let defaults = makeEphemeralDefaults(prefix: "PensieveLaunchIntentTests")

    let restoredFolder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRestoredWorkspace-\(UUID().uuidString)", isDirectory: true)
    let launchFolder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveLaunchFile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: restoredFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: launchFolder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: restoredFolder)
      try? FileManager.default.removeItem(at: launchFolder)
    }

    try "restored".write(
      to: restoredFolder.appendingPathComponent("restored.md"), atomically: true, encoding: .utf8)
    let launchURL = launchFolder.appendingPathComponent("clicked.md")
    try "clicked first".write(to: launchURL, atomically: true, encoding: .utf8)

    let bookmarkStore = BookmarkStore(defaults: defaults)
    try bookmarkStore.persistRoot(url: restoredFolder, into: AppState())

    let scanStarted = DispatchSemaphore(value: 0)
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      scanStarted.signal()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: restoredFolder)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: builder
    )
    let controller = AppController(
      appState: appState,
      folderManager: manager,
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)

    coordinator.handle(urls: [launchURL])
    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(scanStarted.wait(timeout: .now() + 0.1), .timedOut)
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
    XCTAssertEqual(appState.openFiles.map(\.url), [launchURL.standardizedFileURL])
    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL, launchURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "clicked first")
  }

  @MainActor
  func testDefaultLaunchDecisionDoesNotInsertHumanVisibleDelay() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveInstantLaunchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()
      ),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator()
    let startedAt = ContinuousClock.now

    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    let elapsed = ContinuousClock.now - startedAt
    XCTAssertLessThan(
      elapsed,
      .milliseconds(50),
      "a bare launch must settle within one imperceptible UI frame, not an artificial timer"
    )
  }

  @MainActor
  func testLaunchFileIntentKeepsFirstMarkdownActiveAndReportsUnsupportedURLs() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveMultiLaunchIntentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let firstURL = folder.appendingPathComponent("first.md")
    let secondURL = folder.appendingPathComponent("second.markdown")
    let plainURL = folder.appendingPathComponent("plain.txt")
    let unsupportedURL = folder.appendingPathComponent("not-markdown.rtf")
    try "first body".write(to: firstURL, atomically: true, encoding: .utf8)
    try "second body".write(to: secondURL, atomically: true, encoding: .utf8)
    try "plain text".write(to: plainURL, atomically: true, encoding: .utf8)
    try "rich text".write(to: unsupportedURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)

    coordinator.handle(urls: [firstURL, secondURL, plainURL, unsupportedURL])
    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(
      appState.openFiles.map { $0.url.standardizedFileURL },
      [firstURL.standardizedFileURL, secondURL.standardizedFileURL, plainURL.standardizedFileURL])
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, firstURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "first body")
    XCTAssertTrue(appState.lastError?.contains(".md, .markdown, or .txt") == true)
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
  }

  /// System "Prefer tabs when opening documents: Always" contract: a file
  /// opened from Finder/Dock while this window already shows a document must
  /// route to the window registry (a native tab), NOT replace the document the
  /// user is reading in place. The old drain special-cased the first URL into
  /// `openFileInCurrentWindow`, which is correct only for a cold-start empty
  /// window — `openFile` itself already makes that distinction.
  @MainActor
  func testRuntimeFileOpenRoutesToDocumentWindowInsteadOfReplacingCurrent() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRuntimeOpenTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let readingURL = folder.appendingPathComponent("reading.md")
    let incomingURL = folder.appendingPathComponent("incoming.md")
    try "the doc being read".write(to: readingURL, atomically: true, encoding: .utf8)
    try "the doc arriving from Finder".write(to: incomingURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()
      ),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )

    // The window is already showing a document (editable buffer)...
    controller.openFile(url: readingURL)
    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL, readingURL.standardizedFileURL)

    // ...and document-window routing is wired, as in a real running window.
    var routedRefs: [URL] = []
    controller.requestOpenDocumentWindow = { ref in routedRefs.append(ref.id) }

    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)
    coordinator.handle(urls: [incomingURL])
    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(
      routedRefs.map(\.standardizedFileURL), [incomingURL.standardizedFileURL],
      "an external open with a document on screen must go to the registry (native tab)")
    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL, readingURL.standardizedFileURL,
      "the document the user is reading was replaced in place by the external open")
  }

  @MainActor
  func testBareLaunchSettlesAndShowsLauncherWhenSavedWorkspaceIsGone() async throws {
    let defaults = makeEphemeralDefaults(prefix: "PensieveBareLaunchTests")

    let removedFolder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRemovedWorkspace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: removedFolder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: removedFolder)
    }

    let bookmarkStore = BookmarkStore(defaults: defaults)
    try bookmarkStore.persistRoot(url: removedFolder, into: AppState())
    try FileManager.default.removeItem(at: removedFolder)

    let indexFolder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveBareLaunchIndex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: indexFolder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: indexFolder)
    }

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: indexFolder)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore
    )
    let controller = AppController(
      appState: appState,
      folderManager: manager,
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)
    var startupDecisionCount = 0

    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch) {
      startupDecisionCount += 1
    }
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(startupDecisionCount, 1)
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
    XCTAssertTrue(appState.openFiles.isEmpty)
    XCTAssertNil(appState.documentSession.url)
    XCTAssertNil(appState.lastError)
  }

  @MainActor
  func testLaunchFileIntentInterruptingSettleSignalsStartupDecisionOnce() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveLaunchInterruptTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let launchURL = folder.appendingPathComponent("clicked-during-settle.md")
    try "clicked during settle".write(to: launchURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 10_000_000_000)
    var startupDecisionCount = 0

    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch) {
      startupDecisionCount += 1
    }
    XCTAssertEqual(startupDecisionCount, 0)

    coordinator.handle(urls: [launchURL])
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(startupDecisionCount, 1)
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, launchURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "clicked during settle")
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
  }

  @MainActor
  func testDirtyDocumentIsSavedBeforeFastSelectionLoad() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDirtySwitchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha original".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta original".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    appState.documents = [DocumentRef(id: alphaURL), DocumentRef(id: betaURL)]
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    controller.selectDocument(id: alphaURL)

    appState.activeDocumentText = "alpha unsaved"
    appState.activeDocumentDirty = true

    // SwiftUI List selection can mutate before its onChange load callback runs.
    appState.selectedDocumentID = betaURL
    controller.selectDocument(id: betaURL)

    XCTAssertEqual(try String(contentsOf: alphaURL, encoding: .utf8), "alpha unsaved")
    XCTAssertEqual(try String(contentsOf: betaURL, encoding: .utf8), "beta original")
    XCTAssertEqual(appState.activeDocumentText, "beta original")
    XCTAssertEqual(
      appState.activeDocumentURL?.resolvingSymlinksInPath(), betaURL.resolvingSymlinksInPath())
    XCTAssertFalse(appState.activeDocumentDirty)
  }

  @MainActor
  func testDocumentSessionOwnsActiveDocumentState() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveSessionOwnershipTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("session.md")
    try "session original".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    appState.documents = [DocumentRef(id: noteURL.standardizedFileURL)]
    makeTestDocumentStore(indexDatabase: temporaryIndexDatabase(in: folder))
      .load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)

    XCTAssertEqual(
      appState.documentSession.url?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
    XCTAssertEqual(appState.documentSession.text, "session original")
    XCTAssertFalse(appState.documentSession.isDirty)

    appState.activeDocumentText = "session edited"
    appState.activeDocumentDirty = true

    XCTAssertEqual(appState.documentSession.text, "session edited")
    XCTAssertTrue(appState.documentSession.isDirty)
  }

  @MainActor
  func testSelectionRefusesWhenDirtySessionCannotBeSaved() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDirtyRefusalTests-\(UUID().uuidString)", isDirectory: true)
    let deletedFolder = folder.appendingPathComponent("Deleted", isDirectory: true)
    try FileManager.default.createDirectory(at: deletedFolder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = deletedFolder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha original".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta original".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    appState.documents = [
      DocumentRef(id: alphaURL.standardizedFileURL),
      DocumentRef(id: betaURL.standardizedFileURL),
    ]
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(indexDatabase: temporaryIndexDatabase(in: folder))
    )
    controller.selectDocument(id: alphaURL.standardizedFileURL)

    appState.activeDocumentText = "alpha unsaved"
    appState.activeDocumentDirty = true
    try FileManager.default.removeItem(at: deletedFolder)

    controller.selectDocument(id: betaURL.standardizedFileURL)

    XCTAssertEqual(
      appState.selectedDocumentID?.resolvingSymlinksInPath(),
      alphaURL.standardizedFileURL.resolvingSymlinksInPath())
    XCTAssertEqual(
      appState.documentSession.url?.resolvingSymlinksInPath(),
      alphaURL.standardizedFileURL.resolvingSymlinksInPath())
    XCTAssertEqual(appState.documentSession.text, "alpha unsaved")
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertTrue(appState.lastError?.contains("Could not save alpha.md") == true)
  }

  @MainActor
  func testExternalRefreshReloadsCleanSessionButProtectsDirtySession() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRefreshSessionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("note.md")
    try "clean original".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder),
      watcher: FileWatcher(sourceFactory: { @Sendable in InertWatcherEventSource() }))
    manager.open(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()
    selectDocument(at: noteURL, in: appState)
    XCTAssertEqual(appState.documentSession.text, "clean original")

    // The reload happens after the scheduled off-main reconcile publishes, not synchronously.
    try "clean external".write(to: noteURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    await manager.waitForPendingForcedRefresh()
    XCTAssertEqual(appState.documentSession.text, "clean external")
    XCTAssertFalse(appState.documentSession.isDirty)

    appState.activeDocumentText = "dirty local edit"
    appState.activeDocumentDirty = true
    try "dirty external replacement is longer".write(to: noteURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    await manager.waitForPendingForcedRefresh()

    XCTAssertEqual(appState.documentSession.text, "dirty local edit")
    XCTAssertTrue(appState.documentSession.isDirty)
  }

  @MainActor
  func testExplicitSaveWritesLoadedDocumentEvenIfSelectionAlreadyMoved() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveExplicitSaveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha original".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta original".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    appState.documents = [DocumentRef(id: alphaURL), DocumentRef(id: betaURL)]
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(indexDatabase: indexDatabase)
    documentStore.load(ref: DocumentRef(id: alphaURL), into: appState)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase
    )

    appState.activeDocumentText = "alpha command save"
    appState.activeDocumentDirty = true
    appState.selectedDocumentID = betaURL

    controller.saveActiveDocument()

    XCTAssertEqual(try String(contentsOf: alphaURL, encoding: .utf8), "alpha command save")
    XCTAssertEqual(try String(contentsOf: betaURL, encoding: .utf8), "beta original")
    XCTAssertFalse(appState.activeDocumentDirty)
  }

  @MainActor
  func testCloseActiveDocumentClearsSessionWithoutDroppingWorkspace() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseClearTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha body".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta body".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    controller.selectDocument(id: alphaURL.standardizedFileURL)
    XCTAssertNotNil(appState.documentSession.document)

    let workspaceDocumentsBefore = appState.documents.map(\.id)

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertNil(appState.documentSession.document)
    XCTAssertNil(appState.selectedDocumentID)
    XCTAssertEqual(appState.documentSession.text, "")
    XCTAssertFalse(appState.documentSession.isDirty)
    // Workspace and other open documents stay alive — only the active
    // session is cleared, not the window or sidebar contents.
    XCTAssertEqual(appState.documents.map(\.id), workspaceDocumentsBefore)
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
  }

  @MainActor
  func testCloseActiveDocumentSavesDirtySessionWhenTheUserConfirms() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseDirtyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("dirty.md")
    try "original".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    appState.documents = [DocumentRef(id: noteURL.standardizedFileURL)]
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(indexDatabase: indexDatabase)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      confirmSaveChanges: { _, _, _, respond in respond(.save) }
    )
    documentStore.load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)

    appState.activeDocumentText = "edited before close"
    appState.activeDocumentDirty = true

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "edited before close")
    XCTAssertNil(appState.documentSession.document)
    XCTAssertNil(appState.selectedDocumentID)
    XCTAssertFalse(appState.documentSession.isDirty)
  }

  @MainActor
  func testCloseActiveDocumentRefusesWhenDirtySaveFails() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseRefusalTests-\(UUID().uuidString)", isDirectory: true)
    let writable = folder.appendingPathComponent("Writable", isDirectory: true)
    try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = writable.appendingPathComponent("doomed.md")
    try "original".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    appState.documents = [DocumentRef(id: noteURL.standardizedFileURL)]
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(indexDatabase: indexDatabase)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      confirmSaveChanges: { _, _, _, respond in respond(.save) }
    )
    documentStore.load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)

    appState.activeDocumentText = "unsaved tail"
    appState.activeDocumentDirty = true

    // Knock the directory out from under the active document so its save
    // fails. The session must stay alive and dirty rather than silently
    // dropping the user's edits.
    try FileManager.default.removeItem(at: writable)

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, false)
    XCTAssertNotNil(appState.documentSession.document)
    XCTAssertEqual(appState.documentSession.text, "unsaved tail")
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertEqual(
      appState.selectedDocumentID?.resolvingSymlinksInPath(),
      noteURL.standardizedFileURL.resolvingSymlinksInPath())
    XCTAssertTrue(appState.lastError?.contains("Could not save doomed.md") == true)
  }

  @MainActor
  func testControllerRoutesModeAndPreferenceCommands() {
    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: FileManager.default.temporaryDirectory)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.setMode(.preview)
    XCTAssertEqual(appState.mode, .preview)

    controller.toggleSidebar()
    XCTAssertFalse(appState.sidebarVisible)

    controller.toggleRichMarkdown()
    XCTAssertFalse(appState.richMarkdownEnabled)

    controller.bumpFontSize(by: 2)
    XCTAssertEqual(appState.fontSize, 16)

    controller.resetFontSize()
    XCTAssertEqual(appState.fontSize, 14)
  }

  @MainActor
  func testControllerRoutesWorkspaceCommands() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveWorkspaceCommandTests-\(UUID().uuidString)", isDirectory: true)
    let hidden = folder.appendingPathComponent("Hidden", isDirectory: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    try "visible".write(
      to: folder.appendingPathComponent("visible.md"), atomically: true, encoding: .utf8)
    try "hidden".write(
      to: hidden.appendingPathComponent("hidden.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let folderManager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase)
    let controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    XCTAssertEqual(appState.documents.count, 2)

    controller.excludeFromWorkspace(urls: [hidden])
    await folderManager.waitForPendingForcedRefresh()
    await folderManager.waitForPendingIndexUpdate()
    await folderManager.waitForPendingWorkspaceIndexWrite()
    let expectedExclusion = try XCTUnwrap(
      WorkspaceExclusion.scopedKey(for: hidden, roots: [folder])
    )
    XCTAssertEqual(appState.excludedWorkspacePaths, Set([expectedExclusion]))
    XCTAssertEqual(appState.documents.count, 1)

    controller.clearWorkspaceExclusions()
    await folderManager.waitForPendingForcedRefresh()
    await folderManager.waitForPendingIndexUpdate()
    await folderManager.waitForPendingWorkspaceIndexWrite()
    XCTAssertTrue(appState.excludedWorkspacePaths.isEmpty)
    XCTAssertEqual(appState.documents.count, 2)
  }

  @MainActor
  func testControllerCreatesMarkdownFileInWorkspaceAndSelectsIt() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCreateFileTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase)
    let controller = AppController(
      appState: appState,
      folderManager: manager,
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    let createdURL = folder.appendingPathComponent("Fresh Note.md").standardizedFileURL

    XCTAssertTrue(controller.createMarkdownFile(url: folder.appendingPathComponent("Fresh Note")))
    XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, createdURL)
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, createdURL)
    XCTAssertEqual(appState.activeDocumentText, "")
    XCTAssertFalse(appState.activeDocumentDirty)
    XCTAssertEqual(appState.documents.first?.relativePath, "Fresh Note.md")
    XCTAssertEqual(appState.workspaceTree.first?.children?.first?.name, "Fresh Note")
  }

  @MainActor
  func testControllerCreatesDocumentAndFolderWithCollisionNames() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveCreateCollisionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let existingDocumentURL = folder.appendingPathComponent("Untitled.md")
    let existingFolderURL = folder.appendingPathComponent("New Folder", isDirectory: true)
    try "keep existing".write(to: existingDocumentURL, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: existingFolderURL,
      withIntermediateDirectories: true
    )

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)

    let createdDocumentURL = try XCTUnwrap(controller.createDocument(in: nil))
    await indexDatabase.waitForPendingReindex()

    XCTAssertEqual(
      createdDocumentURL.standardizedFileURL,
      folder.appendingPathComponent("Untitled 2.md").standardizedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: createdDocumentURL.path))
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, createdDocumentURL)
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, createdDocumentURL)
    XCTAssertFalse(appState.activeDocumentDirty)
    XCTAssertEqual(appState.pendingSidebarRenameURL?.standardizedFileURL, createdDocumentURL)
    XCTAssertTrue(
      appState.documents.contains {
        $0.url.standardizedFileURL == createdDocumentURL.standardizedFileURL
      })

    let createdFolderURL = try XCTUnwrap(controller.createFolder(in: nil))

    XCTAssertEqual(
      createdFolderURL.standardizedFileURL,
      folder.appendingPathComponent("New Folder 2", isDirectory: true).standardizedFileURL)
    var isDirectory = ObjCBool(false)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: createdFolderURL.path,
        isDirectory: &isDirectory
      ))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertEqual(appState.pendingSidebarRenameURL?.standardizedFileURL, createdFolderURL)
    XCTAssertTrue(
      appState.workspaceTree.first?.children?.contains {
        $0.url?.standardizedFileURL == createdFolderURL.standardizedFileURL
      } == true)
  }

  @MainActor
  func testControllerCreatesUntitledDocumentWithoutWritingAFile() {
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory))
    )

    XCTAssertTrue(controller.createUntitledDocument())

    XCTAssertTrue(appState.documentSession.isUntitled)
    XCTAssertTrue(appState.documentSession.hasEditableBuffer)
    XCTAssertNil(appState.documentSession.url)
    XCTAssertEqual(appState.documentSession.displayTitle, "Untitled.md")
    XCTAssertEqual(appState.activeDocumentText, "")
    XCTAssertFalse(appState.activeDocumentDirty)
  }

  @MainActor
  func testControllerCreatesDistinctUntitledTitlesForFreshCommandN() {
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory))
    )

    XCTAssertTrue(controller.createUntitledDocument())
    XCTAssertEqual(appState.documentSession.displayTitle, "Untitled.md")

    XCTAssertTrue(controller.createUntitledDocument())
    XCTAssertEqual(appState.documentSession.displayTitle, "Untitled 2.md")

    XCTAssertTrue(controller.createUntitledDocument())
    XCTAssertEqual(appState.documentSession.displayTitle, "Untitled 3.md")
  }

  @MainActor
  func testUntitledDocumentSaveAsWritesFileAndSwitchesSession() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveUntitledSaveAsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: folder),
        bookmarkStore: temporaryBookmarkStore()
      )
    )
    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "untitled body"
    appState.activeDocumentDirty = true

    let savedURL = folder.appendingPathComponent("saved-untitled.md")

    XCTAssertTrue(controller.saveActiveDocument(as: savedURL))
    XCTAssertEqual(try String(contentsOf: savedURL, encoding: .utf8), "untitled body")
    XCTAssertFalse(appState.documentSession.isUntitled)
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, savedURL.standardizedFileURL)
    XCTAssertFalse(appState.activeDocumentDirty)
    XCTAssertTrue(
      appState.openFiles.contains { $0.url.standardizedFileURL == savedURL.standardizedFileURL })
  }

  @MainActor
  func testDirtyUntitledDocumentCanCancelTerminationPrompt() {
    let appState = AppState()
    var prompted = false
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory),
      dirtySessionPrompt: { session in
        prompted = session.isUntitled
        return .cancel
      }
    )
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: documentStore
    )

    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "please keep me"
    appState.activeDocumentDirty = true

    XCTAssertFalse(controller.applicationShouldTerminate())
    XCTAssertTrue(prompted)
    XCTAssertTrue(appState.documentSession.isUntitled)
    XCTAssertTrue(appState.activeDocumentDirty)
  }

  /// ⌘Q must ask about EVERY window's unsaved work, not just the one it fired
  /// from — otherwise other windows exit through their teardown path, which has
  /// no veto point and can never ask. With every window's guard resolving, the
  /// quit proceeds and each dirty session was asked.
  @MainActor
  func testQuitResolvesEveryWindowsUnsavedWork() {
    let registry = DocumentWindowRegistry(canMutateWindowTabs: { true })
    let windowA = Self.makeControllerlessWindow()
    let windowB = Self.makeControllerlessWindow()
    defer {
      windowA.close()
      windowB.close()
    }

    var promptedA = false
    let stateA = AppState()
    let controllerA = AppController(
      appState: stateA,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory),
        dirtySessionPrompt: { _ in
          promptedA = true
          return .discard
        }),
      indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory),
      documentWindowRegistry: registry)
    XCTAssertTrue(controllerA.createUntitledDocument())
    stateA.activeDocumentText = "window A unsaved"
    stateA.activeDocumentDirty = true

    var promptedB = false
    let stateB = AppState()
    let controllerB = AppController(
      appState: stateB,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory),
        dirtySessionPrompt: { _ in
          promptedB = true
          return .discard
        }),
      documentWindowRegistry: registry)
    XCTAssertTrue(controllerB.createUntitledDocument())
    stateB.activeDocumentText = "window B unsaved"
    stateB.activeDocumentDirty = true

    registry.registerController(controllerA, for: windowA)
    registry.registerController(controllerB, for: windowB)

    XCTAssertTrue(controllerA.applicationShouldTerminate())
    XCTAssertTrue(promptedA, "the firing window's dirty session must be asked about")
    XCTAssertTrue(promptedB, "the OTHER window's dirty session must be asked about too")
    XCTAssertFalse(stateA.documentSession.isDirty)
    XCTAssertFalse(stateB.documentSession.isDirty)
  }

  /// A Cancel in ANY window aborts the whole quit; every window keeps its work.
  @MainActor
  func testQuitCancelledInAnotherWindowAbortsTheWholeQuit() {
    let registry = DocumentWindowRegistry(canMutateWindowTabs: { true })
    let firingWindow = Self.makeControllerlessWindow()
    let otherWindow = Self.makeControllerlessWindow()
    defer {
      firingWindow.close()
      otherWindow.close()
    }

    let firingState = AppState()
    let firingController = AppController(
      appState: firingState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory),
        dirtySessionPrompt: { _ in .discard }),
      indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory),
      documentWindowRegistry: registry)
    XCTAssertTrue(firingController.createUntitledDocument())
    firingState.activeDocumentText = "firing window work"
    firingState.activeDocumentDirty = true

    var promptedOther = false
    let otherState = AppState()
    let otherController = AppController(
      appState: otherState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory),
        dirtySessionPrompt: { _ in
          promptedOther = true
          return .cancel
        }),
      documentWindowRegistry: registry)
    XCTAssertTrue(otherController.createUntitledDocument())
    otherState.activeDocumentText = "please keep this"
    otherState.activeDocumentDirty = true

    registry.registerController(firingController, for: firingWindow)
    registry.registerController(otherController, for: otherWindow)

    XCTAssertFalse(
      firingController.applicationShouldTerminate(),
      "a Cancel in another window must abort the whole quit")
    XCTAssertTrue(promptedOther, "the cancelling window must have been asked")
    XCTAssertTrue(
      otherState.documentSession.isDirty, "the cancelled window keeps its unsaved work intact")
  }

  /// The quit pass must be TRANSACTIONAL, not just vetoable. The existing Cancel
  /// pin above asks the cancelling window FIRST, so the destructive branch never
  /// fires; here the Don't Save is answered BEFORE the Cancel — the firing window
  /// is asked LAST — which is the order that used to lose data. With decide and
  /// apply fused, window B's "Don't Save" physically deleted its recovery draft
  /// and cleared `isDirty` while window A's Cancel then kept the app running: B
  /// still showed its text, but a crash lost it and the next ⌘Q/close asked
  /// nothing. A cancelled quit must leave B exactly as recoverable as before.
  @MainActor
  func testQuitDiscardInAnotherWindowThenCancelKeepsTheRecoveryDraft() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveQuitDiscardTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let registry = DocumentWindowRegistry(canMutateWindowTabs: { true })
    let firingWindow = Self.makeControllerlessWindow()
    let discardWindow = Self.makeControllerlessWindow()
    defer {
      firingWindow.close()
      discardWindow.close()
    }

    // Window B: untitled, dirty, with a recovery draft already on disk. Its
    // guard answers Don't Save. It is an "other" window, so ⌘Q asks it FIRST.
    let discardRecovery = RecoveryStore(
      directoryURL: folder.appendingPathComponent("RecoveryB", isDirectory: true))
    var promptedDiscard = false
    let discardState = AppState()
    let discardStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: discardRecovery,
      dirtySessionPrompt: { session in
        promptedDiscard = session.isUntitled
        return .discard
      })
    let discardController = AppController(
      appState: discardState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: discardStore,
      documentWindowRegistry: registry)
    XCTAssertTrue(discardController.createUntitledDocument())
    discardState.activeDocumentText = "window B unsaved draft"
    discardState.activeDocumentDirty = true
    // Flush a recovery draft the way autosave/close would, so the Discard has
    // something real to drop.
    XCTAssertTrue(discardStore.savePendingChangesOnClose(appState: discardState))
    XCTAssertFalse(discardRecovery.loadDrafts().isEmpty, "fixture must seed a recovery draft")
    let discardIdentity = try XCTUnwrap(discardState.windowModel.documentIdentity)

    // Window A: fires ⌘Q, so it is asked LAST — and Cancels.
    var promptedCancel = false
    let firingState = AppState()
    let firingController = AppController(
      appState: firingState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: folder),
        dirtySessionPrompt: { _ in
          promptedCancel = true
          return .cancel
        }),
      indexDatabase: temporaryIndexDatabase(in: folder),
      documentWindowRegistry: registry)
    XCTAssertTrue(firingController.createUntitledDocument())
    firingState.activeDocumentText = "window A unsaved"
    firingState.activeDocumentDirty = true

    registry.registerController(discardController, for: discardWindow)
    registry.registerController(firingController, for: firingWindow)

    XCTAssertFalse(
      firingController.applicationShouldTerminate(),
      "a Cancel in the firing window must abort the whole quit")
    XCTAssertTrue(promptedDiscard, "window B must have been asked before window A")
    XCTAssertTrue(promptedCancel, "the firing window must have been asked last")

    XCTAssertTrue(
      discardState.activeDocumentDirty,
      "the discarded window must stay dirty — Don't Save was only recorded")
    XCTAssertEqual(
      discardState.activeDocumentText, "window B unsaved draft",
      "the buffer text must survive the aborted quit")
    XCTAssertEqual(
      discardState.windowModel.documentIdentity, discardIdentity,
      "the discarded window must still own its document")
    XCTAssertFalse(
      discardRecovery.loadDrafts().isEmpty,
      "the recovery draft must still exist — a cancelled Discard is recoverable")
    // The teardown guard and the close sheet both key off the session being
    // dirty: a silently-cleaned session would ask nothing on the NEXT close.
    XCTAssertNotNil(
      discardStore.closeDecision(appState: discardState).prompt,
      "closing window B again must still ask about its unsaved work")
  }

  /// The pathed twin of the pin above, for the SECOND kind of Discard: a
  /// file-backed document with auto-save OFF answers Don't Save, and the firing
  /// window then Cancels. The in-memory edit is the only copy — auto-save off
  /// means nothing reached disk — so cancelling the pending write and clearing
  /// `isDirty` is just as irreversible as dropping an untitled draft, and must
  /// wait for the apply phase. The file itself is never written by this path.
  @MainActor
  func testQuitPathedDontSaveInAnotherWindowThenCancelKeepsTheEdit() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveQuitPathedTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let registry = DocumentWindowRegistry(canMutateWindowTabs: { true })
    let firingWindow = Self.makeControllerlessWindow()
    let discardWindow = Self.makeControllerlessWindow()
    defer {
      firingWindow.close()
      discardWindow.close()
    }

    // Window B: a pathed doc with auto-save OFF, edited in memory only.
    let fileURL = folder.appendingPathComponent("pathed.md")
    try "on disk".write(to: fileURL, atomically: true, encoding: .utf8)
    var promptedForPathedDocument = false
    let discardState = AppState()
    let discardStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      savingSettings: makeAutoSaveSettings(enabled: false),
      dirtySessionPrompt: { session in
        promptedForPathedDocument = !session.isUntitled
        return .discard
      })
    let discardController = AppController(
      appState: discardState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: discardStore,
      documentWindowRegistry: registry)
    discardStore.load(ref: DocumentRef(id: fileURL.standardizedFileURL), into: discardState)
    discardState.activeDocumentText = "edited, never written"
    discardState.activeDocumentDirty = true

    // Window A: fires ⌘Q, asked LAST, and Cancels.
    let firingState = AppState()
    let firingController = AppController(
      appState: firingState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: folder),
        dirtySessionPrompt: { _ in .cancel }),
      indexDatabase: temporaryIndexDatabase(in: folder),
      documentWindowRegistry: registry)
    XCTAssertTrue(firingController.createUntitledDocument())
    firingState.activeDocumentText = "window A unsaved"
    firingState.activeDocumentDirty = true

    registry.registerController(discardController, for: discardWindow)
    registry.registerController(firingController, for: firingWindow)

    XCTAssertFalse(
      firingController.applicationShouldTerminate(),
      "a Cancel in the firing window must abort the whole quit")
    XCTAssertTrue(
      promptedForPathedDocument,
      "auto-save off must ask before a pathed document is settled on quit")
    XCTAssertTrue(
      discardState.activeDocumentDirty,
      "a cancelled quit must leave the pathed edit dirty — Don't Save was only recorded")
    XCTAssertEqual(
      discardState.activeDocumentText, "edited, never written",
      "the in-memory edit is the only copy and must survive the aborted quit")
    XCTAssertEqual(
      try String(contentsOf: fileURL, encoding: .utf8), "on disk",
      "auto-save off means the quit pass writes nothing to the file, aborted or not")
    XCTAssertNotNil(
      discardStore.closeDecision(appState: discardState).prompt,
      "closing window B again must still ask about its unsaved edit")
  }

  /// Open Files mirrors EVERY window's documents into EVERY window's sidebar, so
  /// closing a row can target a document owned by ANOTHER window. The dirty
  /// guard must run in the target's OWN session — cancelling it there must abort
  /// the close instead of force-closing the target and dropping unsaved edits
  /// into a silent recovery draft.
  @MainActor
  func testCrossWindowCloseRoutesDirtyGuardToOwningSessionAndCancelAborts() {
    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let callerWindow = Self.makeControllerlessWindow()
    let ownerWindow = Self.makeControllerlessWindow()
    defer {
      callerWindow.close()
      ownerWindow.close()
    }

    let callerController = AppController(
      appState: AppState(),
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(),
      documentWindowRegistry: registry
    )

    let ownerRecorder = SaveChangesRecorder()
    ownerRecorder.answer = .cancel
    let ownerState = AppState()
    let ownerController = AppController(
      appState: ownerState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(),
      documentWindowRegistry: registry,
      confirmSaveChanges: ownerRecorder.confirmation()
    )

    XCTAssertTrue(ownerController.createUntitledDocument())
    ownerState.activeDocumentText = "unsaved work living in another window"
    ownerState.activeDocumentDirty = true
    let ownerIdentity = try! XCTUnwrap(ownerState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        ownerWindow, identity: ownerIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(ownerController, for: ownerWindow)
    registry.registerController(callerController, for: callerWindow)

    // The CALLER closes the OWNER's untitled row from its mirrored Open Files.
    callerController.closeOpenDocument(identity: ownerIdentity)

    XCTAssertEqual(
      ownerRecorder.prompts, [.saveAsUntitled],
      "the close decision must be asked in the owning window's session")
    XCTAssertTrue(closedWindows.isEmpty, "a cancelled decision must abort the close")
    XCTAssertTrue(ownerState.documentSession.isUntitled)
    XCTAssertTrue(ownerState.activeDocumentDirty, "the unsaved work must survive intact")
    XCTAssertEqual(ownerState.windowModel.documentIdentity, ownerIdentity)
  }

  /// Same cross-window routing, but the owning session's close decision resolves
  /// (Don't Save) — so the close proceeds and the owner's window is torn down.
  @MainActor
  func testCrossWindowCloseProceedsWhenOwningGuardResolves() {
    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let callerWindow = Self.makeControllerlessWindow()
    let ownerWindow = Self.makeControllerlessWindow()
    defer {
      callerWindow.close()
      ownerWindow.close()
    }

    let callerController = AppController(
      appState: AppState(),
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(),
      documentWindowRegistry: registry
    )

    let ownerRecorder = SaveChangesRecorder()
    ownerRecorder.answer = .discard
    let ownerState = AppState()
    let ownerController = AppController(
      appState: ownerState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(),
      documentWindowRegistry: registry,
      confirmSaveChanges: ownerRecorder.confirmation()
    )

    XCTAssertTrue(ownerController.createUntitledDocument())
    ownerState.activeDocumentText = "discardable"
    ownerState.activeDocumentDirty = true
    let ownerIdentity = try! XCTUnwrap(ownerState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        ownerWindow, identity: ownerIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(ownerController, for: ownerWindow)
    registry.registerController(callerController, for: callerWindow)

    callerController.closeOpenDocument(identity: ownerIdentity)

    XCTAssertEqual(closedWindows, [ownerWindow], "a resolved guard must close the owner's window")
    XCTAssertFalse(ownerState.documentSession.isDirty)
  }

  /// "Clear Open Files" mirrors EVERY window's documents, so it tears down tabs
  /// owned by other windows. It must guard each document in its OWNING window's
  /// session and abort the WHOLE pass if any guard is cancelled — close NOTHING.
  /// But the abort rolls back only the CLOSING of windows, not content decisions
  /// already made earlier in the pass: a window that force-saved keeps its bytes
  /// on disk even though the overall operation is cancelled.
  @MainActor
  func testClearOpenFilesCancelledInAnotherWindowClosesNothing() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearOpenFilesTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let saveWindow = Self.makeControllerlessWindow()
    let cleanWindow = Self.makeControllerlessWindow()
    let cancelWindow = Self.makeControllerlessWindow()
    defer {
      saveWindow.close()
      cleanWindow.close()
      cancelWindow.close()
    }

    // Window A ("this" window): a real file, dirtied, whose owning guard
    // force-saves EARLIER in the pass (existing file → write, no prompt).
    let fileURL = folder.appendingPathComponent("saved.md")
    try "on disk".write(to: fileURL, atomically: true, encoding: .utf8)
    let saveState = AppState()
    let saveStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore())
    let saveController = AppController(
      appState: saveState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: saveStore,
      documentWindowRegistry: registry
    )
    saveStore.load(ref: DocumentRef(id: fileURL.standardizedFileURL), into: saveState)
    saveState.activeDocumentText = "edited in memory"
    saveState.activeDocumentDirty = true
    let saveIdentity = try XCTUnwrap(saveState.windowModel.documentIdentity)

    // Window C (ANOTHER window): a real file, CLEAN (not dirty). Its guard is a
    // no-op that must neither prompt nor clear — the pre-fix pass blanked it
    // anyway via select(ref: nil), so it exercises the clean-window hole.
    let cleanURL = folder.appendingPathComponent("clean.md")
    try "clean on disk".write(to: cleanURL, atomically: true, encoding: .utf8)
    let cleanState = AppState()
    let cleanStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore())
    let cleanController = AppController(
      appState: cleanState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: cleanStore,
      documentWindowRegistry: registry
    )
    cleanStore.load(ref: DocumentRef(id: cleanURL.standardizedFileURL), into: cleanState)
    let cleanIdentity = try XCTUnwrap(cleanState.windowModel.documentIdentity)

    // Window B (ANOTHER window): untitled, dirty; its guard is CANCELLED.
    var cancelPrompted = false
    let cancelState = AppState()
    let cancelController = AppController(
      appState: cancelState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(dirtySessionPrompt: { session in
        cancelPrompted = session.isUntitled
        return .cancel
      }),
      documentWindowRegistry: registry
    )
    XCTAssertTrue(cancelController.createUntitledDocument())
    cancelState.activeDocumentText = "unsaved work in another window"
    cancelState.activeDocumentDirty = true
    let cancelIdentity = try XCTUnwrap(cancelState.windowModel.documentIdentity)

    // Attach the Save and Clean windows FIRST so they resolve EARLIER in the
    // pass, the Cancel window LAST so the abort trips only after the earlier
    // windows have already been asked.
    XCTAssertTrue(
      registry.attach(
        saveWindow, identity: saveIdentity, documentID: fileURL,
        title: "saved.md", isDirty: true, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cleanWindow, identity: cleanIdentity, documentID: cleanURL,
        title: "clean.md", isDirty: false, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cancelWindow, identity: cancelIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(saveController, for: saveWindow)
    registry.registerController(cleanController, for: cleanWindow)
    registry.registerController(cancelController, for: cancelWindow)

    // "Clear Open Files" invoked from window A.
    saveController.clearOpenFiles()

    // (1) Cancel in another window aborts: zero windows closed, buffer intact.
    XCTAssertTrue(cancelPrompted, "the abort must originate in the owning window's guard")
    XCTAssertTrue(closedWindows.isEmpty, "a cancelled guard must close NOTHING")
    XCTAssertTrue(cancelState.documentSession.isUntitled)
    XCTAssertTrue(cancelState.activeDocumentDirty, "the cancelled window's unsaved work survives")
    XCTAssertEqual(cancelState.windowModel.documentIdentity, cancelIdentity)

    // (2) Documented non-rollback: the Save resolved earlier in the SAME pass is
    // NOT undone — its bytes are on disk even though the pass was cancelled.
    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "edited in memory")
    XCTAssertFalse(saveState.activeDocumentDirty, "the force-saved window is clean on disk")

    // (3) Partial-state hole: a Cancel raised on a LATER window must NOT blank
    // the windows asked earlier. The force-saved (dirty) window keeps its
    // document, and so does the clean (no-op guard) window — both stay
    // open-with-content, never blanked-but-open.
    XCTAssertEqual(
      saveState.windowModel.documentIdentity, saveIdentity,
      "the earlier force-saved window must still own its document after the abort")
    XCTAssertTrue(
      saveState.documentSession.hasEditableBuffer,
      "the earlier force-saved window's session must not be cleared")
    XCTAssertEqual(
      cleanState.windowModel.documentIdentity, cleanIdentity,
      "the earlier clean window must still own its document after the abort")
    XCTAssertTrue(
      cleanState.documentSession.hasEditableBuffer,
      "the earlier clean window's session must not be cleared")
  }

  /// Case 1 — the guarantee this rework adds. Window A chose Discard on an
  /// untitled draft; window B then Cancels. The whole pass aborts, so A's
  /// Discard must NOT have been applied: its buffer is still dirty and — the
  /// load-bearing bit — its recovery draft is still on disk, recoverable. The
  /// pre-rework code applied the Discard eagerly in the ASK phase, dropping the
  /// draft before the Cancel could abort.
  @MainActor
  func testClearOpenFilesDiscardThenCancelKeepsRecoveryDraft() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearDiscardTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let discardWindow = Self.makeControllerlessWindow()
    let cancelWindow = Self.makeControllerlessWindow()
    defer {
      discardWindow.close()
      cancelWindow.close()
    }

    // Window A: untitled, dirty, with a recovery draft already on disk. Its
    // guard chooses Discard.
    let discardRecovery = RecoveryStore(
      directoryURL: folder.appendingPathComponent("RecoveryA", isDirectory: true))
    let discardState = AppState()
    let discardStore = makeTestDocumentStore(
      recoveryStore: discardRecovery,
      dirtySessionPrompt: { _ in .discard })
    let discardController = AppController(
      appState: discardState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: discardStore,
      documentWindowRegistry: registry
    )
    XCTAssertTrue(discardController.createUntitledDocument())
    discardState.activeDocumentText = "unsaved untitled work"
    discardState.activeDocumentDirty = true
    // Flush a recovery draft the way the close/autosave path would, so a later
    // Discard has something to drop. This also stamps the recovered identity.
    XCTAssertTrue(discardStore.savePendingChangesOnClose(appState: discardState))
    XCTAssertFalse(discardRecovery.loadDrafts().isEmpty, "fixture must seed a recovery draft")
    let discardIdentity = try XCTUnwrap(discardState.windowModel.documentIdentity)

    // Window B: untitled, dirty; its guard Cancels.
    var cancelPrompted = false
    let cancelState = AppState()
    let cancelController = AppController(
      appState: cancelState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(dirtySessionPrompt: { session in
        cancelPrompted = session.isUntitled
        return .cancel
      }),
      documentWindowRegistry: registry
    )
    XCTAssertTrue(cancelController.createUntitledDocument())
    cancelState.activeDocumentText = "unsaved work in another window"
    cancelState.activeDocumentDirty = true
    let cancelIdentity = try XCTUnwrap(cancelState.windowModel.documentIdentity)

    // Discard window FIRST (resolves earlier), Cancel window SECOND.
    XCTAssertTrue(
      registry.attach(
        discardWindow, identity: discardIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cancelWindow, identity: cancelIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(discardController, for: discardWindow)
    registry.registerController(cancelController, for: cancelWindow)

    discardController.clearOpenFiles()

    XCTAssertTrue(cancelPrompted, "the abort must originate in the owning window's guard")
    XCTAssertTrue(closedWindows.isEmpty, "a cancelled pass must close NOTHING")
    // The deferred Discard was NEVER applied because the pass aborted.
    XCTAssertTrue(
      discardState.activeDocumentDirty,
      "the discarded window's buffer must stay dirty when the pass is cancelled")
    XCTAssertEqual(
      discardState.activeDocumentText, "unsaved untitled work",
      "the buffer text must survive the aborted pass")
    XCTAssertEqual(
      discardState.windowModel.documentIdentity, discardIdentity,
      "the discarded window must still own its document")
    XCTAssertFalse(
      discardRecovery.loadDrafts().isEmpty,
      "the recovery draft must still exist — a cancelled Discard is recoverable")
  }

  /// Case 2 — a clean earlier window is untouched when a later window Cancels.
  @MainActor
  func testClearOpenFilesCleanWindowSurvivesLaterCancel() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearCleanTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let cleanWindow = Self.makeControllerlessWindow()
    let cancelWindow = Self.makeControllerlessWindow()
    defer {
      cleanWindow.close()
      cancelWindow.close()
    }

    let cleanURL = folder.appendingPathComponent("clean.md")
    try "clean on disk".write(to: cleanURL, atomically: true, encoding: .utf8)
    let cleanState = AppState()
    let cleanStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore())
    let cleanController = AppController(
      appState: cleanState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: cleanStore,
      documentWindowRegistry: registry
    )
    cleanStore.load(ref: DocumentRef(id: cleanURL.standardizedFileURL), into: cleanState)
    let cleanIdentity = try XCTUnwrap(cleanState.windowModel.documentIdentity)

    let cancelState = AppState()
    let cancelController = AppController(
      appState: cancelState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(dirtySessionPrompt: { _ in .cancel }),
      documentWindowRegistry: registry
    )
    XCTAssertTrue(cancelController.createUntitledDocument())
    cancelState.activeDocumentText = "unsaved"
    cancelState.activeDocumentDirty = true
    let cancelIdentity = try XCTUnwrap(cancelState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        cleanWindow, identity: cleanIdentity, documentID: cleanURL,
        title: "clean.md", isDirty: false, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cancelWindow, identity: cancelIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(cleanController, for: cleanWindow)
    registry.registerController(cancelController, for: cancelWindow)

    cleanController.clearOpenFiles()

    XCTAssertTrue(closedWindows.isEmpty, "a cancelled pass must close NOTHING")
    XCTAssertEqual(
      cleanState.windowModel.documentIdentity, cleanIdentity,
      "the clean window must still own its document")
    XCTAssertTrue(
      cleanState.documentSession.hasEditableBuffer,
      "the clean window's session must not be cleared")
  }

  /// Case 3 — a force-saved earlier window keeps its bytes and its session when
  /// a later window Cancels. The Save is the one content decision NOT rolled
  /// back (the bytes are already on disk), but the window is not torn down.
  @MainActor
  func testClearOpenFilesSaveThenCancelKeepsBytesAndSession() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearSaveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let saveWindow = Self.makeControllerlessWindow()
    let cancelWindow = Self.makeControllerlessWindow()
    defer {
      saveWindow.close()
      cancelWindow.close()
    }

    let fileURL = folder.appendingPathComponent("saved.md")
    try "on disk".write(to: fileURL, atomically: true, encoding: .utf8)
    let saveState = AppState()
    let saveStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore())
    let saveController = AppController(
      appState: saveState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: saveStore,
      documentWindowRegistry: registry
    )
    saveStore.load(ref: DocumentRef(id: fileURL.standardizedFileURL), into: saveState)
    saveState.activeDocumentText = "edited in memory"
    saveState.activeDocumentDirty = true
    let saveIdentity = try XCTUnwrap(saveState.windowModel.documentIdentity)

    let cancelState = AppState()
    let cancelController = AppController(
      appState: cancelState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(dirtySessionPrompt: { _ in .cancel }),
      documentWindowRegistry: registry
    )
    XCTAssertTrue(cancelController.createUntitledDocument())
    cancelState.activeDocumentText = "unsaved"
    cancelState.activeDocumentDirty = true
    let cancelIdentity = try XCTUnwrap(cancelState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        saveWindow, identity: saveIdentity, documentID: fileURL,
        title: "saved.md", isDirty: true, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cancelWindow, identity: cancelIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(saveController, for: saveWindow)
    registry.registerController(cancelController, for: cancelWindow)

    saveController.clearOpenFiles()

    XCTAssertTrue(closedWindows.isEmpty, "a cancelled pass must close NOTHING")
    XCTAssertEqual(
      try String(contentsOf: fileURL, encoding: .utf8), "edited in memory",
      "the force-saved bytes are on disk and NOT rolled back")
    XCTAssertFalse(saveState.activeDocumentDirty, "the force-saved window is clean")
    XCTAssertEqual(
      saveState.windowModel.documentIdentity, saveIdentity,
      "the force-saved window must still own its document")
    XCTAssertTrue(
      saveState.documentSession.hasEditableBuffer,
      "the force-saved window's session must not be cleared")
  }

  /// Case 4 — the happy path. Every window resolves without a Cancel, so the
  /// deferred Discard IS applied (draft dropped, buffer clean) and every window
  /// is torn down. Guards phase 2 against forgetting to apply what phase 1 only
  /// recorded.
  @MainActor
  func testClearOpenFilesFullSuccessAppliesDeferredDiscardAndClosesAll() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearSuccessTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let discardWindow = Self.makeControllerlessWindow()
    let cleanWindow = Self.makeControllerlessWindow()
    defer {
      discardWindow.close()
      cleanWindow.close()
    }

    // Window A: untitled, dirty, with a recovery draft; guard chooses Discard.
    let discardRecovery = RecoveryStore(
      directoryURL: folder.appendingPathComponent("RecoveryA", isDirectory: true))
    let discardState = AppState()
    let discardStore = makeTestDocumentStore(
      recoveryStore: discardRecovery,
      dirtySessionPrompt: { _ in .discard })
    let discardController = AppController(
      appState: discardState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: discardStore,
      documentWindowRegistry: registry
    )
    XCTAssertTrue(discardController.createUntitledDocument())
    discardState.activeDocumentText = "unsaved untitled work"
    discardState.activeDocumentDirty = true
    XCTAssertTrue(discardStore.savePendingChangesOnClose(appState: discardState))
    XCTAssertFalse(discardRecovery.loadDrafts().isEmpty, "fixture must seed a recovery draft")
    let discardIdentity = try XCTUnwrap(discardState.windowModel.documentIdentity)

    // Window B: a clean file — resolves with no prompt, so the pass succeeds.
    let cleanURL = folder.appendingPathComponent("clean.md")
    try "clean on disk".write(to: cleanURL, atomically: true, encoding: .utf8)
    let cleanState = AppState()
    let cleanStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore())
    let cleanController = AppController(
      appState: cleanState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: cleanStore,
      documentWindowRegistry: registry
    )
    cleanStore.load(ref: DocumentRef(id: cleanURL.standardizedFileURL), into: cleanState)
    let cleanIdentity = try XCTUnwrap(cleanState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        discardWindow, identity: discardIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cleanWindow, identity: cleanIdentity, documentID: cleanURL,
        title: "clean.md", isDirty: false, hasEditableBuffer: true))
    registry.registerController(discardController, for: discardWindow)
    registry.registerController(cleanController, for: cleanWindow)

    discardController.clearOpenFiles()

    XCTAssertEqual(
      Set(closedWindows.map(ObjectIdentifier.init)),
      Set([discardWindow, cleanWindow].map(ObjectIdentifier.init)),
      "a fully resolved pass closes every window")
    XCTAssertFalse(
      discardState.activeDocumentDirty,
      "the deferred Discard must be applied on a successful pass")
    XCTAssertTrue(
      discardRecovery.loadDrafts().isEmpty,
      "the deferred Discard must drop the recovery draft on a successful pass")
  }

  /// Case 5 — the test the "keep Save in phase 1" decision rests on. A Discard
  /// window is confirmed FIRST (its Discard deferred), then a pathed window's
  /// force-save FAILS with an I/O error. That failure is the only thing left
  /// that can abort the pass — and it must, WITHOUT the earlier deferred Discard
  /// leaking to execution. If the abort path (decide's
  /// `guard !isDirty else { return nil }`) did not fire, phase 2 would run and
  /// the Discard window's draft would be dropped; asserting the draft survives
  /// proves the save genuinely failed and aborted rather than silently
  /// succeeding.
  @MainActor
  func testClearOpenFilesSaveIOFailureAbortsPassAndSparesDeferredDiscard() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearSaveFailTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let discardWindow = Self.makeControllerlessWindow()
    let failWindow = Self.makeControllerlessWindow()
    defer {
      discardWindow.close()
      failWindow.close()
    }

    // Window B: untitled, dirty, with a seeded recovery draft; guard Discards.
    // Attached FIRST so phase 1 records its deferred Discard BEFORE the failure.
    let discardRecovery = RecoveryStore(
      directoryURL: folder.appendingPathComponent("RecoveryB", isDirectory: true))
    let discardState = AppState()
    let discardStore = makeTestDocumentStore(
      recoveryStore: discardRecovery,
      dirtySessionPrompt: { _ in .discard })
    let discardController = AppController(
      appState: discardState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: discardStore,
      documentWindowRegistry: registry
    )
    XCTAssertTrue(discardController.createUntitledDocument())
    discardState.activeDocumentText = "unsaved untitled work"
    discardState.activeDocumentDirty = true
    XCTAssertTrue(discardStore.savePendingChangesOnClose(appState: discardState))
    XCTAssertFalse(discardRecovery.loadDrafts().isEmpty, "fixture must seed a recovery draft")
    let discardIdentity = try XCTUnwrap(discardState.windowModel.documentIdentity)

    // Window A: a pathed doc, dirtied, whose write throws. saveExisting catches
    // the throw and returns false, leaving the session dirty — the decide guard
    // then returns nil (abort). Attached SECOND so the failure trips after B.
    let fileURL = folder.appendingPathComponent("cannot-write.md")
    try "on disk".write(to: fileURL, atomically: true, encoding: .utf8)
    let failState = AppState()
    let failStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      writeDocument: { _, _ in throw NSError(domain: "PensieveTestWriteFailure", code: 1) })
    let failController = AppController(
      appState: failState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: failStore,
      documentWindowRegistry: registry
    )
    failStore.load(ref: DocumentRef(id: fileURL.standardizedFileURL), into: failState)
    failState.activeDocumentText = "edited but the write will fail"
    failState.activeDocumentDirty = true
    let failIdentity = try XCTUnwrap(failState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        discardWindow, identity: discardIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        failWindow, identity: failIdentity, documentID: fileURL,
        title: "cannot-write.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(discardController, for: discardWindow)
    registry.registerController(failController, for: failWindow)

    discardController.clearOpenFiles()

    XCTAssertTrue(closedWindows.isEmpty, "an I/O-aborted pass must close NOTHING")
    // The failed save is what aborted the pass — prove it propagated, not swallowed.
    XCTAssertTrue(failState.activeDocumentDirty, "the failed-write window stays dirty")
    XCTAssertEqual(
      try String(contentsOf: fileURL, encoding: .utf8), "on disk",
      "no new bytes reached disk when the write threw")
    XCTAssertEqual(
      failState.activeDocumentText, "edited but the write will fail",
      "the failed-write window keeps its buffer")
    XCTAssertEqual(
      failState.windowModel.documentIdentity, failIdentity,
      "the failed-write window still owns its document")
    // The core: the earlier-recorded Discard must NOT have leaked to execution.
    XCTAssertTrue(
      discardState.activeDocumentDirty,
      "the deferred Discard must stay unapplied when a later save aborts the pass")
    XCTAssertEqual(
      discardState.windowModel.documentIdentity, discardIdentity,
      "the Discard window still owns its document")
    XCTAssertFalse(
      discardRecovery.loadDrafts().isEmpty,
      "the recovery draft must survive — a deferred Discard can't leak past an I/O abort")
  }

  /// THE PIN. "Clear Open Files" snapshots identities BEFORE phase 1 — but
  /// phase 1 can change one. Saving a dirty untitled draft runs `saveAs`, which
  /// appends a NEW `.file` ref to `openFiles` and persists a bookmark for it,
  /// while the snapshot still holds that window's old `.untitled(UUID)`. The
  /// retire sweep guards on `case .file`, skipped the untitled entry, and the
  /// file the user had just created survived both the Open Files list and the
  /// `fileBookmarks` default — so the affordance that promises to empty the list
  /// left an entry in it, and the next launch reopened the file.
  @MainActor
  func testClearOpenFilesRetiresAFileSavedDuringThePassItself() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearSavedInPass-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let window = Self.makeControllerlessWindow()
    defer { window.close() }

    let savedURL = folder.appendingPathComponent("rescued.md").standardizedFileURL
    let bookmarkDefaults = makeEphemeralDefaults(prefix: "PensieveClearSavedInPass")
    let bookmarkStore = BookmarkStore(defaults: bookmarkDefaults)
    let appState = AppState()
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: bookmarkStore,
      dirtySessionPrompt: { _ in .save },
      savePanelURLProvider: { _ in savedURL })
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: store,
      documentWindowRegistry: registry
    )

    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "work with no name yet"
    appState.activeDocumentDirty = true
    let untitledIdentity = try XCTUnwrap(appState.windowModel.documentIdentity)
    XCTAssertTrue(
      registry.attach(
        window, identity: untitledIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(controller, for: window)

    controller.clearOpenFiles()

    // The Save happened, so the premise holds: there IS a new file to retire.
    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL, savedURL,
      "the fixture never took the Save branch, so this pin proves nothing")
    XCTAssertFalse(closedWindows.isEmpty, "an uncancelled pass must close the window")

    XCTAssertTrue(
      appState.openFiles.isEmpty,
      "the file saved DURING the pass stayed in Open Files — retiring by the pre-prompt"
        + " snapshot cannot see an identity the prompt itself created")
    let reopened = BookmarkStore(defaults: bookmarkDefaults).restoreWorkspace(into: AppState())
    XCTAssertTrue(
      reopened.fileURLs.isEmpty,
      "the bookmark persisted by the in-pass Save survived, so the next launch reopens a file"
        + " the user just cleared")
  }

  /// CONTROL LEG. Retiring by the owner's CURRENT identity must stay inside the
  /// same transaction: when a LATER window cancels, the pass applies nothing and
  /// forgets nothing — including the file an earlier window saved. Its bytes are
  /// the documented non-rollback, but the working set is not touched.
  @MainActor
  func testAFileSavedDuringACancelledPassIsNotRetired() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearSavedCancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let saveWindow = Self.makeControllerlessWindow()
    let cancelWindow = Self.makeControllerlessWindow()
    defer {
      saveWindow.close()
      cancelWindow.close()
    }

    let savedURL = folder.appendingPathComponent("rescued.md").standardizedFileURL
    let bookmarkDefaults = makeEphemeralDefaults(prefix: "PensieveClearSavedCancel")
    let bookmarkStore = BookmarkStore(defaults: bookmarkDefaults)
    let saveState = AppState()
    let saveStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: bookmarkStore,
      dirtySessionPrompt: { _ in .save },
      savePanelURLProvider: { _ in savedURL })
    let saveController = AppController(
      appState: saveState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: saveStore,
      documentWindowRegistry: registry
    )
    XCTAssertTrue(saveController.createUntitledDocument())
    saveState.activeDocumentText = "work with no name yet"
    saveState.activeDocumentDirty = true
    let saveIdentity = try XCTUnwrap(saveState.windowModel.documentIdentity)

    let cancelState = AppState()
    let cancelController = AppController(
      appState: cancelState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(dirtySessionPrompt: { _ in .cancel }),
      documentWindowRegistry: registry
    )
    XCTAssertTrue(cancelController.createUntitledDocument())
    cancelState.activeDocumentText = "unsaved"
    cancelState.activeDocumentDirty = true
    let cancelIdentity = try XCTUnwrap(cancelState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        saveWindow, identity: saveIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cancelWindow, identity: cancelIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(saveController, for: saveWindow)
    registry.registerController(cancelController, for: cancelWindow)

    saveController.clearOpenFiles()

    XCTAssertTrue(closedWindows.isEmpty, "a cancelled pass must close NOTHING")
    XCTAssertTrue(
      saveState.openFiles.contains { $0.url.standardizedFileURL == savedURL },
      "a cancelled pass must forget nothing — the in-pass Save's file stays in the working set")
    let reopened = BookmarkStore(defaults: bookmarkDefaults).restoreWorkspace(into: AppState())
    XCTAssertEqual(
      reopened.fileURLs.map(\.standardizedFileURL), [savedURL],
      "a cancelled pass must leave the persisted bookmark intact")
  }

  /// Case 6 — the SECOND kind of Discard, introduced with the auto-save setting.
  /// A file-backed document with auto-save OFF answers "Don't Save"; a later
  /// window Cancels. Dropping that edit is just as irreversible as dropping an
  /// untitled draft — the buffer is the only copy, since the whole point of
  /// auto-save-off is that nothing reached disk — so it must be deferred too.
  /// The file itself is never written by this path in either direction.
  @MainActor
  func testClearOpenFilesPathedDontSaveThenCancelKeepsTheEdit() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearPathedTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let discardWindow = Self.makeControllerlessWindow()
    let cancelWindow = Self.makeControllerlessWindow()
    defer {
      discardWindow.close()
      cancelWindow.close()
    }

    // Window A: a pathed doc with auto-save OFF, edited in memory only. Its
    // guard answers Don't Save — recorded, not executed. Attached FIRST.
    let fileURL = folder.appendingPathComponent("pathed.md")
    try "on disk".write(to: fileURL, atomically: true, encoding: .utf8)
    var promptedForPathedDocument = false
    let discardState = AppState()
    let discardStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      savingSettings: makeAutoSaveSettings(enabled: false),
      dirtySessionPrompt: { session in
        promptedForPathedDocument = !session.isUntitled
        return .discard
      })
    let discardController = AppController(
      appState: discardState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: discardStore,
      documentWindowRegistry: registry
    )
    discardStore.load(ref: DocumentRef(id: fileURL.standardizedFileURL), into: discardState)
    discardState.activeDocumentText = "edited, never written"
    discardState.activeDocumentDirty = true
    let discardIdentity = try XCTUnwrap(discardState.windowModel.documentIdentity)

    // Window B: untitled, dirty; its guard Cancels. Attached SECOND.
    let cancelState = AppState()
    let cancelController = AppController(
      appState: cancelState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(dirtySessionPrompt: { _ in .cancel }),
      documentWindowRegistry: registry
    )
    XCTAssertTrue(cancelController.createUntitledDocument())
    cancelState.activeDocumentText = "unsaved"
    cancelState.activeDocumentDirty = true
    let cancelIdentity = try XCTUnwrap(cancelState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        discardWindow, identity: discardIdentity, documentID: fileURL,
        title: "pathed.md", isDirty: true, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cancelWindow, identity: cancelIdentity, documentID: nil,
        title: "Untitled.md", isDirty: true, hasEditableBuffer: true))
    registry.registerController(discardController, for: discardWindow)
    registry.registerController(cancelController, for: cancelWindow)

    discardController.clearOpenFiles()

    XCTAssertTrue(
      promptedForPathedDocument,
      "auto-save off must ask before a pathed document is settled")
    XCTAssertTrue(closedWindows.isEmpty, "a cancelled pass must close NOTHING")
    XCTAssertTrue(
      discardState.activeDocumentDirty,
      "a cancelled pass must leave the pathed edit dirty — Don't Save was only recorded")
    XCTAssertEqual(
      discardState.activeDocumentText, "edited, never written",
      "the in-memory edit is the only copy and must survive the aborted pass")
    XCTAssertEqual(
      discardState.windowModel.documentIdentity, discardIdentity,
      "the pathed window must still own its document")
    XCTAssertEqual(
      try String(contentsOf: fileURL, encoding: .utf8), "on disk",
      "auto-save off means the pass writes nothing to the file, aborted or not")
  }

  /// Case 7 — the same pathed Don't Save, but nothing cancels: the recorded
  /// discard IS applied, the windows close, and the file on disk still keeps the
  /// bytes it had. Guards phase 2 against forgetting the new case, the way case 4
  /// does for `.discardUntitled`.
  @MainActor
  func testClearOpenFilesPathedDontSaveWithoutCancelDropsTheEdit() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveClearPathedOKTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    var closedWindows: [NSWindow] = []
    let registry = Self.makeCrossWindowRegistry { closedWindows.append($0) }
    let discardWindow = Self.makeControllerlessWindow()
    let cleanWindow = Self.makeControllerlessWindow()
    defer {
      discardWindow.close()
      cleanWindow.close()
    }

    let fileURL = folder.appendingPathComponent("pathed.md")
    try "on disk".write(to: fileURL, atomically: true, encoding: .utf8)
    let discardState = AppState()
    let discardStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      savingSettings: makeAutoSaveSettings(enabled: false),
      dirtySessionPrompt: { _ in .discard })
    let discardController = AppController(
      appState: discardState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: discardStore,
      documentWindowRegistry: registry
    )
    discardStore.load(ref: DocumentRef(id: fileURL.standardizedFileURL), into: discardState)
    discardState.activeDocumentText = "edited, never written"
    discardState.activeDocumentDirty = true
    let discardIdentity = try XCTUnwrap(discardState.windowModel.documentIdentity)

    // Window B: a clean file — resolves with no prompt, so the pass succeeds.
    let cleanURL = folder.appendingPathComponent("clean.md")
    try "clean on disk".write(to: cleanURL, atomically: true, encoding: .utf8)
    let cleanState = AppState()
    let cleanStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore(),
      savingSettings: makeAutoSaveSettings(enabled: false))
    let cleanController = AppController(
      appState: cleanState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: cleanStore,
      documentWindowRegistry: registry
    )
    cleanStore.load(ref: DocumentRef(id: cleanURL.standardizedFileURL), into: cleanState)
    let cleanIdentity = try XCTUnwrap(cleanState.windowModel.documentIdentity)

    XCTAssertTrue(
      registry.attach(
        discardWindow, identity: discardIdentity, documentID: fileURL,
        title: "pathed.md", isDirty: true, hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        cleanWindow, identity: cleanIdentity, documentID: cleanURL,
        title: "clean.md", isDirty: false, hasEditableBuffer: true))
    registry.registerController(discardController, for: discardWindow)
    registry.registerController(cleanController, for: cleanWindow)

    discardController.clearOpenFiles()

    XCTAssertEqual(
      Set(closedWindows.map(ObjectIdentifier.init)),
      Set([discardWindow, cleanWindow].map(ObjectIdentifier.init)),
      "a fully resolved pass closes every window")
    XCTAssertFalse(
      discardState.activeDocumentDirty,
      "the recorded pathed discard must be applied on a successful pass")
    XCTAssertEqual(
      try String(contentsOf: fileURL, encoding: .utf8), "on disk",
      "Don't Save drops the edit — it must never write it out on the way past")
  }

  @MainActor
  private static func makeCrossWindowRegistry(
    closeWindow: @escaping @MainActor (NSWindow) -> Void
  ) -> DocumentWindowRegistry {
    DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      closeWindow: closeWindow)
  }

  @MainActor
  private static func makeControllerlessWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    return window
  }

  @MainActor
  func testSaveAsRegularDocumentCreatesCopyAndSwitchesSession() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRegularSaveAsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let originalURL = folder.appendingPathComponent("original.md")
    let copyURL = folder.appendingPathComponent("copy.md")
    try "original body".write(to: originalURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore()
    )
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: documentStore
    )
    documentStore.load(ref: DocumentRef(id: originalURL.standardizedFileURL), into: appState)
    appState.activeDocumentText = "copy body"
    appState.activeDocumentDirty = true

    XCTAssertTrue(controller.saveActiveDocument(as: copyURL))

    XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "original body")
    XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "copy body")
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, copyURL.standardizedFileURL)
    XCTAssertFalse(appState.activeDocumentDirty)
    XCTAssertTrue(
      appState.openFiles.contains { $0.url.standardizedFileURL == copyURL.standardizedFileURL })
  }

  @MainActor
  func testPlainTextDocumentRoundTripsThroughOpenEditAndSave() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensievePlainTextRoundTripTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let textURL = folder.appendingPathComponent("plain-note.txt")
    try "plain-token original".write(to: textURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)

    XCTAssertTrue(
      appState.documents.contains { $0.url.standardizedFileURL == textURL.standardizedFileURL })
    selectDocument(at: textURL, in: appState)

    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, textURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "plain-token original")

    appState.activeDocumentText = "plain-token edited"
    appState.activeDocumentDirty = true
    controller.saveActiveDocument()

    XCTAssertEqual(try String(contentsOf: textURL, encoding: .utf8), "plain-token edited")
    XCTAssertEqual(textURL.pathExtension, "txt")
    XCTAssertFalse(appState.activeDocumentDirty)

    let copyURL = folder.appendingPathComponent("plain-copy.txt")
    XCTAssertTrue(controller.saveActiveDocument(as: copyURL))
    XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "plain-token edited")
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, copyURL.standardizedFileURL)
    XCTAssertEqual(copyURL.pathExtension, "txt")
  }

  @MainActor
  func testControllerCreateMarkdownFileRefusesToOverwriteExistingFile() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCreateExistingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let existingURL = folder.appendingPathComponent("existing.md")
    try "keep me".write(to: existingURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)

    XCTAssertFalse(controller.createMarkdownFile(url: existingURL))
    XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "keep me")
    XCTAssertTrue(appState.lastError?.contains("already exists") == true)
  }

  @MainActor
  func testWorkspaceSearchIndexesBodyTextAndSnippet() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSearchBodyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("ordinary-title.md")
    try """
    # Ordinary Title

    The hidden phrase is crystal harmonics inside the body.
    """.write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let ref = DocumentRef(
      id: noteURL.standardizedFileURL, rootURL: folder.standardizedFileURL,
      relativePath: "ordinary-title.md")
    indexDatabase.reindex(documents: [ref], appState: appState)

    let results = indexDatabase.search(
      query: "crystal harmonics", documents: [ref], appState: appState)

    XCTAssertEqual(results.map(\.document.id), [noteURL.standardizedFileURL])
    XCTAssertEqual(results.first?.matchKind, .body)
    XCTAssertTrue(results.first?.snippet?.contains("crystal harmonics") == true)
  }

  @MainActor
  func testWorkspaceSearchDropsExcludedPathsAfterReindex() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveSearchExclusionTests-\(UUID().uuidString)", isDirectory: true)
    let drafts = folder.appendingPathComponent("Drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    try "public notes".write(
      to: folder.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
    let skipURL = drafts.appendingPathComponent("skip.md")
    try "private nebula keyword".write(to: skipURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase)
    let controller = AppController(
      appState: appState,
      folderManager: manager,
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    await manager.waitForPendingIndexUpdate()
    controller.updateWorkspaceSearch(query: "nebula")
    await controller.waitForPendingWorkspaceSearch()
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [skipURL.standardizedFileURL])

    controller.excludeFromWorkspace(urls: [drafts])
    // The exclusion edit refreshes the workspace, which now writes the FTS delta off-main and
    // re-runs the search projection on completion. Await that before asserting on results.
    await manager.waitForPendingForcedRefresh()
    await manager.waitForPendingIndexUpdate()
    await manager.waitForPendingWorkspaceIndexWrite()

    XCTAssertFalse(appState.documents.contains { $0.url == skipURL.standardizedFileURL })
    XCTAssertTrue(appState.workspaceSearchResults.isEmpty)
  }

  @MainActor
  func testSearchResultSelectionLoadsDocumentThroughController() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveSearchSelectionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha body".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta contains selection-token".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    controller.updateWorkspaceSearch(query: "selection-token")
    await controller.waitForPendingWorkspaceSearch()
    let result = try XCTUnwrap(appState.workspaceSearchResults.first)

    controller.selectSearchResult(result)

    XCTAssertEqual(
      appState.selectedDocumentID?.resolvingSymlinksInPath(), betaURL.resolvingSymlinksInPath())
    XCTAssertEqual(appState.activeDocumentText, "beta contains selection-token")
  }

  @MainActor
  func testWorkspaceExplorerNodeSelectionLoadsDocumentThroughController() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveExplorerSelectionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("clickable.md")
    try "click me".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    let root = try XCTUnwrap(appState.workspaceTree.first)
    let node = try XCTUnwrap(
      root.children?.first(where: { $0.documentID == noteURL.standardizedFileURL }))
    controller.selectDocument(id: nil)

    controller.selectWorkspaceNode(node)

    XCTAssertEqual(
      appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
    XCTAssertEqual(appState.activeDocumentText, "click me")
  }

  @MainActor
  func testDocumentSelectionMaintainsWorkingSetTabs() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveTabsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    controller.selectDocument(id: alphaURL.standardizedFileURL)
    controller.selectDocument(id: betaURL.standardizedFileURL)
    controller.selectDocument(id: alphaURL.standardizedFileURL)

    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "alpha")
  }

  @MainActor
  func testOpenFileReusesEmptyWindowBeforeRoutingToDocumentTab() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveOpenFileReuseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    var requestedRefs: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { requestedRefs.append($0) }

    controller.openFile(url: alphaURL)

    XCTAssertTrue(requestedRefs.isEmpty, "an empty window is reused in place")
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "alpha")

    controller.openFile(url: betaURL)

    XCTAssertEqual(
      requestedRefs.map(\.id.standardizedFileURL), [betaURL.standardizedFileURL],
      "once the window shows a document, further opens become document tabs")
    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL,
      "the originating window keeps its document while the tab materializes")
  }

  @MainActor
  func testAccessorDocumentIDDropsInitialDocumentOnceLoadResolved() {
    let initial = DocumentRef(id: URL(fileURLWithPath: "/tmp/initial.md"), isAdHoc: true)
    let selected = URL(fileURLWithPath: "/tmp/selected.md")

    XCTAssertEqual(
      DocumentWindowRootView.accessorDocumentID(
        selected: nil, initialDocument: initial, loadResolved: false),
      initial.id,
      "before the load resolves the scene's initialDocument stands in")
    XCTAssertEqual(
      DocumentWindowRootView.accessorDocumentID(
        selected: selected, initialDocument: initial, loadResolved: true),
      selected,
      "a successful load reports the real selection")
    XCTAssertNil(
      DocumentWindowRootView.accessorDocumentID(
        selected: nil, initialDocument: initial, loadResolved: true),
      "a failed load must stop advertising the document so the registry releases the mapping")
  }

  @MainActor
  func testOpenWordFileImportsUnsavedMarkdownDraftWithoutRegistryRouting() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveOpenWordImportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    let recoveryStore = RecoveryStore(directoryURL: recoveryDirectory)
    let wordURL = folder.appendingPathComponent("Board Brief.docx")
    let data = try DocumentTransfer.docxData(
      fromHTML: "<h1>Board Brief</h1><p>Prokurent approval is required.</p>",
      baseURL: nil
    )
    try data.write(to: wordURL, options: .atomic)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    // The import leaves a dirty untitled session; with the shared autosaver and
    // recovery store its debounced flush fires mid-suite and strands a "Board
    // Brief" draft in the REAL ~/Library/…/Pensieve/Recovery — which the app
    // then resurrects as "Recovered Untitled.md" on every launch.
    let autosaver = Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 100)
    addTeardownBlock { autosaver.cancel() }
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()),
      documentStore: DocumentStore(
        autosaver: autosaver,
        indexDatabase: indexDatabase,
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))),
      indexDatabase: indexDatabase
    )
    var requestedRefs: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { requestedRefs.append($0) }

    controller.openFile(url: wordURL)
    for _ in 0..<100 where appState.documentSession.displayTitle != "Board Brief.md" {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertTrue(requestedRefs.isEmpty, "imports are drafts, not source-backed document tabs")
    XCTAssertTrue(appState.documentSession.isUntitled)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertEqual(appState.documentSession.displayTitle, "Board Brief.md")
    XCTAssertTrue(appState.activeDocumentText.contains("# Board Brief"))
    XCTAssertTrue(appState.activeDocumentText.contains("Prokurent approval is required."))
    XCTAssertNil(appState.lastError)

    let expectedText = appState.activeDocumentText
    XCTAssertTrue(controller.savePendingChangesOnClose())
    let draft = try XCTUnwrap(recoveryStore.loadDrafts().first)
    XCTAssertEqual(recoveryStore.loadDrafts().count, 1)
    XCTAssertEqual(draft.text, expectedText)
    XCTAssertEqual(
      draft.url.deletingLastPathComponent().standardizedFileURL,
      recoveryDirectory.standardizedFileURL)
  }

  @MainActor
  func testRecoveryIsolationControlDetectsWrongRecoveryRoot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveRecoveryControlTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expectedRoot = root.appendingPathComponent("Expected", isDirectory: true)
    let controlRoot = root.appendingPathComponent("Control", isDirectory: true)
    let controlStore = RecoveryStore(directoryURL: controlRoot)
    let appState = AppState()
    appState.documentSession.createUntitled()
    appState.documentSession.text = "control draft"
    appState.documentSession.isDirty = true

    let store = DocumentStore(
      indexDatabase: temporaryIndexDatabase(in: root),
      recoveryStore: controlStore
    )
    XCTAssertTrue(store.savePendingChangesOnClose(appState: appState))

    let controlDraft = try XCTUnwrap(controlStore.loadDrafts().first)
    XCTAssertFalse(FileManager.default.fileExists(atPath: expectedRoot.path))
    XCTAssertFalse(
      controlDraft.url.deletingLastPathComponent().standardizedFileURL
        == expectedRoot.standardizedFileURL,
      "the isolation assertion must fail when a store is bound to the control root"
    )
  }

  @MainActor
  func testOpenFileRejectsUnsupportedTypeBeforeRoutingToRegistry() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveOpenFileUnsupportedTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let imageURL = folder.appendingPathComponent("picture.png")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try Data().write(to: imageURL)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    var requestedRefs: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { requestedRefs.append($0) }

    controller.openFile(url: alphaURL)
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL)

    controller.openFile(url: imageURL)

    XCTAssertTrue(
      requestedRefs.isEmpty,
      "an unsupported file must be rejected before it routes to a new window/tab")
    XCTAssertEqual(appState.lastError, WorkspaceScanner.unsupportedOpenMessage)
  }

  @MainActor
  func testOpenFileRoutesDirectoryToWorkspaceOpen() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveOpenFileDirectoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("alpha.md")
    try "alpha".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    var requestedRefs: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { requestedRefs.append($0) }

    controller.openFile(url: folder)

    XCTAssertTrue(
      requestedRefs.isEmpty,
      "a directory must open as a workspace, never route to a document window/tab")
    XCTAssertEqual(
      appState.workspaceRoots.map { $0.url.resolvingSymlinksInPath() },
      [folder.resolvingSymlinksInPath()],
      "a directory handed to the file-open funnel must become a workspace root")
    XCTAssertEqual(
      appState.documents.map { $0.url.resolvingSymlinksInPath() },
      [noteURL.resolvingSymlinksInPath()]
    )
    XCTAssertNil(
      appState.lastError,
      "a directory open must not surface the unsupported-file error")
  }

  @MainActor
  func testLaunchFolderIntentOpensWorkspaceInsteadOfRejectingIt() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveLaunchFolderIntentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let noteURL = folder.appendingPathComponent("alpha.md")
    try "alpha".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)

    coordinator.handle(urls: [folder])
    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(
      appState.workspaceRoots.map { $0.url.resolvingSymlinksInPath() },
      [folder.resolvingSymlinksInPath()],
      "launching with a folder URL must open it as a workspace")
    XCTAssertNil(appState.lastError)
  }

  @MainActor
  func testOpenFileFallsBackToInWindowLoadWithoutRouting() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveOpenFileFallbackTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFile(url: alphaURL)
    controller.openFile(url: betaURL)

    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, betaURL.standardizedFileURL,
      "headless/no-routing opens load into the current window")
    XCTAssertEqual(appState.activeDocumentText, "beta")
  }

  @MainActor
  func testExplicitInWindowOpenDoesNotRouteThroughNewDocumentScene() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveExplicitInWindowOpenTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let bookURL = folder.appendingPathComponent("book.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "the book".write(to: bookURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore()),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    var requestedRefs: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { requestedRefs.append($0) }

    controller.openFile(url: alphaURL)
    controller.openFileInCurrentWindow(url: bookURL)

    XCTAssertTrue(requestedRefs.isEmpty, "explicit in-window open must not spawn a new scene")
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, bookURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "the book")
  }

  @MainActor
  func testDefaultClickSelectsInPlaceAndExplicitGestureRoutesToRegistry() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveSidebarOpenReuseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    var requestedRefs: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { requestedRefs.append($0) }

    controller.openFolder(url: folder)
    controller.openDocumentWindow(id: alphaURL.standardizedFileURL)

    XCTAssertTrue(requestedRefs.isEmpty, "a default click never spawns a window")
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "alpha")

    // VS Code / Zed model: a default click on another document loads it in place,
    // reusing the current window — it does NOT route to the registry.
    controller.openDocumentWindow(id: betaURL.standardizedFileURL)

    XCTAssertTrue(
      requestedRefs.isEmpty,
      "a default click on another document loads in place, never routing to the registry")
    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, betaURL.standardizedFileURL,
      "the current window swaps to the clicked document")
    XCTAssertEqual(appState.activeDocumentText, "beta")

    controller.openDocumentWindow(id: betaURL.standardizedFileURL)

    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, betaURL.standardizedFileURL,
      "clicking the currently displayed document is a no-op")

    // Only the explicit "Open in New Window" gesture routes to the registry, and
    // only for a document the window is not already showing.
    controller.openDocumentInNewWindow(id: alphaURL.standardizedFileURL)

    XCTAssertEqual(
      requestedRefs.map(\.id.standardizedFileURL), [alphaURL.standardizedFileURL],
      "the explicit gesture opens the document in a new window/tab")
    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, betaURL.standardizedFileURL,
      "the originating window keeps its document while the new window materializes")

    controller.openDocumentInNewWindow(id: betaURL.standardizedFileURL)

    XCTAssertEqual(
      requestedRefs.map(\.id.standardizedFileURL), [alphaURL.standardizedFileURL],
      "the explicit gesture on the currently displayed document is a no-op")
  }

  @MainActor
  func testOpenDocumentWindowFallsBackToInWindowSelectWithoutRouting() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveSidebarOpenFallbackTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    controller.openDocumentWindow(id: alphaURL.standardizedFileURL)
    controller.openDocumentWindow(id: betaURL.standardizedFileURL)

    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, betaURL.standardizedFileURL,
      "headless/no-routing clicks select in the current window")
    XCTAssertEqual(appState.activeDocumentText, "beta")
  }

  @MainActor
  func testDocumentWindowOpenDefersWindowCreationDuringModalRunLoop() throws {
    var canMutateWindowTabs = false
    var scheduledWork: [@MainActor () -> Void] = []
    var factoryRefs: [DocumentRef?] = []
    let documentWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    documentWindow.isReleasedWhenClosed = false
    defer {
      documentWindow.close()
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { canMutateWindowTabs },
      scheduleDeferredMainWork: { scheduledWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      makeDocumentWindow: { ref, _ in
        factoryRefs.append(ref)
        return documentWindow
      }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-modal-open-safe.md").standardizedFileURL
    let ref = DocumentRef(id: documentID)

    registry.open(ref)

    XCTAssertEqual(scheduledWork.count, 1)
    XCTAssertTrue(factoryRefs.isEmpty)

    registry.open(ref)

    XCTAssertEqual(scheduledWork.count, 1, "modal-time open retries coalesce per document")
    XCTAssertTrue(factoryRefs.isEmpty)

    canMutateWindowTabs = true
    let deferredOpen = try XCTUnwrap(scheduledWork.popLast())
    deferredOpen()

    XCTAssertEqual(scheduledWork.count, 0)
    XCTAssertEqual(factoryRefs.compactMap { $0?.id }, [documentID])
  }

  @MainActor
  func testDocumentWindowAttachDefersNativeTabMutationDuringModalRunLoop() throws {
    var canMutateWindowTabs = false
    var scheduledWork: [@MainActor () -> Void] = []
    var mergeCount = 0
    var orderCount = 0

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { canMutateWindowTabs },
      scheduleDeferredMainWork: { scheduledWork.append($0) },
      mergeWindowIntoTabs: { _, _ in mergeCount += 1 },
      orderAndActivateWindow: { _ in orderCount += 1 }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-modal-safe.md").standardizedFileURL
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    // A window from this initializer defaults to `isReleasedWhenClosed = true`: `close()` would then
    // release it, and ARC releases the local reference again at scope exit → double free (objc_release
    // EXC_BAD_ACCESS, SIGSEGV). Let ARC own the single reference so teardown is balanced.
    window.isReleasedWhenClosed = false
    defer {
      window.close()
    }

    registry.attach(window, documentID: documentID)

    XCTAssertEqual(scheduledWork.count, 1)
    XCTAssertEqual(mergeCount, 0)
    XCTAssertEqual(orderCount, 0)

    registry.attach(window, documentID: documentID)

    XCTAssertEqual(scheduledWork.count, 1, "repeated SwiftUI window accessors coalesce retries")
    XCTAssertEqual(mergeCount, 0)
    XCTAssertEqual(orderCount, 0)

    canMutateWindowTabs = true
    let deferredAttach = try XCTUnwrap(scheduledWork.popLast())
    deferredAttach()

    XCTAssertEqual(scheduledWork.count, 0)
    XCTAssertEqual(mergeCount, 0)
    XCTAssertEqual(orderCount, 1)

    registry.attach(window, documentID: documentID)

    XCTAssertEqual(orderCount, 1, "same window/document attach stays idempotent after completion")
  }

  @MainActor
  func testDocumentWindowAttachSharesMergeableTabbingIdentifierForStandaloneDocument() throws {
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer outside modal UI") },
      mergeWindowIntoTabs: { _, _ in XCTFail("standalone document should not merge") },
      orderAndActivateWindow: { _ in }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-standalone-tab.md").standardizedFileURL
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer {
      window.close()
    }

    registry.attach(window, documentID: documentID)

    XCTAssertEqual(window.tabbingMode, .automatic)
    XCTAssertEqual(
      window.tabbingIdentifier, "Pensieve.DocumentWindow",
      "non-factory document windows must share the document tabbing identifier so "
        + "Window > Merge All Windows stays enabled (it greys out without a shared id)")
  }

  @MainActor
  func testClosedDocumentWindowIsUnregisteredAndReopensFresh() throws {
    var createdWindows: [NSWindow] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      makeDocumentWindow: { _, _ in
        let window = DocumentWindow(
          contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
          styleMask: [.titled, .closable],
          backing: .buffered,
          defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: .zero)
        createdWindows.append(window)
        return window
      }
    )
    // Wire the close handler to THIS registry (production wires it to .shared).
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-close-reopen.md").standardizedFileURL

    registry.open(DocumentRef(id: documentID))
    XCTAssertEqual(createdWindows.count, 1)
    let firstWindow = try XCTUnwrap(createdWindows.first as? DocumentWindow)
    firstWindow.onClose = { registry.handleDocumentWindowClosed($0) }

    firstWindow.close()
    // The hosting-view teardown is deferred one runloop turn so AppKit can
    // finish its tab-group reshuffle first.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    XCTAssertNil(
      firstWindow.contentView,
      "close() must dismantle the hosting view to break the SwiftUI retain cycle")

    registry.open(DocumentRef(id: documentID))

    XCTAssertEqual(
      createdWindows.count, 2,
      "a closed document must re-open in a fresh window, never resurrect the closed one")
  }

  @MainActor
  func testLateAccessorAttachOnClosedWindowIsRejected() throws {
    var createdWindows: [NSWindow] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      makeDocumentWindow: { _, _ in
        let window = DocumentWindow(
          contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
          styleMask: [.titled, .closable],
          backing: .buffered,
          defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: .zero)
        createdWindows.append(window)
        return window
      }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-late-attach.md").standardizedFileURL

    registry.open(DocumentRef(id: documentID))
    let window = try XCTUnwrap(createdWindows.first as? DocumentWindow)
    window.onClose = { registry.handleDocumentWindowClosed($0) }
    window.close()

    // Simulates the closed window's SwiftUI accessor firing one last
    // main-queue pass after the close.
    registry.attach(window, documentID: documentID)
    registry.open(DocumentRef(id: documentID))

    XCTAssertEqual(
      createdWindows.count, 2,
      "a late accessor pass must not re-register the closed window; the document re-opens fresh")
  }

  @MainActor
  func testDeadMappingWithoutCloseHandlerStillReopensFresh() throws {
    // Defense-in-depth: even if a mapping survives (close handler bypassed),
    // a window whose content was torn down must not be activated.
    var createdCount = 0
    let zombie = DocumentWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    zombie.isReleasedWhenClosed = false
    zombie.contentView = NSView(frame: .zero)

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { window in
        XCTAssertFalse(window.contentView == nil, "a torn-down window must never be activated")
      },
      currentMergeTarget: { nil },
      makeDocumentWindow: { _, _ in
        createdCount += 1
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
          styleMask: [.titled],
          backing: .buffered,
          defer: false)
        window.isReleasedWhenClosed = false
        return window
      }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-zombie-guard.md").standardizedFileURL

    registry.attach(zombie, documentID: documentID)
    zombie.close()  // no onClose handler wired -> mapping survives, content torn down
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    registry.open(DocumentRef(id: documentID))

    XCTAssertEqual(createdCount, 1, "the dead mapping must be dropped and a fresh window created")
  }

  @MainActor
  func testOpenMergesFactoryWindowIntoTabsBeforeOrderingOnScreen() throws {
    var events: [String] = []
    var factoryRefs: [DocumentRef?] = []
    let targetWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let documentWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    for window in [targetWindow, documentWindow] {
      window.isReleasedWhenClosed = false
    }
    defer {
      targetWindow.close()
      documentWindow.close()
    }

    var mergeTarget: NSWindow? = targetWindow
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("open should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { target, window in
        events.append("merge")
        XCTAssertTrue(target === targetWindow)
        XCTAssertTrue(window === documentWindow)
      },
      orderAndActivateWindow: { window in
        events.append("activate")
        XCTAssertTrue(window === documentWindow)
      },
      currentMergeTarget: { mergeTarget },
      makeDocumentWindow: { ref, _ in
        events.append("create")
        factoryRefs.append(ref)
        return documentWindow
      }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-merge-before-show.md")
      .standardizedFileURL

    registry.open(DocumentRef(id: documentID))

    XCTAssertEqual(
      events, ["create", "merge", "activate"],
      "the window must join the tab group BEFORE it is ever ordered on screen")
    XCTAssertEqual(factoryRefs.compactMap { $0?.id }, [documentID])

    // The window registered synchronously: a second open for the same document
    // activates it instead of creating another window. By then the document
    // window is the key window itself.
    events.removeAll()
    mergeTarget = documentWindow
    registry.open(DocumentRef(id: documentID))

    XCTAssertEqual(
      events, ["activate"],
      "an already-open document activates its window, never re-creates it")
    XCTAssertEqual(factoryRefs.count, 1)
  }

  @MainActor
  func testOpenRegistersWindowSynchronouslySoDoubleClickCreatesOneWindow() throws {
    var createCount = 0
    var activations: [NSWindow] = []
    let documentWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    documentWindow.isReleasedWhenClosed = false
    defer {
      documentWindow.close()
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("open should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { activations.append($0) },
      currentMergeTarget: { nil },
      makeDocumentWindow: { _, _ in
        createCount += 1
        return documentWindow
      }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-doubleclick-open.md")
      .standardizedFileURL
    let ref = DocumentRef(id: documentID)

    registry.open(ref)
    registry.open(ref)

    XCTAssertEqual(createCount, 1, "a double-click must hit the existing-window path")
    XCTAssertEqual(activations.count, 2)
    XCTAssertTrue(activations.allSatisfy { $0 === documentWindow })
  }

  @MainActor
  func testWindowSwitchingDocumentsReleasesStaleDocumentMapping() throws {
    var factoryRefs: [DocumentRef?] = []
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let spawnedWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    for tracked in [window, spawnedWindow] {
      tracked.isReleasedWhenClosed = false
    }
    defer {
      window.close()
      spawnedWindow.close()
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { window },
      makeDocumentWindow: { ref, _ in
        factoryRefs.append(ref)
        return spawnedWindow
      }
    )
    let alphaID = URL(fileURLWithPath: "/tmp/pensieve-stale-alpha.md").standardizedFileURL
    let betaID = URL(fileURLWithPath: "/tmp/pensieve-stale-beta.md").standardizedFileURL

    // The window displays alpha, then switches to beta in place (the default
    // in-window click routing does this constantly).
    registry.attach(window, documentID: alphaID)
    registry.attach(window, documentID: betaID)

    registry.open(DocumentRef(id: alphaID))

    XCTAssertEqual(
      factoryRefs.compactMap { $0?.id }, [alphaID],
      "alpha no longer lives in this window; opening it must spawn a window, not activate the stale mapping"
    )
  }

  @MainActor
  func testOpenAssignsTabbedIdentifierToBothMergeParticipants() throws {
    var mergeCount = 0
    let expectedIdentifier = "Pensieve.DocumentWindow"
    let targetWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let documentWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    for window in [targetWindow, documentWindow] {
      window.isReleasedWhenClosed = false
    }
    defer {
      targetWindow.close()
      documentWindow.close()
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("open should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { target, window in
        mergeCount += 1
        XCTAssertEqual(target.tabbingIdentifier, expectedIdentifier)
        XCTAssertEqual(window.tabbingIdentifier, expectedIdentifier)
      },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { targetWindow },
      applicationWindows: { [targetWindow, documentWindow] },
      makeDocumentWindow: { _, _ in documentWindow }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-merged-tab.md").standardizedFileURL

    registry.open(DocumentRef(id: documentID))
    registry.attach(documentWindow, documentID: documentID)

    XCTAssertEqual(mergeCount, 1)
    XCTAssertEqual(targetWindow.tabbingIdentifier, expectedIdentifier)
    XCTAssertEqual(
      documentWindow.tabbingIdentifier, expectedIdentifier,
      "the scene's later attach must not strip the document tab grouping")
  }

  @MainActor
  func testNewUntitledTabMergesIntoSourceWindowAndSurvivesLauncherSweeps() throws {
    var events: [String] = []
    var factoryRefs: [DocumentRef?] = []
    var scheduledSweeps: [@MainActor () -> Void] = []
    var closedWindows: [NSWindow] = []
    let sourceWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let untitledWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    for window in [sourceWindow, untitledWindow] {
      window.isReleasedWhenClosed = false
    }
    defer {
      sourceWindow.close()
      untitledWindow.close()
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("plus-button tab should not defer") },
      scheduleLauncherWindowSweep: { scheduledSweeps.append($0) },
      mergeWindowIntoTabs: { target, window in
        events.append("merge")
        XCTAssertTrue(target === sourceWindow)
        XCTAssertTrue(window === untitledWindow)
      },
      orderAndActivateWindow: { window in
        events.append(window === untitledWindow ? "activate" : "activate-other")
      },
      currentMergeTarget: { sourceWindow },
      applicationWindows: { [sourceWindow, untitledWindow] },
      closeWindow: { closedWindows.append($0) },
      makeDocumentWindow: { ref, _ in
        factoryRefs.append(ref)
        return untitledWindow
      }
    )

    // The source window is a real document window.
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-plus-source.md").standardizedFileURL
    registry.attach(sourceWindow, documentID: documentID)
    scheduledSweeps.removeAll()
    events.removeAll()

    registry.newUntitledTab(from: sourceWindow)

    XCTAssertEqual(
      events, ["merge", "activate"], "the untitled tab joins the group before showing")
    XCTAssertEqual(factoryRefs.count, 1)
    XCTAssertNil(factoryRefs[0], "the plus button asks the factory for an untitled window")

    // The new tab's scene attaches in launcher mode (no document, no editable
    // buffer yet) — that must NOT classify it as an empty launcher to reap.
    untitledWindow.title = "Pensieve"
    registry.attach(untitledWindow, documentID: nil, hasEditableBuffer: false)

    while let sweep = scheduledSweeps.popLast() {
      sweep()
    }
    XCTAssertTrue(
      closedWindows.isEmpty,
      "a plus-button tab in its launcher-mode state must survive launcher sweeps")
  }

  @MainActor
  func testDocumentWindowOpenMergesExistingDocumentWindowIntoCurrentTabs() throws {
    var factoryCallCount = 0
    var mergeCount = 0
    var orderedWindows: [NSWindow] = []
    var scheduledSweeps: [@MainActor () -> Void] = []
    var closedWindows: [NSWindow] = []
    let expectedIdentifier = "Pensieve.DocumentWindow"
    let launcherWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let documentWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    for window in [launcherWindow, documentWindow] {
      window.isReleasedWhenClosed = false
    }
    launcherWindow.title = "Pensieve"
    defer {
      launcherWindow.close()
      documentWindow.close()
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("open should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { scheduledSweeps.append($0) },
      mergeWindowIntoTabs: { target, window in
        mergeCount += 1
        XCTAssertTrue(target === launcherWindow)
        XCTAssertTrue(window === documentWindow)
        XCTAssertEqual(target.tabbingIdentifier, expectedIdentifier)
        XCTAssertEqual(window.tabbingIdentifier, expectedIdentifier)
      },
      orderAndActivateWindow: { orderedWindows.append($0) },
      currentMergeTarget: { launcherWindow },
      applicationWindows: { [launcherWindow, documentWindow] },
      closeWindow: { closedWindows.append($0) },
      makeDocumentWindow: { _, _ in
        factoryCallCount += 1
        return nil
      }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-existing-document.md").standardizedFileURL
    let ref = DocumentRef(id: documentID)

    registry.attach(launcherWindow, documentID: nil)
    // Run (not just drop) collected sweeps: execution releases the coalescing
    // latch so the next interaction can schedule a fresh sweep.
    while let sweep = scheduledSweeps.popLast() { sweep() }

    registry.attach(
      documentWindow,
      documentID: documentID,
      title: "existing",
      representedURL: documentID,
      hasEditableBuffer: true)
    while let sweep = scheduledSweeps.popLast() { sweep() }
    closedWindows.removeAll()

    registry.open(ref)

    XCTAssertEqual(factoryCallCount, 0, "an already-open document never re-creates a window")
    XCTAssertEqual(mergeCount, 1)
    XCTAssertEqual(orderedWindows.last, documentWindow)
    XCTAssertEqual(scheduledSweeps.count, 1)

    let sweep = try XCTUnwrap(scheduledSweeps.popLast())
    sweep()

    XCTAssertEqual(closedWindows.map { ObjectIdentifier($0) }, [ObjectIdentifier(launcherWindow)])
    XCTAssertFalse(closedWindows.contains { $0 === documentWindow })
  }

  @MainActor
  func testDocumentWindowAttachReapsRegisteredEmptyLauncherWindows() throws {
    var scheduledSweeps: [@MainActor () -> Void] = []
    var closedWindows: [NSWindow] = []
    var closedWindowIDs: Set<ObjectIdentifier> = []
    var documentWindowIsAttached = false

    let launcherA = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let launcherB = NSWindow(
      contentRect: NSRect(x: 10, y: 10, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let documentWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let strayWindow = NSWindow(
      contentRect: NSRect(x: 30, y: 30, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    for window in [launcherA, launcherB, documentWindow, strayWindow] {
      window.isReleasedWhenClosed = false
      window.title = "Pensieve"
    }
    strayWindow.title = "Preferences"
    defer {
      for window in [launcherA, launcherB, documentWindow, strayWindow] {
        window.close()
      }
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { scheduledSweeps.append($0) },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      applicationWindows: {
        var windows = [launcherA, launcherB, strayWindow]
        if documentWindowIsAttached {
          windows.append(documentWindow)
        }
        return windows.filter {
          !closedWindowIDs.contains(ObjectIdentifier($0))
        }
      },
      closeWindow: {
        closedWindowIDs.insert(ObjectIdentifier($0))
        closedWindows.append($0)
      }
    )
    let documentID = URL(fileURLWithPath: "/tmp/foo.md").standardizedFileURL

    registry.attach(launcherA, documentID: nil)
    registry.attach(launcherB, documentID: nil)

    XCTAssertEqual(scheduledSweeps.count, 2, "empty launchers reconcile after registration")
    while let duplicateSweep = scheduledSweeps.popLast() {
      duplicateSweep()
    }

    XCTAssertGreaterThanOrEqual(Set(closedWindows.map { ObjectIdentifier($0) }).count, 1)
    XCTAssertLessThanOrEqual(Set(closedWindows.map { ObjectIdentifier($0) }).count, 2)
    XCTAssertTrue(closedWindows.allSatisfy { $0 === launcherA || $0 === launcherB })

    documentWindowIsAttached = true
    registry.attach(
      documentWindow,
      documentID: documentID,
      title: "foo",
      representedURL: documentID,
      hasEditableBuffer: true)

    XCTAssertEqual(scheduledSweeps.count, 1)
    let contentSweep = try XCTUnwrap(scheduledSweeps.popLast())
    contentSweep()

    XCTAssertEqual(
      Set(closedWindows.map { ObjectIdentifier($0) }),
      Set([ObjectIdentifier(launcherA), ObjectIdentifier(launcherB)])
    )
    XCTAssertFalse(closedWindows.contains { $0 === documentWindow })
    XCTAssertFalse(closedWindows.contains { $0 === strayWindow })
    XCTAssertEqual(documentWindow.title, "foo")
    XCTAssertEqual(documentWindow.representedURL?.standardizedFileURL, documentID)
  }

  @MainActor
  func testDocumentWindowAttachDoesNotReapEditableUntitledWindowAsLauncher() throws {
    var scheduledSweeps: [@MainActor () -> Void] = []
    var closedWindows: [NSWindow] = []
    var closedWindowIDs: Set<ObjectIdentifier> = []

    let launcherWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let untitledWindow = NSWindow(
      contentRect: NSRect(x: 10, y: 10, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let documentWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    for window in [launcherWindow, untitledWindow, documentWindow] {
      window.isReleasedWhenClosed = false
      window.title = "Pensieve"
    }
    defer {
      for window in [launcherWindow, untitledWindow, documentWindow] {
        window.close()
      }
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { scheduledSweeps.append($0) },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      applicationWindows: {
        [launcherWindow, untitledWindow, documentWindow].filter {
          !closedWindowIDs.contains(ObjectIdentifier($0))
        }
      },
      closeWindow: {
        closedWindowIDs.insert(ObjectIdentifier($0))
        closedWindows.append($0)
      }
    )
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-real-document.md").standardizedFileURL

    registry.attach(launcherWindow, documentID: nil)
    registry.attach(
      untitledWindow,
      documentID: nil,
      title: "Draft note",
      representedURL: nil,
      hasEditableBuffer: true)
    registry.attach(documentWindow, documentID: documentID)

    XCTAssertEqual(untitledWindow.title, "Draft note")
    // Sweeps coalesce: the attach churn shares ONE pending close-sweep; the
    // second entry is the launcher-registration reconcile pass.
    XCTAssertEqual(scheduledSweeps.count, 2)
    while let sweep = scheduledSweeps.popLast() {
      sweep()
    }

    XCTAssertEqual(closedWindows.map { ObjectIdentifier($0) }, [ObjectIdentifier(launcherWindow)])
    XCTAssertFalse(closedWindows.contains { $0 === untitledWindow })
    XCTAssertFalse(closedWindows.contains { $0 === documentWindow })
  }

  @MainActor
  func testDocumentWindowAttachReapsLauncherBesideVisibleUntrackedContentWindow() throws {
    var scheduledSweeps: [@MainActor () -> Void] = []
    var closedWindows: [NSWindow] = []

    let launcherWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    let restoredContentWindow = NSWindow(
      contentRect: NSRect(x: 20, y: 20, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    launcherWindow.isReleasedWhenClosed = false
    restoredContentWindow.isReleasedWhenClosed = false
    launcherWindow.title = "Pensieve"
    restoredContentWindow.title = "SKILL"
    defer {
      launcherWindow.close()
      restoredContentWindow.close()
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { scheduledSweeps.append($0) },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      applicationWindows: { [launcherWindow, restoredContentWindow] },
      closeWindow: { closedWindows.append($0) }
    )

    registry.attach(launcherWindow, documentID: nil)

    XCTAssertEqual(scheduledSweeps.count, 1)
    let sweep = try XCTUnwrap(scheduledSweeps.popLast())
    sweep()

    XCTAssertEqual(closedWindows.map { ObjectIdentifier($0) }, [ObjectIdentifier(launcherWindow)])
    XCTAssertFalse(closedWindows.contains { $0 === restoredContentWindow })
  }

  @MainActor
  func testCloseActiveDocumentClearsWindowSessionWithoutDroppingWorkspace() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveTabsEmptyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    controller.selectDocument(id: alphaURL.standardizedFileURL)

    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL)

    controller.closeActiveDocument()

    XCTAssertNil(appState.selectedDocumentID)
    XCTAssertNil(appState.documentSession.document)
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
  }

  @MainActor
  func testClosingActiveDocumentTabSelectsNeighborWithoutDroppingWorkspace() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseTabTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    controller.selectDocument(id: alphaURL.standardizedFileURL)
    controller.selectDocument(id: betaURL.standardizedFileURL)

    controller.closeActiveDocument()

    XCTAssertNil(appState.selectedDocumentID)
    XCTAssertNil(appState.documentSession.document)
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
  }

  @MainActor
  func testSearchIndexUpdatesAfterSaveAndRefresh() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSearchRefreshTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha original".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta original".write(to: betaURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase)
    let controller = AppController(
      appState: appState,
      folderManager: manager,
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    controller.selectDocument(id: alphaURL.standardizedFileURL)
    appState.activeDocumentText = "alpha saved search-token"
    appState.activeDocumentDirty = true
    controller.saveActiveDocument()

    controller.updateWorkspaceSearch(query: "search-token")
    await controller.waitForPendingWorkspaceSearch()
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [alphaURL.standardizedFileURL])

    try "beta externally refreshed-token".write(to: betaURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    controller.updateWorkspaceSearch(query: "refreshed-token")
    await controller.waitForPendingWorkspaceSearch()

    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [betaURL.standardizedFileURL])
  }

  @MainActor
  func testWorkspaceSearchCompletesWhileReindexWriteIsInFlight() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveSearchConcurrentReadTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let oldURL = folder.appendingPathComponent("old.md")
    let newURL = folder.appendingPathComponent("new.md")
    try "old-token stable snapshot".write(to: oldURL, atomically: true, encoding: .utf8)
    try "new-token pending rebuild".write(to: newURL, atomically: true, encoding: .utf8)

    let writeStarted = expectation(description: "reindex write starts")
    let releaseWrite = DispatchSemaphore(value: 0)
    let holdFirstReindexBatch = BlockingBatchProbe(
      onFirstBatch: {
        writeStarted.fulfill()
        _ = releaseWrite.wait(timeout: .now() + 2)
      })
    let appState = AppState()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { @Sendable size in
        holdFirstReindexBatch.recordBatch(size)
      }
    )
    let oldRef = DocumentRef(
      id: oldURL.standardizedFileURL,
      rootURL: folder.standardizedFileURL,
      relativePath: "old.md"
    )
    let newRef = DocumentRef(
      id: newURL.standardizedFileURL,
      rootURL: folder.standardizedFileURL,
      relativePath: "new.md"
    )
    appState.documents = [oldRef]
    indexDatabase.index(document: oldRef, body: "old-token stable snapshot", appState: appState)

    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      workspaceSearchDebounceNanoseconds: 0
    )

    let reindexTask = Task {
      _ = await indexDatabase.reindexInBackground(documents: [newRef], appState: nil)
    }
    await fulfillment(of: [writeStarted], timeout: 1)

    controller.updateWorkspaceSearch(query: "old-token")
    await controller.waitForPendingWorkspaceSearch()

    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [oldURL.standardizedFileURL])
    releaseWrite.signal()
    await reindexTask.value
  }

  @MainActor
  func testWorkspaceReindexBuildsSearchRecordsInBatches() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSearchBatchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let recorder = BatchSizeRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false),
      searchIndexBatchSize: 2,
      didInsertSearchIndexBatch: { @Sendable size in
        recorder.record(size)
      }
    )
    let refs = try (0..<5).map { index -> DocumentRef in
      let url = folder.appendingPathComponent("note-\(index).md")
      try "batch-token-\(index)".write(to: url, atomically: true, encoding: .utf8)
      return DocumentRef(
        id: url.standardizedFileURL,
        rootURL: folder.standardizedFileURL,
        relativePath: "note-\(index).md"
      )
    }

    indexDatabase.reindex(documents: refs, appState: AppState())

    XCTAssertEqual(recorder.values, [2, 2, 1])
    XCTAssertEqual(
      indexDatabase.search(query: "batch-token-4", documents: refs).map(\.document.id),
      [refs[4].id])
  }

  @MainActor
  func testSavingWorkspaceDocumentDoesNotRebuildFromSelfWriteWatcher() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveSelfWriteWatcherTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    // Production topology: the index database lives in Application Support, never inside a
    // watched root. With per-path self-write filtering, SQLite churn inside the watched folder
    // would otherwise count as an external mutation and break this contract's premise.
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveSelfWriteWatcherSupport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: support)
    }

    let noteURL = folder.appendingPathComponent("watched.md")
    try "before save".write(to: noteURL, atomically: true, encoding: .utf8)

    let rebuildProbe = RebuildProbe()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      rebuildProbe.recordBuild()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let appState = AppState()
    let indexDatabase = temporaryIndexDatabase(in: support)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      workspaceBuilder: builder
    )
    let controller = AppController(
      appState: appState,
      folderManager: manager,
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    XCTAssertEqual(rebuildProbe.value, 1)

    let externalRebuild = expectation(description: "external write triggers watcher refresh")
    rebuildProbe.expectNextRebuild(externalRebuild)
    try "external".write(
      to: folder.appendingPathComponent("external.md"), atomically: true, encoding: .utf8)
    await fulfillment(of: [externalRebuild], timeout: 2)
    XCTAssertEqual(rebuildProbe.value, 2)

    controller.selectDocument(id: noteURL.standardizedFileURL)

    let unexpectedSelfWriteRebuild = expectation(
      description: "self-write save does not trigger watcher rebuild")
    unexpectedSelfWriteRebuild.isInverted = true
    rebuildProbe.expectNextRebuild(unexpectedSelfWriteRebuild)
    appState.activeDocumentText = "after save self-write-token"
    appState.activeDocumentDirty = true
    controller.saveActiveDocument()

    await fulfillment(of: [unexpectedSelfWriteRebuild], timeout: 1.4)
    XCTAssertEqual(rebuildProbe.value, 2)

    controller.updateWorkspaceSearch(query: "self-write-token")
    await controller.waitForPendingWorkspaceSearch()
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [noteURL.standardizedFileURL])
  }

  @MainActor
  func testIndexDatabaseUsesCanonicalApplicationSupportPath() {
    let applicationSupportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    )[0]
    let expectedDatabaseURL =
      applicationSupportDirectory
      .appendingPathComponent("Pensieve", isDirectory: true)
      .appendingPathComponent("index.db", isDirectory: false)

    XCTAssertEqual(expectedDatabaseURL.lastPathComponent, "index.db")
    XCTAssertEqual(
      expectedDatabaseURL.deletingLastPathComponent().lastPathComponent,
      "Pensieve")
    XCTAssertEqual(
      expectedDatabaseURL.deletingLastPathComponent().deletingLastPathComponent(),
      applicationSupportDirectory)
  }

  @MainActor
  func testIndexDatabaseMigratorIsIdempotentAcrossTwoOpens() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveIndexMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }

    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let firstAppState = AppState()
    let firstDatabase = IndexDatabase(databaseURL: databaseURL)

    firstDatabase.open(into: firstAppState)

    XCTAssertNil(firstAppState.lastError)
    XCTAssertEqual(firstDatabase.databaseURL?.lastPathComponent, "index.db")
    XCTAssertEqual(firstDatabase.databaseURL?.standardizedFileURL, databaseURL.standardizedFileURL)

    let secondAppState = AppState()
    let secondDatabase = IndexDatabase(databaseURL: databaseURL)

    secondDatabase.open(into: secondAppState)

    XCTAssertNil(secondAppState.lastError)
    XCTAssertEqual(secondDatabase.databaseURL?.lastPathComponent, "index.db")
    XCTAssertEqual(secondDatabase.databaseURL?.standardizedFileURL, databaseURL.standardizedFileURL)

    let noteURL = folder.appendingPathComponent("idempotent-search.md", isDirectory: false)
    try """
    # Idempotent Search

    Migration reopen keeps searchable content alive.
    """.write(to: noteURL, atomically: true, encoding: .utf8)

    let ref = DocumentRef(
      id: noteURL.standardizedFileURL,
      rootURL: folder.standardizedFileURL,
      relativePath: "idempotent-search.md"
    )
    secondDatabase.reindex(documents: [ref], appState: secondAppState)

    let results = secondDatabase.search(
      query: "searchable content", documents: [ref], appState: secondAppState)

    XCTAssertEqual(results.map(\.document.id), [noteURL.standardizedFileURL])
  }

  @MainActor
  func testBookmarkRestoreClearsDeletedFolder() throws {
    let defaults = makeEphemeralDefaults(prefix: "PensieveBookmarkTests")

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveBookmarkTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let appState = AppState()
    let store = BookmarkStore(defaults: defaults)
    try store.persist(url: folder, into: appState)
    try FileManager.default.removeItem(at: folder)

    XCTAssertNil(store.restore(into: appState))
    XCTAssertNil(appState.bookmarkData)
    XCTAssertNotNil(appState.lastError)
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveMetadataTests-\(UUID().uuidString)", isDirectory: true)
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  @MainActor
  private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
  }

  @MainActor
  private func temporaryBookmarkStore() -> BookmarkStore {
    BookmarkStore(defaults: makeEphemeralDefaults(prefix: "PensieveBookmarkStoreTests"))
  }

  private func temporaryApplicationSupportDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveApplicationSupportTests-\(UUID().uuidString)",
        isDirectory: true
      )
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("Pensieve", isDirectory: true)
  }

  @MainActor
  private func waitForHighlightingDebounce() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    pollNanoseconds: UInt64 = 20_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async throws -> Bool
  ) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

    while true {
      if try await condition() {
        return
      }

      let now = DispatchTime.now().uptimeNanoseconds
      if now >= deadline {
        XCTFail("Timed out waiting for condition", file: file, line: line)
        return
      }

      try await Task.sleep(nanoseconds: min(pollNanoseconds, deadline - now))
    }
  }
}

private final class RecordingPreviewSink: PreviewSink {
  var loadedDocuments: [PreviewDocument] = []

  func load(document: PreviewDocument) {
    loadedDocuments.append(document)
  }
}

private final class BuildCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

private final class RebuildProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var nextRebuildExpectation: XCTestExpectation?

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func expectNextRebuild(_ expectation: XCTestExpectation) {
    lock.lock()
    nextRebuildExpectation = expectation
    lock.unlock()
  }

  func recordBuild() {
    lock.lock()
    count += 1
    let expectation = count > 1 ? nextRebuildExpectation : nil
    if expectation != nil {
      nextRebuildExpectation = nil
    }
    lock.unlock()
    expectation?.fulfill()
  }
}

/// Inert watcher source for tests that assert exact scan counts around manually driven
/// reconciles: a live FSEvents stream on the fixture root would deliver real events for the
/// same mutations and add machine-timing-dependent scans (same discipline as
/// WorkspaceFreshnessTests).
private final class InertWatcherEventSource: FileWatcherEventSource, @unchecked Sendable {
  func start(
    paths: [String],
    onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void
  ) throws {}

  func stop() {}
}

/// Thread-placement probe for injected workspace builders (Sendable-safe counter + flags).
private final class ScanThreadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var mainThreadFlags: [Bool] = []

  func record(isMainThread: Bool) {
    lock.lock()
    mainThreadFlags.append(isMainThread)
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return mainThreadFlags.count
  }

  func samples(after callCount: Int) -> [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return Array(mainThreadFlags.dropFirst(callCount))
  }
}

private final class BatchSizeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValues: [Int] = []

  var values: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return recordedValues
  }

  func record(_ size: Int) {
    lock.lock()
    recordedValues.append(size)
    lock.unlock()
  }
}

private final class BlockingBatchProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var didBlock = false
  private let onFirstBatch: @Sendable () -> Void

  init(onFirstBatch: @escaping @Sendable () -> Void) {
    self.onFirstBatch = onFirstBatch
  }

  func recordBatch(_ size: Int) {
    guard size > 0 else { return }

    lock.lock()
    let shouldBlock = !didBlock
    if shouldBlock {
      didBlock = true
    }
    lock.unlock()

    if shouldBlock {
      onFirstBatch()
    }
  }
}
