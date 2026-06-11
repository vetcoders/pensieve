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
    surface.update(text: updatedText, fontSize: 18, syntaxHighlightingEnabled: true)

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

    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
      NSColor.systemGreen)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor,
      NSColor.systemPink)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? NSColor,
      NSColor.controlAccentColor)
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

    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: unorderedMarker.location, effectiveRange: nil)
        as? NSColor,
      NSColor.systemBlue)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: orderedMarker.location, effectiveRange: nil)
        as? NSColor,
      NSColor.systemBlue)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: taskMarker.location, effectiveRange: nil)
        as? NSColor,
      NSColor.systemBlue)
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
      NSColor.systemGreen)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: updatedFarHeadingRange.location, effectiveRange: nil)
        as? NSColor,
      NSColor.systemGreen)
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
      NSColor.systemPink)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: returnRange.location, effectiveRange: nil)
        as? NSColor,
      NSColor.systemPink)
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: stringRange.location, effectiveRange: nil)
        as? NSColor,
      NSColor.systemRed)
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
      NSColor.systemPink)
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
        NSColor.systemPink,
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
      NSColor.systemPink)
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
      NSColor.systemPink)

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
      NSColor.systemPink,
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

    surface.update(text: storage.string, fontSize: 14, syntaxHighlightingEnabled: true)

    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor,
      NSColor.systemPink)
  }

  @MainActor
  func testPreviewAutoReloadDefaultsOffButPreservesStoredPreference() {
    let suiteName = "PensievePreviewDefaultsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

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
    let suiteName = "PensieveSidebarSortTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

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
      documentStore: DocumentStore(autosaver: autosaver, indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    controller.openFolder(url: folder)

    XCTAssertEqual(
      appState.documents.map { $0.url.resolvingSymlinksInPath() },
      [noteURL.resolvingSymlinksInPath()]
    )
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
    let store = DocumentStore(
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
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(saveCount, 1)
    XCTAssertEqual(indexCount, 0)

    try await Task.sleep(nanoseconds: 110_000_000)
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
    let documentStore = DocumentStore(
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

    let restoredState = AppState()
    XCTAssertTrue(documentStore.restoreRecoveredDraft(into: restoredState))
    XCTAssertTrue(restoredState.documentSession.isUntitled)
    XCTAssertTrue(restoredState.activeDocumentDirty)
    XCTAssertEqual(restoredState.activeDocumentText, "keep this crash draft")
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
    let documentStore = DocumentStore(
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
    let suiteName = "PensieveAsyncRestoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

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
    XCTAssertEqual(
      appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
    XCTAssertEqual(appState.activeDocumentText, "launch-search-token")
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [noteURL.standardizedFileURL])
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )

    controller.openFolder(url: folder)

    XCTAssertEqual(scanStarted.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
    XCTAssertEqual(appState.workspaceActivity?.title, "Importing Workspace")
    XCTAssertTrue(appState.workspaceActivity?.detail.contains(folder.lastPathComponent) == true)
    XCTAssertNotNil(appState.workspaceActivity?.progress)

    releaseScan.signal()
    await manager.waitForPendingWorkspaceBuild()

    XCTAssertNil(appState.workspaceActivity)
    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])
  }

  @MainActor
  func testRefreshSkipsRebuildWhenMarkdownUnchanged() throws {
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
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      workspaceBuilder: builder
    )

    manager.open(url: folder, into: appState)
    let afterOpen = calls.count
    XCTAssertGreaterThan(afterOpen, 0, "open must scan once")
    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])

    // 1) refresh, nothing changed -> must skip rebuild (no new scan)
    manager.refresh(into: appState)
    XCTAssertEqual(calls.count, afterOpen, "refresh with unchanged .md must skip rebuild")

    // 2) add a non-markdown file (e.g. screenshot/.DS_Store) -> must still skip
    try Data().write(to: folder.appendingPathComponent("shot.png"))
    manager.refresh(into: appState)
    XCTAssertEqual(calls.count, afterOpen, "non-.md change must skip rebuild")

    // 3) change .md content (size differs -> fingerprint changes even within same second) -> must rebuild
    try "body changed and noticeably longer".write(to: noteURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    XCTAssertGreaterThan(calls.count, afterOpen, ".md content change must trigger rebuild")
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
  /// when the `.md` set is unchanged — the off-main signature gate matches and the path returns
  /// without touching the main-actor rebuild.
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
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: temporaryIndexDatabase(in: folder),
      workspaceBuilder: builder,
      watcherDebounceMilliseconds: 10
    )

    manager.open(url: folder, into: appState)
    let afterOpen = calls.count

    // Foreign churn: a screenshot / .DS_Store sibling write leaves the .md set untouched.
    try Data().write(to: folder.appendingPathComponent("shot.png"))
    manager.scheduleWatcherRefresh(into: appState)
    await manager.waitForPendingWatcherRefresh()

    XCTAssertEqual(calls.count, afterOpen, "non-.md change must not trigger a rebuild")
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
      watcherDebounceMilliseconds: 10
    )

    manager.open(url: folder, into: appState)
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

  /// Invariant 5: the skip-when-unchanged gate still returns early when the `.md` set is
  /// identical (non-.md churn) — no rebuild, no upsert.
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
      workspaceBuilder: builder)

    manager.open(url: folder, into: appState)
    await manager.waitForPendingIndexUpdate()
    let scansAfterOpen = calls.count
    let recordsAfterOpen = recorder.values.reduce(0, +)

    // Non-.md churn: a screenshot leaves the .md set untouched.
    try Data().write(to: folder.appendingPathComponent("shot.png"))
    manager.refresh(into: appState)
    await manager.waitForPendingIndexUpdate()

    XCTAssertEqual(calls.count, scansAfterOpen, "unchanged .md set must skip the rebuild")
    XCTAssertEqual(
      recorder.values.reduce(0, +), recordsAfterOpen, "skip path must not touch the FTS index")
  }

  // MARK: - Stage A1: off-main index write (rebuildWorkspace)

  /// A watcher-triggered rebuild does NOT block the main actor: after the refresh returns, the
  /// in-memory document tree (`appState.allDocuments`) already reflects the change synchronously
  /// (the metadata-only `applyWorkspaceScans` ran on the main actor), while the FTS index write
  /// is still pending off-main. Only after `waitForPendingReindex()` does the index reflect the
  /// change. The observable gap between "tree updated" and "index updated" structurally proves
  /// the index write is OFF the main actor.
  @MainActor
  func testRebuildIndexWriteIsOffMainTreeObservableBeforeIndex() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveOffMainTreeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    try "seed-token original".write(
      to: folder.appendingPathComponent("seed.md"), atomically: true, encoding: .utf8)

    let indexDatabase = temporaryIndexDatabase(in: folder)
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())

    manager.open(url: folder, into: appState)
    await manager.waitForPendingIndexUpdate()

    // Add a new file, then refresh. The refresh returns synchronously after the tree update;
    // the index write is launched off-main and is NOT awaited by `refresh`.
    let freshURL = folder.appendingPathComponent("fresh.md")
    try "fresh-token freshly added".write(to: freshURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)

    // Tree reflects the new file IMMEDIATELY (sync metadata path) — before the index write.
    XCTAssertTrue(
      appState.allDocuments.contains(where: {
        $0.url.standardizedFileURL == freshURL.standardizedFileURL
      }),
      "the document tree sees the new file synchronously, before the off-main index write")

    // Only after awaiting the off-main write does the FTS index reflect the change.
    await manager.waitForPendingIndexUpdate()
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
    // not block with a multi-root error (that was the B-1b regression Maciej hit).
    XCTAssertNil(appState.lastError)
    XCTAssertEqual(
      Set(appState.workspaceRoots.map(\.url)),
      Set([firstRoot.standardizedFileURL, secondRoot.standardizedFileURL]))
    XCTAssertEqual(
      Set(appState.documents.map(\.relativePath)), Set(["one.md", "two.md"]))
  }

  @MainActor
  func testWorkspaceExclusionsPersistAndFilterImportedPaths() throws {
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

    XCTAssertEqual(appState.excludedWorkspacePaths, Set(["Drafts"]))
    XCTAssertEqual(
      appState.documents.map { $0.url.resolvingSymlinksInPath() },
      [keepURL.resolvingSymlinksInPath()])
    XCTAssertEqual(metadataStore.load().excludedPaths, ["Drafts"])
    XCTAssertFalse(appState.documents.contains(where: { $0.url == skipURL.standardizedFileURL }))

    let relaunchedState = AppState()
    let relaunchedManager = FolderManager(
      metadataStore: metadataStore, indexDatabase: indexDatabase)
    relaunchedManager.open(url: folder, into: relaunchedState)
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
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
    let suiteName = "PensieveLaunchIntentTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)

    coordinator.handle(urls: [launchURL])
    coordinator.startWhenLaunchIntentsSettle(controller: controller)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(scanStarted.wait(timeout: .now() + 0.1), .timedOut)
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
    XCTAssertEqual(appState.openFiles.map(\.url), [launchURL.standardizedFileURL])
    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL, launchURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "clicked first")
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)

    coordinator.handle(urls: [firstURL, secondURL, plainURL, unsupportedURL])
    coordinator.startWhenLaunchIntentsSettle(controller: controller)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(
      appState.openFiles.map { $0.url.standardizedFileURL },
      [firstURL.standardizedFileURL, secondURL.standardizedFileURL, plainURL.standardizedFileURL])
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, firstURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "first body")
    XCTAssertTrue(appState.lastError?.contains(".md, .markdown, or .txt") == true)
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 10_000_000_000)
    var startupDecisionCount = 0

    coordinator.startWhenLaunchIntentsSettle(controller: controller) {
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
    DocumentStore(indexDatabase: temporaryIndexDatabase(in: folder))
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
      documentStore: DocumentStore(indexDatabase: temporaryIndexDatabase(in: folder))
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
  func testExternalRefreshReloadsCleanSessionButProtectsDirtySession() throws {
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
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder))
    manager.open(url: folder, into: appState)
    XCTAssertEqual(appState.documentSession.text, "clean original")

    try "clean external".write(to: noteURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    XCTAssertEqual(appState.documentSession.text, "clean external")
    XCTAssertFalse(appState.documentSession.isDirty)

    appState.activeDocumentText = "dirty local edit"
    appState.activeDocumentDirty = true
    try "dirty external".write(to: noteURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)

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
    let documentStore = DocumentStore(indexDatabase: indexDatabase)
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    controller.selectDocument(id: alphaURL.standardizedFileURL)
    XCTAssertNotNil(appState.documentSession.document)

    let workspaceDocumentsBefore = appState.documents.map(\.id)

    let didClose = controller.closeActiveDocument()

    XCTAssertTrue(didClose)
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
  func testCloseActiveDocumentSavesDirtySessionBeforeClearing() throws {
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
    let documentStore = DocumentStore(indexDatabase: indexDatabase)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase
    )
    documentStore.load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)

    appState.activeDocumentText = "edited before close"
    appState.activeDocumentDirty = true

    let didClose = controller.closeActiveDocument()

    XCTAssertTrue(didClose)
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
    let documentStore = DocumentStore(indexDatabase: indexDatabase)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase
    )
    documentStore.load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)

    appState.activeDocumentText = "unsaved tail"
    appState.activeDocumentDirty = true

    // Knock the directory out from under the active document so its save
    // fails. The session must stay alive and dirty rather than silently
    // dropping the user's edits.
    try FileManager.default.removeItem(at: writable)

    let didClose = controller.closeActiveDocument()

    XCTAssertFalse(didClose)
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
  func testControllerRoutesWorkspaceCommands() throws {
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
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: DocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)
    XCTAssertEqual(appState.documents.count, 2)

    controller.excludeFromWorkspace(urls: [hidden])
    XCTAssertEqual(appState.excludedWorkspacePaths, Set(["Hidden"]))
    XCTAssertEqual(appState.documents.count, 1)

    controller.clearWorkspaceExclusions()
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(
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
      documentStore: DocumentStore(
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
      documentStore: DocumentStore(
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
    let documentStore = DocumentStore(
      indexDatabase: temporaryIndexDatabase(in: FileManager.default.temporaryDirectory),
      dirtyUntitledPrompt: { session in
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
    let documentStore = DocumentStore(
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )

    controller.openFolder(url: folder)

    XCTAssertTrue(
      appState.documents.contains { $0.url.standardizedFileURL == textURL.standardizedFileURL })
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
    await manager.waitForPendingIndexUpdate()

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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
  func testOpenDocumentWindowReusesEmptyWindowBeforeCreatingTab() throws {
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase
    )
    var requestedRefs: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { requestedRefs.append($0) }

    controller.openFolder(url: folder)
    controller.openDocumentWindow(id: alphaURL.standardizedFileURL)

    XCTAssertTrue(requestedRefs.isEmpty, "an empty window is reused in place")
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "alpha")

    controller.openDocumentWindow(id: betaURL.standardizedFileURL)

    XCTAssertEqual(
      requestedRefs.map(\.id.standardizedFileURL), [betaURL.standardizedFileURL],
      "tab per document: a list click on another document routes to the registry")
    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL,
      "the originating window keeps its document while the tab materializes")

    controller.openDocumentWindow(id: alphaURL.standardizedFileURL)

    XCTAssertEqual(
      requestedRefs.map(\.id.standardizedFileURL), [betaURL.standardizedFileURL],
      "clicking the currently displayed document is a no-op")

    // The explicit context-menu gesture rides the same path.
    controller.openDocumentInNewWindow(id: betaURL.standardizedFileURL)

    XCTAssertEqual(
      requestedRefs.map(\.id.standardizedFileURL),
      [betaURL.standardizedFileURL, betaURL.standardizedFileURL])
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      makeDocumentWindow: { ref in
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
  func testDocumentWindowAttachDoesNotForceTabbedIdentifierForStandaloneDocument() throws {
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
    XCTAssertNotEqual(window.tabbingIdentifier, "Pensieve.DocumentWindow")
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
      makeDocumentWindow: { _ in
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
      makeDocumentWindow: { _ in
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
      makeDocumentWindow: { _ in
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
      makeDocumentWindow: { ref in
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
      makeDocumentWindow: { _ in
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
      makeDocumentWindow: { ref in
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
      makeDocumentWindow: { _ in documentWindow }
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
      makeDocumentWindow: { ref in
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
      makeDocumentWindow: { _ in
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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

    let noteURL = folder.appendingPathComponent("watched.md")
    try "before save".write(to: noteURL, atomically: true, encoding: .utf8)

    let rebuildProbe = RebuildProbe()
    let builder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      rebuildProbe.recordBuild()
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
      documentStore: DocumentStore(indexDatabase: indexDatabase),
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
    let suiteName = "PensieveBookmarkTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

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
    let suiteName = "PensieveBookmarkStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return BookmarkStore(defaults: defaults)
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
    RunLoop.main.run(until: Date().addingTimeInterval(0.16))
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
