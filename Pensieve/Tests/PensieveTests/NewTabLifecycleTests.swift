import AppKit
import XCTest

@testable import Pensieve

/// The new-tab lifecycle contract: a "+" / ⌘T / ⌘N tab is presented and selected
/// synchronously, so every surface that describes it must be true synchronously
/// too.
///
/// The bug this class pins is one clock, seen from two surfaces. The window is
/// built, merged into the source group and ordered front inside ONE main-actor
/// turn (`DocumentWindowRegistry.newUntitledTab`), while the session that fills
/// it materializes several run-loop turns later — SwiftUI root cold start →
/// `LaunchIntentCoordinator.startWhenLaunchIntentsSettle` → `Task` hop →
/// `AppController.start(.newUntitledTab)`. In that gap the tab renders the
/// launcher (title "Pensieve", New File / Open File / RECENT) and the sidebar's
/// Open Files list is short by exactly the number of pending tabs, because a
/// descriptor is published only when the accessor attaches.
///
/// Nothing here touches a native presentation API: the window-lifecycle testing
/// contract in `docs/keyboard-shortcuts-and-file-lifecycle-contract.md` allows
/// only inert `defer: true` fixtures, so ownership is modelled through the
/// registry's injectable seams.
final class NewTabLifecycleTests: XCTestCase {

  // MARK: - PIN 1 — surface truth exists before the tab is presented

  /// The descriptor is not "eventually consistent" with the tab bar: the native
  /// tab group mutates synchronously at click, so Open Files has to already
  /// describe the new tab by the time that tab is ordered front. Reading the
  /// published list from INSIDE the `orderAndActivateWindow` seam is the exact
  /// moment the user first sees the tab.
  @MainActor
  func testNewUntitledTabIsPublishedBeforeItIsEverPresented() {
    let sourceWindow = Self.makeWindow(title: "Source")
    let newWindow = Self.makeWindow()
    defer {
      sourceWindow.close()
      newWindow.close()
    }
    XCTAssertTrue(DocumentWindowOwnership.claimDocumentHost(sourceWindow))

    var descriptorsAtPresentation: [OpenDocumentDescriptor]?
    var registry: DocumentWindowRegistry!
    registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("an unblocked new tab must not defer") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { window in
        guard window === newWindow else { return }
        descriptorsAtPresentation = registry.openDocuments
      },
      applicationWindows: { [sourceWindow, newWindow] },
      makeDocumentWindow: { ref, intent in
        XCTAssertNil(ref)
        XCTAssertEqual(intent, .newUntitledTab)
        return newWindow
      })

    XCTAssertTrue(registry.newDocumentForTab(from: sourceWindow))

