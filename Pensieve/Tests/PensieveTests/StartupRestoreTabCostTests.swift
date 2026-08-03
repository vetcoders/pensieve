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
  }

  /// CONTROL: with no tab group to join, a restored window has no other way
  /// onto the screen. Quiet must never mean invisible.
  func testARestoredWindowWithNoGroupToJoinIsStillPresented() {
    let fixture = makeFixture(hasTabGroupToJoin: false)
    let refs = (0..<2).map { DocumentRef(id: fixture.url(at: $0), isAdHoc: true) }

    fixture.registry.openRestoredDocuments(refs)

    XCTAssertTrue(fixture.probe.backgroundMerges.isEmpty)
    XCTAssertEqual(
      fixture.probe.activations.count, 3,
      "two windows presented on their own, plus the restore's closing activation")
  }

  // MARK: - Fixture

  private func restore(fileCount: Int) -> RestoreFixture {
    let fixture = makeFixture()
    let refs = (0..<fileCount).map { DocumentRef(id: fixture.url(at: $0), isAdHoc: true) }
    fixture.registry.openRestoredDocuments(refs)
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
      scheduleDeferredMainWork: { _ in XCTFail("a launch restore must not defer its opens") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, window in probe.foregroundMerges.append(window) },
      mergeWindowIntoTabsBehind: { target, window in
        probe.backgroundMerges.append(window)
        probe.framesMatchingTargetAtMerge.append(window.frame == target.frame)
      },
      orderAndActivateWindow: { probe.activations.append($0) },
      currentMergeTarget: { resolvedTarget },
      makeDocumentWindow: { [weak probe] _ in
        guard let probe else { return nil }
        let window = self.makeWindow(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        probe.windows.append(window)
        probe.createdWindows.append(window)
        return window
      })
    return Fixture(registry: registry, probe: probe)
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
  /// Every window the fixture built, kept alive for the length of the test —
  /// the registry only holds weak references.
  var windows: [NSWindow] = []
}

@MainActor
private struct Fixture {
  let registry: DocumentWindowRegistry
  let probe: RestoreCostProbe

  func url(at index: Int) -> URL {
    URL(fileURLWithPath: "/tmp/pensieve-restore-cost-\(index).md").standardizedFileURL
  }
}

@MainActor
private struct RestoreFixture {
  let registry: DocumentWindowRegistry
  let probe: RestoreCostProbe
  let refs: [DocumentRef]
}
