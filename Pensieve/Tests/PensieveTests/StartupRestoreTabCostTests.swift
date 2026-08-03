import AppKit
import XCTest

@testable import Pensieve

/// WHAT A LAUNCH IS ALLOWED TO PAY FOR THE TABS IT BRINGS BACK.
///
/// Sampled on the operator's machine, build 528: the main thread sat inside ONE
/// layout pass for five seconds, at 100% CPU, with the process at 1.2 GB after
/// forty seconds of launch. The stack was unambiguous —
///
///   `AppController.start` → `reopenRestoredOpenFiles`
///     → `DocumentWindowRegistry.open`
///     → `-[NSWindow _addTabbedWindow:ordered:]`
///     → `-[NSWindowStackController _syncInactiveTabWindowSizesToWindow:]`
///     → `-[NSWindow _setFrameCommon:display:fromServer:]`
///     → `_layoutViewTree` → `NSHostingView.layout()`
///     → … → `PreviewRepresentable.makeNSView` → `PreviewPipeline.apply`
///
/// — every tab already in the group was resized to fit the newcomer, and every
/// one of those resizes laid that tab's view tree out synchronously, down to a
/// complete Markdown→HTML render of its document. Restoring N files paid that
/// bill N² times. The working-set cap bounds N at twelve; it does nothing about
/// the per-tab cost, which is what this pin is about.
///
/// A unit test cannot measure AppKit's internal layout, so what is pinned here
/// is the SHAPE the fix has to hold: the number of times the restore presents a
/// window — the act that triggers the sync — must not grow with the number of
/// files restored, and each window must already carry the tab group's frame by
/// the time it is merged, so the sync has nothing to resize.
///
/// ROUND TWO, measured on the staged build of the fix (twelve ad-hoc files,
/// 2000-file workspace): the quadratic term was gone and the app was STILL
/// frozen. Window on screen at t+0.7s, first event serviced at t+8.6s, and the
/// samples put 47.8% of the main thread under
/// `_syncInactiveTabWindowSizesToWindow:` → `CA::Transaction::commit()` →
/// `_layoutSubtreeIfNeededAndAllowTemporaryEngine:`. A CoreAnimation commit is
/// process-wide, so the insertion lays out the NEWCOMER's own hosting view —
/// brand new, entirely dirty — synchronously, whether or not its tab is
/// selected. A background tab does not "wait to be looked at"; it pays its own
/// first full SwiftUI layout, ~0.6s, the moment it joins the group.
///
/// That cost belongs to the tab. The freeze does not: twelve of them in one
/// loop is a single uninterruptible main-thread block, with a window already on
/// screen for the user to click at. So the restore now drains its queue one tab
/// per run-loop turn, which is the second thing pinned here.
@MainActor
final class StartupRestoreTabCostTests: XCTestCase {
  /// THE COST PIN. Three files and eight files must cost the SAME number of
  /// window presentations: one, at the end. Before the fix each restored file
  /// was presented on its own — and paid for every tab already in the group.
  func testPresentationCostDoesNotGrowWithTheNumberOfRestoredFiles() {
    let small = restore(fileCount: 3)
    let large = restore(fileCount: 8)

    XCTAssertEqual(
      [small.probe.activations.count, large.probe.activations.count], [1, 1],
      "the restore presents a window per file: each presentation makes AppKit re-sync — and so"
        + " re-lay-out — every tab already in the group, which is the quadratic launch cost")
    XCTAssertEqual(
      [small.probe.backgroundMerges.count, large.probe.backgroundMerges.count], [3, 8],
      "every restored file must still become a tab — cheap is not the same as absent")
    XCTAssertTrue(
      small.probe.foregroundMerges.isEmpty && large.probe.foregroundMerges.isEmpty,
      "a restored tab that is merged in front becomes the selected tab, which is exactly the"
        + " presentation this restore is not supposed to be paying for")
  }

  /// THE TURN PIN — the second measured failure, and the one the user actually
  /// sees. Each insertion ends in a CoreAnimation commit that lays the new tab's
  /// whole view tree out on the spot; the cost is the tab's own and is not this
  /// pass's to avoid, but paying twelve of them back to back is one main-thread
  /// block the app cannot interrupt — and the window is on screen for all of it.
  ///
  /// So the budget is per TURN, not per pass: the restore may build at most ONE
  /// window before it gives the run loop back. Counted here in windows built,
  /// because a window built is the layout paid.
  func testTheRestoreBuildsAtMostOneTabPerRunLoopTurn() {
    let fixture = makeFixture()
    let refs = (0..<4).map { DocumentRef(id: fixture.url(at: $0), isAdHoc: true) }

    fixture.registry.openRestoredDocuments(refs)

    XCTAssertEqual(
      fixture.probe.createdWindows.count, 1,
      "the restore built every tab in the turn it was called in — each of those constructions"
        + " ends in a synchronous full layout of the new tab, so the whole working set is one"
        + " uninterruptible main-thread block with the window already on screen")
    XCTAssertTrue(
      fixture.probe.activations.isEmpty,
      "the restore's closing activation belongs at the END of the pass, not before the tabs it"
        + " is supposed to be waiting for")

    var builtPerTurn = [fixture.probe.createdWindows.count]
    while fixture.runOneScheduledStep() {
      builtPerTurn.append(fixture.probe.createdWindows.count)
    }

    XCTAssertEqual(
      builtPerTurn, [1, 2, 3, 4],
      "a turn built more than one tab, or the queue stopped draining before the working set"
        + " was open")
    XCTAssertEqual(
      fixture.probe.activations.count, 1,
      "spreading the pass over turns must not turn one closing activation into one per tab")
  }

