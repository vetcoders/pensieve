import AppKit
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
    let representable = EditorRepresentable(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      formattingCommand: nil,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      isDirty: Binding(get: { isDirty }, set: { isDirty = $0 }),
      onDocumentChanged: {
        didRouteDocumentChange = true
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
    let controller = AppController(appState: appState)
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

    try await Task.sleep(nanoseconds: 1_800_000_000)

    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "changed")
    XCTAssertFalse(appState.activeDocumentDirty)

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
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)
    try "ignored".write(
      to: nested.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
    try "package".write(
      to: nodeModules.appendingPathComponent("package.md"), atomically: true, encoding: .utf8)
    try "git".write(to: git.appendingPathComponent("config.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    let manager = FolderManager(metadataStore: temporaryMetadataStore())
    manager.open(url: folder, into: appState)

    XCTAssertEqual(
      Set(appState.documents.map { $0.url.resolvingSymlinksInPath() }),
      Set([alphaURL.resolvingSymlinksInPath(), betaURL.resolvingSymlinksInPath()])
    )
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
    XCTAssertEqual(appState.workspaceTree.first?.name, folder.lastPathComponent)
    XCTAssertTrue(
      appState.workspaceTree.first?.children?.contains(where: { $0.name == "Nested" }) == true)
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
    let appState = AppState()
    let manager = FolderManager(metadataStore: metadataStore)
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
    let relaunchedManager = FolderManager(metadataStore: metadataStore)
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
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: .shared
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
    let unsupportedURL = folder.appendingPathComponent("not-markdown.txt")
    try "first body".write(to: firstURL, atomically: true, encoding: .utf8)
    try "second body".write(to: secondURL, atomically: true, encoding: .utf8)
    try "plain text".write(to: unsupportedURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: .shared,
      importsFoldersInBackground: true
    )
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)

    coordinator.handle(urls: [firstURL, secondURL, unsupportedURL])
    coordinator.startWhenLaunchIntentsSettle(controller: controller)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(
      appState.openFiles.map { $0.url.standardizedFileURL },
      [firstURL.standardizedFileURL, secondURL.standardizedFileURL])
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, firstURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "first body")
    XCTAssertTrue(appState.lastError?.contains(".md or .markdown") == true)
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
    let controller = AppController(appState: appState)
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
    DocumentStore.shared.load(ref: DocumentRef(id: alphaURL), into: appState)
    let controller = AppController(appState: appState)

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
    let controller = AppController(appState: appState)

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
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: .shared
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
  func testWorkspaceSearchDropsExcludedPathsAfterReindex() throws {
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
    controller.updateWorkspaceSearch(query: "nebula")
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [skipURL.standardizedFileURL])

    controller.excludeFromWorkspace(urls: [drafts])

    XCTAssertFalse(appState.documents.contains { $0.url == skipURL.standardizedFileURL })
    XCTAssertTrue(appState.workspaceSearchResults.isEmpty)
  }

  @MainActor
  func testSearchResultSelectionLoadsDocumentThroughController() throws {
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

    XCTAssertEqual(appState.documentTabs.map { $0.url.lastPathComponent }, ["beta.md", "alpha.md"])
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL)
  }

  @MainActor
  func testDocumentTabsAreEmptyUntilDocumentsAreSelectedAndClosed() throws {
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

    XCTAssertTrue(appState.documentTabs.isEmpty)

    controller.openFolder(url: folder)
    controller.selectDocument(id: alphaURL.standardizedFileURL)

    XCTAssertFalse(appState.documentTabs.isEmpty)

    controller.closeDocumentTab(id: alphaURL.standardizedFileURL)

    XCTAssertTrue(appState.documentTabs.isEmpty)
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

    controller.closeDocumentTab(id: betaURL.standardizedFileURL)

    XCTAssertEqual(appState.documentTabs.map { $0.url.lastPathComponent }, ["alpha.md"])
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, alphaURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "alpha")
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])

    controller.closeDocumentTab(id: alphaURL.standardizedFileURL)

    XCTAssertTrue(appState.documentTabs.isEmpty)
    XCTAssertNil(appState.selectedDocumentID)
    XCTAssertNil(appState.documentSession.document)
    XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
  }

  @MainActor
  func testSearchIndexUpdatesAfterSaveAndRefresh() throws {
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
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [alphaURL.standardizedFileURL])

    try "beta externally refreshed-token".write(to: betaURL, atomically: true, encoding: .utf8)
    manager.refresh(into: appState)
    controller.updateWorkspaceSearch(query: "refreshed-token")

    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [betaURL.standardizedFileURL])
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
    XCTAssertEqual(
      appState.workspaceSearchResults.map(\.document.id), [noteURL.standardizedFileURL])
  }

  @MainActor
  func testIndexDatabaseUsesCanonicalApplicationSupportPath() {
    let appState = AppState()

    IndexDatabase.shared.open(into: appState)

    XCTAssertNil(appState.lastError)
    XCTAssertEqual(IndexDatabase.shared.databaseURL?.lastPathComponent, "index.db")
    XCTAssertEqual(
      IndexDatabase.shared.databaseURL?.deletingLastPathComponent().lastPathComponent, "Pensieve")
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
