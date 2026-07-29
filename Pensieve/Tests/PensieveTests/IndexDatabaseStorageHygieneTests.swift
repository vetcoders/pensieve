//  IndexDatabaseStorageHygieneTests.swift
//  PensieveTests
//
//  W1-B (index hygiene): pins the disk-space contract of the index database.
//  `DatabasePool` implies WAL, and SQLite's own auto-checkpoint is PASSIVE — it
//  recycles WAL frames but never shrinks the `-wal` file, which is how this
//  project measured a 3.7 GB index.db next to a 2.2 GB index.db-wal during a
//  reindex storm. These tests assert on FILE SIZES and SQLite pragmas, not on
//  "the maintenance function ran": a green checkpoint call that leaves the WAL
//  at its high-water mark would be exactly the bug this cut exists to prevent.

import AppKit
import GRDB
import XCTest

@testable import Pensieve

@MainActor
final class IndexDatabaseStorageHygieneTests: XCTestCase {

  // MARK: - Fixtures

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveStorageHygieneTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func fileSize(at url: URL) -> Int64 {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? Int64
    else { return 0 }
    return size
  }

  private func walSize(for databaseURL: URL) -> Int64 {
    fileSize(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
  }

  /// Reads a pragma through an INDEPENDENT connection, so the assertion reflects
  /// the on-disk database rather than the state of the pool under test.
  private func pragmaValue(_ pragma: String, at databaseURL: URL) throws -> Int {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA \(pragma)") ?? 0 }
  }

  private func documentRef(root: URL, name: String) -> DocumentRef {
    DocumentRef(
      id: root.appendingPathComponent(name).standardizedFileURL,
      rootURL: root,
      relativePath: name
    )
  }

  /// Writes `count` documents of ~24 KiB each through the synchronous index path
  /// (one transaction per document, no maintenance hook), then deletes
  /// `deleting` of them — the upsert+delete churn a reindex storm produces.
  /// Returns the paths that are still indexed.
  @discardableResult
  private func churn(
    database: IndexDatabase,
    root: URL,
    count: Int,
    deleting: Int
  ) -> [String] {
    let body = String(repeating: "pensieve storage hygiene churn payload ", count: 600)
    var paths: [String] = []
    for index in 0..<count {
      let ref = documentRef(root: root, name: "churn-\(index).md")
      database.index(document: ref, body: "\(body) \(index)")
      paths.append(ref.url.path)
    }
    let deletedPaths = Array(paths.prefix(deleting))
    if !deletedPaths.isEmpty {
      database.updateSearchIndex(upserting: [], deletingPaths: deletedPaths)
    }
    return Array(paths.dropFirst(deleting))
  }

  // MARK: - auto_vacuum provisioning

  /// A fresh index.db must be born `auto_vacuum = INCREMENTAL` (mode 2). SQLite
  /// only accepts the mode change while the file header does not exist yet —
  /// after `journal_mode = WAL` it silently ignores the pragma — so this pins the
  /// ordering that `IndexDatabase.makeConfiguration` relies on. Without it, every
  /// page freed by a delete stays inside the file forever.
  func testFreshIndexDatabaseIsCreatedWithIncrementalAutoVacuum() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 2,
      "fresh index.db must use auto_vacuum = INCREMENTAL so freed pages can be reclaimed")
  }

  /// Migration path for databases created before this cut: they carry
  /// `auto_vacuum = 0`, and SQLite only switches modes through a full VACUUM.
  /// Workspace close performs that one-shot conversion.
  func testLegacyDatabaseIsConvertedToIncrementalAutoVacuumOnWorkspaceClose() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    // Stand up the file the pre-hygiene way: WAL first, so the header exists and
    // auto_vacuum can no longer be set by a pragma alone.
    let legacyPool = try DatabasePool(path: databaseURL.path)
    try await legacyPool.write { db in
      try db.execute(sql: "CREATE TABLE legacy_marker(id INTEGER PRIMARY KEY)")
    }
    // Release the fixture connection so the conversion VACUUM runs against the
    // same single-writer situation the app has at workspace close.
    try legacyPool.close()
    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 0,
      "fixture precondition: the legacy database must start in auto_vacuum = NONE")

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)
    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 0,
      "opening an existing database must not silently rewrite it — only maintenance may VACUUM")

    await database.performMaintenanceInBackground(reason: .workspaceClose)

    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 2,
      "workspace-close maintenance must convert a legacy database to INCREMENTAL auto_vacuum")
  }

  // MARK: - WAL bound

  /// The headline assertion: after churn the `-wal` file has a real high-water
  /// mark, and a workspace-close checkpoint gives that space back.
  ///
  /// Thresholds: the churn writes ~7 MiB across ~300 transactions, so the WAL
  /// high-water mark sits around SQLite's 4 MiB auto-checkpoint threshold —
  /// asserting `>= 512 KiB` before keeps the test honest (a vacuous run would
  /// fail here) with a wide margin. A TRUNCATE checkpoint sets the WAL to 0
  /// bytes; the `<= 64 KiB` ceiling afterwards absorbs any incidental frame a
  /// later connection could append without accepting a still-growing log.
  func testWorkspaceCloseMaintenanceTruncatesWalAfterChurn() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 150)

    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThanOrEqual(
      walBefore, 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL, otherwise the truncate proves nothing"
    )

    await database.performMaintenanceInBackground(reason: .workspaceClose)

    let walAfter = walSize(for: databaseURL)
    XCTAssertLessThanOrEqual(
      walAfter, 64 * 1024,
      "TRUNCATE checkpoint must hand the WAL back to the filesystem (was \(walBefore) bytes, now \(walAfter))"
    )
  }

  /// The batch hook must NOT take the barrier lock on every small write — that
  /// would put a full checkpoint on the save/watcher path. Below the 16 MiB
  /// threshold the WAL is left alone, which a non-zero `-wal` file proves.
  func testIndexBatchMaintenanceIsThrottledBelowWalThreshold() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let noteURL = root.appendingPathComponent("small.md")
    try "tiny delta".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    await database.openInBackground(into: appState)
    XCTAssertNil(appState.lastError)

    let didWrite = await database.updateSearchIndexInBackground(
      upserting: [documentRef(root: root, name: "small.md")],
      deletingPaths: [],
      appState: appState
    )
    XCTAssertTrue(didWrite)
    await database.waitForPendingReindex()

    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "a single small delta must not trigger a barrier checkpoint — the WAL throttle is the point")
  }

  // MARK: - Compaction

  /// Deleting indexed documents leaves free pages behind. In INCREMENTAL mode
  /// maintenance must return them to the filesystem instead of letting the file
  /// keep its worst-ever size.
  func testMaintenanceReclaimsFreePagesAfterDeletes() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 300)

    let freelistBefore = try pragmaValue("freelist_count", at: databaseURL)
    XCTAssertGreaterThan(
      freelistBefore, IndexDatabaseStorageHygieneTests.compactionThresholdPages,
      "fixture precondition: deleting every indexed document must leave free pages to reclaim")
    let sizeBefore = fileSize(at: databaseURL)

    await database.performMaintenanceInBackground(reason: .workspaceClose)

    let freelistAfter = try pragmaValue("freelist_count", at: databaseURL)
    let sizeAfter = fileSize(at: databaseURL)
    XCTAssertLessThan(
      freelistAfter, freelistBefore,
      "incremental_vacuum must consume the freelist (was \(freelistBefore), now \(freelistAfter))")
    XCTAssertLessThan(
      sizeAfter, sizeBefore,
      "reclaimed pages must shrink index.db itself (was \(sizeBefore) bytes, now \(sizeAfter))")
  }

  // MARK: - Production wiring: every quit path checkpoints

  /// The checkpoint used to hang off the custom "Quit Pensieve" menu item alone
  /// (`AppController.applicationShouldTerminate()`), so Dock quit, logout and
  /// shutdown — everything that goes straight to `terminate:` — skipped it.
  ///
  /// This drives the REAL delegate entry point AppKit calls, not a helper: the
  /// bug was never in `checkpointOnTerminate()` (which had its own passing
  /// tests), it was in nothing calling it. Note the delegate hook deliberately
  /// is NOT `applicationShouldTerminate(_:)`: under
  /// `@NSApplicationDelegateAdaptor` that method is never invoked at all
  /// (falsified at runtime on 2026-07-29), so a test pinning it would have gone
  /// green against dead code.
  func testApplicationWillTerminateCheckpointsTheIndexOnQuitPathsWithoutTheMenuItem() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThanOrEqual(
      walBefore, 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL, otherwise the truncate proves nothing"
    )

    let delegate = PensieveAppDelegate()
    // Kept off the process-wide singletons so this test cannot leave a
    // `beginTermination()` latch behind for whatever runs next in the suite.
    delegate.terminationWindowRegistryOverride = DocumentWindowRegistry()
    delegate.terminationIndexDatabaseOverride = database
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification))

    XCTAssertLessThanOrEqual(
      walSize(for: databaseURL), 64 * 1024,
      "quitting without the menu item must still truncate the WAL (was \(walBefore) bytes, now \(walSize(for: databaseURL)))"
    )
  }

  // MARK: - Production wiring: last-root removal orders its delete before maintenance

  /// `removeRoot` on the LAST root closes the workspace and then deletes that
  /// root's paths from the index. Close arms the compaction/checkpoint, so the
  /// two used to be independent tasks with no ordering between them: maintenance
  /// could truncate the WAL and reclaim pages BEFORE the delete, and the delete's
  /// own frames and free pages then stayed on disk — with the workspace gone,
  /// no further batch checkpoint was coming to notice them.
  ///
  /// The assertion is the ordering, not "maintenance ran": awaiting ONLY the
  /// maintenance handle must already imply the delete landed (it is chained
  /// behind it), and the WAL must be back at zero — which can only be true if
  /// the truncate was strictly last.
  ///
  /// Sibling pin:
  /// `testCloseWorkspaceDefersMaintenanceOnlyWhenTheCallerOwnsAFinalIndexWrite`
  /// covers the other half of the fix (close must not fire its own maintenance
  /// alongside the delete). Removing the fix makes THAT one fail deterministically;
  /// this one is a race, and GRDB's write barrier happens to queue behind an
  /// in-flight write often enough that the unordered version still passes it
  /// most of the time — measured, not assumed.
  func testLastRootRemovalDeletesFromTheIndexBeforeMaintenanceCompacts() async throws {
    let sandbox = try makeWorkspaceSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Sized so the DELETE alone writes well past the post-truncate ceiling asserted
    // below: that is what makes the ordering observable rather than merely likely.
    let body = String(repeating: "pensieve last root removal payload ", count: 600)
    for index in 0..<120 {
      try "\(body) \(index)".write(
        to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let harness = try makeWorkspaceHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)

    let indexedDocument = try XCTUnwrap(appState.documents.first)
    XCTAssertFalse(
      harness.indexDatabase.search(
        query: "payload", documents: [indexedDocument], appState: appState
      ).isEmpty,
      "fixture precondition: the workspace must actually be indexed before it is removed")
    XCTAssertEqual(appState.workspaceRoots.count, 1)

    harness.manager.removeRoot(root, into: appState)
    // ONLY the maintenance handle — deliberately not the index-update handle.
    // Under the unordered version this returns while the delete is still in
    // flight, which is precisely the defect.
    await harness.manager.waitForPendingIndexMaintenance()
    // Sampled before any assertion touches the pool, so the reading is the state
    // the maintenance left behind and nothing else.
    let databaseURL = sandbox.support.appendingPathComponent("index.db", isDirectory: false)
    let walAfterMaintenance = walSize(for: databaseURL)

    XCTAssertTrue(
      harness.indexDatabase.search(
        query: "payload", documents: [indexedDocument], appState: appState
      ).isEmpty,
      "close-time maintenance must not complete before the last root's rows are deleted")
    XCTAssertLessThanOrEqual(
      walAfterMaintenance, 64 * 1024,
      "the truncating checkpoint must run AFTER the delete, otherwise the delete's WAL frames "
        + "survive the workspace that would have checkpointed them (WAL is \(walAfterMaintenance) bytes)"
    )
  }

  /// The half of the last-root fix that does not depend on scheduling: a close
  /// whose CALLER still owes the index a write must not arm its own maintenance,
  /// because that is the task that could otherwise compact ahead of the write.
  /// Both directions are asserted, so neither "never runs maintenance" nor
  /// "always runs it" can pass.
  func testCloseWorkspaceDefersMaintenanceOnlyWhenTheCallerOwnsAFinalIndexWrite() async throws {
    for deferring in [true, false] {
      let sandbox = try makeWorkspaceSandbox()
      let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let body = String(repeating: "pensieve close maintenance payload ", count: 600)
      for index in 0..<120 {
        try "\(body) \(index)".write(
          to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
      }

      let harness = try makeWorkspaceHarness(in: sandbox.support)
      let appState = AppState()
      harness.manager.open(url: root, into: appState)
      await settle(harness)

      let databaseURL = sandbox.support.appendingPathComponent("index.db", isDirectory: false)
      XCTAssertGreaterThan(
        walSize(for: databaseURL), 64 * 1024,
        "fixture precondition: indexing the workspace must leave a WAL worth truncating")

      harness.manager.closeWorkspace(into: appState, deferringIndexMaintenance: deferring)
      await harness.manager.waitForPendingIndexMaintenance()
      let wal = walSize(for: databaseURL)

      if deferring {
        XCTAssertGreaterThan(
          wal, 64 * 1024,
          "a deferring close must leave the housekeeping to its caller — firing it here is the "
            + "task that races the caller's final delete (WAL is \(wal) bytes)")
      } else {
        XCTAssertLessThanOrEqual(
          wal, 64 * 1024,
          "an ordinary close is still the point where the WAL gets truncated (WAL is \(wal) bytes)")
      }
    }
  }

  // MARK: - Production wiring: an ordinary save is subject to the WAL threshold

  /// Production saves route a single document through `indexInBackground`. That
  /// path wrote, refreshed and returned — it never consulted the 16 MiB WAL
  /// bound the rest of this cut declares, so a large document (or a long
  /// editing session) could push the log past the ceiling and leave it there
  /// until an unrelated lifecycle event. Threshold lowered through the internal
  /// seam so the test does not have to write 16 MiB to reach the checkpoint.
  func testSingleDocumentSaveCheckpointsOnceTheWalPassesTheThreshold() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThan(
      walBefore, 0, "fixture precondition: the WAL must be non-empty before the save under test")
    database.walCheckpointThresholdBytesOverride = Int64(walBefore)

    let didWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "saved.md"),
      body: "the document the operator just saved",
      appState: appState
    )
    XCTAssertTrue(didWrite)

    XCTAssertLessThanOrEqual(
      walSize(for: databaseURL), 64 * 1024,
      "an ordinary save past the WAL threshold must take the checkpoint like any other index batch "
        + "(was \(walBefore) bytes, now \(walSize(for: databaseURL)))"
    )
  }

  /// The other half of the same contract: below the threshold a save must stay
  /// free. A non-empty `-wal` afterwards proves no barrier checkpoint was taken
  /// on the typing/saving hot path.
  func testSingleDocumentSaveIsThrottledBelowTheWalThreshold() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    await database.openInBackground(into: appState)
    XCTAssertNil(appState.lastError)

    let didWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "small.md"),
      body: "tiny save",
      appState: appState
    )
    XCTAssertTrue(didWrite)

    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "a small save must not take the barrier checkpoint — the 16 MiB throttle is the point")
  }

  /// Ordinary `Close Folder` used to compact against whatever the index happened to have finished.
  /// `closeWorkspace` cancels `FolderManager`'s `indexUpdateTask` — which by its own contract
  /// abandons only the WAIT, never the write underneath, that one belongs to `IndexDatabase`'s
  /// supersede chain — and then armed the housekeeping with nothing to await. A write still queued
  /// behind a predecessor therefore landed AFTER the TRUNCATE, and its frames stayed on disk: the
  /// workspace is gone, so no later close is coming to notice them.
  ///
  /// Sibling `testCloseWorkspaceDefersMaintenanceOnlyWhenTheCallerOwnsAFinalIndexWrite` covers the
  /// last-root special case. This is the general one, and it is deterministic where the older
  /// last-root pin is not: the first write is BLOCKED at an injection seam so a second write is
  /// genuinely still queued when the close runs. That matters because GRDB's
  /// `barrierWriteWithoutTransaction` usually queues behind an already submitted `pool.write`, which
  /// is exactly how the unordered version passes a settle-first test by accident.
  ///
  /// The ordering is asserted directly — the housekeeping must NOT be able to complete while the
  /// queue is still parked — and then corroborated by the after-effects: both queued documents are
  /// in the index and the WAL is back at zero, which can only be true if the truncate went last.
  func testCloseWorkspaceMaintenanceWaitsForTheWholePendingIndexChain() async throws {
    let sandbox = try makeWorkspaceSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let body = String(repeating: "pensieve pending chain payload ", count: 600)
    for index in 0..<60 {
      try "\(body) \(index)".write(
        to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let harness = try makeWorkspaceHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)

    let databaseURL = sandbox.support.appendingPathComponent("index.db", isDirectory: false)
    XCTAssertGreaterThan(
      walSize(for: databaseURL), 64 * 1024,
      "fixture precondition: indexing the workspace must leave a WAL worth truncating")

    // Deliberately OUTSIDE the workspace root: nothing but the two queued writes below can put
    // these documents in the index, so finding them afterwards proves those writes committed.
    let outside = sandbox.root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let firstRef = documentRef(root: outside, name: "queued-first.md")
    let secondRef = documentRef(root: outside, name: "queued-second.md")
    try "\(body) firstqueuedmarker".write(to: firstRef.url, atomically: true, encoding: .utf8)
    try "\(body) secondqueuedmarker".write(to: secondRef.url, atomically: true, encoding: .utf8)

    let gate = FirstWriteGate()
    let indexDatabase = harness.indexDatabase
    indexDatabase.backgroundWriteGateOverride = { await gate.arrive() }

    // Write #1 parks at the gate holding the chain open; write #2 passes the gate and queues behind
    // #1. Each is only submitted once the previous one has ARRIVED, because arrival happens after
    // the write took its place in the supersede chain — that is what makes the queue real.
    Task {
      await indexDatabase.updateSearchIndexInBackground(
        upserting: [firstRef], deletingPaths: [], appState: nil)
    }
    try await waitUntil("the first index write to park at the gate") { await gate.arrivals >= 1 }
    Task {
      await indexDatabase.updateSearchIndexInBackground(
        upserting: [secondRef], deletingPaths: [], appState: nil)
    }
    try await waitUntil("the second index write to queue behind it") { await gate.arrivals >= 2 }

    harness.manager.closeWorkspace(into: appState)

    let maintenanceFinished = CompletionFlag()
    let maintenance = Task { @MainActor in
      await harness.manager.waitForPendingIndexMaintenance()
      maintenanceFinished.isSet = true
    }
    // The ordering assertion. A close that waits for the chain CANNOT finish its housekeeping while
    // both writes are still parked; the unordered version truncates within milliseconds.
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(
      maintenanceFinished.isSet,
      "close-time maintenance completed while two index writes were still queued — the truncate "
        + "would land before their frames")

    await gate.open()
    await maintenance.value
    // Sampled before any assertion touches the pool, so the reading is the state maintenance left.
    let walAfterMaintenance = walSize(for: databaseURL)

    XCTAssertFalse(
      indexDatabase.search(query: "firstqueuedmarker", documents: [firstRef], appState: nil)
        .isEmpty,
      "the first queued write must have committed before maintenance finished")
    XCTAssertFalse(
      indexDatabase.search(query: "secondqueuedmarker", documents: [secondRef], appState: nil)
        .isEmpty,
      "the second queued write must have committed before maintenance finished")
    XCTAssertLessThanOrEqual(
      walAfterMaintenance, 64 * 1024,
      "the truncating checkpoint must run AFTER the whole queue drains, otherwise the queued writes' "
        + "WAL frames survive the workspace that would have checkpointed them (WAL is "
        + "\(walAfterMaintenance) bytes)")
  }

  // MARK: - Production wiring: quit flushes windows and drains the index before it checkpoints

  /// Quit used to checkpoint the index and only THEN let the windows tear down. That is backwards:
  /// `applicationWillTerminate` fires BEFORE `NSWindow.willCloseNotification`, so a dirty window's
  /// final save ran after the truncate — and the save's index write is a background hand-off, so it
  /// landed after that again, if the process lived long enough to run it at all. On a Dock quit or a
  /// logout the last edit's FTS row was simply lost.
  ///
  /// This drives the REAL delegate entry point, not a helper, and asserts the whole contract in one
  /// go: the file on disk carries the edit (the sequence flushed the window itself), the index
  /// carries it (the write was drained), and the WAL is empty (the checkpoint went last). The final
  /// write is deliberately tiny, so it is BELOW the 16 MiB batch threshold and cannot have
  /// checkpointed itself — see `testSingleDocumentSaveIsThrottledBelowTheWalThreshold`, which pins
  /// exactly that. The pre-existing WAL-only test above cannot see any of this: it quits with no
  /// dirty window, so nothing writes after the checkpoint.
  func testTerminationFlushesTheFinalWindowSaveIntoTheIndexBeforeCheckpointing() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let noteURL = root.appendingPathComponent("quit-note.md")
    try "before the quit".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Give the terminal truncate something to reclaim, so "WAL is empty afterwards" cannot be an
    // artefact of nothing ever having been written.
    churn(database: database, root: root, count: 300, deleting: 0)
    XCTAssertGreaterThanOrEqual(
      walSize(for: databaseURL), 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL")

    // A minute-long debounce: the only thing that can reach disk before the process exits is the
    // termination flush itself, never a scheduled autosave.
    let autosaver = Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveTerminationFlushBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )
    let registry = DocumentWindowRegistry()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: folder.appendingPathComponent("workspace.json")),
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveTerminationFlushWorkspace"))),
      documentStore: store,
      indexDatabase: database,
      documentWindowRegistry: registry
    )

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    registry.registerController(controller, for: window)

    let ref = DocumentRef(id: noteURL.standardizedFileURL)
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "before the quit")
    appState.activeDocumentText = "edited moments before the quit"
    store.documentDidChange(appState: appState)
    XCTAssertTrue(appState.activeDocumentDirty)
    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "before the quit",
      "fixture precondition: the debounced write must not have fired yet")

    let delegate = PensieveAppDelegate()
    delegate.terminationWindowRegistryOverride = registry
    delegate.terminationIndexDatabaseOverride = database
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification))

    // Sampled before the search below opens anything against the pool.
    let walAfterQuit = walSize(for: databaseURL)

    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "edited moments before the quit",
      "the quit must flush the window's pending edit itself — willCloseNotification fires after "
        + "applicationWillTerminate, far too late to be the app's final save")
    XCTAssertFalse(
      database.search(query: "moments", documents: [ref], appState: appState).isEmpty,
      "the final save's index write must be drained before the process is allowed to go")
    XCTAssertLessThanOrEqual(
      walAfterQuit, 64 * 1024,
      "the truncating checkpoint must be the LAST step of the quit (WAL is \(walAfterQuit) bytes)")
  }

  /// "Exactly one owner" is a testable claim, so it is tested. The custom ⌘Q item used to take its
  /// own checkpoint before calling `terminate:` — a SECOND checkpoint, and the earlier one, so it ran
  /// before the final window saves it was supposed to protect. It must now be a pure dirty-session
  /// guard that leaves storage alone; the shared `applicationWillTerminate` path that ⌘Q also goes
  /// through is what truncates.
  func testQuitMenuGuardLeavesTheCheckpointToTheTerminationSequence() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThanOrEqual(
      walBefore, 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL")

    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: folder.appendingPathComponent("workspace.json")),
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveQuitGuardWorkspace"))),
      documentStore: DocumentStore(
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveQuitGuardBookmarks")),
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))),
      indexDatabase: database,
      documentWindowRegistry: DocumentWindowRegistry()
    )

    XCTAssertTrue(controller.applicationShouldTerminate(), "a clean session must let the quit pass")
    XCTAssertEqual(
      walSize(for: databaseURL), walBefore,
      "the quit menu guard must not checkpoint: the termination sequence owns the ordering, and a "
        + "checkpoint fired here runs BEFORE the final window saves")

    let delegate = PensieveAppDelegate()
    delegate.terminationWindowRegistryOverride = DocumentWindowRegistry()
    delegate.terminationIndexDatabaseOverride = database
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification))

    XCTAssertLessThanOrEqual(
      walSize(for: databaseURL), 64 * 1024,
      "…and the one owner still truncates on the very same ⌘Q path (was \(walBefore) bytes)")
  }

  // MARK: - Ordering fixtures

  /// One-shot release valve behind `IndexDatabase.backgroundWriteGateOverride`. The FIRST background
  /// index write parks here until the test opens the gate; every later write passes straight through
  /// so it queues on the supersede chain — behind write #1 — rather than on this gate. `arrivals` is
  /// how the test knows a write has genuinely taken its place in that chain: the gate sits at the
  /// head of the write task, which cannot start before the write registered itself.
  private actor FirstWriteGate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
      arrivals += 1
      guard arrivals == 1, !isOpen else { return }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }

    func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }

  /// Main-actor flag a probe task can set, so a test can observe "did this finish yet?" without
  /// awaiting the thing it is trying to prove has NOT finished.
  @MainActor private final class CompletionFlag {
    var isSet = false
  }

  /// Polls a monotone condition instead of sleeping a fixed amount: a correct build waits only as
  /// long as it actually needs, and a wrong one fails the assertion rather than a guessed duration.
  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 10,
    _ condition: () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for \(description)")
  }

  // MARK: - Workspace fixtures (last-root removal)

  private struct WorkspaceSandbox {
    let root: URL
    let support: URL
  }

  private struct WorkspaceHarness {
    let manager: FolderManager
    let indexDatabase: IndexDatabase
  }

  private func makeWorkspaceSandbox() throws -> WorkspaceSandbox {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveStorageHygieneWorkspace-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return WorkspaceSandbox(root: root, support: support)
  }

  private func makeWorkspaceHarness(in support: URL) throws -> WorkspaceHarness {
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db", isDirectory: false))
    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: indexDatabase,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveStorageHygieneBookmarks")),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    )
    return WorkspaceHarness(manager: manager, indexDatabase: indexDatabase)
  }

  private func settle(_ harness: WorkspaceHarness) async {
    await harness.manager.waitForPendingWorkspaceBuild()
    await harness.manager.waitForPendingForcedRefresh()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  /// Mirrors `IndexDatabase.freelistCompactionThresholdPages`; kept local because
  /// the production constant is private and the test asserts the OBSERVABLE
  /// contract (enough slack exists to be worth reclaiming), not the constant.
  private static let compactionThresholdPages = 256
}