  /// THE FRAME PIN — the other half, and the reason the sync had work to do at
  /// all. The factory sizes a new window to its own recipe, so every insertion
  /// handed AppKit a frame that disagreed with the group's. A window adopts the
  /// group's frame either way; doing it HERE, before the window has ever been
  /// shown, is free.
  func testARestoredWindowAlreadyCarriesTheTabGroupFrameWhenItIsMerged() {
    let restored = restore(fileCount: 4)

    XCTAssertEqual(
      restored.probe.framesMatchingTargetAtMerge.count, 4,
      "the fixture did not merge every window; the pin below would be vacuous")
    XCTAssertTrue(
      restored.probe.framesMatchingTargetAtMerge.allSatisfy { $0 },
      "a window joined the tab group with a frame of its own, so AppKit resized every window"
        + " already in the group to match it — one full layout of each, per restored file")
  }

  /// THE END STATE, unchanged. Same files, same order, and the window in front
  /// when the restore finishes is the last file it opened — exactly where a run
  /// of interactive opens would have left the user.
  func testTheRestoreLeavesTheSameFilesOpenAndTheLastOneInFront() {
    let restored = restore(fileCount: 3)

    XCTAssertEqual(
      restored.registry.openDocuments.map(\.identity),
      restored.refs.map { .file($0.id.standardizedFileURL) },
      "the restore must open exactly the files it was given, in the order it was given them")
    XCTAssertTrue(
      restored.probe.activations.last === restored.probe.createdWindows.last,
      "the front window after a restore is the last file restored, as it is after a run of"
        + " ordinary opens")
  }

  /// THE FRONT PIN. Measured on the staged build: the tab the user left in
  /// front (`adhoc-11`) came back in front at t≈7.7s and was shoved aside at
  /// t≈8.3s by `adhoc-00` — the file the LAUNCH WINDOW had loaded into itself
  /// rather than opening as a tab.
  ///
  /// That window never went through `open()`, so its document was unknown to
  /// the registry until its SwiftUI accessor attached — asynchronously, and so
  /// after the pass had already fronted its last tab. `completeAttach` read the
  /// document as ordered for the first time and brought its window front. The
  /// restore's own decision has to outlive an attach that is merely late.
  func testTheWindowThatLoadedAFileInPlaceDoesNotStealTheRestoresFront() {
    let fixture = makeFixture()
    let inPlace = fixture.url(at: 0)
    let refs = (1..<4).map { DocumentRef(id: fixture.url(at: $0), isAdHoc: true) }

    // The launch window loaded `inPlace` into itself, which is what
    // `reopenRestoredOpenFiles` does with the first restored ref before handing
    // the rest to the registry.
    fixture.registry.noteDocumentAlreadyOnScreen(inPlace)
    fixture.registry.openRestoredDocuments(refs)
    fixture.drain()
    let frontAfterRestore = fixture.probe.activations.last

    // …and only now does that window's accessor get around to reporting what it
    // holds. In the app this is a `DispatchQueue.main.async` off a SwiftUI
    // render pass; the render itself happens inside the first insertion's
    // CoreAnimation commit, so the attach lands after the whole pass.
    fixture.registry.attach(fixture.launchWindow, documentID: inPlace, title: "adhoc-00")

    XCTAssertTrue(
      frontAfterRestore === fixture.probe.createdWindows.last,
      "the fixture did not leave the last restored tab in front, so the pin below is vacuous")
    XCTAssertTrue(
      fixture.probe.activations.last === fixture.probe.createdWindows.last,
      "a late attach pulled the launch window in front of the tab the restore put there — the"
        + " user gets back the FIRST file of the working set instead of the one they were on")
  }

