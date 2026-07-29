//  TerminationQuiescenceTests.swift
//  PensieveTests
//
//  R5 (termination quiescence): pins the two-layer contract that makes "quit" a bounded, ordered
//  event instead of a race between the checkpoint and whichever producer happened to still be alive.
//
//  Layer one is QUIESCENCE: before anything is flushed or drained, every producer this app owns is
//  told to stop — the watcher, the refresh/build tasks, the debounced autosave index, the in-flight
//  import. Layer two is the LATCH: once everything owed has drained, `IndexDatabase` closes its
//  funnel one way, so a producer nobody inventoried cannot write behind the terminal checkpoint.
//
//  Five review rounds each found another producer alive during the quit, and each was patched
//  individually. These tests exist because the patch-per-producer answer is unfalsifiable: they
//  assert the two structural properties instead — nothing is scheduled after the stop, and nothing
//  is accepted after the latch — plus the one case the whole design turns on, the AD-HOC document
//  whose sleeping index debounce has no cold-open repair path and therefore must be FLUSHED rather
//  than cancelled.
//
//  Siblings: `IndexDatabaseStorageHygieneTests` owns the WAL/checkpoint ordering pins and the two
//  budget pins (a wedged writer and a wedged reader, both wedged INSIDE the pool).

import AppKit
import GRDB
import XCTest

@testable import Pensieve

@MainActor
final class TerminationQuiescenceTests: XCTestCase {

  // MARK: - F2: the armed index debounce is flushed, not cancelled

  /// `Autosaver` is the debounce itself, and the flush is where the ordering bug lived: the old
  /// `savePendingChangesOnClose` returned on a CLEAN session before it ever reached the autosaver, so
  /// an armed index write simply died with the process. Three properties, all of which the
  /// termination sequence depends on: the flush RUNS the armed body immediately, it runs it EXACTLY
  /// once however often it is called, and after `quiesceForTermination()` nothing can re-arm — which
  /// is what stops the flushed write from scheduling a successor while the drain is running.
  func testAutosaverFlushRunsTheArmedIndexWriteExactlyOnceAndCannotReArmAfterQuiescence() {
    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let runs = Counter()
    let owner = URL(fileURLWithPath: "/tmp/pensieve-autosaver-pin.md").standardizedFileURL

    // A CLEAN owner: this pin is about flush mechanics, and a clean owner is the case that flushes.
    autosaver.scheduleIndex(owner: owner, ownerIsDirty: { false }) { runs.increment() }
    XCTAssertEqual(
      runs.value, 0,
      "fixture precondition: with a ten-minute debounce the body must still be asleep")
    XCTAssertEqual(
      autosaver.armedIndexOwner, owner,
      "…and the armed body must name the document it would index, so a close can tell its own "
        + "unsaved text from another window's")

    autosaver.flushIndex()
    XCTAssertEqual(
      runs.value, 1,
      "the flush must run the armed index write NOW — the process is not going to be alive in ten "
        + "minutes")

    autosaver.flushIndex()
    XCTAssertEqual(
      runs.value, 1,
      "a second flush must not repeat the write: the sequence flushes through the window close AND "
        + "through `quiesceForTermination()`, and both may reach the same debounce")

    autosaver.quiesceForTermination()
    XCTAssertTrue(autosaver.isQuiescedForTermination)

    autosaver.scheduleIndex(owner: owner, ownerIsDirty: { false }) { runs.increment() }
    autosaver.scheduleSave { runs.increment() }
    autosaver.flushIndex()
    XCTAssertEqual(
      runs.value, 1,
      "nothing may re-arm after quiescence — a write scheduled here would be a producer the drain "
        + "has already walked past")
  }

  /// The operator-mandated pin, and the reason the contract FLUSHES this debounce instead of
  /// cancelling it.
  ///
  /// The window is 1.5 s to 5 s after the last keystroke: the autosave has written the bytes and
  /// marked the buffer CLEAN, while the index debounce is still asleep. Quitting there used to lose
  /// the FTS row outright — `savePendingChangesOnClose` saw a clean session and returned before
  /// touching the autosaver, so the armed write died with the process.
  ///
  /// The document is AD-HOC on purpose. A workspace document self-heals: the next cold open compares
  /// the workspace signature, notices the changed `.md`, and reindexes it. `signature(from:)` only
  /// covers workspace scans, so an ad-hoc document has NO such repair path — its stale FTS row stays
  /// stale until the user edits it again. That asymmetry is the whole argument: for this document
  /// cancelling the debounce is permanent data loss, and it is why the fix flushes.
  ///
  /// Driven through the REAL `applicationWillTerminate` entry point, and read back through an
  /// INDEPENDENT connection — after the latch the database under test refuses to open anything, so a
  /// query through it would prove nothing either way.
  func testTerminationFlushesTheSleepingIndexDebounceOfAnAdHocDocument() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Outside every workspace root — no `rootURL`, no relative path, `isAdHoc`. This is the document
    // class that has no cold-open repair.
    let noteURL = folder.appendingPathComponent("ad-hoc-note.md")
    try "before the quit".write(to: noteURL, atomically: true, encoding: .utf8)
    let ref = DocumentRef(id: noteURL.standardizedFileURL, isAdHoc: true)