    let atPresentation = try? XCTUnwrap(descriptorsAtPresentation)
    XCTAssertEqual(
      atPresentation?.count, 1,
      "the new tab was ordered front before Open Files knew it existed")
    XCTAssertTrue(
      atPresentation?.first?.window === newWindow,
      "the descriptor visible at presentation must belong to the new tab")
    XCTAssertEqual(
      registry.openDocuments.count, 1,
      "one new tab must publish exactly one descriptor")
    XCTAssertNil(
      registry.openDocuments.first?.fileURL,
      "a pending untitled tab is backed by no file yet")
  }

  // MARK: - PIN 2 — a burst loses nothing and duplicates nothing

  /// The native "+" route. Every click is its own gesture; none of them waits
  /// for the previous tab's SwiftUI root to attach, so the registry has to
  /// account for all of them on its own.
  @MainActor
  func testBurstOfNativeNewTabRequestsPublishesOneDescriptorPerWindow() {
    for requestCount in [2, 5] {
      let fixture = Self.makeBurstFixture(requestCount: requestCount)
      defer { fixture.dispose() }

      for _ in 0..<requestCount {
        XCTAssertTrue(fixture.registry.newDocumentForTab(from: fixture.sourceWindow))
      }

      XCTAssertEqual(
        fixture.createdWindows.count, requestCount,
        "\(requestCount) native new-tab clicks produced a different number of windows")
      Self.assertOneDescriptorPerPendingTab(
        fixture.registry, expecting: fixture.createdWindows, requestCount: requestCount)
    }
  }

  /// The counted lane. `LaunchIntentCoordinator` exists because a host factory
  /// returns before SwiftUI attaches its controller, so ⌘N presses in that gap
  /// are counted and replayed. The replay lands in the same registry entry
  /// point, and must publish the same one-row-per-tab truth.
  @MainActor
  func testCountedNewDocumentLanePublishesOneDescriptorPerReplayedTab() {
    let requestCount = 3
    let fixture = Self.makeBurstFixture(requestCount: requestCount)
    defer { fixture.dispose() }

    let harness = makeSeedHarness()
    let coordinator = LaunchIntentCoordinator(
      focusedControllerProvider: { harness.controller },
      hasLiveDocumentCapableWindow: { true },
      createUntitledDocument: { [registry = fixture.registry, source = fixture.sourceWindow] _ in
        registry.newUntitledTab(from: source)
      })

    for _ in 0..<requestCount {
      coordinator.requestNewDocument()
    }

    XCTAssertEqual(
      fixture.createdWindows.count, requestCount,
      "the counted New lane lost or duplicated a tab on its way to the registry")
    Self.assertOneDescriptorPerPendingTab(
      fixture.registry, expecting: fixture.createdWindows, requestCount: requestCount)
  }

  /// Closing a pending tab retires its row. A descriptor published before the
  /// accessor attaches would otherwise outlive the window it describes and leave
  /// a phantom row in Open Files.
  @MainActor
  func testClosingAPendingNewTabRetiresItsDescriptor() {
    let fixture = Self.makeBurstFixture(requestCount: 2)
    defer { fixture.dispose() }

    XCTAssertTrue(fixture.registry.newDocumentForTab(from: fixture.sourceWindow))
    XCTAssertTrue(fixture.registry.newDocumentForTab(from: fixture.sourceWindow))
    XCTAssertEqual(fixture.registry.openDocuments.count, 2)

    let closed = fixture.createdWindows[0]
    fixture.registry.handleWindowClosed(closed, tombstonePolicy: .factoryWindow)

    XCTAssertEqual(
      fixture.registry.openDocuments.count, 1,
      "a closed pending tab left a phantom Open Files row")
    XCTAssertFalse(
      fixture.registry.openDocuments.contains { $0.window === closed },
      "the retired row still points at the closed window")
  }

  // MARK: - PIN 3 — a new tab never presents the launcher

  /// The other half of the same clock, on the CONTENT side. While the session
  /// was missing, `DocumentWindowSurface` resolved the tab to `.launcher` and
  /// the window title to the literal "Pensieve" — the factory bridges that title
  /// straight onto the native window (`sceneBridgingOptions = [.toolbars,
  /// .title]`), so the user got an interactive "Pensieve" launcher tab wedged
  /// between two Untitled.md tabs.
  @MainActor
  func testANewUntitledTabNeverResolvesToTheLauncherSurface() {
    let harness = makeSeedHarness()
    XCTAssertEqual(
      Self.surface(of: harness.appState), .launcher,
      "fixture precondition: a controller with no session starts on the launcher")

    // Exactly what a factory-built `.newUntitledTab` window does when it is
    // constructed — no `start`, no coordinator hop, no run-loop turn.
    XCTAssertTrue(
      NewTabSessionSeed.seedIfNeeded(
        controller: harness.controller, intent: .newUntitledTab, initialDocument: nil))

    XCTAssertEqual(
      Self.surface(of: harness.appState), .editor,
      "a new tab presented the launcher branch instead of an editor")
    XCTAssertEqual(
      DocumentWindowSurface.navigationTitle(
        hasEditableBuffer: harness.appState.documentHasEditableBuffer,
        documentTitle: harness.appState.documentTitle),
      "Untitled.md",
      "a new tab was titled with the app name, which is the launcher's title")
  }

  /// The seed is scoped to the one intent that promises a draft. Every other
  /// window still legitimately starts on the launcher surface, and a window
  /// built FOR a document loads that document instead.
  @MainActor
  func testOnlyAnUntitledNewTabSeedsADraftAtConstruction() {
    for intent in [LaunchIntent.coldLaunch, .dockReopen, .explicitDocument] {
      XCTAssertFalse(
        NewTabSessionSeed.seedsUntitledDraft(intent: intent, initialDocument: nil),
        "\(intent) must not create an untitled buffer the user never asked for")
    }
    XCTAssertTrue(
      NewTabSessionSeed.seedsUntitledDraft(intent: .newUntitledTab, initialDocument: nil))
    XCTAssertFalse(
      NewTabSessionSeed.seedsUntitledDraft(
        intent: .newUntitledTab,
        initialDocument: DocumentRef(id: URL(fileURLWithPath: "/tmp/note.md"))),
      "a window built for a document must load it, not a draft")
  }

  /// The late half of the same gesture. `start(.newUntitledTab)` still runs once
  /// the coordinator settles, seconds after the tab appeared — by then the user
  /// may have typed into it. It must not create a second draft: that would
  /// renumber the tab and throw the typing away.
  @MainActor
  func testTheLateStartNeitherReplacesNorRenumbersTheSeededDraft() {
    let harness = makeSeedHarness()
    NewTabSessionSeed.seedIfNeeded(
      controller: harness.controller, intent: .newUntitledTab, initialDocument: nil)
    harness.appState.documentSession.text = "typed while the tab was still starting up"

    harness.controller.start(intent: .newUntitledTab)

    XCTAssertEqual(
      harness.appState.documentSession.text, "typed while the tab was still starting up",
      "the late startup pass replaced a buffer the user was already typing into")
    XCTAssertEqual(
      harness.appState.documentTitle, "Untitled.md",
      "the late startup pass created a second draft and renumbered the tab")
    XCTAssertEqual(Self.surface(of: harness.appState), .editor)
  }

  // MARK: - Fixtures

  @MainActor
  private static func surface(of appState: AppState) -> DocumentWindowSurface {
    DocumentWindowSurface.resolve(
      isLoading: appState.documentIsLoading,
      hasEditableBuffer: appState.documentHasEditableBuffer)
  }

  @MainActor
  private struct BurstFixture {
    let registry: DocumentWindowRegistry
    let sourceWindow: NSWindow
    let windowPool: [NSWindow]
    /// Only the windows the factory actually handed out, in creation order.
    let createdWindows: WindowLog

    func dispose() {
      sourceWindow.close()
      for window in windowPool { window.close() }
    }
  }

  /// Reference box so the factory closure can record its output while the
  /// fixture stays a value type.
  @MainActor
  private final class WindowLog {
    private(set) var windows: [NSWindow] = []
    var count: Int { windows.count }
    subscript(index: Int) -> NSWindow { windows[index] }
    func append(_ window: NSWindow) { windows.append(window) }
  }

  @MainActor
  private static func makeBurstFixture(requestCount: Int) -> BurstFixture {
    let sourceWindow = makeWindow(title: "Source")
    XCTAssertTrue(DocumentWindowOwnership.claimDocumentHost(sourceWindow))
    let pool = (0..<requestCount).map { _ in makeWindow() }
    let log = WindowLog()
    var remaining = pool[...]

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("an unblocked new tab must not defer") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      applicationWindows: { [sourceWindow] + pool },
      makeDocumentWindow: { _, _ in
        guard let next = remaining.popFirst() else {
          XCTFail("the factory was asked for more windows than the burst requested")
          return nil
        }
        log.append(next)
        return next
      })

    return BurstFixture(
      registry: registry,
      sourceWindow: sourceWindow,
      windowPool: pool,
      createdWindows: log)
  }

  @MainActor
  private static func assertOneDescriptorPerPendingTab(
    _ registry: DocumentWindowRegistry,
    expecting windows: WindowLog,
    requestCount: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let published = registry.openDocuments
    XCTAssertEqual(
      published.count, requestCount,
      "Open Files trails the tab bar by \(requestCount - published.count) pending tab(s)",
      file: file, line: line)
    XCTAssertEqual(
      Set(published.map(\.identity)).count, published.count,
      "a pending tab was published twice", file: file, line: line)
    let publishedWindows = published.compactMap(\.window).map(ObjectIdentifier.init)
    XCTAssertEqual(
      Set(publishedWindows).count, published.count,
      "two descriptors claim the same window", file: file, line: line)
    for index in 0..<windows.count {
      XCTAssertTrue(
        published.contains { $0.window === windows[index] },
        "tab #\(index + 1) of the burst never reached Open Files", file: file, line: line)
    }
  }

  @MainActor
  private static func makeWindow(title: String = "") -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -9000, y: -9000, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = NSView(frame: .zero)
    window.title = title
    return window
  }

  @MainActor
  private struct SeedHarness {
    let appState: AppState
    let controller: AppController
  }

  /// A controller wired to throwaway state, built the way a factory window's
  /// SwiftUI root builds one.
  @MainActor
  private func makeSeedHarness() -> SeedHarness {
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveNewTabLifecycleTests-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: support)
    }
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db", isDirectory: false))
    let folderManager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json", isDirectory: false)),
      indexDatabase: indexDatabase,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveNewTabLifecycleTests")),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))))
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: makeTestDocumentStore(
        indexDatabase: indexDatabase,
        recoveryStore: RecoveryStore(
          directoryURL: support.appendingPathComponent("Recovery", isDirectory: true))),
      indexDatabase: indexDatabase,
      launchSettings: LaunchSettings(
        defaults: makeEphemeralDefaults(prefix: "PensieveNewTabLifecycleTestsLaunch")),
      documentWindowRegistry: DocumentWindowRegistry(canMutateWindowTabs: { true }),
      startupRestore: ApplicationStartupRestore(),
      importsFoldersInBackground: true)
    return SeedHarness(appState: appState, controller: controller)
  }
}