  /// CONTROL for the pin above: an attach that is the document's genuine first
  /// presentation still fronts its window. The fix must be "the restore already
  /// ordered this document", not "attaches no longer order anything".
  func testAnAttachForADocumentNothingHasPresentedStillFrontsItsWindow() {
    let fixture = makeFixture()

    fixture.registry.attach(fixture.launchWindow, documentID: fixture.url(at: 0), title: "fresh")

    XCTAssertEqual(
      fixture.probe.activations.count, 1,
      "a window that started showing a document nothing else has presented has no other way of"
        + " getting in front")
  }

  /// CONTROL: the interactive route is untouched. A user opening a document
  /// wants it NOW — in front, with the app activated. Only the bulk restore
  /// joins the group quietly.
  func testAnInteractiveOpenStillFrontsItsTabImmediately() {
    let fixture = makeFixture()
    let ref = DocumentRef(id: fixture.url(at: 0), isAdHoc: true)

    fixture.registry.open(ref)

    XCTAssertEqual(fixture.probe.foregroundMerges.count, 1)
    XCTAssertTrue(fixture.probe.backgroundMerges.isEmpty)
    XCTAssertEqual(fixture.probe.activations.count, 1)
    XCTAssertTrue(
      fixture.probe.restoreSteps.isEmpty,
      "an interactive open must arrive in the turn the user asked for it, not on the restore's"
        + " one-tab-per-turn schedule")
  }

  /// CONTROL: with no tab group to join, a restored window has no other way
  /// onto the screen. Quiet must never mean invisible.
  func testARestoredWindowWithNoGroupToJoinIsStillPresented() {
    let fixture = makeFixture(hasTabGroupToJoin: false)
    let refs = (0..<2).map { DocumentRef(id: fixture.url(at: $0), isAdHoc: true) }

    fixture.registry.openRestoredDocuments(refs)
    fixture.drain()

    XCTAssertTrue(fixture.probe.backgroundMerges.isEmpty)
    XCTAssertEqual(
      fixture.probe.activations.count, 3,
      "two windows presented on their own, plus the restore's closing activation")
  }

  /// THE SCHEDULER ITSELF. Every pin above drives the steps by hand, so none of
  /// them would notice a production scheduler that never fires — a restore that
  /// opens one tab and stops. This one omits the seam and lets the registry use
  /// the schedule it ships with.
  func testTheShippedSchedulerDrainsTheWholeWorkingSetOnItsOwn() {
    let probe = RestoreCostProbe()
    let target = makeWindow(frame: NSRect(x: 120, y: 140, width: 700, height: 500))
    probe.windows.append(target)
    // No `scheduleRestoreStep:` argument — this is the default the app runs on.
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, window in probe.foregroundMerges.append(window) },
      mergeWindowIntoTabsBehind: { _, window in probe.backgroundMerges.append(window) },
      orderAndActivateWindow: { probe.activations.append($0) },
      currentMergeTarget: { target },
      makeDocumentWindow: { [weak probe] _, _ in
        guard let probe else { return nil }
        let window = self.makeWindow(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        probe.windows.append(window)
        probe.createdWindows.append(window)
        return window
      })
    let refs = (0..<12).map {
      DocumentRef(
        id: URL(fileURLWithPath: "/tmp/pensieve-restore-schedule-\($0).md").standardizedFileURL,
        isAdHoc: true)
    }

    registry.openRestoredDocuments(refs)

