import Foundation
import XCTest

@testable import Pensieve

/// The working set has a declared size — `WorkspaceStore.maxOpenFiles` — and
/// until now only the LIVE list obeyed it.
///
/// `pruneOpenFilesWorkingSet` truncated `appState.openFiles` in memory and
/// stopped there; `BookmarkStore.persistFile` kept appending, and the only paths
/// that ever shrank that key were an explicit close of an Open Files row and the
/// removal of a workspace root. The restore then read every surviving bookmark
/// straight into `appState.openFiles` with no prune at all.
///
/// That was invisible for as long as a relaunch opened nothing. Once the startup
/// restore began opening the working set for real, it became "every ad-hoc file
/// you have ever opened and not explicitly closed comes back as a tab" — dozens
/// of them, against a cap of twelve.
///
/// So the cap now governs both halves, and it governs them together: whatever
/// the prune drops out of the list, it also drops out of the persisted set. A
/// bookmark with no row is the same invisible state as a row with no window.
///
/// These pins span a simulated relaunch — fresh stores over the SAME defaults —
/// because the whole failure lived across process boundaries.
@MainActor
final class StartupRestoreWorkingSetCapTests: XCTestCase {
  private var cap: Int { WorkspaceStore.maxOpenFiles }

  /// THE LEGACY CASE, and the one that matters for anyone already running
  /// Pensieve: a defaults key that accumulated far past the cap before this
  /// change existed. Nothing in-session can fix that install — only the restore
  /// can — so the restore is where the cap has to bite.
  func testALaunchRestoresAtMostTheWorkingSetCap() throws {
    let harness = try makeHarness()
    let notes = try (1...(cap + 6)).map { index in
      try harness.writeNote(named: String(format: "note-%02d.md", index))
    }

    // Straight into the persisted key, bypassing the live list entirely — the
    // shape an older build left behind.
    let writer = BookmarkStore(defaults: harness.defaults)
    let seed = AppState()
    for note in notes { try writer.persistFile(url: note, into: seed) }

    let relaunched = try harness.relaunch()

    XCTAssertEqual(
      relaunched.openFiles.map(\.url.lastPathComponent),
      notes.suffix(cap).map(\.lastPathComponent),
      "the launch restored the whole accumulated history instead of the newest \(cap) — every"
        + " one of those refs is a tab the startup restore now opens for real")
  }

  /// The other half of the contract: what the prune drops, it drops everywhere.
  /// Leaving the evicted bookmarks in the key would keep the next launch
  /// resolving files that have no row and no window — the invisible state this
  /// branch spent its previous round removing — and would keep their
  /// security-scoped grants alive for nothing.
  func testEvictedFilesLoseTheirBookmarkTooNotJustTheirRow() throws {
    let harness = try makeHarness()
    let notes = try (1...(cap + 6)).map { index in
      try harness.writeNote(named: String(format: "note-%02d.md", index))
    }

    let session = AppState()
    for note in notes {
      XCTAssertNotNil(harness.manager.registerOpenFile(url: note, into: session))
    }
    XCTAssertEqual(session.openFiles.count, cap, "the live list has always obeyed the cap")

    let persisted = BookmarkStore(defaults: harness.defaults)
      .restoreWorkspace(into: AppState())
      .fileURLs
      .map(\.standardizedFileURL.path)

    XCTAssertEqual(
      Set(persisted), Set(session.openFiles.map(\.url.path)),
      "the persisted set outgrew the list it is supposed to be the record of")
  }

  /// CONTROL: a working set that fits is untouched — same files, same order,
  /// nothing pruned. Without this leg the cap could be implemented as "keep the
  /// last twelve of whatever you find" and still pass the pins above while
  /// quietly reordering an ordinary session.
  func testAWorkingSetUnderTheCapIsRestoredWhole() throws {
    let harness = try makeHarness()
    let notes = try (1...5).map { index in
      try harness.writeNote(named: String(format: "small-%02d.md", index))
    }

    let session = AppState()
    for note in notes {
      XCTAssertNotNil(harness.manager.registerOpenFile(url: note, into: session))
    }

    let relaunched = try harness.relaunch()

    XCTAssertEqual(
      relaunched.openFiles.map(\.url.lastPathComponent),
      notes.map(\.lastPathComponent),
      "a session well inside the cap must come back exactly as it was left")
  }

  /// CONTROL: the cap is applied ONCE per restore, not compounded. Two launches
  /// in a row over the same defaults must land on the same twelve files — a
  /// prune that re-read its own output could walk the working set down to
  /// nothing over a few launches.
  func testASecondLaunchRestoresTheSameSetAsTheFirst() throws {
    let harness = try makeHarness()
    let notes = try (1...(cap + 6)).map { index in
      try harness.writeNote(named: String(format: "note-%02d.md", index))
    }

    let writer = BookmarkStore(defaults: harness.defaults)
    let seed = AppState()
    for note in notes { try writer.persistFile(url: note, into: seed) }

    let first = try harness.relaunch()
    let second = try harness.relaunch()

    XCTAssertEqual(
      second.openFiles.map(\.url.lastPathComponent),
      first.openFiles.map(\.url.lastPathComponent),
      "the second launch disagreed with the first — the cap is eating its own output")
    XCTAssertEqual(second.openFiles.count, cap)
  }

  // MARK: - Harness

  private func makeHarness() throws -> RestoreCapHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveStartupRestoreCap-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }

    let defaults = makeEphemeralDefaults(prefix: "PensieveStartupRestoreCap")
    return RestoreCapHarness(
      root: root,
      support: support,
      defaults: defaults,
      manager: Self.makeManager(support: support, bookmarkStore: BookmarkStore(defaults: defaults)),
      makeManager: Self.makeManager
    )
  }

  private static func makeManager(support: URL, bookmarkStore: BookmarkStore) -> FolderManager {
    FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("index-\(UUID().uuidString).db")),
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    )
  }
}

@MainActor
private struct RestoreCapHarness {
  let root: URL
  let support: URL
  let defaults: UserDefaults
  let manager: FolderManager
  let makeManager: (URL, BookmarkStore) -> FolderManager

  func writeNote(named name: String) throws -> URL {
    let url = root.appendingPathComponent(name).standardizedFileURL
    try name.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// The next launch: brand-new stores over the same persisted defaults, with
  /// nothing carried over in memory.
  func relaunch() throws -> AppState {
    let appState = AppState()
    makeManager(support, BookmarkStore(defaults: defaults)).restoreLastFolder(into: appState)
    return appState
  }
}