    // A short SAVE debounce and a ten-minute INDEX debounce reproduce the 1.5–5 s window
    // deterministically: the save is guaranteed to land, the index write is guaranteed not to.
    let autosaver = Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveAdHocFlushBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )
    let folderManager = makeIsolatedFolderManager(in: folder, database: database, prefix: "AdHocFlush")
    let registry = DocumentWindowRegistry()
    let controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: store,
      indexDatabase: database,
      documentWindowRegistry: registry
    )
    let window = makeWindow()
    defer { window.close() }
    registry.registerController(controller, for: window)

    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "before the quit")
    appState.activeDocumentText = "adhocflushneedle typed moments before the quit"
    store.documentDidChange(appState: appState)

    pumpMainRunLoop(
      until: {
        (try? String(contentsOf: noteURL, encoding: .utf8))?.contains("adhocflushneedle") == true
      },
      timeout: 5)
    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8),
      "adhocflushneedle typed moments before the quit",
      "fixture precondition: the debounced autosave must have landed on disk")
    XCTAssertFalse(
      appState.documentSession.isDirty,
      "fixture precondition: the session must be CLEAN — that is the state the old dirty guard "
        + "returned on before it ever reached the autosaver")
    XCTAssertEqual(
      try indexHits(matching: "adhocflushneedle", at: databaseURL), 0,
      "fixture precondition: the index debounce must still be asleep, so the FTS row is stale")

    let delegate = PensieveAppDelegate()
    delegate.terminationWindowRegistryOverride = registry
    delegate.terminationIndexDatabaseOverride = database
    delegate.terminationFolderManagerOverride = folderManager
    delegate.terminationAutosaverOverride = autosaver
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification))

    XCTAssertEqual(
      try indexHits(matching: "adhocflushneedle", at: databaseURL), 1,
      "the quit must FLUSH the sleeping index debounce and drain the write it produces: this "
        + "document has no cold-open repair path, so a cancelled debounce loses its searchability "
        + "permanently")
    XCTAssertEqual(
      walSize(for: databaseURL), 0,
      "…and the flushed write must still land BEFORE the terminal truncate, not behind it")
  }

  /// The narrow half of the same fix, driven through `savePendingChangesOnClose` directly — the
  /// method review round 5 flagged, and an ORDINARY window close rather than a quit.
  ///
  /// The bug was pure ordering: the dirty guard returned before the autosaver was ever touched, so a
  /// CLEAN session's armed index debounce was never flushed and never cancelled — it simply died with
  /// the window's `AppState`. The fix moves the flush ahead of the guard, and it flushes rather than
  /// cancels because `Autosaver` is a process-wide singleton: the armed debounce may belong to a
  /// DIFFERENT window than the one closing, and cancelling it would silently drop that window's
  /// freshness. Flushing is safe in both cases — the write is owed either way.
  ///
  /// The sibling above covers the same loss on the quit path; this one fails even if the termination
  /// sequence is not involved at all.
  func testClosingACleanWindowStillFlushesItsSleepingIndexDebounce() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let noteURL = folder.appendingPathComponent("closing-note.md")
    try "before the close".write(to: noteURL, atomically: true, encoding: .utf8)
    let ref = DocumentRef(id: noteURL.standardizedFileURL, isAdHoc: true)

    let autosaver = Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveCleanCloseBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )

    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "before the close")
    appState.activeDocumentText = "cleanclosneedle typed and then left alone"
    store.documentDidChange(appState: appState)

    try await waitUntil("the debounced autosave to land") {
      appState.documentSession.isDirty == false
    }
    XCTAssertEqual(
      try indexHits(matching: "cleanclosneedle", at: databaseURL), 0,
      "fixture precondition: the index debounce must still be asleep")

    XCTAssertFalse(
      store.savePendingChangesOnClose(appState: appState),
      "nothing is dirty, so the close persists nothing — and that return value is exactly what used "
        + "to make the early return look harmless")
    await database.drainPendingIndexWrites()

    XCTAssertEqual(
      try indexHits(matching: "cleanclosneedle", at: databaseURL), 1,
      "closing a window must flush its armed index debounce even when the session is clean: the "
        + "autosave marked it clean 1.5 s in, the index write was still asleep at 5 s, and the "
        + "AppState is about to be torn down with it")
  }

  // MARK: - L: the latch

  /// The funnel closes one way, and it closes AFTER the drain. Everything that arrives later is
  /// refused by name — no write reaches the pool, so the terminal checkpoint stays the last database
  /// operation of the process and the WAL it truncated stays truncated.
  ///
  /// The `didInsertSearchIndexBatch` count is the sharp end: it fires from INSIDE the index write's
  /// `pool.write`, so an unchanged count after the checkpoint is direct evidence that no transaction
  /// opened, rather than the indirect "the row is not there" evidence a query gives.
  func testWritesSubmittedAfterTheLatchAreRefusedAndTheCheckpointStaysTheLastDatabaseOperation()
    throws
  {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let batches = Counter()
    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didInsertSearchIndexBatch: { _ in batches.increment() })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Give the terminal truncate something to reclaim, so "the WAL is empty" cannot be an artefact
    // of nothing ever having been written.
    churn(database: database, root: root, count: 300)
    XCTAssertGreaterThanOrEqual(
      walSize(for: databaseURL), 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL")

    TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      folderManager: makeIsolatedFolderManager(in: folder, database: database, prefix: "PostLatch"),
      autosaver: Autosaver()
    ).runBlockingMainRunLoop()

    let walAfterQuit = walSize(for: databaseURL)
    let batchesAfterCheckpoint = batches.value
    XCTAssertTrue(
      database.isClosedForTermination,
      "a completed sequence must leave the funnel closed")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, [],
      "the sequence's own phases must all run BEFORE the latch — a rejection here would mean the "
        + "quit refused work it was supposed to have flushed or drained")
    XCTAssertEqual(
      walAfterQuit, 0,
      "fixture precondition for the rest of this test: the terminal checkpoint must have truncated "
        + "the WAL (it is \(walAfterQuit) bytes)")

    // Producers arriving after the sequence returned: exactly what the latch exists for. In
    // production these are the tail of a detached scan or a deferred sweep; here they are called
    // directly so every entry point is named in the assertion.
    let lateRef = documentRef(root: root, name: "late-write.md")
    try "postlatchneedle".write(to: lateRef.url, atomically: true, encoding: .utf8)
    let finished = CompletionFlag()
    Task { @MainActor in
      _ = await database.indexInBackground(document: lateRef, body: "postlatchneedle", appState: nil)
      await database.updateSearchIndexInBackground(
        upserting: [lateRef], deletingPaths: [], appState: nil)
      _ = await database.reindexInBackground(documents: [lateRef], appState: nil)
      await database.performMaintenanceInBackground(reason: .workspaceClose)
      database.scheduleIndexWrite { }
      finished.isSet = true
    }
    pumpMainRunLoop(until: { finished.isSet }, timeout: 10)
    XCTAssertTrue(finished.isSet, "the refused entry points must return promptly, not hang")

    XCTAssertEqual(
      database.terminationRejectedEntryPoints,
      [
        "indexInBackground", "updateSearchIndexInBackground", "reindexInBackground",
        "performMaintenanceInBackground", "scheduleIndexWrite",
      ],
      "every managed write entry point must refuse by name once the funnel is closed")
    XCTAssertEqual(
      try indexHits(matching: "postlatchneedle", at: databaseURL), 0,
      "a refused write must leave no trace in the index")
    XCTAssertEqual(
      batches.value, batchesAfterCheckpoint,
      "no index transaction may open after the terminal checkpoint — `didInsertSearchIndexBatch` "
        + "fires from inside `pool.write`, so any increment here is a write that landed behind it")
    XCTAssertEqual(
      walSize(for: databaseURL), 0,
      "…and the truncated WAL must stay truncated (it is \(walSize(for: databaseURL)) bytes)")
  }

  /// The subtle half of the latch: refusing WRITES is not enough, because in this app a read can
  /// write. `ensureOpen` builds the pool lazily and runs every migration on first creation, so a
  /// backlink query or a search arriving during the quit could create the database file, execute a
  /// pile of DDL and backfill FTS — after the checkpoint that was supposed to be final, and on a
  /// process that is about to be killed mid-migration.
  ///
  /// A never-opened database at a path whose PARENT does not exist makes that observable with no
  /// ambiguity: if the gate leaks, the directory and the file both appear.
  func testAPostLatchReadCannotCreateOrMigrateTheIndex() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder
      .appendingPathComponent("Index", isDirectory: true)
      .appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: databaseURL.path),
      "fixture precondition: this database has never been opened")

    database.closeForTermination()

    let ref = DocumentRef(id: folder.appendingPathComponent("note.md").standardizedFileURL)
    XCTAssertTrue(
      database.search(query: "anything", documents: [ref], appState: nil).isEmpty,
      "a synchronous search must return empty rather than open the database")

    let finished = CompletionFlag()
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: ref, documents: [ref])
      _ = await database.searchInBackground(query: "anything", documents: [ref])
      finished.isSet = true
    }
    pumpMainRunLoop(until: { finished.isSet }, timeout: 10)
    XCTAssertTrue(finished.isSet, "the refused reads must return promptly, not hang")

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path),
      "a post-latch read must not create the index directory")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: databaseURL.path),
      "a post-latch read must not create and migrate index.db — the first open of a fresh database "
        + "is the single largest write this app performs")
    XCTAssertNil(
      database.databaseURL,
      "…and no pool may be published, or a later caller would use it")
    XCTAssertTrue(
      database.terminationRejectedEntryPoints.contains("ensureOpen"),
      "the synchronous lazy-open gate must be the one that refused")
    XCTAssertTrue(
      database.terminationRejectedEntryPoints.contains("ensureOpenInBackground"),
      "…and its asynchronous sibling, which is what every background reader goes through")
  }

  /// The escape hatch must not reopen the funnel. When the drain budget expires the quit stops
  /// WAITING, but the process is still alive and still full of producers — and its checkpoint is now
  /// best-effort and unwaited, i.e. the worst possible moment to accept a new write. So the timeout
  /// path latches too.
  ///
  /// The budget is forced to expire with a genuine, deterministic stall: a background write parked at
  /// `backgroundWriteGateOverride` registers itself on the supersede chain first, so the drain has
  /// something real to wait for and cannot be satisfied until the test opens the gate.
  func testASpentDrainBudgetStillClosesTheFunnel() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let gate = ParkingGate()
    database.backgroundWriteGateOverride = { await gate.arrive() }

    let parkedRef = documentRef(root: root, name: "parked-write.md")
    try "the write that never gets there".write(to: parkedRef.url, atomically: true, encoding: .utf8)
    let writeFinished = CompletionFlag()
    database.scheduleIndexWrite {
      await database.updateSearchIndexInBackground(
        upserting: [parkedRef], deletingPaths: [], appState: nil)
      writeFinished.isSet = true
    }
    pumpMainRunLoop(until: { gate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      gate.arrivalCount, 1,
      "fixture precondition: the scheduled write must be parked, so the drain genuinely stalls")

    let startedAt = Date()
    TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      folderManager: makeIsolatedFolderManager(in: folder, database: database, prefix: "SpentBudget"),
      autosaver: Autosaver(),
      drainTimeout: Self.shrunkDrainBudget
    ).runBlockingMainRunLoop()
    let elapsed = Date().timeIntervalSince(startedAt)

    XCTAssertLessThan(
      elapsed, Self.boundedQuitSeconds,
      "the quit must return once its budget expires; it waited \(elapsed) s")
    XCTAssertTrue(
      database.isClosedForTermination,
      "a spent budget stops the WAITING, it does not put the app back into a running state: the "
        + "funnel must be closed on the timeout path too, or a producer that outlived the drain "
        + "slips a write in behind a checkpoint nobody is waiting for")

    let lateRef = documentRef(root: root, name: "after-the-timeout.md")
    let lateFinished = CompletionFlag()
    Task { @MainActor in
      _ = await database.indexInBackground(document: lateRef, body: "timeoutneedle", appState: nil)
      lateFinished.isSet = true
    }
    pumpMainRunLoop(until: { lateFinished.isSet }, timeout: 10)
    // `contains`, not equality: the write this test parked is still in flight and its own tail
    // (a batch-triggered maintenance pass) legitimately arrives at the closed funnel afterwards.
    XCTAssertTrue(
      database.terminationRejectedEntryPoints.contains("indexInBackground"),
      "…which is only true if the refusal actually happens")

    Task { await gate.open() }
    pumpMainRunLoop(until: { writeFinished.isSet }, timeout: 10)
  }

  // MARK: - Q: producer quiescence

  /// P4/P10: the file watcher. The primitive existed — `FileWatcher.stop()` — and nothing on the
  /// quit path called it, so FSEvents kept delivering while the sequence drained: an event landing
  /// mid-quit scheduled a debounced refresh, the refresh scanned, and the scan asked the index to
  /// write. Cancelling the refresh task alone does not help, because the next event arms another one.
  ///
  /// Two assertions, and the second is the one that matters: the sequence CALLS stop, and a delivery
  /// that was already in flight on the watcher's queue when it stopped produces no index traffic at
  /// all. The funnel is left OPEN for that second half deliberately — a refused entry point would be
  /// evidence that the refresh ran and was caught by the latch, and this test is about the layer
  /// above the latch.
  func testTerminationStopsTheWatcherSoALateFilesystemEventSchedulesNoRefresh() async throws {
    let sandbox = try makeWorkspaceSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteURL = root.appendingPathComponent("watched-note.md")
    try "before the quit".write(to: noteURL, atomically: true, encoding: .utf8)

    let source = RecordingWatcherSource()
    let indexDatabase = IndexDatabase(
      databaseURL: sandbox.support.appendingPathComponent("index.db", isDirectory: false))
    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: sandbox.support.appendingPathComponent("workspace.json")),
      indexDatabase: indexDatabase,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveWatcherQuiesceBookmarks")),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: sandbox.support.appendingPathComponent("WorkspaceCache", isDirectory: true))
      ),
      watcher: FileWatcher(sourceFactory: { source })
    )

    let appState = AppState()
    manager.open(url: root, into: appState)
    await settle(manager, indexDatabase)
    XCTAssertTrue(
      source.isStarted,
      "fixture precondition: opening a workspace must start the watcher, or there is nothing to stop")
    let stopsBeforeQuit = source.stopCount

    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: indexDatabase,
      folderManager: manager,
      autosaver: Autosaver())
    await sequence.run()

    XCTAssertGreaterThan(
      source.stopCount, stopsBeforeQuit,
      "the quiescence phase must stop the watcher: leaving it running means the drain is waiting for "
        + "a target the watcher keeps moving")

    // A batch that was already on the watcher's queue when the stream stopped, delivered after the
    // quiescence — the real-world shape of this race.
    try "changed while the app was quitting".write(to: noteURL, atomically: true, encoding: .utf8)
    source.deliver([
      FileWatcherEvent(path: noteURL.path, flags: [.itemIsFile, .itemModified])
    ])
    // Comfortably past the 300 ms watcher debounce, so a refresh that WAS scheduled has had every
    // chance to run and reach the index.
    try await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertEqual(
      indexDatabase.terminationRejectedEntryPoints, [],
      "a delivery after the quiescence must not schedule a refresh at all — a refusal here would "
        + "mean the watcher was still driving the scanner while the app was shutting down")
  }

  /// P9: the post-close index housekeeping. `Close Folder` arms a barrier vacuum plus a truncating
  /// checkpoint on a task nobody but the tests ever awaited; a fast ⌘Q straight after it raced that
  /// vacuum against the quit's own checkpoint, and GRDB serializes the two without ordering them —
  /// so the vacuum could land last and leave WAL frames behind the checkpoint that was supposed to
  /// be final.
  ///
  /// The proof is the rejection list, not the timing: the sequence latches the funnel after its
  /// drain, so housekeeping that escaped the budget can only reach the index by being REFUSED, and a
  /// refusal is recorded permanently. Settling the manager afterwards is what forces that evidence to
  /// appear instead of dying with the test process.
  func testCloseFolderFollowedImmediatelyByQuitAwaitsTheIndexHousekeeping() async throws {
    let sandbox = try makeWorkspaceSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let body = String(repeating: "pensieve close-then-quit payload ", count: 600)
    for index in 0..<80 {
      try "\(body) \(index)".write(
        to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let indexDatabase = IndexDatabase(
      databaseURL: sandbox.support.appendingPathComponent("index.db", isDirectory: false))
    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: sandbox.support.appendingPathComponent("workspace.json")),
      indexDatabase: indexDatabase,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveCloseThenQuitBookmarks")),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: sandbox.support.appendingPathComponent("WorkspaceCache", isDirectory: true))
      )
    )
    let databaseURL = sandbox.support.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    manager.open(url: root, into: appState)
    await settle(manager, indexDatabase)

    // Back to back, with no `await` in between: the user's ⌘Q lands while the close-time vacuum is
    // still on its way to the pool.
    manager.closeWorkspace(into: appState)
    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: indexDatabase,
      folderManager: manager,
      autosaver: Autosaver())
    await sequence.run()
    // Sampled before anything else touches the database.
    let walAfterQuit = walSize(for: databaseURL)

    await manager.waitForPendingIndexMaintenance()
    try await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(
      indexDatabase.terminationRejectedEntryPoints, [],
      "the close-time housekeeping must be AWAITED inside the quit's budget: a vacuum that only "
        + "reached the funnel after the latch shows up here as a refused entry point, and in "
        + "production its frames would sit behind the terminal checkpoint")
    XCTAssertEqual(
      walAfterQuit, 0,
      "…and the quit's own checkpoint must still go last (WAL is \(walAfterQuit) bytes)")
  }

  /// P11 (`AppController.reindexCreatedDocument`) plus the hand-off gap in general. A write handed to
  /// a bare `Task { }` is invisible to `drainPendingIndexWrites()` until the task actually starts and
  /// registers itself on the supersede chain — so a quit racing that hand-off drains nothing, and the
  /// write lands behind the checkpoint. Routing it through `scheduleIndexWrite` closes the gap by
  /// construction: registration happens SYNCHRONOUSLY at submission.
  ///
  /// The gate makes the wait observable without any timing assumption: with the write parked before
  /// the pool, a drain that can see it cannot complete. `indexDocument` is stubbed out so the save-as
  /// write `createDocument` also performs cannot satisfy the drain on the reindex's behalf — the
  /// assertion has to be about THIS write.
  ///
  /// Honest limit of this pin: it does NOT fail if the write is put back on a bare `Task { }`.
  /// Main-actor jobs run FIFO, so a bare task created before the drain still registers itself first
  /// and the drain still waits for it. The hand-off gap is a genuine race, not a deterministic loss,
  /// and `scheduleIndexWrite` closes it by CONSTRUCTION — registration is synchronous at submission,
  /// with no window at all — which is a property no in-process pin can distinguish from winning the
  /// race every time. What this test does guard is the outcome that matters: a newly created
  /// document's index write is something the quit's drain waits for.
  func testACreatedDocumentIndexWriteIsVisibleToTheDrainFromTheMomentItIsSubmitted() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let gate = ParkingGate()
    database.backgroundWriteGateOverride = { await gate.arrive() }

    let controller = AppController(
      appState: appState,
      folderManager: makeIsolatedFolderManager(in: folder, database: database, prefix: "CreateDoc"),
      documentStore: DocumentStore(
        autosaver: Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000),
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveCreateDocBookmarks")),
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true)),
        indexDocument: { _, _, _ in }),
      indexDatabase: database,
      documentWindowRegistry: DocumentWindowRegistry()
    )

    let createdURL = controller.createDocument(in: root)
    XCTAssertNotNil(createdURL, "fixture precondition: the document must actually be created")

    let drained = CompletionFlag()
    Task { @MainActor in
      await database.drainPendingIndexWrites()
      drained.isSet = true
    }
    pumpMainRunLoop(until: { gate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      gate.arrivalCount, 1,
      "fixture precondition: the new document's index write must reach the gate")
    XCTAssertFalse(
      drained.isSet,
      "the drain completed while the created document's index write was still queued — that write "
        + "was handed to a bare `Task`, so the quit would checkpoint before it ever reached the pool")

    Task { await gate.open() }
    pumpMainRunLoop(until: { drained.isSet }, timeout: 10)
    XCTAssertTrue(drained.isSet, "…and it must complete once the write is allowed through")
  }

  /// P13: the document import. Its task has a semantic boundary in the middle — before publication it
  /// is a pure conversion that owns nothing, after publication it replaces the document session AND
  /// persists a recovery draft, i.e. managed persistence appearing after the flush phase has already
  /// run. The quiescence command cancels it, and because the cancel and the task's own
  /// `Task.isCancelled` re-check are both on the main actor, there is no interleaving in which a
  /// cancelled import still publishes.
  func testTerminationCancelsAnInFlightImportBeforeItCanPublish() throws {
    let folder = try makeTemporaryFolder()
    // A real PDF, not a Markdown file: `importMarkdown` rejects anything that is not `.docx`/`.pdf`,
    // and a rejected conversion would make this test pass for the wrong reason.
    let sourceURL = folder.appendingPathComponent("Imported Brief.pdf")
    try makeTextPDF("importneedle in the source document").write(to: sourceURL, options: .atomic)
    XCTAssertFalse(
      try DocumentTransfer.importMarkdown(from: sourceURL).markdown.isEmpty,
      "fixture precondition: this document must genuinely convert, so a cancelled import is the "
        + "only reason nothing gets published")

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
    database.open(into: appState)
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    let controller = AppController(
      appState: appState,
      folderManager: makeIsolatedFolderManager(in: folder, database: database, prefix: "Import"),
      documentStore: DocumentStore(
        autosaver: Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000),
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveImportBookmarks")),
        recoveryStore: RecoveryStore(directoryURL: recoveryDirectory)),
      indexDatabase: database,
      documentWindowRegistry: DocumentWindowRegistry()
    )

    controller.importDocument(url: sourceURL)
    // Same run-loop turn: the conversion is still on its detached task and cannot have published.
    controller.quiesceForTermination()

    // Long enough for the conversion to finish and for the publication to have happened, had it not
    // been cancelled.
    pumpMainRunLoop(until: { false }, timeout: 0.5)

    XCTAssertFalse(
      appState.documentSession.hasEditableBuffer,
      "a cancelled import must not publish an untitled draft into the document session after the "
        + "quit began: publication replaces the session AND persists a recovery draft, which is "
        + "managed persistence arriving after the flush phase already ran")
    XCTAssertNil(
      appState.documentSession.document,
      "…and must not adopt a document either")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: recoveryDirectory.path),
      "…and must not persist a recovery draft, which is managed persistence arriving after the "
        + "flush phase")
  }

  // MARK: - R6: the open that passed the latch

  /// Round 6, finding 1 — the hand-off gap one floor above the one round 5 closed.
  ///
  /// `ensureOpenInBackground` consults the funnel gate on ENTRY and then parks on
  /// `makeDatabasePool`, which builds the pool and runs every migration. Between those two moments
  /// the open is owed work that registers in neither drain collection: not in `scheduledIndexWrites`,
  /// not on the supersede chain. A drain that cannot see it reports "nothing owed", the latch closes,
  /// and `startCheckpointOnTerminate()` skips outright because `databasePool` is still nil — after
  /// which the open publishes a pool whose caller writes to a database the quit believes it has
  /// already finished with.
  ///
  /// The wedge sits INSIDE the open, after the gate and after `openTask` is registered, because that
  /// is the only state that proves anything: parked before the gate an open is simply refused. With
  /// it held, a drain that participates CANNOT complete — that "has not finished yet" is the whole
  /// assertion, and it is the direction that cannot pass by luck.
  func testTheDrainWaitsForADatabaseOpenThatIsStillBuildingItsPool() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)
    XCTAssertNil(
      database.databaseURL,
      "fixture precondition: this database has never been opened, so the open under test is the "
        + "first one and `databasePool` is nil while it runs")

    let gate = ParkingGate()
    database.databaseOpenGateOverride = { await gate.arrive() }

    let openFinished = CompletionFlag()
    Task { @MainActor in
      await database.openInBackground(into: nil)
      openFinished.isSet = true
    }
    pumpMainRunLoop(until: { gate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      gate.arrivalCount, 1,
      "fixture precondition: the open must be parked mid-flight, past the funnel gate and already "
        + "registered as `openTask`")
    XCTAssertFalse(openFinished.isSet, "fixture precondition: …and must not have completed")

    let quitFinished = CompletionFlag()
    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      folderManager: makeIsolatedFolderManager(in: folder, database: database, prefix: "OpenDrain"),
      autosaver: Autosaver())
    Task { @MainActor in
      await sequence.run()
      quitFinished.isSet = true
    }
    // Every other phase of the sequence is O(1); given a chance this long, only the open can still be
    // holding it.
    pumpMainRunLoop(until: { quitFinished.isSet }, timeout: 1)

    XCTAssertFalse(
      quitFinished.isSet,
      "the quit finished while a database open was still building its pool: the drain walked past "
        + "work it cannot see anywhere else, so the latch would close over an open that then "
        + "publishes a pool behind a checkpoint which — with `databasePool` still nil — never ran")
    XCTAssertFalse(
      database.isClosedForTermination,
      "…and the latch must not be closed yet either, for the same reason")

    Task { await gate.open() }
    pumpMainRunLoop(until: { quitFinished.isSet }, timeout: 10)
    XCTAssertTrue(quitFinished.isSet, "…and the quit must complete once the open is allowed through")

    XCTAssertTrue(
      database.isClosedForTermination, "a completed sequence must leave the funnel closed")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, [],
      "an open the drain waited for finishes BEFORE the latch, so nothing may be refused: a "
        + "rejection here would mean the pool was published behind the checkpoint instead")
    XCTAssertEqual(
      database.databaseURL, databaseURL,
      "…and the pool must be published, so the terminal checkpoint had a database to truncate")
    XCTAssertEqual(
      walSize(for: databaseURL), 0,
      "…which it did (the WAL is \(walSize(for: databaseURL)) bytes)")
  }

  /// The second half of the same finding, and the reason the fix needs both. The drain closes the
  /// window it can see; this closes the one it cannot — an open that passes the gate DURING the
  /// drain's own suspensions, after the drain has already walked past the open handle.
  ///
  /// Such an open completes with the latch already closed. It must then behave exactly like every
  /// other post-latch producer: refuse by name and publish nothing. Publishing would be the worst of
  /// the two failures, because the caller parked on it is holding a live pool and the sequence has
  /// already taken (or skipped) its terminal checkpoint.
  func testAnOpenThatCompletesAfterTheLatchPublishesNoPool() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)

    let gate = ParkingGate()
    database.databaseOpenGateOverride = { await gate.arrive() }

    let openFinished = CompletionFlag()
    Task { @MainActor in
      await database.openInBackground(into: nil)
      openFinished.isSet = true
    }
    pumpMainRunLoop(until: { gate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      gate.arrivalCount, 1,
      "fixture precondition: the open must be parked past the funnel gate — an open refused on ENTRY "
        + "would make this test pass for the wrong reason")

    // The latch closes while the open sleeps: the residual window a drain cannot cover, because the
    // open can be started by anything running during the drain's own suspension points.
    database.closeForTermination()

    Task { await gate.open() }
    pumpMainRunLoop(until: { openFinished.isSet }, timeout: 10)
    XCTAssertTrue(openFinished.isSet, "the refused open must return promptly, not hang")

    XCTAssertNil(
      database.databaseURL,
      "an open that completes after the latch must publish NO pool: its caller is parked on it and "
        + "would write to a database the quit has already finished with")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, ["ensureOpenInBackground"],
      "…and must refuse by name exactly once — at the publication point, not on entry, which is "
        + "where it still had permission")
  }

  // MARK: - R6: a dirty session's index write follows its file write

  /// Round 6, finding 3 — the cost of round 5's deliberate ordering, in the error path.
  ///
  /// Flushing the armed debounce ahead of the dirty guard is what repairs the CLEAN session (see
  /// `testClosingACleanWindowStillFlushesItsSleepingIndexDebounce`), but for a DIRTY session that
  /// owns the debounce it submits the in-memory edit to SQLite before `saveExisting` has even tried
  /// the file write. The `autosaver.cancel()` that follows cannot retract an already-scheduled
  /// database task, so a write that fails — full volume, revoked permissions — leaves FTS advertising
  /// text that never reached the disk.
  ///
  /// The failure is injected through `writeDocument`, the store's own seam, so the save fails exactly
  /// where a real one would: after the flush decision, inside `saveExisting`. Read back through an
  /// independent connection, as every index assertion in this suite is.
  func testAFailedCloseSaveIndexesNothingForTheDirtySessionThatOwnsTheDebounce() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let noteURL = folder.appendingPathComponent("unwritable-note.md")
    try "before the doomed edit".write(to: noteURL, atomically: true, encoding: .utf8)
    let ref = DocumentRef(id: noteURL.standardizedFileURL, isAdHoc: true)

    // Ten-minute debounces: nothing fires on its own, so whatever reaches the index reached it
    // because the close put it there.
    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveFailedSaveBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true)),
      writeDocument: { _, url in
        throw CocoaError(
          .fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
      }
    )

    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "before the doomed edit")
    appState.activeDocumentText = "faileddsaveneedle that never reaches the disk"
    store.documentDidChange(appState: appState)

    XCTAssertTrue(
      appState.documentSession.isDirty,
      "fixture precondition: the session must be DIRTY — that is the half of the case the "
        + "unconditional flush got wrong")
    XCTAssertEqual(
      autosaver.armedIndexOwner, ref.id,
      "fixture precondition: the armed debounce must belong to THIS document, not to another window")
    XCTAssertEqual(
      try indexHits(matching: "faileddsaveneedle", at: databaseURL), 0,
      "fixture precondition: the debounce must still be asleep")

    XCTAssertFalse(
      store.savePendingChangesOnClose(appState: appState),
      "fixture precondition: the close-time file write must genuinely fail")
    await database.drainPendingIndexWrites()

    XCTAssertEqual(
      try indexHits(matching: "faileddsaveneedle", at: databaseURL), 0,
      "a dirty session's index write must follow its own SUCCESSFUL file save: the bytes never "
        + "reached the disk, so FTS must not advertise them — and once the write is scheduled, "
        + "`autosaver.cancel()` cannot take it back")
    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "before the doomed edit",
      "…and the file on disk must still hold the pre-edit body, which is what makes the index row a "
        + "lie rather than a race")
    XCTAssertNotNil(
      appState.lastError,
      "…and the user must be told the save failed")
  }

  /// The other side of the same guard, and the reason it is scoped to the OWNER's state rather than
  /// to "is it mine": `Autosaver` is a process-wide singleton, so the armed debounce routinely
  /// belongs to a window other than the one closing. When that owner is CLEAN — its 1.5 s autosave
  /// already wrote the bytes and marked the buffer clean while the 5 s index write was still asleep
  /// — the debounce owes a write for text that is already on disk. It is owed unconditionally: the
  /// closing session's save cannot speak for it, and for an ad-hoc document nothing else ever will
  /// (no workspace signature ⇒ no cold-open self-heal). So a dirty close must still flush it even
  /// when its own save is doomed.
  ///
  /// R7 renamed this from `…StillFlushesAnotherDocumentsArmedDebounce` and made the other window
  /// explicitly CLEAN. The old fixture left it dirty and asserted the flush, which pinned the very
  /// defect its sibling below now forbids; the R5 argument this pin defends was always about a clean
  /// owner.
  func testAFailedCloseSaveStillFlushesACleanOwnersArmedDebounce() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let otherURL = folder.appendingPathComponent("other-window-note.md")
    try "the other window's saved body".write(to: otherURL, atomically: true, encoding: .utf8)
    let otherRef = DocumentRef(id: otherURL.standardizedFileURL, isAdHoc: true)

    let closingURL = folder.appendingPathComponent("closing-note.md")
    try "before the doomed edit".write(to: closingURL, atomically: true, encoding: .utf8)
    let closingRef = DocumentRef(id: closingURL.standardizedFileURL, isAdHoc: true)

    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveOtherDebounceBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true)),
      writeDocument: { text, url in
        guard url.standardizedFileURL != closingRef.id else {
          throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
      }
    )

    // The OTHER window edits last, so it is the one holding the singleton's armed debounce.
    let otherState = AppState()
    otherState.documents = [otherRef]
    otherState.documentSession.load(document: otherRef, text: "the other window's saved body")
    otherState.activeDocumentText = "otherwindowneedle from the window that is not closing"
    store.documentDidChange(appState: otherState)
    XCTAssertEqual(
      autosaver.armedIndexOwner, otherRef.id,
      "fixture precondition: the singleton's debounce must belong to the OTHER document")

    // …and then its own autosave lands: bytes on disk, buffer clean, index debounce still asleep.
    // This is the R5 window, and the reason the flush must not be withheld here.
    try otherState.documentSession.text.write(to: otherURL, atomically: true, encoding: .utf8)
    otherState.documentSession.isDirty = false
    XCTAssertFalse(
      autosaver.armedIndexOwnerIsDirty,
      "fixture precondition: the debounce's owner must read as CLEAN — that is the half of the rule "
        + "this pin defends")

    appState.documents = [closingRef]
    appState.documentSession.load(document: closingRef, text: "before the doomed edit")
    appState.documentSession.isDirty = true

    XCTAssertFalse(
      store.savePendingChangesOnClose(appState: appState),
      "fixture precondition: the closing window's own save must fail")
    await database.drainPendingIndexWrites()

    XCTAssertEqual(
      try indexHits(matching: "otherwindowneedle", at: databaseURL), 1,
      "a CLEAN owner's armed debounce is owed regardless of what happens to this close: its bytes "
        + "are already on disk, and withholding the write would drop that window's freshness for "
        + "good on an ad-hoc document, which has no cold-open self-heal")
  }

  /// Round 7 — the same defect class as the dirty-session pin above, one window over.
  ///
  /// Two dirty file-backed windows, the debounce owned by the one processed SECOND. The first
  /// controller to close is not the owner, so the R6 check ("is this debounce mine and am I dirty?")
  /// said `false` and flushed — publishing the OTHER window's still-unsaved text to FTS before that
  /// window had even attempted its own file write. When that write then fails, the index advertises
  /// content absent from disk, which is exactly what the owner-scoped guard was introduced to stop.
  ///
  /// The rule the fix generalises to: a debounce whose OWNER is dirty anywhere in the process waits
  /// for that owner's own SUCCESSFUL save. Deferred means left ARMED — not flushed, not cancelled —
  /// so the owner's own close still decides, and its buffer stays dirty until a save actually lands.
  func testACloseDefersAnotherDirtyWindowsDebounceUntilThatWindowSavesSuccessfully() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let otherURL = folder.appendingPathComponent("other-dirty-window.md")
    try "the other window's OLD body".write(to: otherURL, atomically: true, encoding: .utf8)
    let otherRef = DocumentRef(id: otherURL.standardizedFileURL, isAdHoc: true)

    let closingURL = folder.appendingPathComponent("closing-dirty-window.md")
    try "before the doomed edit".write(to: closingURL, atomically: true, encoding: .utf8)
    let closingRef = DocumentRef(id: closingURL.standardizedFileURL, isAdHoc: true)

    // Both windows' writes fail at first — the closing one because its own save is doomed, the owner
    // because the whole point is a debounce whose owner's save does NOT succeed. The gate is flipped
    // open at the end to prove the deferral lost nothing.
    let writes = WriteFailureGate(failing: [closingRef.id, otherRef.id])

    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveDeferredDebounceBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true)),
      writeDocument: { text, url in
        guard !writes.fails(url) else {
          throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
      }
    )

    // The OTHER window edits last and stays DIRTY, so it owns the singleton's armed debounce and its
    // text exists nowhere but memory.
    let otherState = AppState()
    otherState.documents = [otherRef]
    otherState.documentSession.load(document: otherRef, text: "the other window's OLD body")
    otherState.activeDocumentText = "deferredneedle that is only in the other window's buffer"
    store.documentDidChange(appState: otherState)
    XCTAssertEqual(
      autosaver.armedIndexOwner, otherRef.id,
      "fixture precondition: the singleton's debounce must belong to the OTHER document")
    XCTAssertTrue(
      otherState.documentSession.isDirty,
      "fixture precondition: the debounce's owner must be DIRTY — that is the case the R6 check "
        + "still flushed")

    appState.documents = [closingRef]
    appState.documentSession.load(document: closingRef, text: "before the doomed edit")
    appState.documentSession.isDirty = true

    XCTAssertFalse(
      store.savePendingChangesOnClose(appState: appState),
      "fixture precondition: the closing window's own save must fail")
    await database.drainPendingIndexWrites()

    XCTAssertEqual(
      try indexHits(matching: "deferredneedle", at: databaseURL), 0,
      "a dirty owner's index write must follow its OWN successful save: this close does not speak "
        + "for another window's unsaved buffer, and once the write is scheduled nothing can take it "
        + "back")
    XCTAssertEqual(
      autosaver.armedIndexOwner, otherRef.id,
      "…and deferred means LEFT ARMED, not cancelled: dropping it would be the loss the flush-over-"
        + "cancel rule exists to prevent")

    // Now the owner itself closes — and its save fails too. Still nothing may reach FTS.
    XCTAssertFalse(
      store.savePendingChangesOnClose(appState: otherState),
      "fixture precondition: the owner's own close-time write must genuinely fail")
    await database.drainPendingIndexWrites()

    XCTAssertEqual(
      try indexHits(matching: "deferredneedle", at: databaseURL), 0,
      "the owner's own failed save must not publish its text either — that is the R6 guarantee, "
        + "reached here through the deferral instead of an early flush")
    XCTAssertEqual(
      try String(contentsOf: otherURL, encoding: .utf8), "the other window's OLD body",
      "…and the file on disk must still hold the pre-edit body, which is what would make an index "
        + "row a lie rather than a race")
    XCTAssertTrue(
      otherState.documentSession.isDirty,
      "…and the owner's buffer must stay DIRTY, so the text is still recoverable by a later save")

    // The deferral cost nothing: once a save actually lands, the text is indexed.
    writes.stopFailing(otherRef.id)
    XCTAssertTrue(
      store.savePendingChangesOnClose(appState: otherState),
      "fixture precondition: the retried save must succeed")
    await database.drainPendingIndexWrites()

    XCTAssertEqual(
      try indexHits(matching: "deferredneedle", at: databaseURL), 1,
      "index only after bytes land — but then it MUST land, or the deferral would be a silent loss "
        + "of searchability")
  }

  // MARK: - R6: the flush loop is deadline-aware between windows

  /// Round 6, finding 2 — the budget could be consumed invisibly.
  ///
  /// Every per-window save is the app's ordinary synchronous save primitive, and phase F ran them in
  /// one uninterrupted loop on the main actor. Control could therefore not return to the pump in
  /// `runBlockingMainRunLoop()` until the LAST window had finished writing, so N dirty windows on a
  /// slow volume could burn the whole deadline in a single block the timeout could not observe.
  ///
  /// This is a bounded mitigation, not a redesign: the write itself stays synchronous (making it
  /// suspending means moving document state off the main actor, a save-path refactor outside this
  /// contract), so a SINGLE large file can still overrun the budget. What is pinned here is the
  /// granularity — the pump regains control BETWEEN windows — observed through the sequence's own
  /// `pumpRunLoop` seam interleaved with the stores' `writeDocument` seam.
  func testTheFinalWindowSavesLetTheDeadlinePumpRunBetweenFiles() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let log = EventLog()
    let registry = DocumentWindowRegistry()
    let folderManager = makeIsolatedFolderManager(in: folder, database: database, prefix: "PumpLoop")
    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)

    var windows: [NSWindow] = []
    var noteURLs: [URL] = []
    // Held strongly for the length of the test on purpose: the registry keeps only weak references,
    // so controllers dropped at the end of the loop below would be reaped before the quit ever asked
    // for them and this pin would pass with zero saves.
    var controllers: [AppController] = []
    defer { windows.forEach { $0.close() } }

    for name in ["window-a", "window-b"] {
      let noteURL = folder.appendingPathComponent("\(name).md")
      try "before the quit".write(to: noteURL, atomically: true, encoding: .utf8)
      noteURLs.append(noteURL)
      let ref = DocumentRef(id: noteURL.standardizedFileURL, isAdHoc: true)

      let windowState = AppState()
      let store = DocumentStore(
        autosaver: autosaver,
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensievePumpLoop\(name)Bookmarks")),
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery-\(name)", isDirectory: true)),
        writeDocument: { text, url in
          log.append("save:\(url.deletingPathExtension().lastPathComponent)")
          try text.write(to: url, atomically: true, encoding: .utf8)
        }
      )
      windowState.documents = [ref]
      windowState.documentSession.load(document: ref, text: "before the quit")
      windowState.activeDocumentText = "pumploopneedle in \(name)"
      windowState.documentSession.isDirty = true

      let controller = AppController(
        appState: windowState,
        folderManager: folderManager,
        documentStore: store,
        indexDatabase: database,
        documentWindowRegistry: registry)
      controllers.append(controller)
      let window = makeWindow()
      windows.append(window)
      registry.registerController(controller, for: window)
    }
    XCTAssertEqual(controllers.count, 2)
    XCTAssertEqual(
      registry.liveDocumentControllers().count, 2,
      "fixture precondition: two live windows, both dirty — one save cannot demonstrate a gap")

    let startedAt = Date()
    TerminationSequence(
      registry: registry,
      indexDatabase: database,
      folderManager: folderManager,
      autosaver: autosaver,
      drainTimeout: Self.shrunkDrainBudget,
      pumpRunLoop: { limit in
        log.append("pump")
        RunLoop.current.run(mode: .default, before: limit)
      }
    ).runBlockingMainRunLoop()
    let elapsed = Date().timeIntervalSince(startedAt)

    let events = log.events
    let saveIndices = events.indices.filter { events[$0].hasPrefix("save:") }
    XCTAssertEqual(
      saveIndices.count, 2,
      "fixture precondition: both windows must have saved (events: \(events))")
    XCTAssertTrue(
      events[saveIndices[0]..<saveIndices[1]].contains("pump"),
      "the deadline pump must regain control BETWEEN the two window saves; without a suspension "
        + "point there the whole loop is one uninterruptible block and the five-second budget cannot "
        + "be enforced until the last file has been written (events: \(events))")

    for noteURL in noteURLs {
      XCTAssertEqual(
        try String(contentsOf: noteURL, encoding: .utf8),
        "pumploopneedle in \(noteURL.deletingPathExtension().lastPathComponent)",
        "…and every window's bytes must still land: yielding buys deadline granularity, it must not "
          + "cost a save")
    }
    XCTAssertLessThan(
      elapsed, Self.boundedQuitSeconds,
      "…and the quit must stay bounded; it took \(elapsed) s")
    XCTAssertTrue(
      database.isClosedForTermination,
      "…and the funnel must end up closed, whichever path the sequence took")
  }

  // MARK: - Fixtures

  /// The drain budget under test, shrunk from the production 5 s through `TerminationSequence`'s own
  /// init seam. The contract is "returns once it expires", not "expires after exactly 5 s".
  private static let shrunkDrainBudget: TimeInterval = 0.4

  /// The bound a bounded quit must respect: ~12× the shrunk budget, loose on purpose because this
  /// suite already carries wall-clock flakes and this assertion must not become the next one.
  private static let boundedQuitSeconds: TimeInterval = 5

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveTerminationQuiescence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
  }

  private struct WorkspaceSandbox {
    let root: URL
    let support: URL
  }

  private func makeWorkspaceSandbox() throws -> WorkspaceSandbox {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveTerminationWorkspace-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return WorkspaceSandbox(root: root, support: support)
  }

  /// A `FolderManager` bound to this test's temp directory and index. Tests that do not exercise the
  /// workspace still need one, because `TerminationSequence` quiesces it — and the process-wide
  /// `FolderManager.shared` must never be touched from a unit test.
  private func makeIsolatedFolderManager(
    in folder: URL,
    database: IndexDatabase,
    prefix: String
  ) -> FolderManager {
    FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: folder.appendingPathComponent("workspace.json")),
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "Pensieve\(prefix)Workspace")),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: folder.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    )
  }

  private func settle(_ manager: FolderManager, _ indexDatabase: IndexDatabase) async {
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingForcedRefresh()
    await manager.waitForPendingIndexUpdate()
    await manager.waitForPendingWorkspaceIndexWrite()
    await indexDatabase.waitForPendingReindex()
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  private func documentRef(root: URL, name: String) -> DocumentRef {
    DocumentRef(
      id: root.appendingPathComponent(name).standardizedFileURL,
      rootURL: root,
      relativePath: name
    )
  }

  /// Writes `count` documents of ~24 KiB each through the SYNCHRONOUS index path, so the WAL grows
  /// without leaving anything for the drain to wait for.
  private func churn(database: IndexDatabase, root: URL, count: Int) {
    let body = String(repeating: "pensieve termination churn payload ", count: 600)
    for index in 0..<count {
      database.index(document: documentRef(root: root, name: "churn-\(index).md"), body: "\(body) \(index)")
    }
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

  /// Counts FTS matches through an INDEPENDENT connection. Mandatory here rather than merely tidy:
  /// after the latch the database under test refuses to open anything, so a query through it would
  /// return empty whether or not the write landed.
  private func indexHits(matching needle: String, at databaseURL: URL) throws -> Int {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM document_fts WHERE document_fts MATCH ?",
        arguments: [needle]) ?? 0
    }
  }

  /// Pumps the run loop exactly the way production does, so main-actor work keeps making progress
  /// while a non-async test waits. `pumpMainRunLoop(until: { false }, timeout:)` is a deliberate
  /// "give everything pending a chance to run" wait.
  private func pumpMainRunLoop(until condition: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
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

  /// A one-page PDF with a real text layer, mirroring `DocumentTransferTests`' fixture: the import
  /// path only accepts `.docx`/`.pdf`, so the cancellation pin needs a document that genuinely
  /// converts.
  private func makeTextPDF(_ text: String) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw CocoaError(.fileWriteUnknown)
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    context.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    context.textPosition = CGPoint(x: 72, y: 720)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }

  /// Thread-safe counter for hooks that fire on GRDB's writer thread while the test reads them from
  /// the main thread, and for closures whose call count is the assertion.
  private final class Counter: @unchecked Sendable {
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

  /// Which file writes the `writeDocument` seam should reject, mutable mid-test so a pin can show
  /// the SAME buffer failing and then succeeding. Locked because the seam is a plain closure the
  /// store may call from wherever it saves.
  private final class WriteFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Set<URL>

    init(failing: Set<URL>) {
      self.failing = failing
    }

    func fails(_ url: URL) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return failing.contains(url.standardizedFileURL)
    }

    func stopFailing(_ url: URL) {
      lock.lock()
      failing.remove(url.standardizedFileURL)
      lock.unlock()
    }
  }

  /// Holds EVERY background index write until the test opens it. The gate sits at the head of the
  /// write task, AFTER the write has registered itself on the supersede chain — which is what makes
  /// "the drain can see this write" observable.
  private actor ParkingGate {
    private var arrivals = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Readable from a synchronous pump without awaiting the actor.
    private let arrivalCounter = Counter()

    nonisolated var arrivalCount: Int { arrivalCounter.value }

    func arrive() async {
      arrivals += 1
      arrivalCounter.increment()
      guard !isOpen else { return }
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
  /// awaiting the very thing it is trying to prove has NOT finished.
  @MainActor private final class CompletionFlag {
    var isSet = false
  }

  /// An ordered log two different seams write into, so a test can assert on their INTERLEAVING
  /// rather than on wall-clock durations. Locked because `TerminationSequence`'s `pumpRunLoop` seam
  /// is a plain nonisolated closure.
  private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
      lock.lock()
      defer { lock.unlock() }
      return recorded
    }

    func append(_ event: String) {
      lock.lock()
      recorded.append(event)
      lock.unlock()
    }
  }

  /// A `FileWatcherEventSource` the test drives by hand: it records the stop the quiescence phase is
  /// supposed to issue, and it can deliver an event AFTER that stop — the batch already in flight on
  /// the watcher queue, which is the case a `stop()` alone cannot prevent.
  private final class RecordingWatcherSource: FileWatcherEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([FileWatcherEvent]) -> Void)?
    private var stops = 0
    private var started = false

    var stopCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return stops
    }

    var isStarted: Bool {
      lock.lock()
      defer { lock.unlock() }
      return started
    }

    func start(paths: [String], onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void) throws {
      lock.lock()
      handler = onEvents
      started = true
      lock.unlock()
    }

    func stop() {
      lock.lock()
      stops += 1
      lock.unlock()
    }

    func deliver(_ events: [FileWatcherEvent]) {
      lock.lock()
      let handler = self.handler
      lock.unlock()
      handler?(events)
    }
  }
}