    let drained = expectation(description: "the restore drains its queue")
    poll(until: { probe.activations.count == 1 }, fulfilling: drained)
    wait(for: [drained], timeout: 10)
    XCTAssertEqual(
      probe.createdWindows.count, 12,
      "the shipped schedule stopped draining part-way, so a real launch would come up with a"
        + " fraction of the working set open")
  }

  /// THE WIRING for the pin above. The registry can only hold its ground if
  /// somebody tells it the launch window already has a document on screen, and
  /// the only party that knows is the controller: it loads the first restored
  /// ref into its OWN window instead of opening a tab for it. It has to say so
  /// before it hands the rest to the bulk route.
  func testTheLaunchRestoreAnnouncesTheFileItLoadsInPlace() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRestoreFront-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let notes = try (0..<3).map { index -> URL in
      let url = folder.appendingPathComponent("adhoc-\(index).md").standardizedFileURL
      try "note \(index)".write(to: url, atomically: true, encoding: .utf8)
      return url
    }

    let appState = AppState()
    appState.openFiles = notes.map { DocumentRef(id: $0, isAdHoc: true) }
    let indexDatabase = IndexDatabase(databaseURL: folder.appendingPathComponent("index.db"))
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: folder.appendingPathComponent("workspace.json")),
        indexDatabase: indexDatabase,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveRestoreFront"))),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      documentWindowRegistry: DocumentWindowRegistry(
        scheduleLauncherWindowSweep: { _ in }, currentMergeTarget: { nil }),
      startupRestore: ApplicationStartupRestore())
    var announced: [URL] = []
    var bulkRestored: [[URL]] = []
    controller.requestNoteDocumentAlreadyOnScreen = { announced.append($0) }
    controller.requestOpenRestoredDocumentWindows = { bulkRestored.append($0.map(\.id)) }

    controller.start(intent: .coldLaunch)

    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL, notes[0],
      "the launch window did not take the first restored file in place, so this pin is not"
        + " exercising the path it is about")
    XCTAssertEqual(
      announced, [notes[0]],
      "the file the launch window loaded into itself was never announced as already on screen —"
        + " its late attach counts as a first presentation and steals the front from the tab the"
        + " restore fronted")
    XCTAssertEqual(
      bulkRestored, [[notes[1], notes[2]]],
      "the bulk route must still get exactly the refs the launch window did NOT take")
  }

  // MARK: - Fixture

  private func poll(
    until condition: @escaping @MainActor () -> Bool,
    fulfilling expectation: XCTestExpectation
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
      MainActor.assumeIsolated {
        if condition() {
          expectation.fulfill()
        } else {
          self.poll(until: condition, fulfilling: expectation)
        }
      }
    }
  }

  private func restore(fileCount: Int) -> RestoreFixture {
    let fixture = makeFixture()
    let refs = (0..<fileCount).map { DocumentRef(id: fixture.url(at: $0), isAdHoc: true) }
    fixture.registry.openRestoredDocuments(refs)
    fixture.drain()
    return RestoreFixture(registry: fixture.registry, probe: fixture.probe, refs: refs)
  }

  private func makeFixture(hasTabGroupToJoin: Bool = true) -> Fixture {
    let probe = RestoreCostProbe()
    // The launch window: already on screen, already sized the way the user left
    // it — deliberately NOT the size the factory builds new windows at, which
    // is what gave AppKit's tab-size sync something to do on every insertion.
    let target = makeWindow(frame: NSRect(x: 120, y: 140, width: 700, height: 500))
    probe.windows.append(target)
    let resolvedTarget: NSWindow? = hasTabGroupToJoin ? target : nil
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in
        XCTFail(
          "a launch restore defers through scheduleRestoreStep, never through the modal deferral"
            + " seam — reaching this one means an open was postponed, not scheduled")
      },
      scheduleLauncherWindowSweep: { _ in },
      // Held, not run: every pin here decides for itself how many run-loop turns
      // the restore is allowed to have had.
      scheduleRestoreStep: { [weak probe] work in probe?.restoreSteps.append(work) },
      mergeWindowIntoTabs: { _, window in probe.foregroundMerges.append(window) },
      mergeWindowIntoTabsBehind: { target, window in
        probe.backgroundMerges.append(window)
        probe.framesMatchingTargetAtMerge.append(window.frame == target.frame)
      },
      orderAndActivateWindow: { probe.activations.append($0) },
      currentMergeTarget: { resolvedTarget },
      makeDocumentWindow: { [weak probe] _, _ in
        guard let probe else { return nil }
        let window = self.makeWindow(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        probe.windows.append(window)
        probe.createdWindows.append(window)
        return window
      })
    return Fixture(registry: registry, probe: probe, launchWindow: target)
  }

  private func makeWindow(frame: NSRect) -> NSWindow {
    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    addTeardownBlock {
      await MainActor.run { window.close() }
    }
    return window
  }
}

@MainActor
private final class RestoreCostProbe {
  var foregroundMerges: [NSWindow] = []
  var backgroundMerges: [NSWindow] = []
  var framesMatchingTargetAtMerge: [Bool] = []
  var activations: [NSWindow] = []
  var createdWindows: [NSWindow] = []
  /// The restore's continuations, one per run-loop turn it asked for.
  var restoreSteps: [@MainActor () -> Void] = []
  /// Every window the fixture built, kept alive for the length of the test —
  /// the registry only holds weak references.
  var windows: [NSWindow] = []
}

@MainActor
private struct Fixture {
  let registry: DocumentWindowRegistry
  let probe: RestoreCostProbe
  /// The window the app launched into — the one that loads the first restored
  /// file in place instead of opening a tab for it.
  let launchWindow: NSWindow

  func url(at index: Int) -> URL {
    URL(fileURLWithPath: "/tmp/pensieve-restore-cost-\(index).md").standardizedFileURL
  }

  /// Runs one pending restore step, standing in for one run-loop turn.
  /// Returns false when the restore asked for no further turn.
  @discardableResult
  func runOneScheduledStep() -> Bool {
    guard !probe.restoreSteps.isEmpty else { return false }
    probe.restoreSteps.removeFirst()()
    return true
  }

  func drain() {
    while runOneScheduledStep() {}
  }
}

@MainActor
private struct RestoreFixture {
  let registry: DocumentWindowRegistry
  let probe: RestoreCostProbe
  let refs: [DocumentRef]
}
