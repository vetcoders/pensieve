import Foundation
import XCTest

@testable import Pensieve

/// The quit has to make the saved working set DURABLE, not merely written.
///
/// `UserDefaults` hands every change to cfprefsd, which updates the backing
/// plist on its own schedule — measured on this machine at up to ~14 s AFTER the
/// writing process had already exited. So the state the next launch restores
/// from was still in flight while the app looked entirely gone, and a flush that
/// late could land on top of an external change made to a quit app's saved state
/// in the meantime.
///
/// Asserted through a counting `UserDefaults` rather than by watching a plist:
/// WHEN that file appears is cfprefsd's business, which is the whole problem.
@MainActor
final class WorkingSetDurabilityAtQuitTests: XCTestCase {

  /// The seam itself: the quit sequence flushes the domain, exactly once.
  func testQuitFlushesTheSavedWorkingSet() async throws {
    let fixture = try makeFixture()

    XCTAssertEqual(
      fixture.defaults.synchronizeCount, 0,
      "fixture precondition: nothing flushes until the process is leaving")

    await fixture.sequence.run()

    XCTAssertEqual(
      fixture.defaults.synchronizeCount, 1,
      "quit must hand the saved workspace to disk synchronously, exactly once")
  }

  /// The flush is about WHEN state is durable, never about what it contains. A
  /// quit that edited the working set on the way out would be a far worse bug
  /// than the one being fixed.
  func testQuitDoesNotChangeWhatTheWorkingSetHolds() async throws {
    let fixture = try makeFixture()
    let noteURL = fixture.sandbox.appendingPathComponent("open-note.md").standardizedFileURL
    try "# open-note".write(to: noteURL, atomically: true, encoding: .utf8)
    try fixture.bookmarkStore.persistFile(url: noteURL, into: AppState())

    let before = fixture.restoredFileURLs()
    XCTAssertEqual(before, [noteURL], "fixture precondition: there is a working set to preserve")

    await fixture.sequence.run()

    XCTAssertEqual(fixture.restoredFileURLs(), before)
  }

  /// The flush must not be reachable only through the fully-awaited `run()`: the
  /// production entry point is the synchronous one, which pumps the run loop
  /// around a budgeted task. If the flush were placed outside that task's reach,
  /// this is the pin that would notice.
  func testTheSynchronousQuitEntryPointFlushesToo() throws {
    let fixture = try makeFixture()

    fixture.sequence.runBlockingMainRunLoop()

    XCTAssertEqual(
      fixture.defaults.synchronizeCount, 1,
      "applicationWillTerminate's own entry point must flush, not only the awaitable one")
  }

  // MARK: - Fixture

  @MainActor
  private struct Fixture {
    let sequence: TerminationSequence
    let defaults: FlushCountingDefaults
    let bookmarkStore: BookmarkStore
    let sandbox: URL

    func restoredFileURLs() -> [URL] {
      BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState()).fileURLs
        .map(\.standardizedFileURL)
    }
  }

  @MainActor
  private func makeFixture() throws -> Fixture {
    let sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkingSetDurabilityTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }

    let suiteName = EphemeralDefaults.suiteName(prefix: "PensieveWorkingSetDurability")
    let defaults = try XCTUnwrap(FlushCountingDefaults(suiteName: suiteName))
    addTeardownBlock { EphemeralDefaults.destroy(suiteName: suiteName) }

    let bookmarkStore = BookmarkStore(defaults: defaults)
    let indexDatabase = IndexDatabase(
      databaseURL: sandbox.appendingPathComponent("index.db", isDirectory: false))
    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: sandbox.appendingPathComponent("workspace.json", isDirectory: false)),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: sandbox.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    )

    return Fixture(
      sequence: TerminationSequence(
        registry: DocumentWindowRegistry(),
        indexDatabase: indexDatabase,
        folderManager: manager,
        autosaver: Autosaver(),
        launchIntentCoordinator: LaunchIntentCoordinator()
      ),
      defaults: defaults,
      bookmarkStore: bookmarkStore,
      sandbox: sandbox
    )
  }
}

/// `UserDefaults` that counts `synchronize()` calls, so the quit flush can be
/// asserted as a seam instead of inferred from a plist whose write timing is
/// cfprefsd's business. Backed by an absolute-path suite, so it strands nothing
/// in `~/Library/Preferences`.
final class FlushCountingDefaults: UserDefaults {
  private let lock = NSLock()
  private nonisolated(unsafe) var flushes = 0

  var synchronizeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return flushes
  }

  override func synchronize() -> Bool {
    lock.lock()
    flushes += 1
    lock.unlock()
    return super.synchronize()
  }
}
