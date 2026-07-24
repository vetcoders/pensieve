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
    let document = URL(fileURLWithPath: "/tmp/pensieve-autosaver-pin.md").standardizedFileURL
    // Both debounces are owned by a SESSION object; held for the whole test because the autosaver
    // keeps that ownership weakly.
    let indexingSession = AppState()
    let savingSession = AppState()

    // A CLEAN owner: this pin is about flush mechanics, and a clean owner is the case that flushes.
    autosaver.scheduleIndex(owner: indexingSession, document: document, ownerIsDirty: { false }) {
      runs.increment()
    }
    XCTAssertEqual(
      runs.value, 0,
      "fixture precondition: with a ten-minute debounce the body must still be asleep")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: indexingSession), document,
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

    autosaver.scheduleIndex(owner: indexingSession, document: document, ownerIsDirty: { false }) {
      runs.increment()
    }
    autosaver.scheduleSave(owner: savingSession) { runs.increment() }
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

  // MARK: - R16 / F1: an ACCEPTED write must stop building at the latch

  /// Round 16, finding 1 — the half of the latch that entry gating cannot reach.
  ///
  /// Everything above is about writes that arrive AFTER the funnel closed. This one is about the
  /// write that was already inside it. `reindexInBackground` re-checks the latch only at entry (via
  /// `ensureOpenInBackground`); past that point its `replaceSearchIndex` runs on a `Task.detached`
  /// holding the pool's writer, and the budget-expiry path — `sequence.cancel()` →
  /// `closeForTermination()` → best-effort `startCheckpointOnTerminate()` — reaches none of it.
  /// `cancel()` does not stop a detached task, and SQLite work is not cancellation-aware anyway.
  ///
  /// So the substrate matters, and it is not what "batches" suggests: `replaceSearchIndex` is ONE
  /// `pool.write` for the WHOLE document set — the batch loop batches STATEMENTS, not transactions.
  /// A reindex that outlives the budget therefore commits everything at once, after the fallback
  /// checkpoint that was supposed to be the last word on the WAL. And it makes the fix exact:
  /// throwing between batches rolls the whole transaction back, so nothing lands behind the
  /// checkpoint rather than "less" landing behind it.
  ///
  /// The wedge is real: `didInsertSearchIndexBatch` fires from INSIDE that `pool.write`, so holding
  /// the first batch holds a genuine writer mid-build — the exact state the finding describes. With
  /// `searchIndexBatchSize: 1` the loop has an iteration left for every remaining document, so the
  /// batch count IS the observation: 1 means the write stopped at the latch, more means it kept
  /// building through the quit.
  ///
  /// A safety valve releases the wedge so a regressed build FAILS the assertions instead of hanging
  /// the suite.
  func testAnAcceptedReindexStopsBuildingWhenTheQuitBudgetExpires() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let batches = Counter()
    let releaseWedge = DispatchSemaphore(value: 0)
    defer { releaseWedge.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.readerWedgeReleaseSeconds) {
      releaseWedge.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { _ in
        // Only the FIRST batch is held. Holding every batch would park the write again after the
        // latch and prove nothing about whether the loop CHOSE to stop.
        guard batches.next() == 1 else { return }
        releaseWedge.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let refs = (0..<12).map { documentRef(root: root, name: "abandon-\($0).md") }
    for (offset, ref) in refs.enumerated() {
      try "abandonedreindexneedle \(offset)".write(to: ref.url, atomically: true, encoding: .utf8)
    }

    let writeFinished = CompletionFlag()
    let writeReportedSuccess = CompletionFlag()
    Task { @MainActor in
      let wrote = await database.reindexInBackground(documents: refs, appState: nil)
      writeReportedSuccess.isSet = wrote
      writeFinished.isSet = true
    }
    pumpMainRunLoop(until: { batches.value >= 1 }, timeout: 10)
    XCTAssertEqual(
      batches.value, 1,
      "fixture precondition: the reindex must be mid-build, holding the pool's writer inside its "
        + "transaction")

    // The quit. Its drain parks on this accepted write, the budget expires, and the fallback
    // latches and starts the best-effort checkpoint — all while the reindex is still building.
    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      folderManager: makeIsolatedFolderManager(
        in: folder, database: database, prefix: "AbandonedReindex"),
      autosaver: Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000),
      drainTimeout: Self.shrunkDrainBudget)
    let startedAt = Date()
    sequence.runBlockingMainRunLoop()
    let elapsed = Date().timeIntervalSince(startedAt)

    XCTAssertLessThan(
      elapsed, Self.boundedQuitSeconds,
      "fixture precondition: the quit must have escaped its budget rather than waited the wedge "
        + "out; it took \(elapsed) s")
    XCTAssertTrue(
      database.isClosedForTermination,
      "fixture precondition: a spent budget must still close the funnel — that latch is the signal "
        + "this pin is about")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, [],
      "fixture precondition: the reindex must have been ACCEPTED, not refused at entry. A rejection "
        + "here would mean this pin never reproduced the window it exists for")

    releaseWedge.signal()
    pumpMainRunLoop(until: { writeFinished.isSet }, timeout: 20)
    XCTAssertTrue(writeFinished.isSet, "the abandoned write must return promptly, not hang")

    XCTAssertEqual(
      batches.value, 1,
      "the accepted reindex kept building after the termination latch closed: with a batch per "
        + "document, every increment past the first is a statement executed behind the fallback "
        + "checkpoint, and the whole transaction then commits behind it")
    XCTAssertFalse(
      writeReportedSuccess.isSet,
      "…and an abandoned write must report failure, because that is what stops its caller from "
        + "persisting the on-disk `.md` signature — the next launch has to cold-reindex rather than "
        + "skip over an index this quit never finished")
    XCTAssertEqual(
      try indexHits(matching: "abandonedreindexneedle", at: databaseURL), 0,
      "…and the transaction must have rolled back WHOLLY: `replaceSearchIndex` is a single "
        + "`pool.write`, so a partially-built reindex is not a smaller commit, it is no commit")
  }

  /// The same defect on the THIRD write path, and the one round 16 knowingly left open: the
  /// workspace-manifest upsert. `upsertWorkspace` has the entry guard and the write-gate seam, but
  /// nothing inside its `pool.write` ever asked whether the funnel had closed — so an accepted
  /// manifest commit that outlived the quit's budget wrote `documents` (and, through the triggers,
  /// FTS) rows and recreated WAL frames behind the terminal checkpoint, exactly as the reindex did.
  ///
  /// Two things make this path its own pin rather than a copy. Its batching lives one level down, in
  /// the shared `upsertDocuments(records:workspaceID:indexedAt:batchSize:didInsertBatch:latch:in:)`
  /// writer, so the consultation had to go to the batch BOUNDARY there — this writer counts only
  /// rows it actually wrote, so "one iteration" and "one batch" are not the same thing. And it
  /// returns `Void`: there is no `false` to carry the abandonment out to a caller. What must not
  /// happen is the rest of `commitWorkspaceManifest`'s hand-off recording the workspace as freshly
  /// scanned over rows that rolled back, and that is covered by refusal — `appendScanSession` and
  /// `refreshWorkspaceStats` are separate entry points which the funnel refuses. The manifest and
  /// fingerprint themselves are written BEFORE the index write is handed off, so no return value
  /// could have retracted them anyway.
  ///
  /// Handed over through `scheduleIndexWrite` because that is how production hands it over: the
  /// quit's drain then genuinely parks on this write instead of racing it.
  func testAnAcceptedWorkspaceUpsertStopsBuildingWhenTheQuitBudgetExpires() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let batches = Counter()
    let releaseWedge = DispatchSemaphore(value: 0)
    defer { releaseWedge.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.readerWedgeReleaseSeconds) {
      releaseWedge.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { _ in
        // Only the FIRST batch is held — see the reindex twin: holding every batch would park the
        // write again after the latch and prove nothing about whether the loop CHOSE to stop.
        guard batches.next() == 1 else { return }
        releaseWedge.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let refs = (0..<12).map { documentRef(root: root, name: "manifest-abandon-\($0).md") }
    for (offset, ref) in refs.enumerated() {
      try "abandonedmanifestneedle \(offset)".write(to: ref.url, atomically: true, encoding: .utf8)
    }
    let identity = WorkspaceIdentity.make(roots: [root], bookmarkData: nil)

    // The write's OWN app state, so the last assertion can tell "logged" from "reported": an
    // abandoned write must not raise a user-facing error on an app that is closing.
    let writeAppState = AppState()
    let writeFinished = CompletionFlag()
    database.scheduleIndexWrite {
      await database.upsertWorkspace(
        identity: identity,
        roots: [root],
        documents: refs,
        appState: writeAppState
      )
      writeFinished.isSet = true
    }
    pumpMainRunLoop(until: { batches.value >= 1 }, timeout: 10)
    XCTAssertEqual(
      batches.value, 1,
      "fixture precondition: the manifest upsert must be mid-build, holding the pool's writer "
        + "inside its transaction")

    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      folderManager: makeIsolatedFolderManager(
        in: folder, database: database, prefix: "AbandonedManifest"),
      autosaver: Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000),
      drainTimeout: Self.shrunkDrainBudget)
    let startedAt = Date()
    sequence.runBlockingMainRunLoop()
    let elapsed = Date().timeIntervalSince(startedAt)

    XCTAssertLessThan(
      elapsed, Self.boundedQuitSeconds,
      "fixture precondition: the quit must have escaped its budget rather than waited the wedge "
        + "out; it took \(elapsed) s")
    XCTAssertTrue(
      database.isClosedForTermination,
      "fixture precondition: a spent budget must still close the funnel — that latch is the signal "
        + "this pin is about")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, [],
      "fixture precondition: the manifest upsert must have been ACCEPTED, not refused at entry. A "
        + "rejection here would mean this pin never reproduced the window it exists for")

    releaseWedge.signal()
    pumpMainRunLoop(until: { writeFinished.isSet }, timeout: 20)
    XCTAssertTrue(writeFinished.isSet, "the abandoned write must return promptly, not hang")

    XCTAssertEqual(
      batches.value, 1,
      "the accepted workspace upsert kept building after the termination latch closed: with a batch "
        + "per document, every increment past the first is a statement executed behind the fallback "
        + "checkpoint, and the whole transaction then commits behind it")
    XCTAssertEqual(
      try indexHits(matching: "abandonedmanifestneedle", at: databaseURL), 0,
      "…and the transaction must have rolled back WHOLLY: the manifest upsert is a single "
        + "`pool.write` too, so a half-written workspace is not a smaller commit, it is no commit")
    XCTAssertNil(
      writeAppState.lastError,
      "…and abandonment is a decision the quit made about the index, not an error the user can act "
        + "on: it must be LOGGED like the reindex twin, never surfaced as \"could not update "
        + "workspace index\" on an app nobody can answer any more")
  }

  /// R20 / F1 — the same defect on the NO-LOOP member: the ordinary single-document save.
  ///
  /// `indexInBackground` is the write the production autosave/save tail takes, and until round 20 its
  /// `pool.write` (ensure-workspace + upsert) was the one transaction body in this file that never
  /// asked whether the funnel had closed. Round 16 skipped it with a "no loop" justification, and
  /// that argument only ever ruled out MID-transaction consultations — the one at transaction ENTRY
  /// is owed here exactly as it was owed to the batch paths.
  ///
  /// The window had to be MEASURED rather than assumed, and it is narrower than "every suspension
  /// after the entry guard". `awaitBackgroundWriteGate()`, `await previous?.value` and the open are
  /// all followed by `ensureOpenInBackground`'s own post-await latch consultation, so a write parked
  /// at any of them comes back to a `nil` pool and never reaches the transaction. What is left is the
  /// detached hop and the wait for the pool's SERIALIZED WRITER — and that is not a hairline: a save
  /// queued behind a long reindex sits there for the whole quit. `singleDocumentIndexWriteGateOverride`
  /// parks exactly in that slot: pool in hand, no lock held, transaction not yet open.
  ///
  /// Asserted at the SUBSTRATE, through an independent connection, because the returned `Bool` is not
  /// the contract — the rows and the WAL frames are. The terminal checkpoint is allowed to complete
  /// FIRST (the parked write holds neither the writer nor a reader), so `walSize == 0` before the
  /// release is a real precondition and any frame afterwards is a frame recreated behind the
  /// checkpoint that was supposed to be the last word.
  ///
  /// A safety valve opens the gate so a regressed build FAILS the assertions instead of hanging.
  func testAnAcceptedSingleDocumentIndexWriteStopsAtTheLatchWhenTheQuitBudgetExpires() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Seed frames so the terminal checkpoint has something to truncate — otherwise "the WAL is zero"
    // would be true before the quit and could not tell a rolled-back write from a checkpointed one.
    let seedRef = documentRef(root: root, name: "seed.md")
    try "singledocseedneedle".write(to: seedRef.url, atomically: true, encoding: .utf8)
    database.index(document: seedRef, body: "singledocseedneedle")
    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "fixture precondition: there must be WAL frames for the terminal checkpoint to truncate")

    let gate = ParkingGate()
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.readerWedgeReleaseSeconds) {
      Task { await gate.open() }
    }
    database.singleDocumentIndexWriteGateOverride = { await gate.arrive() }

    // The write's OWN app state, so the last assertion can tell "logged" from "reported".
    let writeAppState = AppState()
    let writeFinished = CompletionFlag()
    let writeReportedSuccess = CompletionFlag()
    let savedRef = documentRef(root: root, name: "late-save.md")
    try "abandonedsavedocneedle".write(to: savedRef.url, atomically: true, encoding: .utf8)
    // Handed over through `scheduleIndexWrite` because that is how the save tail hands it over: the
    // quit's drain then genuinely parks on this write instead of racing it.
    database.scheduleIndexWrite {
      let wrote = await database.indexInBackground(
        document: savedRef, body: "abandonedsavedocneedle", appState: writeAppState)
      writeReportedSuccess.isSet = wrote
      writeFinished.isSet = true
    }
    pumpMainRunLoop(until: { gate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertEqual(
      gate.arrivalCount, 1,
      "fixture precondition: the save's index write must be parked past its entry guard and past the "
        + "open, with the pool already in hand — that is the only window this entry point has")

    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      folderManager: makeIsolatedFolderManager(
        in: folder, database: database, prefix: "AbandonedSingleDoc"),
      autosaver: Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000),
      drainTimeout: Self.shrunkDrainBudget)
    let startedAt = Date()
    sequence.runBlockingMainRunLoop()
    let elapsed = Date().timeIntervalSince(startedAt)

    XCTAssertLessThan(
      elapsed, Self.boundedQuitSeconds,
      "fixture precondition: the quit must have escaped its budget rather than waited the wedge "
        + "out; it took \(elapsed) s")
    XCTAssertTrue(
      database.isClosedForTermination,
      "fixture precondition: a spent budget must still close the funnel — that latch is the signal "
        + "this pin is about")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, [],
      "fixture precondition: the save's write must have been ACCEPTED, not refused at entry. A "
        + "rejection here would mean this pin never reproduced the window it exists for")

    // The parked write holds neither the pool's writer nor a reader, so the terminal checkpoint can
    // and must finish while it waits. This is the state the resumed write must not be able to spoil.
    pumpMainRunLoop(until: { walSize(for: databaseURL) == 0 }, timeout: 10)
    XCTAssertEqual(
      walSize(for: databaseURL), 0,
      "fixture precondition: the terminal checkpoint must have taken the WAL to zero before the "
        + "parked write resumes (it is \(walSize(for: databaseURL)) bytes)")

    Task { await gate.open() }
    pumpMainRunLoop(until: { writeFinished.isSet }, timeout: 20)
    XCTAssertTrue(writeFinished.isSet, "the abandoned write must return promptly, not hang")

    // Measured BEFORE any new connection is opened, so the number is the write's doing and nothing
    // else's.
    let walAfterResume = walSize(for: databaseURL)
    XCTAssertEqual(
      walAfterResume, 0,
      "the accepted save committed after the termination latch closed: its frames land BEHIND the "
        + "terminal checkpoint, so the WAL→0 the quit promises is simply untrue (the WAL is "
        + "\(walAfterResume) bytes)")
    XCTAssertEqual(
      try indexHits(matching: "abandonedsavedocneedle", at: databaseURL), 0,
      "…and the transaction must have rolled back: a single-statement writer has no half-commit, so "
        + "the row is either absent or it is a row written behind the checkpoint")
    XCTAssertFalse(
      writeReportedSuccess.isSet,
      "…and an abandoned write must report failure, because that is what stops the save tail from "
        + "persisting an on-disk signature for an index write that never landed")
    XCTAssertNil(
      writeAppState.lastError,
      "…and abandonment is a decision the quit made about the index, not an error the user can act "
        + "on: it must be LOGGED like the reindex and manifest twins, never surfaced as \"could not "
        + "update Pensieve search index\" on an app nobody can answer any more")
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

  /// The half of the watcher quiescence `stop()` cannot reach, and the reason it cannot: the
  /// generation token is checked on the WATCHER's queue, one line above the `Task { @MainActor }`
  /// that carries the delivery to the main actor (`FileWatcher.start(watching:onEvents:)`). A batch
  /// that passed that check a moment before the quit is therefore already enqueued, and nothing in
  /// the quiescence retracts it: bumping the generation is too late, and `watcherRefreshTask?.cancel()`
  /// cancels the task that EXISTS, not the one this hop is about to arm. The quit then pumps the run
  /// loop, which is precisely what hands that hop the main actor — after quiescence, after the drain,
  /// in time to arm a fresh 300 ms refresh whose scan would ask the index to write.
  ///
  /// The construction is PLACED, not raced: `deliver` and `quiesceForTermination()` are two
  /// synchronous main-actor calls with no suspension point between them, so the hop is provably
  /// enqueued and provably has not run when the quit arrives.
  ///
  /// The control phase is load-bearing. A pin that only asserts "nothing was armed" passes just as
  /// happily when the fixture never reached the arming site at all, so the same delivery is first run
  /// through a LIVE manager and must arm a refresh. Only then is the second delivery meaningful.
  func testAQueuedWatcherHopArmsNoRefreshAfterTheQuiescence() async throws {
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
        defaults: makeEphemeralDefaults(prefix: "PensieveQueuedHopBookmarks")),
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
      "fixture precondition: opening a workspace must start the watcher, or there is no delivery to "
        + "queue")

    // CONTROL: the identical delivery on a live manager arms a refresh.
    let armedBeforeControl = manager.watcherRefreshGeneration
    try "changed while the app was running".write(to: noteURL, atomically: true, encoding: .utf8)
    source.deliver([
      FileWatcherEvent(path: noteURL.path, flags: [.itemIsFile, .itemModified])
    ])
    try await waitUntil("the control delivery to arm a watcher refresh") {
      manager.watcherRefreshGeneration > armedBeforeControl
    }
    await manager.waitForPendingWatcherRefresh()
    await settle(manager, indexDatabase)

    // THE PIN. Deliver, then quiesce, with nothing between them: the hop is past `FileWatcher`'s
    // generation check and has not run.
    try "changed a moment before the quit".write(to: noteURL, atomically: true, encoding: .utf8)
    let armedBeforeQuiesce = manager.watcherRefreshGeneration
    source.deliver([
      FileWatcherEvent(path: noteURL.path, flags: [.itemIsFile, .itemModified])
    ])
    manager.quiesceForTermination()

    // Give the enqueued hop the main actor — the quit's own pumped run loop is what does this in
    // production — and comfortably outlast the 300 ms debounce, so a refresh that WAS armed has had
    // every chance to arm, run, and reach the index.
    try await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertEqual(
      manager.watcherRefreshGeneration, armedBeforeQuiesce,
      "a watcher hop that was already queued when the quit quiesced must arm NOTHING: the drain has "
        + "finished, so a refresh armed here is a producer nobody is waiting for, scanning the tree "
        + "and asking the index to write behind the terminal checkpoint")
    XCTAssertEqual(
      indexDatabase.terminationRejectedEntryPoints, [],
      "…and it must be refused one layer ABOVE the latch: a refused entry point here would mean the "
        + "refresh ran and only the funnel stopped it")
  }

  /// Round 19, blocker 2. The sibling of the pin above, on the route the R17 fix does not cover.
  ///
  /// `moveToTrash` genuinely SUSPENDS: it parks on a `withCheckedContinuation` around Finder's
  /// `recycleItems` and only afterwards prunes, removes references, and calls
  /// `scheduleExplicitRefresh(forcePresentation: true)`. A quit that begins while it is parked
  /// therefore finds no `forcedRefreshTask` to cancel — there is none yet — and the termination
  /// run-loop pump is exactly what resumes the continuation. The arming site used to consult only
  /// `hasWorkspaceContent`, so the resumed call armed a full replacement scan whose `applyRefresh`
  /// publishes the workspace cache, commits the manifest, and asks the index to write, all after the
  /// drain has already taken its snapshots.
  ///
  /// This is a DIFFERENT route rather than a hole in R17: that round latched the watcher's queued hop,
  /// and correctly said `scheduleExplicitRefresh` was unreachable from one. It is reachable from here.
  ///
  /// Arming is observed through the injected scanner, because there is no public handle for a task
  /// that was never created: every refresh runs its walk through the builder, so zero invocations
  /// after the quiescence IS "nothing armed". The control ahead of it trashes an identical folder on a
  /// LIVE manager, so a fixture that silently stopped reaching the refresh at all would fail loudly
  /// instead of passing for the wrong reason.
  func testATrashResumedAfterTheQuiescenceArmsNoExplicitRefresh() async throws {
    let fixture = try TrashTestFixture.make()
    let liveFolderURL = fixture.root.appendingPathComponent("live", isDirectory: true)
      .standardizedFileURL
    let quitFolderURL = fixture.root.appendingPathComponent("quit", isDirectory: true)
      .standardizedFileURL
    for folder in [liveFolderURL, quitFolderURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try "# \(folder.lastPathComponent) note".write(
        to: folder.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    }

    let scanner = CountingWorkspaceBuilder()
    let harness = try makeTrashHarness(root: fixture.root, workspaceBuilder: scanner.builder)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }
    await harness.openWorkspace()

    // CONTROL: the identical trash on a live manager reconciles, and a reconcile is a scanner walk.
    scanner.reset()
    let armedBeforeControl = harness.folderManager.forcedRefreshGeneration
    let liveOperation = harness.requestTrash(liveFolderURL)
    await harness.waitForRecycleRequest()
    harness.completeRecycle()
    let liveDidTrash = await liveOperation.value
    XCTAssertTrue(liveDidTrash)
    await settle(harness.folderManager, harness.indexDatabase)
    XCTAssertGreaterThan(
      harness.folderManager.forcedRefreshGeneration, armedBeforeControl,
      "fixture precondition: a normal trash must still ARM its explicit refresh — the latch below is "
        + "quit-only, and a fixture that never reached the refresh would prove nothing")
    XCTAssertGreaterThan(
      scanner.invocations, 0, "…and that arming must really reach a scanner walk")
    XCTAssertFalse(treeContains(harness.appState.workspaceTree, url: liveFolderURL))

    // THE PIN. Park on the recycle continuation, quiesce, and only then resume — the ordering the
    // termination run-loop pump produces.
    scanner.reset()
    let armedBeforeQuiesce = harness.folderManager.forcedRefreshGeneration
    let quitOperation = harness.requestTrash(quitFolderURL)
    await harness.waitForRecycleRequest()
    harness.folderManager.quiesceForTermination()
    harness.completeRecycle()
    let quitDidTrash = await quitOperation.value
    XCTAssertTrue(
      quitDidTrash,
      "the trash itself must still succeed: the latch refuses the PRODUCER, it does not abort the "
        + "user's operation or its synchronous state repair")

    // Give anything that WAS armed every chance to arm, walk, and publish before asserting it wasn't.
    await settle(harness.folderManager, harness.indexDatabase)
    try await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
    await settle(harness.folderManager, harness.indexDatabase)

    XCTAssertEqual(
      harness.folderManager.forcedRefreshGeneration, armedBeforeQuiesce,
      "a continuation resumed after the quiescence must ARM no explicit refresh: the drain has taken "
        + "its snapshots, so a replacement scan armed here publishes workspace cache and manifest "
        + "state and asks the index to write behind the terminal checkpoint")
    XCTAssertEqual(
      scanner.invocations, 0,
      "…and nothing may reach a scanner walk either — refused at the arming site, so the walk is "
        + "never even started inside the quit's budget")
    XCTAssertFalse(
      treeContains(harness.appState.workspaceTree, url: quitFolderURL),
      "…while the synchronous half of the trash — prune, reference removal — is untouched by the "
        + "latch, so the quit still sees the state the user's action produced")
  }

  /// The successor half of the pin above: a refresh whose ARMING site was passed a moment before the
  /// latch closed, but whose task body only gets the main actor afterwards.
  ///
  /// `quiesceForTermination()` cancels `forcedRefreshTask`, but the body's only cancellation check
  /// sits AFTER its detached walk — so without a latch consultation inside the body, a quit still
  /// paid for a full tree scan it had already decided to discard, inside its own budget. The arming
  /// and the quiescence are two synchronous main-actor steps here with no suspension between them,
  /// which is exactly the production ordering: the body cannot have started yet.
  func testARefreshArmedAMomentBeforeTheQuiescenceStartsNoScanAfterIt() async throws {
    let fixture = try TrashTestFixture.make()
    try "# a note the refresh would walk".write(
      to: fixture.root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

    let scanner = CountingWorkspaceBuilder()
    let harness = try makeTrashHarness(root: fixture.root, workspaceBuilder: scanner.builder)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }
    await harness.openWorkspace()

    // CONTROL: the same arming on a live manager really does walk.
    scanner.reset()
    harness.folderManager.refresh(into: harness.appState, force: true)
    await settle(harness.folderManager, harness.indexDatabase)
    XCTAssertGreaterThan(
      scanner.invocations, 0,
      "fixture precondition: this arming must reach the scanner when nothing has quiesced")

    // THE PIN. Arm, then quiesce, with no suspension between them.
    scanner.reset()
    harness.folderManager.refresh(into: harness.appState, force: true)
    harness.folderManager.quiesceForTermination()

    await settle(harness.folderManager, harness.indexDatabase)
    try await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
    await settle(harness.folderManager, harness.indexDatabase)

    XCTAssertEqual(
      scanner.invocations, 0,
      "a body that reaches the main actor after the quiescence must not start its walk: the result "
        + "is discarded either way, and the walk is charged to the quit's budget")
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
  ///
  /// Round 9 amended the tail of this test, not its subject. It used to demand an EMPTY rejection
  /// list, reading any refusal as proof that the pool had been published behind the checkpoint. That
  /// inference stopped holding once the owner path grew its own post-await recheck: the owner and the
  /// drain are parked on the SAME task, so which of them resumes first is the scheduler's business,
  /// and an owner that resumes second is correctly handed nil. Published-inside-the-quit is now
  /// proved by the two assertions that actually mean it — the pool is published and the terminal
  /// checkpoint truncated the WAL — while the list is checked for anything OTHER than that one
  /// benign refusal.
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
    XCTAssertTrue(
      Set(database.terminationRejectedEntryPoints).isSubset(of: ["ensureOpenInBackground"]),
      "the ONLY refusal allowed after an open the drain waited for is the owner's own post-await "
        + "recheck, which fires whenever the drain's continuation is scheduled first. Anything else "
        + "here is real work that reached the funnel behind the terminal checkpoint. Got "
        + "\(database.terminationRejectedEntryPoints)")
    XCTAssertEqual(
      database.databaseURL, databaseURL,
      "…and the pool must be published — which is also what separates that benign refusal from a "
        + "REFUSED publication, since the latter leaves this nil — so the terminal checkpoint had a "
        + "database to truncate")
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

  // MARK: - R9: the OWNER of an open, resuming behind a latch that closed while it slept

  /// Round 9, finding 1 — the mirror of the joiner half round 6 fixed, and the last window left in
  /// the open-vs-latch family.
  ///
  /// The termination drain awaits the SAME `openTask` the owning caller is parked on. The instant
  /// that task publishes its pool both continuations become runnable, and the drain's may run first:
  /// it finds nothing else owed, the sequence closes the latch and takes the terminal checkpoint, and
  /// only THEN does the owner resume — holding a live pool for a database the quit has already
  /// finished with. The latch check inside the task cannot cover this: it refuses a latch that closed
  /// BEFORE publication, and here the latch closes after it.
  ///
  /// `indexInBackground` is the owner on purpose. It is a real workspace update, it consumes the
  /// open's return value directly, and given a pool it writes — so the assertion is not "a private
  /// function returned nil" but the property the finding is actually about: none of its payload is in
  /// the index. Read back through an INDEPENDENT connection, because the latched database refuses
  /// reads too.
  ///
  /// Honest limit, and the reason for the publication seam. Racing the two continuations for real is
  /// not a pin, it is a coin toss: measured over 15 runs of an earlier draft of this test the drain
  /// won 13 times and the owner 2, and an owner that wins writes legitimately (the drain then awaits
  /// its write and the checkpoint still goes last). So the latch is closed HERE, from inside the
  /// publishing step, which reaches the same state the drain produces when it wins — deterministically
  /// and with no continuation able to interleave. What is pinned is the contract ("a pool published
  /// before a latch may not be handed to a caller afterwards"), not the scheduler.
  func testTheOwnerOfAnOpenRefusesAPoolTheLatchClosedOverWhileItWasParked() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)
    XCTAssertNil(
      database.databaseURL,
      "fixture precondition: this database has never been opened, so the update below OWNS the open "
        + "rather than joining one")

    let gate = ParkingGate()
    database.databaseOpenGateOverride = { await gate.arrive() }
    // The drain, standing in for the one the sequence below runs: it awaits this very open, and when
    // its continuation is the first of the two to be scheduled it closes the latch at precisely this
    // instant — pool already published, owner still parked.
    database.didPublishDatabasePool = { [weak database] in database?.closeForTermination() }

    let ownerFinished = CompletionFlag()
    let ownerWroteThrough = CompletionFlag()
    Task { @MainActor in
      let didWrite = await database.indexInBackground(
        document: self.documentRef(root: folder, name: "owner-note.md"),
        body: "r9ownerpayload behind the terminal checkpoint")
      ownerWroteThrough.isSet = didWrite
      ownerFinished.isSet = true
    }
    pumpMainRunLoop(until: { gate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      gate.arrivalCount, 1,
      "fixture precondition: the update must be parked inside the open it owns, past the funnel gate "
        + "and already registered as `openTask`")
    XCTAssertFalse(ownerFinished.isSet, "fixture precondition: …and must not have completed")

    let quitFinished = CompletionFlag()
    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      folderManager: makeIsolatedFolderManager(in: folder, database: database, prefix: "OpenOwner"),
      autosaver: Autosaver())
    Task { @MainActor in
      await sequence.run()
      quitFinished.isSet = true
    }
    pumpMainRunLoop(until: { quitFinished.isSet }, timeout: 1)
    XCTAssertFalse(
      quitFinished.isSet,
      "fixture precondition: the drain must be parked on the very same `openTask`, which is what "
        + "makes this a race at all")

    Task { await gate.open() }
    pumpMainRunLoop(until: { quitFinished.isSet }, timeout: 10)
    XCTAssertTrue(quitFinished.isSet, "the quit must complete once the open is allowed through")
    pumpMainRunLoop(until: { ownerFinished.isSet }, timeout: 10)
    XCTAssertTrue(ownerFinished.isSet, "…and the refused owner must return promptly, not hang")

    XCTAssertEqual(
      database.databaseURL, databaseURL,
      "the pool must still be PUBLISHED: it was published before the latch closed, so the terminal "
        + "checkpoint saw it — this refusal discards nothing and tears nothing down, it only declines "
        + "to hand the pool onward")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, ["ensureOpenInBackground"],
      "…and the owner must be refused by name exactly once, AFTER its await: an empty list here means "
        + "the owner's continuation won the race and this test never reproduced the window")
    XCTAssertFalse(
      ownerWroteThrough.isSet,
      "…so the update must report that it wrote nothing")
    XCTAssertEqual(
      try indexHits(matching: "r9ownerpayload", at: databaseURL), 0,
      "…and nothing of its payload may be in the index, which is the whole point: a write through the "
        + "returned pool would land behind a checkpoint that has already been taken")
    XCTAssertEqual(
      walSize(for: databaseURL), 0,
      "…leaving the terminal checkpoint genuinely last (WAL is \(walSize(for: databaseURL)) bytes)")
  }

  // MARK: - R9: a second close must not orphan the first close's maintenance

  /// Round 9, finding 2 — the missing half of round 5's P9 await.
  ///
  /// `indexMaintenanceTask` is the ONLY handle to a close's housekeeping, and
  /// `scheduleIndexMaintenance(after:)` used to overwrite it. Close a workspace, reopen and close
  /// another before the first pass has finished, and the older task is dropped on the floor:
  /// `waitForPendingIndexMaintenance()` — the quit's one sync point — then awaits the newest handle
  /// only, while the orphan is still draining and can enter its vacuum + truncate after the terminal
  /// checkpoint has started, recreating WAL frames behind the operation meant to be final.
  ///
  /// The wedge sits INSIDE the maintenance pass, immediately before the detached vacuum, because
  /// that is the only state that proves anything — a pass parked before it was scheduled is simply a
  /// pass that does not exist yet. It holds the FIRST arrival only, which is precisely the finding's
  /// shape: an old pass still working while a new, quick one sails past it.
  ///
  /// The assertion that cannot pass by luck is the negative one: with the first pass held, the wait
  /// must NOT return. Unchained, the second pass runs to completion and releases it.
  func testASecondCloseDoesNotOrphanTheFirstClosesIndexMaintenance() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)
    XCTAssertEqual(
      database.databaseURL, databaseURL,
      "fixture precondition: the pool must be open, or maintenance returns before it ever reaches "
        + "the wedge")

    let manager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "MaintenanceChain")

    let log = EventLog()
    let arrivals = Counter()
    let gate = ParkingGate()
    database.maintenanceGateOverride = { _ in
      let arrival = arrivals.next()
      log.append("maintenance-\(arrival)-enter")
      // Only the FIRST pass is held. A gate that parked every pass would be satisfied by the buggy
      // build too — the second task would park in the first one's place and the wait would block for
      // the wrong reason.
      guard arrival == 1 else { return }
      await gate.arrive()
    }

    manager.closeWorkspace(into: appState)
    pumpMainRunLoop(until: { gate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertEqual(
      gate.arrivalCount, 1,
      "fixture precondition: the first close's maintenance must be parked inside its vacuum, past "
        + "every early return")

    // The second close. This is the assignment the finding is about: it replaces the only handle to
    // the pass that is still parked above.
    manager.closeWorkspace(into: appState)

    let waitReturned = CompletionFlag()
    Task { @MainActor in
      await manager.waitForPendingIndexMaintenance()
      log.append("wait-returned")
      waitReturned.isSet = true
    }
    pumpMainRunLoop(until: { waitReturned.isSet }, timeout: 1)
    XCTAssertFalse(
      waitReturned.isSet,
      "the quit's only maintenance sync point returned while the FIRST close's vacuum was still "
        + "parked: in production the terminal checkpoint would start here, and that orphaned pass "
        + "would truncate and rewrite the WAL behind it")
    XCTAssertEqual(
      gate.arrivalCount, 1,
      "…and the first pass must still be the one being held, not released early")

    log.append("gate-opened")
    Task { await gate.open() }
    pumpMainRunLoop(until: { waitReturned.isSet }, timeout: 10)
    XCTAssertTrue(
      waitReturned.isSet, "…and the wait must return once the held pass is allowed to finish")

    XCTAssertEqual(
      log.events, ["maintenance-1-enter", "gate-opened", "maintenance-2-enter", "wait-returned"],
      "…in that order: the second pass may not even ENTER its vacuum until the first has finished, "
        + "which is the compaction-after-writes ordering `scheduleIndexMaintenance(after:)` "
        + "documents, preserved for free by the chain")
  }

  // MARK: - R15 / B3: a late-waking truncation retry may not be overtaken by the latch

  /// Round 15 — the last producer the quit's drain could not see.
  ///
  /// The hot-path truncate's backoff ladder (`deferIndexBatchTruncation()`) sleeps OUTSIDE
  /// `scheduledIndexWrites`, deliberately: the drain must never have to wait out a timer. The cost of
  /// that is invisibility, and the sequence used to run drain → `waitForPendingIndexMaintenance()` →
  /// latch with nothing between the second wait and the latch. A retry waking DURING that wait clears
  /// its handle, re-enters `scheduleIndexBatchMaintenance()` and registers a maintenance pass after
  /// BOTH drains have returned — the outer one and the one the housekeeping task runs internally.
  /// That pass is a plain `pool.write` doing `incremental_vacuum` + truncate, so the latch and the
  /// terminal checkpoint can overtake it and leave WAL frames behind the operation that is supposed
  /// to be final.
  ///
  /// The wedges are placed, not raced. The close's housekeeping is parked at
  /// `maintenanceGateOverride`, which sits AFTER that task's own `drainPendingIndexWrites()` and
  /// after every early return — the only position that makes the window real; the sibling
  /// `maintenanceCompletionGateOverride` is never awaited for a `.workspaceClose` pass at all, so it
  /// could not reach this state. The retry is a REAL one: a genuine wedged pool reader refuses a
  /// genuine truncate, and the ladder takes ownership of the successor. The seam carries its
  /// `MaintenanceReason`, so "the close's pass" and "the retry's pass" are told apart by identity
  /// rather than by arrival order.
  ///
  /// The assertion that cannot pass by luck is the negative one: with the close's housekeeping
  /// released and the retry's pass still held, a quit that FINISHES has latched and checkpointed over
  /// a maintenance pass it never waited for.
  func testALateWakingTruncationRetryIsNotOvertakenByTheLatch() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // A genuine `pool.read` held open on a snapshot older than the write below, which is what makes
    // the truncate answer `SQLITE_BUSY` instead of succeeding. The release valve sits far above every
    // wait here, so a wrong build fails an assertion rather than being rescued by a timeout.
    let readerReached = Counter()
    let releaseReader = DispatchSemaphore(value: 0)
    defer { releaseReader.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.readerWedgeReleaseSeconds) {
      releaseReader.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didOpenBacklinkRead: {
        readerReached.increment()
        releaseReader.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let seedRef = documentRef(root: root, name: "seed.md")
    database.index(document: seedRef, body: "latewakingseedneedle")
    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "fixture precondition: there must be WAL frames for a reader to hold and a truncate to want")
    // Every pass is allowed to reach its truncate: the 16 MiB bound is not what this pin is about,
    // and leaving it in force would only make the fixture depend on how big the churn happened to be.
    database.walCheckpointThresholdBytesOverride = 1
    database.indexBatchTruncationRetryDelayNanosecondsOverride = Self.lateRetryDelayNanoseconds

    // 1 — wedge the reader, then arm the hot path so its truncate is REFUSED and the ladder takes
    //     ownership of the successor. This is the retry the rest of the pin is about.
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: seedRef, documents: [seedRef])
    }
    pumpMainRunLoop(until: { readerReached.value >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      readerReached.value, 1,
      "fixture precondition: the backlink query must be holding one of the pool's readers")

    Task { @MainActor in
      _ = await database.indexInBackground(
        document: documentRef(root: root, name: "arms-ladder.md"),
        body: "latewakingarmneedle", appState: appState)
    }
    pumpMainRunLoop(until: { database.indexBatchTruncationDeferrals >= 1 }, timeout: 10)
    XCTAssertEqual(
      database.indexBatchTruncationDeferrals, 1,
      "fixture precondition: the refused truncate must have deferred onto the backoff ladder — that "
        + "sleeping retry is the producer the drain cannot see")
    // Let the refused pass's own task clear the coalescing handle. Without this the retry would meet
    // round 14's absorption guard instead of arming a pass, which is a different (already pinned)
    // window.
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)

    // 2 — let the reader go, so the retry's pass can do real work rather than be refused again.
    releaseReader.signal()

    // 3 — park the close's housekeeping AFTER its internal drain. Installed only now, so a
    //     `.indexBatch` arrival at this seam can only be the ladder's retry.
    let closeGate = ParkingGate()
    let retryGate = ParkingGate()
    // Nothing in this pin opens a workspace, so the close's housekeeping must still be running into
    // a quiet index and the round-16 downgrade must not fire. Counted rather than folded into
    // `closeGate`, so a build that downgrades here fails an assertion instead of passing quietly.
    let downgradedArrivals = Counter()
    database.maintenanceGateOverride = { reason in
      switch reason {
      case .workspaceClose: await closeGate.arrive()
      case .indexBatch: await retryGate.arrive()
      case .workspaceCloseIntoOpenWorkspace: downgradedArrivals.increment()
      }
    }

    let folderManager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "LateRetry")
    folderManager.closeWorkspace(into: appState)
    pumpMainRunLoop(until: { closeGate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertEqual(
      closeGate.arrivalCount, 1,
      "fixture precondition: the close's housekeeping must be parked inside its vacuum — past its "
        + "own `drainPendingIndexWrites()`, which is what makes the window this pin needs")
    XCTAssertEqual(
      retryGate.arrivalCount, 0,
      "fixture precondition: the ladder's retry must still be ASLEEP when the quit starts, or the "
        + "pass it registers would be one the quit's first drain could still see")

    // 4 — the quit. Its drain finds nothing owed and parks on the housekeeping above; the retry wakes
    //     underneath it and registers a pass neither drain has seen.
    let quitFinished = CompletionFlag()
    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      folderManager: folderManager,
      autosaver: Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000))
    Task { @MainActor in
      await sequence.run()
      quitFinished.isSet = true
    }
    pumpMainRunLoop(until: { retryGate.arrivalCount >= 1 }, timeout: 20)
    XCTAssertEqual(
      retryGate.arrivalCount, 1,
      "fixture precondition: the ladder's retry must have woken and registered a maintenance pass "
        + "while the quit was parked on the close's housekeeping")
    XCTAssertFalse(quitFinished.isSet, "fixture precondition: …and the quit must still be waiting")

    // 5 — release the close's housekeeping ONLY. This is the instant the sequence used to latch.
    Task { await closeGate.open() }
    pumpMainRunLoop(until: { quitFinished.isSet }, timeout: Self.settleSeconds)

    XCTAssertFalse(
      quitFinished.isSet,
      "the quit latched and checkpointed while a maintenance pass registered by the truncation "
        + "ladder was still in flight. That pass is a plain `pool.write` doing `incremental_vacuum` "
        + "+ truncate, so its frames land BEHIND the terminal checkpoint — the WAL→0 the quit "
        + "promises is then simply untrue")
    XCTAssertFalse(
      database.isClosedForTermination,
      "…and the latch must not be closed over it either, for the same reason")
    XCTAssertEqual(
      retryGate.arrivalCount, 1,
      "…with that pass demonstrably still held, so this cannot be a slow-machine artefact")

    // 6 — and once it is allowed to finish, the quit completes with nothing refused behind it.
    Task { await retryGate.open() }
    pumpMainRunLoop(until: { quitFinished.isSet }, timeout: 20)
    XCTAssertTrue(
      quitFinished.isSet, "…and the quit must complete once the pass it waited for is done")
    XCTAssertTrue(
      database.isClosedForTermination, "a completed sequence must leave the funnel closed")
    XCTAssertTrue(
      database.isIndexBatchTruncationRetryQuiesced,
      "…and the ladder must have been stopped on the way there. That is what bounds the loop above: "
        + "without it, 'nothing is registered' never becomes 'nothing can be registered' and the "
        + "stability drain would be trusting a sleeping timer to stay asleep")
    XCTAssertFalse(
      database.terminationRejectedEntryPoints.contains("performMaintenanceInBackground"),
      "…and a pass the drain waited for is never a pass the latch has to refuse. Got "
        + "\(database.terminationRejectedEntryPoints)")
    XCTAssertEqual(
      downgradedArrivals.value, 0,
      "…and no pass may have taken the reopen downgrade: nothing here opens a workspace, so the "
        + "close's housekeeping owes the quit its reader-excluding WAL→0")
    XCTAssertEqual(
      database.barrierTimeMaintenanceDowngrades, 0,
      "…including round 20's LATER downgrade window, which the reason at the seam cannot show: the "
        + "quit's barrier is unconditional, and quiescence is what makes it so — the sequence stops "
        + "the watcher and cancels every refresh/build before it drains, so no open can arrive "
        + "between a close pass's decision and its lock while the process is closing")
    XCTAssertEqual(
      walSize(for: databaseURL), 0,
      "…and the terminal checkpoint is the last word on the WAL (it is "
        + "\(walSize(for: databaseURL)) bytes)")
  }

  // MARK: - R16 / F2: a close's housekeeping must not exclude the NEXT workspace's readers

  /// Round 16, finding 2 — the close pass that outlives the close.
  ///
  /// `closeWorkspace` arms `indexMaintenanceTask` and nobody on any OPEN path cancels it, awaits it
  /// or even looks at it. Its own head is where the seconds go — the predecessor pass, the caller's
  /// final write, `drainPendingIndexWrites()` — so `Close Folder` followed by `Open Folder`, an
  /// ordinary two-second sequence, lands the `.workspaceClose` pass inside the NEW workspace's
  /// opening searches. That pass takes `barrierWriteWithoutTransaction`, and in GRDB 6.29.3 that is
  /// the one lock which excludes the pool's reader CHECKOUTS (measured in round 12): every search,
  /// backlink and count in the fresh workspace waits it out.
  ///
  /// The wedged reader is what turns "waits it out" into something a test can decide without a
  /// stopwatch. A barrier cannot complete while a genuine `pool.read` is held, so on the old
  /// behaviour the close's housekeeping never finishes and the probe reads never come back. On the
  /// downgraded pass — plain write, `busy_timeout = 0`, `SQLITE_BUSY` means "not now" — both do.
  /// Neither assertion can pass by luck: they are the two halves of "no reader was excluded".
  ///
  /// The window is placed, not raced. An index write parked at `backgroundWriteGateOverride` holds
  /// the close pass at its own `drainPendingIndexWrites()` — the production position — so the next
  /// workspace demonstrably opens BEFORE the pass chooses its lock.
  func testACloseMaintenancePassDoesNotExcludeTheNextWorkspacesReaders() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let readerReached = Counter()
    let releaseReader = DispatchSemaphore(value: 0)
    defer { releaseReader.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.readerWedgeReleaseSeconds) {
      releaseReader.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didOpenBacklinkRead: {
        readerReached.increment()
        releaseReader.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let seedRef = documentRef(root: root, name: "seed.md")
    try "reopenmaintenanceseed".write(to: seedRef.url, atomically: true, encoding: .utf8)
    database.index(document: seedRef, body: "reopenmaintenanceseed")
    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "fixture precondition: there must be WAL frames for the close's pass to want to truncate")
    // Every pass is allowed to reach its checkpoint: the 16 MiB bound is not what this pin decides.
    database.walCheckpointThresholdBytesOverride = 1

    // 1 — a genuine pool reader, held for the whole experiment.
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: seedRef, documents: [seedRef])
    }
    pumpMainRunLoop(until: { readerReached.value >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      readerReached.value, 1,
      "fixture precondition: the backlink query must be holding one of the pool's readers")

    // 2 — an index write the close still owes, parked at the head of its task. This is what holds
    //     the close's housekeeping at its drain while the operator opens the next folder.
    let writeGate = ParkingGate()
    database.backgroundWriteGateOverride = { await writeGate.arrive() }
    let owedRef = documentRef(root: root, name: "still-owed.md")
    database.scheduleIndexWrite {
      _ = await database.indexInBackground(
        document: owedRef, body: "reopenmaintenanceowed", appState: nil)
    }
    pumpMainRunLoop(until: { writeGate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertEqual(
      writeGate.arrivalCount, 1,
      "fixture precondition: an index write must be owed and parked, or the close's housekeeping "
        + "sails past its drain and there is no window to open a workspace into")

    // 3 — the close. Its pass is armed and immediately parks behind the drain above.
    let reasonsAtTheLock = EventLog()
    database.maintenanceGateOverride = { reason in reasonsAtTheLock.append("\(reason)") }
    let manager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "ReopenMaintenance")
    manager.closeWorkspace(into: appState)
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)
    XCTAssertEqual(
      reasonsAtTheLock.events, [],
      "fixture precondition: the close's pass must still be behind its drain — a pass that already "
        + "chose its lock cannot be shown to notice the open that follows")

    // 4 — the next workspace, opened through the path the app actually uses. The synchronous
    //     sibling would rebuild the `DatabasePool`, which would strand the wedged reader on the old
    //     one and quietly dissolve the experiment.
    manager.openInBackground(url: root, into: appState)
    XCTAssertFalse(
      appState.workspaceRoots.isEmpty,
      "fixture precondition: the next workspace must actually have opened")

    // 5 — let the owed write through. The close's pass now chooses its lock, with a workspace open.
    Task { await writeGate.open() }

    let maintenanceFinished = CompletionFlag()
    Task { @MainActor in
      await manager.waitForPendingIndexMaintenance()
      maintenanceFinished.isSet = true
    }
    // Reads issued continuously from the moment the pass is released, so one of them is guaranteed
    // to ask for a reader connection while the pass holds its lock.
    let probeReads = Counter()
    let rootPaths = [root.standardizedFileURL.path]
    Task { @MainActor in
      while !maintenanceFinished.isSet {
        _ = await database.indexedDocumentCountInBackground(forRootPaths: rootPaths)
        probeReads.increment()
      }
    }

    pumpMainRunLoop(until: { maintenanceFinished.isSet }, timeout: 20)

    XCTAssertTrue(
      maintenanceFinished.isSet,
      "the close's housekeeping ran a reader-excluding barrier into the next workspace. With a "
        + "genuine pool reader held it cannot complete — and in production that is every search, "
        + "backlink and count in the freshly opened folder waiting on a vacuum the previous "
        + "workspace armed")
    XCTAssertGreaterThan(
      probeReads.value, 0,
      "…and the new workspace's reads must have kept flowing while it ran, which is the same fact "
        + "from the reader's side")
    // The owed write's own hot-path pass reaches this seam too — `.indexBatch` arrivals are
    // expected company. What must NOT appear is an undowngraded close.
    XCTAssertTrue(
      reasonsAtTheLock.events.contains("workspaceCloseIntoOpenWorkspace"),
      "…by DOWNGRADING rather than cancelling: cancelling would drop the WAL bound the close pass "
        + "exists to provide, and delaying the open on it would be worse still. Got "
        + "\(reasonsAtTheLock.events)")
    XCTAssertFalse(
      reasonsAtTheLock.events.contains("workspaceClose"),
      "…and no pass may still be claiming the quiet index this one no longer has. Got "
        + "\(reasonsAtTheLock.events)")
    XCTAssertGreaterThanOrEqual(
      database.indexBatchTruncationDeferrals, 1,
      "…and the bound must be deferred onto the backoff ladder rather than retired: the wedged "
        + "reader still holds WAL frames, so the truncate is owed, not done")
    XCTAssertFalse(
      database.isIndexBatchTruncationRetryQuiesced,
      "…with the ladder still live, since nothing here is quitting")
  }

  // MARK: - R20 / F2: the exclusion decision must hold AT the barrier, not merely at call time

  /// Round 20, finding 2 — the R16 downgrade through a later window.
  ///
  /// Round 16 decided the close pass's reason on the main actor immediately before the call and
  /// argued that no open could slip in, because `performMaintenanceInBackground` "only suspends once
  /// it reaches its detached work". That covered decision→call and nothing after it. Round 12 had
  /// already measured where the pass actually parks — BEFORE `Task.detached { barrier }` — and on the
  /// undowngraded path a one-off `VACUUM` conversion runs inside that detached closure before the
  /// lock is taken. `Open Folder` landing anywhere in that prologue left a `.workspaceClose` pass
  /// excluding the readers of a workspace that opened after it decided: the exact R16 symptom, one
  /// window later.
  ///
  /// `maintenanceGateOverride` parks in precisely that slot, which is why this pin can place the open
  /// rather than race it. The reason recorded AT the seam is `workspaceClose` — the call-time
  /// decision was exclusion, and that is the whole point: a build that downgraded earlier would be
  /// proving round 16's fix, not this one. The downgrade therefore has to be read from
  /// `barrierTimeMaintenanceDowngrades`, the only seam that can see it.
  ///
  /// The wedged reader is what makes it decidable without a stopwatch, as in the R16 twin: a barrier
  /// cannot complete while a genuine `pool.read` is held, so on the old behaviour the pass never
  /// finishes and the probe reads never come back. A safety valve releases the reader so a regressed
  /// build FAILS instead of hanging.
  func testACloseMaintenancePassRevalidatesItsDowngradeAtBarrierAcquisition() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let readerReached = Counter()
    let releaseReader = DispatchSemaphore(value: 0)
    defer { releaseReader.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.readerWedgeReleaseSeconds) {
      releaseReader.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didOpenBacklinkRead: {
        readerReached.increment()
        releaseReader.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let seedRef = documentRef(root: root, name: "seed.md")
    try "barrierrevalidationseed".write(to: seedRef.url, atomically: true, encoding: .utf8)
    database.index(document: seedRef, body: "barrierrevalidationseed")
    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "fixture precondition: there must be WAL frames for the close's pass to want to truncate")
    // Every pass is allowed to reach its checkpoint: the 16 MiB bound is not what this pin decides.
    database.walCheckpointThresholdBytesOverride = 1

    // 1 — a genuine pool reader, held for the whole experiment.
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: seedRef, documents: [seedRef])
    }
    pumpMainRunLoop(until: { readerReached.value >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      readerReached.value, 1,
      "fixture precondition: the backlink query must be holding one of the pool's readers")

    // 2 — the close, parked at the gap round 12 measured: past the reason decision, before the lock.
    let reasonsAtTheLock = EventLog()
    let closeGate = ParkingGate()
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.readerWedgeReleaseSeconds) {
      Task { await closeGate.open() }
    }
    database.maintenanceGateOverride = { reason in
      reasonsAtTheLock.append("\(reason)")
      guard reason == .workspaceClose else { return }
      await closeGate.arrive()
    }
    let manager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "BarrierRevalidation")
    manager.closeWorkspace(into: appState)
    pumpMainRunLoop(until: { closeGate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertEqual(
      closeGate.arrivalCount, 1,
      "fixture precondition: the close's pass must be parked INSIDE the gap — past its own drain and "
        + "past the reason it chose, but before the lock that reason selects")
    XCTAssertTrue(
      reasonsAtTheLock.events.contains("workspaceClose"),
      "fixture precondition: the CALL-TIME decision must have been exclusion, or this pin would be "
        + "re-proving round 16's fix instead of this one. Got \(reasonsAtTheLock.events)")

    // 3 — the next workspace, opened through the path the app actually uses, INTO the gap.
    manager.openInBackground(url: root, into: appState)
    XCTAssertFalse(
      appState.workspaceRoots.isEmpty,
      "fixture precondition: the next workspace must actually have opened")
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)

    // 4 — the observers first, so the reads are demonstrably in flight WHILE the pass runs. Armed
    //     after the release they could all land afterwards on a fast machine and prove nothing.
    let maintenanceFinished = CompletionFlag()
    Task { @MainActor in
      await manager.waitForPendingIndexMaintenance()
      maintenanceFinished.isSet = true
    }
    let probeReads = Counter()
    let rootPaths = [root.standardizedFileURL.path]
    Task { @MainActor in
      while !maintenanceFinished.isSet {
        _ = await database.indexedDocumentCountInBackground(forRootPaths: rootPaths)
        probeReads.increment()
      }
    }
    pumpMainRunLoop(until: { probeReads.value >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      probeReads.value, 1,
      "fixture precondition: the new workspace's reads must already be flowing before the pass is "
        + "released, or 'they kept flowing' would be a statement about scheduling luck")

    // 5 — release the pass. It now has to notice, at the lock, what it could not know when it chose.
    Task { await closeGate.open() }
    pumpMainRunLoop(until: { maintenanceFinished.isSet }, timeout: 20)

    XCTAssertTrue(
      maintenanceFinished.isSet,
      "the close's housekeeping took a reader-excluding barrier against a workspace that opened "
        + "after it chose. With a genuine pool reader held it cannot complete — and in production "
        + "that is every search, backlink and count in the freshly opened folder waiting on a vacuum "
        + "the previous workspace armed")
    // The exclusion proof is the assertion above, not this counter: with a genuine `pool.read` held
    // for the whole run, a barrier cannot complete AT ALL (round 12's measurement), so "it finished"
    // already means "it excluded nobody". This is the same fact from the reader's side, and it is
    // deliberately NOT asserted as "more reads after the release than before" — a downgraded pass is
    // a plain write of a fraction of a millisecond, so requiring the counter to straddle that instant
    // would be asserting the scheduler. What it does pin is that the new workspace's reads were in
    // flight against this pool while the pass was live.
    XCTAssertGreaterThanOrEqual(
      probeReads.value, 1,
      "…and the new workspace's reads must have been flowing against this pool while the pass ran")
    XCTAssertEqual(
      database.barrierTimeMaintenanceDowngrades, 1,
      "…by DOWNGRADING at the lock. The reason at the seam stays `workspaceClose` by construction — "
        + "the revalidation happens after it — so this counter is the only place the decision is "
        + "visible, and it is what tells a barrier-time downgrade from round 16's call-time one")
    XCTAssertGreaterThanOrEqual(
      database.indexBatchTruncationDeferrals, 1,
      "…with the WAL obligation deferred onto the backoff ladder rather than retired: the wedged "
        + "reader still holds frames, so the truncate is owed, not done")
    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "…which is the same fact at the substrate — a downgraded pass that had quietly dropped the "
        + "bound would leave a truncated WAL and nothing owed")
    XCTAssertFalse(
      database.didAttemptAutoVacuumConversion,
      "…and the one-off `VACUUM` conversion must be DEFERRED to the next real close, not retired by "
        + "a pass that gave way before paying for it")
  }

  /// The control for the pin above, and the half that keeps the quit honest: with nothing opening in
  /// the gap, the same sequence must still take the reader-excluding barrier.
  ///
  /// Without this, "revalidate at the barrier" could be satisfied by a build that simply never
  /// excludes readers again — which would silently retire the unconditional WAL→0 the last close
  /// before a quit is there to provide. No reader is wedged here on purpose: a correct build takes
  /// the barrier, and a barrier that has to wait out a reader would make the control a timing test
  /// rather than a contract test.
  func testACloseMaintenancePassStillExcludesReadersWhenNothingOpensInTheGap() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let seedRef = documentRef(root: root, name: "seed.md")
    try "barriercontrolseed".write(to: seedRef.url, atomically: true, encoding: .utf8)
    database.index(document: seedRef, body: "barriercontrolseed")
    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "fixture precondition: there must be WAL frames for the close's pass to truncate")
    database.walCheckpointThresholdBytesOverride = 1

    let reasonsAtTheLock = EventLog()
    let closeGate = ParkingGate()
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.readerWedgeReleaseSeconds) {
      Task { await closeGate.open() }
    }
    database.maintenanceGateOverride = { reason in
      reasonsAtTheLock.append("\(reason)")
      guard reason == .workspaceClose else { return }
      await closeGate.arrive()
    }
    let manager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "BarrierControl")
    manager.closeWorkspace(into: appState)
    pumpMainRunLoop(until: { closeGate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertEqual(
      closeGate.arrivalCount, 1,
      "fixture precondition: the close's pass must be parked in the same gap the downgrade pin uses")

    // The gap is opened and closed with NOTHING happening in it. That is the whole experiment.
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)
    Task { await closeGate.open() }

    let maintenanceFinished = CompletionFlag()
    Task { @MainActor in
      await manager.waitForPendingIndexMaintenance()
      maintenanceFinished.isSet = true
    }
    pumpMainRunLoop(until: { maintenanceFinished.isSet }, timeout: 20)
    XCTAssertTrue(maintenanceFinished.isSet, "the close's housekeeping must complete")

    XCTAssertEqual(
      database.barrierTimeMaintenanceDowngrades, 0,
      "no workspace opened, so nothing may have taken the barrier-time downgrade: the close still "
        + "owes the reader-excluding WAL→0 that makes the quit's promise unconditional. Got "
        + "\(reasonsAtTheLock.events)")
    XCTAssertTrue(
      database.didAttemptAutoVacuumConversion,
      "…and the undowngraded pass is the one allowed to spend the one-off `VACUUM` conversion, so "
        + "the flag it sets must still be set")
    XCTAssertEqual(
      walSize(for: databaseURL), 0,
      "…and the barrier's truncate is the last word on the WAL (it is "
        + "\(walSize(for: databaseURL)) bytes)")
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
      autosaver.armedIndexDocument(ownedBy: appState), ref.id,
      "fixture precondition: the armed debounce must belong to THIS window, over THIS document")
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
      autosaver.armedIndexDocument(ownedBy: otherState), otherRef.id,
      "fixture precondition: the armed debounce must belong to the OTHER window's document")

    // …and then its own autosave lands: bytes on disk, buffer clean, index debounce still asleep.
    // This is the R5 window, and the reason the flush must not be withheld here.
    try otherState.documentSession.text.write(to: otherURL, atomically: true, encoding: .utf8)
    otherState.documentSession.isDirty = false
    XCTAssertFalse(
      autosaver.armedIndexOwnerIsDirty(ownedBy: otherState),
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
      autosaver.armedIndexDocument(ownedBy: otherState), otherRef.id,
      "fixture precondition: the armed debounce must belong to the OTHER window's document")
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
      autosaver.armedIndexDocument(ownedBy: otherState), otherRef.id,
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

  // MARK: - R8: the SAVE debounce has an owner too

  /// Round 8 — the residual round 7 named in its own report, fixed before a reviewer asked for it.
  ///
  /// `Autosaver` holds one armed SAVE as well as one armed index write, and the save had no owner:
  /// `savePendingChangesOnClose` cancelled whatever happened to be armed. With two dirty windows both
  /// debounces belong to the one that edited last, so closing the OTHER window deleted the owner's
  /// pending 1.5 s autosave — the very write round 7 deliberately left that owner's index debounce
  /// ARMED to wait for. The index write then fired on its own 5 s schedule over text with nothing
  /// left to put it on disk: FTS ahead of disk in a RUNNING app, and a file-backed document has no
  /// recovery draft behind it if the process dies before the next save.
  ///
  /// The fix is the same minimal ownership round 7 gave the index side: cancel only what is yours. A
  /// foreign armed save stays armed and fires on its own schedule, which is what restores the order —
  /// so this is the end-to-end pin of the combined round 7 + round 8 behaviour, from the close to the
  /// index row. Both delays are shrunk through `Autosaver`'s init seam; the assertion is the ORDER,
  /// not the production timings.
  func testAClosingWindowLeavesAnotherWindowsArmedSaveToLandBeforeItsDeferredIndexWrite()
    async throws
  {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let ownerURL = folder.appendingPathComponent("debounce-owner.md")
    try "the owner's OLD body".write(to: ownerURL, atomically: true, encoding: .utf8)
    let ownerRef = DocumentRef(id: ownerURL.standardizedFileURL, isAdHoc: true)

    let closingURL = folder.appendingPathComponent("closing-window.md")
    try "the closing window's body".write(to: closingURL, atomically: true, encoding: .utf8)
    let closingRef = DocumentRef(id: closingURL.standardizedFileURL, isAdHoc: true)

    // Real writes on both sides: unlike the round 6/7 pins this one is about a save HAPPENING.
    let autosaver = Autosaver(saveDelayMilliseconds: 60, indexDelayMilliseconds: 400)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveForeignArmedSaveBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )

    // The owner window edits last, so it owns BOTH debounces, and its text exists only in memory.
    let ownerBody = "survivingneedle that must reach the disk before it reaches FTS"
    let ownerState = AppState()
    ownerState.documents = [ownerRef]
    ownerState.documentSession.load(document: ownerRef, text: "the owner's OLD body")
    ownerState.activeDocumentText = ownerBody
    store.documentDidChange(appState: ownerState)

    XCTAssertTrue(
      autosaver.armedSaveIsOwned(by: ownerState),
      "fixture precondition: the window that edited last must own an armed SAVE")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: ownerState), ownerRef.id,
      "fixture precondition: …and its armed index write, which round 7 defers to that save")

    // Everything from here to the close is synchronous on purpose: no suspension point, so neither
    // debounce can fire between arming and the assertions about what the close did to them.
    let closingState = AppState()
    closingState.documents = [closingRef]
    closingState.documentSession.load(document: closingRef, text: "the closing window's body")
    closingState.documentSession.isDirty = true
    XCTAssertFalse(
      autosaver.armedSaveIsOwned(by: closingState),
      "fixture precondition: the closing window must NOT own the armed save")

    XCTAssertTrue(
      store.savePendingChangesOnClose(appState: closingState),
      "fixture precondition: the closing window's own save must succeed")

    XCTAssertTrue(
      autosaver.armedSaveIsOwned(by: ownerState),
      "a close must not cancel a save it does not own: that write is precisely the one the owner's "
        + "deferred index debounce is waiting for, and deleting it leaves the index free to publish "
        + "text that no longer has anything scheduled to write it")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: ownerState), ownerRef.id,
      "…and round 7's deferral must still be in place, or this pin would prove nothing about the "
        + "order of the two")

    try await waitUntil("the foreign window's surviving autosave to land its bytes") {
      (try? String(contentsOf: ownerURL, encoding: .utf8)) == ownerBody
    }
    XCTAssertFalse(
      ownerState.documentSession.isDirty,
      "…and it is the OWNER's own debounce that cleaned its buffer, exactly as the deferral assumes")

    try await waitUntil("the deferred index write to fire over the saved bytes") {
      await database.drainPendingIndexWrites()
      return ((try? indexHits(matching: "survivingneedle", at: databaseURL)) ?? 0) == 1
    }
    XCTAssertEqual(
      try String(contentsOf: ownerURL, encoding: .utf8), ownerBody,
      "the whole ordering in one assertion: by the moment FTS advertises this text, the file on disk "
        + "already holds it")
  }

  /// The other half of the same rule, and the reason ownership is not simply "never cancel": a window
  /// closing over its OWN armed save must still cancel it. `savePendingChangesOnClose` writes those
  /// exact bytes synchronously, so a survivor would write the same file a second time — after the
  /// window is gone, and outside every ordering the close just established.
  func testAClosingWindowStillCancelsItsOwnArmedSaveSoTheCloseWritesExactlyOnce() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("own-armed-save.md")
    try "before the edit".write(to: noteURL, atomically: true, encoding: .utf8)
    let ref = DocumentRef(id: noteURL.standardizedFileURL, isAdHoc: true)

    let writes = Counter()
    let autosaver = Autosaver(saveDelayMilliseconds: 50, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: IndexDatabase(
        databaseURL: folder.appendingPathComponent("index.db", isDirectory: false)),
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveOwnArmedSaveBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true)),
      writeDocument: { text, url in
        if url.standardizedFileURL == ref.id { writes.increment() }
        try text.write(to: url, atomically: true, encoding: .utf8)
      },
      // Stubbed: this pin counts FILE writes, and the index path is round 7's subject, not this one's.
      indexDocument: { _, _, _ in }
    )

    let appState = AppState()
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "before the edit")
    appState.activeDocumentText = "the edit the close itself writes"
    store.documentDidChange(appState: appState)
    XCTAssertTrue(
      autosaver.armedSaveIsOwned(by: appState),
      "fixture precondition: this window must own its own armed save")

    XCTAssertTrue(
      store.savePendingChangesOnClose(appState: appState),
      "fixture precondition: the close must persist the buffer itself")
    XCTAssertEqual(writes.value, 1, "…in exactly one write")
    XCTAssertFalse(
      autosaver.armedSaveIsOwned(by: appState),
      "ownership SCOPES the cancel, it does not remove it: the close just wrote these bytes, so its "
        + "own debounce is redundant and must not survive the window")

    // Well past the shrunk debounce: a survivor would have fired by now.
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(
      writes.value, 1,
      "no second write may follow the close — that would be the file being written again by a "
        + "session that is already gone")
  }

  /// The third ownerless cancel the same sweep found, this one on the ARMING path.
  ///
  /// `scheduleIndexUpdate` bailed out of a session with no document by calling `cancelIndex()` — but
  /// an untitled session can never own the armed index debounce: `scheduleIndex` is only ever called
  /// WITH a document, and every path that drops a session's document (`loadClean`, `select(nil)`,
  /// `restoreRecoveredDraft`) already cancels this window's debounce on the way out. So the only
  /// debounce that call could reach belonged to somebody else, and typing one character into an
  /// untitled draft dropped a neighbouring window's pending index write. For an ad-hoc document that
  /// is permanent: no workspace signature ⇒ no cold-open self-heal, so the stale row is never
  /// revisited.
  func testTypingInAnUntitledWindowDoesNotDropAnotherWindowsArmedIndexDebounce() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("neighbour-note.md")
    try "before the neighbour's edit".write(to: noteURL, atomically: true, encoding: .utf8)
    let ref = DocumentRef(id: noteURL.standardizedFileURL, isAdHoc: true)

    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: IndexDatabase(
        databaseURL: folder.appendingPathComponent("index.db", isDirectory: false)),
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveUntitledNeighbourBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true)),
      indexDocument: { _, _, _ in }
    )

    let neighbourState = AppState()
    neighbourState.documents = [ref]
    neighbourState.documentSession.load(document: ref, text: "before the neighbour's edit")
    neighbourState.activeDocumentText = "neighbourneedle waiting out its index debounce"
    store.documentDidChange(appState: neighbourState)
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: neighbourState), ref.id,
      "fixture precondition: the neighbour must hold an armed index debounce")

    let untitledState = AppState()
    untitledState.documentSession.createUntitled()
    untitledState.activeDocumentText = "a draft that has never been saved anywhere"
    store.documentDidChange(appState: untitledState)

    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: neighbourState), ref.id,
      "an untitled window has no index debounce of its own to cancel, so cancelling here could only "
        + "ever throw away a neighbour's — and on an ad-hoc document nothing would ever repair it")
  }

  // MARK: - R10: the deadline cannot cost a window its bytes

  /// Round 10, finding 1 (P1, user-data loss) — and the pin that SUPERSEDES round 6's
  /// `testTheFinalWindowSavesLetTheDeadlinePumpRunBetweenFiles`.
  ///
  /// Round 6 put an `await Task.yield()` between the per-window saves so the pump could re-check the
  /// deadline at file granularity, and round 6's pin locked exactly that interleaving. The mechanism
  /// was real and the trade was wrong: with a suspension point inside phase F, the deadline can now
  /// expire WHILE the loop is parked between two windows. `runBlockingMainRunLoop()` then cancels the
  /// sequence and returns from `applicationWillTerminate`, and the continuation holding the remaining
  /// saves is queued on a main actor nobody pumps again — AppKit tears the process down and those
  /// buffers are gone. Budget observability is not worth a lost file.
  ///
  /// So phases Q and F moved OUT of the cancellable task entirely: they run synchronously on the
  /// calling thread, before the deadline exists.
  ///
  /// The pump seam is driven at its WORST here, and that is the honest way to pin this. The real
  /// failure ends outside any run loop — `applicationWillTerminate` returns and AppKit exits the
  /// process — so the state to reproduce is "the main actor is never serviced again", not "the run
  /// loop happened to slice between two files". A pump that services nothing is exactly that state,
  /// and it is the only shape in which the assertion is a contract rather than a scheduling
  /// observation: a real `RunLoop.run(mode:before:)` drains a freshly enqueued continuation within
  /// the SAME pass, so a build that loses window-b in production can still save it under test.
  ///
  /// Two dirty windows, a budget so small it is spent immediately, a drain that can never be
  /// satisfied (a background write parked at the write gate) and a pump that gives the sequence
  /// nothing. Both windows' bytes must be on disk when the quit returns, both saves must have
  /// happened BEFORE the budget started, and the quit must still be bounded.
  func testTheDeadlineCannotExpireBeforeEveryWindowHasWrittenItsBytes() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // The budget must be SPENT for this pin to mean anything: a parked background write gives the
    // drain something real to wait for, exactly as `testASpentDrainBudgetStillClosesTheFunnel` does.
    let gate = ParkingGate()
    database.backgroundWriteGateOverride = { await gate.arrive() }
    let parkedRef = documentRef(root: root, name: "parked-write.md")
    try "the write that never gets there".write(to: parkedRef.url, atomically: true, encoding: .utf8)
    let parkedWriteFinished = CompletionFlag()
    database.scheduleIndexWrite {
      await database.updateSearchIndexInBackground(
        upserting: [parkedRef], deletingPaths: [], appState: nil)
      parkedWriteFinished.isSet = true
    }
    pumpMainRunLoop(until: { gate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      gate.arrivalCount, 1,
      "fixture precondition: the drain must have something it genuinely cannot finish, or the "
        + "deadline never expires and this pin proves nothing")

    let log = EventLog()
    let registry = DocumentWindowRegistry()
    let folderManager = makeIsolatedFolderManager(in: folder, database: database, prefix: "SaveFirst")
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

      // The slow volume, injected: the FIRST window's write alone outlasts the whole budget, which
      // is the premise of the finding — a save loop that runs longer than the deadline it used to
      // live inside. The bytes must land anyway.
      let isSlow = name == "window-a"
      let windowState = AppState()
      let store = DocumentStore(
        autosaver: autosaver,
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveSaveFirst\(name)Bookmarks")),
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery-\(name)", isDirectory: true)),
        writeDocument: { text, url in
          if isSlow { Thread.sleep(forTimeInterval: Self.slowVolumeWriteSeconds) }
          log.append("save:\(url.deletingPathExtension().lastPathComponent)")
          try text.write(to: url, atomically: true, encoding: .utf8)
        }
      )
      windowState.documents = [ref]
      windowState.documentSession.load(document: ref, text: "before the quit")
      windowState.activeDocumentText = "savefirstneedle in \(name)"
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
      drainTimeout: Self.spentInstantlyDrainBudget,
      pumpRunLoop: { _ in log.append("pump") }
    ).runBlockingMainRunLoop()
    let elapsed = Date().timeIntervalSince(startedAt)

    let events = log.events
    for noteURL in noteURLs {
      XCTAssertEqual(
        try String(contentsOf: noteURL, encoding: .utf8),
        "savefirstneedle in \(noteURL.deletingPathExtension().lastPathComponent)",
        "every window's bytes must be on disk by the time the quit returns, with a pump that never "
          + "serviced anything. The drain budget bounds the INDEX phases; it must never be able to "
          + "abandon a save loop half-way, because a cancelled task's continuation is not guaranteed "
          + "to resume before AppKit exits the process (events: \(events))")
    }
    let saveIndices = events.indices.filter { events[$0].hasPrefix("save:") }
    XCTAssertEqual(
      saveIndices.count, 2, "…which means both saves actually ran (events: \(events))")
    XCTAssertGreaterThanOrEqual(
      events.filter { $0 == "pump" }.count, 1,
      "fixture precondition: the budget must genuinely have been waited on (events: \(events))")
    XCTAssertTrue(
      events.prefix(while: { $0 != "pump" }).filter { $0.hasPrefix("save:") }.count == 2,
      "…and both of them BEFORE the budget started: the user flush is not budgeted work, so no "
        + "window may be waiting on the deadline's pump for its bytes (events: \(events))")
    XCTAssertLessThan(
      elapsed, Self.boundedQuitSeconds,
      "…and the quit must stay bounded; it took \(elapsed) s")
    XCTAssertTrue(
      database.isClosedForTermination,
      "…and the funnel must end up closed, whichever path the sequence took")

    Task { await gate.open() }
    pumpMainRunLoop(until: { parkedWriteFinished.isSet }, timeout: 10)
  }

  // MARK: - R10: the drain re-reads the write tail until it stops moving

  /// Round 10, finding 2 — the last unlooped await in the drain.
  ///
  /// `drainPendingIndexWrites()` loops over the open handle and over the scheduled hand-offs, both by
  /// identity, and then took ONE snapshot of the supersede tail. Two background updates admitted
  /// around the same open can install their tails on either side of that snapshot: the first before
  /// the drain reads it, the second while the drain is already parked on the first. The snapshot
  /// returns as soon as the first finishes, the quit latches and checkpoints, and the second — long
  /// since past the funnel gate, and these entry points never re-check cancellation after the open —
  /// commits WAL frames behind the terminal checkpoint.
  ///
  /// Honesty about the driving (round 9's lesson): which continuation parked on a completed open
  /// resumes first is the scheduler's business, so the two tails are not RACED here, they are placed.
  /// Each update is caught at the write gate, which its task can only reach after the main-actor step
  /// that installed its tail. The drain is started between the two and given the run loop until it can
  /// only be parked on the first tail; only then is the second update admitted. That is the state the
  /// finding describes, reached deterministically instead of hoped for.
  ///
  /// Round 15 note on the driving, not on the contract: the first update used to be parked inside
  /// `databaseOpenGateOverride` and released from there, because the tail was installed only after the
  /// open returned. Positions are now RESERVED before the entry point's first suspension point (see
  /// `IndexDatabase.reserveSupersedePosition(_:)`), so the write gate alone places both tails and the
  /// open needs no wedge here — it happens inside the first write, behind that gate.
  ///
  /// The assertion that cannot pass by luck is the negative one: with the second tail installed and
  /// its write still held, a drain that returns has walked past a write it accepted.
  func testTheDrainWaitsForAWriteTailInstalledWhileItWasAlreadyDraining() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let database = IndexDatabase(databaseURL: databaseURL)
    XCTAssertNil(
      database.databaseURL,
      "fixture precondition: nothing may be open yet — the first update carries the initial open "
        + "with it, behind the write gate")

    let writeGate = OrderedParkingGate()
    database.backgroundWriteGateOverride = { await writeGate.arrive() }

    let firstRef = documentRef(root: root, name: "first-update.md")
    try "tailfirstneedle".write(to: firstRef.url, atomically: true, encoding: .utf8)
    let secondRef = documentRef(root: root, name: "second-update.md")
    try "tailsecondneedle".write(to: secondRef.url, atomically: true, encoding: .utf8)

    let firstFinished = CompletionFlag()
    Task { @MainActor in
      await database.updateSearchIndexInBackground(
        upserting: [firstRef], deletingPaths: [], appState: nil)
      firstFinished.isSet = true
    }
    pumpMainRunLoop(until: { writeGate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      writeGate.arrivalCount, 1,
      "fixture precondition: the first update's write must be parked at the write gate, which is "
        + "only reachable after the main-actor step that installed its tail")

    let drainFinished = CompletionFlag()
    Task { @MainActor in
      await database.drainPendingIndexWrites()
      drainFinished.isSet = true
    }
    // Nothing else is owed at this point — no open in flight, no scheduled hand-off — so once the
    // drain has had the run loop it can only be parked on the first tail.
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)
    XCTAssertFalse(
      drainFinished.isSet,
      "fixture precondition: the drain must be parked on the first tail, not finished")

    // The second update, admitted WHILE the drain is already awaiting the first: it chains onto the
    // first, installs itself as the new tail, and parks at the write gate behind it.
    let secondFinished = CompletionFlag()
    Task { @MainActor in
      await database.updateSearchIndexInBackground(
        upserting: [secondRef], deletingPaths: [], appState: nil)
      secondFinished.isSet = true
    }
    pumpMainRunLoop(until: { writeGate.arrivalCount >= 2 }, timeout: 10)
    XCTAssertGreaterThanOrEqual(
      writeGate.arrivalCount, 2,
      "fixture precondition: the second update must have installed its tail while the drain was "
        + "parked on the first")

    // Only the FIRST write is released. The second stays held, so "the drain returned" and "the
    // second write landed" cannot be confused for one another.
    Task { await writeGate.open(through: 1) }
    pumpMainRunLoop(until: { firstFinished.isSet }, timeout: 10)
    XCTAssertTrue(firstFinished.isSet, "fixture precondition: the first update must have completed")
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)

    XCTAssertFalse(
      drainFinished.isSet,
      "the drain returned as soon as the tail it had SNAPSHOTTED finished, while a second write it "
        + "had already accepted was still owed. The quit would latch and checkpoint here, and that "
        + "write — past the funnel gate, and never re-checking cancellation after the open — would "
        + "add WAL frames behind the terminal checkpoint")
    XCTAssertFalse(
      secondFinished.isSet, "fixture precondition: …with the second write demonstrably still held")

    Task { await writeGate.open(through: 2) }
    pumpMainRunLoop(until: { drainFinished.isSet }, timeout: 10)
    XCTAssertTrue(
      drainFinished.isSet, "…and the drain must complete once the moving tail finally stops")

    // The latch is what the drain protects; after a correct drain it has nothing left to refuse.
    database.closeForTermination()
    XCTAssertTrue(
      secondFinished.isSet,
      "…with every accepted write landed BEFORE the latch, not after it")
    XCTAssertEqual(
      try indexHits(matching: "tailfirstneedle", at: databaseURL), 1,
      "…and both writes must be in the index the terminal checkpoint is about to truncate")
    XCTAssertEqual(
      try indexHits(matching: "tailsecondneedle", at: databaseURL), 1,
      "…including the one that installed its tail mid-drain")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, [],
      "…and a drain that waited for everything leaves the latch with nothing to refuse. Got "
        + "\(database.terminationRejectedEntryPoints)")
  }

  // MARK: - R15 / B2: the supersede position is reserved before the first suspension point

  /// Round 15 — the ordering hole the initial open opened. All three background index entry points
  /// used to read `previous = pendingIndexUpdateTask`, then `await ensureOpenInBackground(...)`, and
  /// install their OWN tail only after that await returned. Two writes suspended on the same initial
  /// open therefore captured the SAME predecessor — neither had installed a tail yet — so neither
  /// awaited the other. Which of them then ran first was the scheduler's business, and the loser
  /// could be the user's NEWER text: the older body's `upsertDocument` replaces the row by path.
  /// GRDB serializes the two `pool.write`s; it does not order them. Ordering is exactly what the
  /// supersede chain exists to add, and a chain position taken AFTER a suspension point is not a
  /// position at all.
  ///
  /// Driving, not racing (round 9's lesson, and the reason this pin is deterministic where an
  /// ordering race could not be). The open is wedged for the whole test, so a build that reaches it
  /// has by definition suspended before reserving. Both writes are then submitted in order and the
  /// SECOND one is released alone at the write gate — reverse resumption, forced rather than hoped
  /// for. A build that reserved synchronously parks it on its predecessor's tail and it cannot even
  /// reach the open; a build that did not reserve never gets a write task to the gate in the first
  /// place, because it is still inside the open.
  ///
  /// Both halves are asserted: the STRUCTURAL one (positions taken with the open not yet attempted)
  /// and the BEHAVIOURAL one (whatever the release order, the newer text is what survives in
  /// `documents`/FTS).
  func testTwoWritesParkedOnTheInitialOpenKeepTheirSubmissionOrder() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let database = IndexDatabase(databaseURL: databaseURL)
    XCTAssertNil(
      database.databaseURL,
      "fixture precondition: nothing may be open yet — the finding is about the INITIAL open, which "
        + "is the one suspension point every entry point is guaranteed to hit")

    let openGate = ParkingGate()
    let writeGate = OrderedParkingGate()
    database.databaseOpenGateOverride = { await openGate.arrive() }
    database.backgroundWriteGateOverride = { await writeGate.arrive() }

    // ONE document, written twice: old then new. The upsert replaces the row by path, so "which
    // body is on disk at the end" is a direct read of which write landed last.
    let ref = documentRef(root: root, name: "superseded.md")

    let olderFinished = CompletionFlag()
    Task { @MainActor in
      _ = await database.indexInBackground(
        document: ref, body: "supersedeoldneedle", appState: nil)
      olderFinished.isSet = true
    }
    pumpMainRunLoop(until: { writeGate.arrivalCount >= 1 }, timeout: 10)

    let newerFinished = CompletionFlag()
    Task { @MainActor in
      _ = await database.indexInBackground(
        document: ref, body: "supersedenewneedle", appState: nil)
      newerFinished.isSet = true
    }
    pumpMainRunLoop(until: { writeGate.arrivalCount >= 2 }, timeout: 10)

    XCTAssertGreaterThanOrEqual(
      writeGate.arrivalCount, 2,
      "both writes must have a task at the write gate, which they can only reach after the "
        + "main-actor step that installed their tail. A build that captures its predecessor and "
        + "then awaits the open before reserving is still parked INSIDE that open here, with no "
        + "task, no tail, and — for the second write — the same predecessor as the first")
    XCTAssertEqual(
      openGate.arrivalCount, 0,
      "…and neither may have reached the open yet: the position in the chain has to be taken "
        + "BEFORE the call's first suspension point, or it is taken from a state two callers share")

    // Reverse resumption, forced: the NEWER write is released alone while the older one is still
    // held at the gate.
    Task { await writeGate.open(only: 2) }
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)
    XCTAssertEqual(
      openGate.arrivalCount, 0,
      "the newer write must be parked on its PREDECESSOR's tail, not racing it: reaching the open "
        + "here means it chained onto nothing and would commit whenever the scheduler let it")
    XCTAssertFalse(
      newerFinished.isSet, "fixture precondition: …with that write demonstrably still owed")

    // Now the older one, and the open behind it.
    Task { await writeGate.open(through: 2) }
    pumpMainRunLoop(until: { openGate.arrivalCount >= 1 }, timeout: 10)
    Task { await openGate.open() }
    pumpMainRunLoop(until: { olderFinished.isSet && newerFinished.isSet }, timeout: 10)
    XCTAssertTrue(
      olderFinished.isSet && newerFinished.isSet,
      "fixture precondition: both writes must have completed once the open was released")

    XCTAssertEqual(
      try indexHits(matching: "supersedenewneedle", at: databaseURL), 1,
      "the NEWER body is what the user last saved, so it is what the index must advertise")
    XCTAssertEqual(
      try indexHits(matching: "supersedeoldneedle", at: databaseURL), 0,
      "…and the older body must not have overwritten it on the way out of a shared open")
  }

  // MARK: - R11: the producer that produces producers

  /// Round 11, finding 1 (P2) — the sixth producer outside phase Q's inventory, and the only one that
  /// can rebuild all the others.
  ///
  /// The initial scene arms `LaunchIntentCoordinator.startWhenLaunchIntentsSettle` and returns. Quit
  /// before that task settles and it runs inside the quit's OWN pumped run loop, calling
  /// `controller.start` — which restores the workspace and creates fresh validation, build, watcher,
  /// manifest and index work after `FolderManager` was quiesced. The manifest/cache half of that can
  /// still commit while its post-latch index write is refused, which leaves the launch metadata ahead
  /// of FTS for the next cold start's skip decision: a stale index the skip-gate believes is current.
  ///
  /// The observable is deliberately the SYNCHRONOUS limb of `controller.start`. Its other two limbs
  /// (the background index warm-up, the workspace restore) are tasks, so asserting on them would be
  /// asserting on the scheduler; `documentStore.restoreRecoveredDraft` is a plain call inside `start`,
  /// so a seeded recovery draft that is still unclaimed afterwards is proof the method never ran —
  /// with no timing in the claim at all.
  ///
  /// Note what a bare `cancel()` would NOT have done here, which is why the fix is a one-way latch:
  /// the startup task's only suspension is `try? await Task.sleep(...)`, so cancelling it merely
  /// makes the sleep return early and the body proceeds to `controller.start` regardless.
  func testQuitBeforeTheLaunchIntentSettlesCannotRestartTheProducersPhaseQStopped() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // The synchronous side-effect of `controller.start`, seeded so its absence is observable.
    let recoveryStore = RecoveryStore(
      directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    _ = try recoveryStore.saveDraft(
      id: nil, title: "Recovered Untitled.md", text: "launchintentneedle from the previous session")

    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveLaunchIntentQuiesceBookmarks")),
      recoveryStore: recoveryStore
    )
    let folderManager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "LaunchIntentQuiesce")
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

    // Armed and NOT settled — the ten-second delay is the launch that is still making up its mind
    // when the user quits. Nothing here sleeps for it; the quit is what runs next.
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 10_000_000_000)
    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch)
    XCTAssertFalse(
      appState.documentSession.hasEditableBuffer,
      "fixture precondition: the startup decision must still be pending, so nothing has restored yet")

    let delegate = PensieveAppDelegate()
    delegate.terminationWindowRegistryOverride = registry
    delegate.terminationIndexDatabaseOverride = database
    delegate.terminationFolderManagerOverride = folderManager
    delegate.terminationAutosaverOverride = autosaver
    delegate.terminationLaunchIntentCoordinatorOverride = coordinator
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification))

    // Everything that CAN still run gets its chance — this pin asserts that something did NOT happen.
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)

    XCTAssertNotNil(
      recoveryStore.claimDraftForRestore(),
      "the launch-intent startup task must not run after phase Q: the draft it would have claimed is "
        + "still pending, which is only true if `controller.start` never ran")
    XCTAssertFalse(
      appState.documentSession.hasEditableBuffer,
      "…so no session was restored into a window the quit has already flushed")
    XCTAssertTrue(
      appState.workspaceRoots.isEmpty,
      "…and no workspace was restored, which is the producer chain — validation, build, watcher, "
        + "manifest, index — phase Q had just stopped")
    XCTAssertEqual(
      database.terminationRejectedEntryPoints, [],
      "…and nothing reached the funnel after the latch, which is what a producer restarted inside "
        + "the pumped run loop would have done. Got \(database.terminationRejectedEntryPoints)")
  }

  /// The other half of the same contract, and the control that stops the pin above from passing
  /// because the coordinator was simply broken: a startup that SETTLED before the quit is untouched.
  ///
  /// This is the ordinary launch — the scene armed the coordinator, it settled, the window restored
  /// its draft — and it must stay exactly as it was. The latch is one-way, but it is only set by
  /// `quiesceForTermination()`, so nothing here may refuse.
  func testALaunchIntentThatSettledBeforeTheQuitStillStartedItsWindow() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let recoveryStore = RecoveryStore(
      directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    _ = try recoveryStore.saveDraft(
      id: nil, title: "Recovered Untitled.md", text: "settledlaunchneedle from the previous session")

    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveSettledLaunchBookmarks")),
      recoveryStore: recoveryStore
    )
    let folderManager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "SettledLaunch")
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

    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)
    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    XCTAssertTrue(
      appState.documentSession.hasEditableBuffer,
      "an ordinary launch must still restore its recovery draft — the termination latch may only be "
        + "set by `quiesceForTermination()`, never by arming")
    XCTAssertEqual(
      appState.documentSession.text, "settledlaunchneedle from the previous session",
      "…with the draft's own bytes, not an empty buffer")
  }

  // MARK: - R11: a session change may not disarm another window's index debounce

  /// Round 11, finding 2 (P2) — the sites 1–4 residual round 8 named consciously, now collected.
  ///
  /// `cancelOwnDebouncesOnSessionChange` narrowed the SAVE half to the calling window in round 8 and
  /// deliberately left the INDEX half unconditional. The two halves are one mechanism, though: window
  /// B arms both, window A switches document, B's save survives and B's index write is thrown away.
  /// B's 1.5 s autosave then writes its edited text through `saveExisting(indexNow: false)` — which
  /// indexes nothing by contract — so the bytes land and the FTS row stays stale. On the AD-HOC
  /// document used here that is permanent: no workspace signature ⇒ no cold-open self-heal.
  ///
  /// Read back through an INDEPENDENT connection, and the disk is read too: the assertion is that
  /// FTS matches what is on disk, not merely that a row exists.
  func testASessionChangeInOneWindowLeavesAnotherWindowsIndexDebounceArmed() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Outside every workspace root: the document class whose stale FTS row nothing ever repairs.
    let neighbourURL = folder.appendingPathComponent("neighbour.md")
    try "before the neighbour's edit".write(to: neighbourURL, atomically: true, encoding: .utf8)
    let neighbourRef = DocumentRef(id: neighbourURL.standardizedFileURL, isAdHoc: true)

    let switcherURL = folder.appendingPathComponent("switcher-target.md")
    try "the document window A switches to".write(
      to: switcherURL, atomically: true, encoding: .utf8)
    let switcherRef = DocumentRef(id: switcherURL.standardizedFileURL, isAdHoc: true)

    // A short save debounce and a slightly longer index debounce reproduce the live 1.5 s / 5 s
    // ordering without a real-second sleep: the save lands first, the index write follows it.
    let autosaver = Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 200)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveForeignIndexDebounceBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )

    // Window B: edits, arms both debounces, and is the window that must survive untouched.
    let neighbourState = AppState()
    neighbourState.documents = [neighbourRef]
    neighbourState.documentSession.load(document: neighbourRef, text: "before the neighbour's edit")
    neighbourState.activeDocumentText = "foreignindexneedle waiting out its index debounce"
    store.documentDidChange(appState: neighbourState)
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: neighbourState), neighbourRef.id,
      "fixture precondition: window B must hold an armed index debounce")

    // Window A, variant 1: an ordinary document switch. Its own session is clean and holds a
    // DIFFERENT document, so the debounce it is about to reach can only ever be somebody else's.
    let switcherState = AppState()
    switcherState.documents = [switcherRef]
    store.load(ref: switcherRef, into: switcherState)
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: neighbourState), neighbourRef.id,
      "a document switch in window A must leave window B's index debounce ARMED — cancelling it "
        + "here is the loss of freshness the save half was narrowed for in round 8")

    // Window A, variant 2: an untitled buffer saved under a new name. Same rule, a different call
    // site (`saveAs`), and the one that also writes bytes of its own on the way through.
    let savingState = AppState()
    savingState.documentSession.createUntitled()
    savingState.activeDocumentText = "a draft window A is about to name"
    XCTAssertTrue(
      store.saveAs(appState: savingState, to: folder.appendingPathComponent("named-by-a.md")),
      "fixture precondition: window A's save-as must succeed, or the call site under test is never "
        + "reached")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: neighbourState), neighbourRef.id,
      "…and a save-as in window A must not disarm it either")

    // Now let window B's own timers run: the 20 ms save lands the bytes, the 200 ms index debounce
    // fires over them.
    try await waitUntil("window B's autosave to land its bytes on disk") {
      (try? String(contentsOf: neighbourURL, encoding: .utf8))?.contains("foreignindexneedle")
        == true
    }
    try await waitUntil("window B's surviving index debounce to publish those bytes") {
      await database.waitForPendingReindex()
      return (try? self.indexHits(matching: "foreignindexneedle", at: databaseURL)) == 1
    }

    XCTAssertEqual(
      try String(contentsOf: neighbourURL, encoding: .utf8),
      "foreignindexneedle waiting out its index debounce",
      "window B's bytes must be on disk…")
    XCTAssertEqual(
      try indexHits(matching: "foreignindexneedle", at: databaseURL), 1,
      "…and FTS must agree with them. An unconditional `cancelIndex()` on the session-change path "
        + "leaves this at 0 for good: the autosave that follows indexes nothing by contract, and an "
        + "ad-hoc document has no workspace signature to trigger a cold-open repair")
  }

  // MARK: - R15: the debounces are held PER WINDOW

  /// Round 15, blocker 1 (P1, user-data loss) — the residual rounds 7, 8 and 11 named and deferred,
  /// and the one that costs bytes without anybody closing anything.
  ///
  /// `Autosaver` held ONE armed save and ONE armed index write, and every arming cancelled whatever
  /// was there. So the defect needed no close, no quit and no unusual timing: window A is edited,
  /// window B is edited less than 1.5 s later, and A's pending save is gone — silently, while both
  /// windows are still open. A's bytes then live only in its buffer, with nothing scheduled to write
  /// them; a crash, a force-quit or a log-out loses the edit, and a FILE-BACKED document has no
  /// recovery draft behind it. One debounce over, B's arming also dropped A's index write, which on
  /// an ad-hoc document is a permanently stale FTS row (no workspace signature ⇒ no cold-open
  /// self-heal). Every ownership rule the previous rounds added guarded the CANCEL paths; none of
  /// them was reached here.
  ///
  /// The pin is deliberately end-to-end and asserts about BOTH sides. The two edits are separated by
  /// no suspension point, so B really does arm inside A's debounce window, and the structural
  /// assertions run before either timer can fire. Then both files must end up holding their OWN text
  /// and both index writes must land — the singleton behaviour leaves A's file at its pre-edit body
  /// and A's needle out of FTS for good.
  func testEditingASecondWindowDoesNotCancelTheFirstWindowsPendingSaveOrIndexWrite() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    // Ad-hoc on both sides: the document class whose stale FTS row nothing ever repairs, so a
    // dropped index write is permanent rather than merely late.
    let urlA = folder.appendingPathComponent("window-a.md")
    try "window A before the edit".write(to: urlA, atomically: true, encoding: .utf8)
    let refA = DocumentRef(id: urlA.standardizedFileURL, isAdHoc: true)

    let urlB = folder.appendingPathComponent("window-b.md")
    try "window B before the edit".write(to: urlB, atomically: true, encoding: .utf8)
    let refB = DocumentRef(id: urlB.standardizedFileURL, isAdHoc: true)

    // The production 1.5 s / 5 s ordering, shrunk through `Autosaver`'s own init seam: the save
    // lands first, the index write follows it. The assertion is the ORDER and the OWNERSHIP, never
    // the timings.
    let autosaver = Autosaver(saveDelayMilliseconds: 40, indexDelayMilliseconds: 200)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensievePerWindowDebounceBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )

    let bodyA = "windowaneedle that must not be cancelled by another window"
    let stateA = AppState()
    stateA.documents = [refA]
    stateA.documentSession.load(document: refA, text: "window A before the edit")
    stateA.activeDocumentText = bodyA
    store.documentDidChange(appState: stateA)

    // No suspension point between the two edits: window B arms strictly INSIDE window A's debounce,
    // which is the entire scenario.
    let bodyB = "windowbneedle from the window that edited second"
    let stateB = AppState()
    stateB.documents = [refB]
    stateB.documentSession.load(document: refB, text: "window B before the edit")
    stateB.activeDocumentText = bodyB
    store.documentDidChange(appState: stateB)

    XCTAssertTrue(
      autosaver.armedSaveIsOwned(by: stateA),
      "arming for window B must not take window A's pending save: nothing else is scheduled to put "
        + "A's buffer on disk, and a file-backed document has no recovery draft behind it")
    XCTAssertTrue(
      autosaver.armedSaveIsOwned(by: stateB),
      "…and B's own save must be armed, or this pin would pass on an autosaver that simply never "
        + "arms")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateA), refA.id,
      "…and the same holds one debounce over: B's arming must not drop A's index write, which on an "
        + "ad-hoc document nothing would ever re-issue")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateB), refB.id,
      "…with B holding its own")

    try await waitUntil("both windows' autosaves to land their own bytes") {
      (try? String(contentsOf: urlA, encoding: .utf8)) == bodyA
        && (try? String(contentsOf: urlB, encoding: .utf8)) == bodyB
    }
    XCTAssertEqual(
      try String(contentsOf: urlA, encoding: .utf8), bodyA,
      "each file must hold ITS OWN text: the loss this pin forbids is A's edit staying in memory "
        + "while B's is written")
    XCTAssertEqual(try String(contentsOf: urlB, encoding: .utf8), bodyB)

    try await waitUntil("both windows' deferred index writes to publish those bytes") {
      await database.drainPendingIndexWrites()
      return ((try? self.indexHits(matching: "windowaneedle", at: databaseURL)) ?? 0) == 1
        && ((try? self.indexHits(matching: "windowbneedle", at: databaseURL)) ?? 0) == 1
    }
    XCTAssertEqual(
      try indexHits(matching: "windowaneedle", at: databaseURL), 1,
      "…and BOTH index writes must land, in the order their saves did")
    XCTAssertEqual(try indexHits(matching: "windowbneedle", at: databaseURL), 1)
  }

  /// The round 8 residual that per-owner keying closes on the way: two windows open on the SAME file.
  ///
  /// Ownership on the index side used to be the document URL, so `cancelArmedIndexIfOwned` could not
  /// tell "my own debounce over this file" from "the other window's debounce over the same file". A
  /// perfectly ordinary document switch in window B therefore threw away window A's pending index
  /// write over A's unsaved text — and for an ad-hoc document that row is never revisited. Keying on
  /// the SESSION makes the two distinguishable: B simply has no entry of its own to cancel.
  ///
  /// End-to-end, because "still armed" is only half the claim: A's own autosave must then land its
  /// bytes and A's surviving debounce must publish exactly those bytes.
  func testASessionChangeInASecondWindowOnTheSameFileLeavesTheFirstWindowsDebounceArmed()
    async throws
  {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let sharedURL = folder.appendingPathComponent("shared-by-two-windows.md")
    try "the shared file before the edit".write(to: sharedURL, atomically: true, encoding: .utf8)
    let sharedRef = DocumentRef(id: sharedURL.standardizedFileURL, isAdHoc: true)

    let elsewhereURL = folder.appendingPathComponent("window-b-switches-here.md")
    try "the document window B switches to".write(
      to: elsewhereURL, atomically: true, encoding: .utf8)
    let elsewhereRef = DocumentRef(id: elsewhereURL.standardizedFileURL, isAdHoc: true)

    let autosaver = Autosaver(saveDelayMilliseconds: 40, indexDelayMilliseconds: 200)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveSameFileDebounceBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )

    let bodyA = "sharedfileneedle from the window that is not switching"
    let stateA = AppState()
    stateA.documents = [sharedRef]
    stateA.documentSession.load(document: sharedRef, text: "the shared file before the edit")
    stateA.activeDocumentText = bodyA
    store.documentDidChange(appState: stateA)
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateA), sharedRef.id,
      "fixture precondition: window A must hold an armed index debounce over the shared file")

    // Window B is open on the SAME document and is clean, so its switch is the ordinary path — the
    // one that used to match on the URL and cancel a debounce belonging to somebody else.
    let stateB = AppState()
    stateB.documents = [sharedRef, elsewhereRef]
    stateB.documentSession.load(document: sharedRef, text: "the shared file before the edit")
    XCTAssertNil(
      autosaver.armedIndexDocument(ownedBy: stateB),
      "fixture precondition: window B must have armed nothing of its own — it only ever reads")

    store.load(ref: elsewhereRef, into: stateB)

    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateA), sharedRef.id,
      "a switch in a window that shares the FILE must leave the other window's debounce armed: "
        + "sharing a document is not owning its debounce, and on an ad-hoc document dropping it is "
        + "permanent")

    try await waitUntil("window A's autosave to land its bytes on disk") {
      (try? String(contentsOf: sharedURL, encoding: .utf8)) == bodyA
    }
    try await waitUntil("window A's surviving index debounce to publish those bytes") {
      await database.drainPendingIndexWrites()
      return ((try? self.indexHits(matching: "sharedfileneedle", at: databaseURL)) ?? 0) == 1
    }
    XCTAssertEqual(
      try String(contentsOf: sharedURL, encoding: .utf8), bodyA,
      "…and FTS must agree with the disk, which is the whole point of not dropping the write")
  }

  /// Round 18. Two windows on the SAME file, and the second one is CLEAN: its settled index debounce
  /// must not publish its stale session buffer over a newer save's row.
  ///
  /// Round 15 gave every window its own index entry and narrowed `cancelArmedIndexIfOwned` to the
  /// saver's own, deliberately leaving a foreign entry armed — on the rationale that its owner's
  /// autosave "will land and correct FTS". That rationale holds for a DIRTY owner and fails for a
  /// settled one: window A autosaves (its bytes on disk, its buffer clean, its 5 s index debounce
  /// still armed), window B then writes different text to the same file and indexes it now, and A's
  /// surviving debounce later publishes A's in-memory text over B's row. B's bytes are the file's
  /// final content, so FTS ends up advertising text that is on no disk — and A, being clean, has no
  /// future save that would ever correct it.
  ///
  /// The debounce is fired through `flushIndex()` rather than by waiting out a timer: it runs the body
  /// through exactly the `runPendingIndex` path the timer would, so the assertion is about which text
  /// a fired body publishes and never about how long anything took.
  func testASettledSecondWindowsIndexDebounceCannotOverwriteANewerSaveOfTheSameFile() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let sharedURL = folder.appendingPathComponent("shared-by-two-windows.md")
    try "the shared file before either edit".write(to: sharedURL, atomically: true, encoding: .utf8)
    let sharedRef = DocumentRef(id: sharedURL.standardizedFileURL, isAdHoc: true)

    // The index delay is long enough that no index timer can fire during this test — the only thing
    // that runs an index body here is the explicit seam below. The save delay is short because window
    // A's own autosave landing is a PRECONDITION, and it is waited for by CONTENT, not by the clock.
    let autosaver = Autosaver(saveDelayMilliseconds: 40, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveSettledForeignDebounceBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )

    let bodyA = "windowaneedle the older text window A still holds in memory"
    let stateA = AppState()
    stateA.documents = [sharedRef]
    stateA.documentSession.load(document: sharedRef, text: "the shared file before either edit")
    stateA.activeDocumentText = bodyA
    store.documentDidChange(appState: stateA)

    try await waitUntil("window A's own autosave to land its bytes") {
      (try? String(contentsOf: sharedURL, encoding: .utf8)) == bodyA
    }
    XCTAssertFalse(
      stateA.documentSession.isDirty,
      "fixture precondition: window A must be SETTLED — its own autosave wrote its bytes")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateA), sharedRef.id,
      "fixture precondition: …while still holding the armed index debounce that owes A's row")

    // Window B writes DIFFERENT text to the same file and indexes it now — an ordinary ⌘S.
    let bodyB = "windowbneedle the newer text window B commits to disk"
    let stateB = AppState()
    stateB.documents = [sharedRef]
    stateB.documentSession.load(document: sharedRef, text: bodyA)
    stateB.activeDocumentText = bodyB
    store.documentDidChange(appState: stateB)
    store.save(appState: stateB)

    XCTAssertEqual(
      try String(contentsOf: sharedURL, encoding: .utf8), bodyB,
      "fixture precondition: B's bytes are the file's final on-disk content")
    try await waitUntil("B's save to publish its row") {
      await database.drainPendingIndexWrites()
      return ((try? self.indexHits(matching: "windowbneedle", at: databaseURL)) ?? 0) == 1
    }

    XCTAssertNil(
      autosaver.armedIndexDocument(ownedBy: stateA),
      "a SETTLED window's debounce over the file just written must be RETIRED: it owes a row for a "
        + "buffer this save has made stale, and a clean owner has no future save that would ever "
        + "supersede it")

    autosaver.flushIndex()
    await database.drainPendingIndexWrites()

    XCTAssertEqual(
      try indexHits(matching: "windowbneedle", at: databaseURL), 1,
      "FTS must still hold the text that is actually on disk…")
    XCTAssertEqual(
      try indexHits(matching: "windowaneedle", at: databaseURL), 0,
      "…and never window A's stale session buffer, which is on nobody's disk and which nothing "
        + "would ever correct")
    XCTAssertEqual(try String(contentsOf: sharedURL, encoding: .utf8), bodyB)
  }

  /// The control for the pin above: the retire must split on the foreign owner's DIRTINESS, not
  /// simply drop every neighbour's entry over the saved document.
  ///
  /// A DIRTY second window still owes a file write of its own. Its index debounce is what publishes
  /// the row for those bytes, and its autosave really will land and correct FTS — the rounds 7/8/15
  /// reservation, unchanged. Retiring it here would be the freshness loss the flush-over-cancel rule
  /// exists to forbid, permanently so on an ad-hoc document, which has no workspace signature and
  /// therefore no cold-open self-heal.
  ///
  /// Both debounces are set beyond the test's life on purpose: window A must still be holding unsaved
  /// text when window B saves, so its autosave must not be allowed to land and settle it.
  func testADirtySecondWindowsIndexDebounceSurvivesANewerSaveOfTheSameFile() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let sharedURL = folder.appendingPathComponent("shared-by-two-windows.md")
    try "the shared file before either edit".write(to: sharedURL, atomically: true, encoding: .utf8)
    let sharedRef = DocumentRef(id: sharedURL.standardizedFileURL, isAdHoc: true)

    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveDirtyForeignDebounceBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )

    let stateA = AppState()
    stateA.documents = [sharedRef]
    stateA.documentSession.load(document: sharedRef, text: "the shared file before either edit")
    stateA.activeDocumentText = "windowaneedle the text window A has NOT saved yet"
    store.documentDidChange(appState: stateA)

    XCTAssertTrue(
      stateA.documentSession.isDirty,
      "fixture precondition: window A must be holding unsaved text")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateA), sharedRef.id,
      "fixture precondition: …behind an armed index debounce over the shared file")

    let stateB = AppState()
    stateB.documents = [sharedRef]
    stateB.documentSession.load(document: sharedRef, text: "the shared file before either edit")
    stateB.activeDocumentText = "windowbneedle the text window B commits to disk"
    store.documentDidChange(appState: stateB)
    store.save(appState: stateB)

    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateA), sharedRef.id,
      "a DIRTY window's debounce over the file just written must stay ARMED: its owner's own save is "
        + "still owed, that save will land these bytes, and this debounce is what publishes them")
    XCTAssertTrue(
      autosaver.armedIndexOwnerIsDirty(ownedBy: stateA),
      "…and it must still read as owed, not be quietly reclassified on the way")
    XCTAssertTrue(
      stateA.documentSession.isDirty,
      "…with window A's unsaved text untouched by a save in another window")
  }

  /// Round 19, blocker 1: a batch flush must publish in ARMING order, not in array order.
  ///
  /// The two orders come apart the moment an owner RE-ARMS: `scheduleIndex` replaces that owner's slot
  /// in place, so its array position is frozen at its FIRST arming while its generation is refreshed.
  /// Window A arms, window B arms, window A edits again — array `[A, B]`, arming order `A, B, A`. Both
  /// owners then settle, so `savePendingChangesOnClose`'s sweep flushes BOTH, and because
  /// `IndexDatabase` preserves submission order the body that runs last is the row that survives.
  ///
  /// In array order that is B — a session buffer A's newer save has already made stale, holding text
  /// that is on nobody's disk. Both entries are consumed by the flush, and this document is AD-HOC (no
  /// workspace signature ⇒ no cold-open self-heal), so nothing would ever correct it. The R18 retire
  /// does not reach this state: it fires only from row-publishing saves (`indexNow: true` / `saveAs`),
  /// and every write here is an autosave.
  ///
  /// The assertion is deliberately about CONTENT, never about which body ran when: FTS must hold the
  /// bytes that are actually on disk.
  func testASettledFlushPublishesTheMostRecentlyArmedDebounceLast() async throws {
    try await assertABatchFlushPublishesTheMostRecentlyArmedDebounceLast(
      defaultsPrefix: "PensieveSettledFlushOrderBookmarks",
      flush: { $0.flushIndexDebouncesWithSettledOwners() }
    )
  }

  /// The same defect on the QUIT path's unconditional form. `flushIndex()` iterated the same array the
  /// same way, and `quiesceForTermination()` calls it — so a quit with two windows on one file could
  /// leave FTS holding the older arming's buffer, permanently, on exactly the documents that have no
  /// cold-open self-heal.
  func testTheQuitFlushPublishesTheMostRecentlyArmedDebounceLast() async throws {
    try await assertABatchFlushPublishesTheMostRecentlyArmedDebounceLast(
      defaultsPrefix: "PensieveQuitFlushOrderBookmarks",
      flush: { $0.flushIndex() }
    )
  }

  private func assertABatchFlushPublishesTheMostRecentlyArmedDebounceLast(
    defaultsPrefix: String,
    flush: @MainActor (Autosaver) -> Void
  ) async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let sharedURL = folder.appendingPathComponent("shared-by-two-windows.md")
    let originalBody = "the shared file before either edit"
    try originalBody.write(to: sharedURL, atomically: true, encoding: .utf8)
    let sharedRef = DocumentRef(id: sharedURL.standardizedFileURL, isAdHoc: true)

    // The index delay is long enough that no index timer can fire during this test — the only thing
    // that runs an index body here is the explicit flush seam below. The save delay is short because
    // each window's own autosave landing is a PRECONDITION, and it is waited for by CONTENT, not by
    // the clock.
    let autosaver = Autosaver(saveDelayMilliseconds: 40, indexDelayMilliseconds: 600_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(defaults: makeEphemeralDefaults(prefix: defaultsPrefix)),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )

    // Window A arms FIRST, which is what buys it array slot 0 — and a re-arm never gives that slot up.
    let stateA = AppState()
    stateA.documents = [sharedRef]
    stateA.documentSession.load(document: sharedRef, text: originalBody)
    stateA.activeDocumentText = "alphafirst window A's first edit, superseded below"
    store.documentDidChange(appState: stateA)

    // Window B arms SECOND, so the array is `[A, B]` from here on.
    let bodyB = "betaneedle the text window B still holds after its own autosave"
    let stateB = AppState()
    stateB.documents = [sharedRef]
    stateB.documentSession.load(document: sharedRef, text: originalBody)
    stateB.activeDocumentText = bodyB
    store.documentDidChange(appState: stateB)

    try await waitUntil("both windows' own autosaves to land and settle their buffers") {
      !stateA.documentSession.isDirty && !stateB.documentSession.isDirty
    }

    // A edits again. `scheduleIndex` replaces A's entry IN PLACE: array position 0 unchanged, fresh
    // generation — this is the single step that makes array order and arming order disagree.
    let bodyA = "alphaneedle the newest text, and the file's final on-disk content"
    stateA.activeDocumentText = bodyA
    store.documentDidChange(appState: stateA)

    try await waitUntil("window A's second autosave to land its newer bytes") {
      (try? String(contentsOf: sharedURL, encoding: .utf8)) == bodyA
        && !stateA.documentSession.isDirty
    }

    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateA), sharedRef.id,
      "fixture precondition: window A holds an armed index debounce over the shared file…")
    XCTAssertEqual(
      autosaver.armedIndexDocument(ownedBy: stateB), sharedRef.id,
      "…and so does window B, whose entry an autosave never retires")
    XCTAssertFalse(
      autosaver.armedIndexOwnerIsDirty(ownedBy: stateA),
      "fixture precondition: both owners must be SETTLED, so the sweep flushes both rather than…")
    XCTAssertFalse(
      autosaver.armedIndexOwnerIsDirty(ownedBy: stateB),
      "…leaving either of them armed — a deferred entry would never reach the ordering under test")
    XCTAssertEqual(
      try String(contentsOf: sharedURL, encoding: .utf8), bodyA,
      "fixture precondition: A's bytes are the file's final on-disk content, B's buffer is stale")

    flush(autosaver)
    await database.drainPendingIndexWrites()

    XCTAssertEqual(
      try indexHits(matching: "alphaneedle", at: databaseURL), 1,
      "the entry armed MOST RECENTLY must publish LAST, so FTS holds the text that is on disk…")
    XCTAssertEqual(
      try indexHits(matching: "betaneedle", at: databaseURL), 0,
      "…and never the older arming's session buffer, which array-order iteration would have let "
        + "publish last purely because its owner armed into a later array slot")
    XCTAssertEqual(try String(contentsOf: sharedURL, encoding: .utf8), bodyA)
  }

  // MARK: - R21 / F3: the quit's window flush follows last-edit recency

  /// Round 21, finding 3 — an OPERATOR DECISION (2026-07-30), not a review finding.
  ///
  /// Two windows can hold the same file, both dirty, with different text. Every save writes the WHOLE
  /// buffer, so whichever window's save runs LAST is the one whose bytes survive — and the quit's
  /// flush loop took that order from `DocumentWindowRegistry.liveDocumentControllers()`, which walks a
  /// dictionary keyed by `ObjectIdentifier`. The winner was therefore neither focus nor recency nor
  /// registration order: it was the hash seed, and the user could lose the text they had just typed to
  /// a window they had not touched in an hour. The rule Monika decided is the one a user can predict —
  /// the window edited MOST RECENTLY writes last and wins.
  ///
  /// The array handed to the flush is ADVERSARIAL on purpose: the older-edited window sits LAST, which
  /// is exactly the position that used to decide the file. Handing it to `flushPendingWindowSaves`
  /// directly rather than driving `runUserFlushPhases()` is what makes the mutation proof mean
  /// something — the registry cannot be asked for a specific iteration order, so a pin that went
  /// through it would be asserting the hash seed.
  ///
  /// The sibling half is FTS, and it is asserted here too. Nothing extra was needed to make it agree:
  /// each save publishes its own row as it lands, so reordering the saves reorders the index writes
  /// with them, and `quiesceForTermination()` then flushes what remains in ARMING order (round 19) —
  /// the same recency, one debounce down. Both roads point at the newer window. The pin asserts the
  /// index anyway, because "disk and search name the same winner" is the contract the user meets, and
  /// the mutation below breaks BOTH halves at once.
  func testTheQuitFlushLetsTheMostRecentlyEditedWindowWriteItsBytesLast() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let sharedURL = folder.appendingPathComponent("shared-by-two-windows.md")
    let originalBody = "the shared file before either edit"
    try originalBody.write(to: sharedURL, atomically: true, encoding: .utf8)
    let sharedRef = DocumentRef(id: sharedURL.standardizedFileURL, isAdHoc: true)

    // Both delays are effectively infinite: nothing in this pin may be written by a TIMER. Every byte
    // that reaches the disk comes from the quit's own flush, which is the path under test.
    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let folderManager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "EditRecency")
    let registry = DocumentWindowRegistry()
    let log = EventLog()

    let bodyA = "alphaneedle window A's text, edited FIRST and therefore the loser"
    let bodyB = "betaneedle window B's text, edited SECOND and therefore the winner"

    var windows: [NSWindow] = []
    defer { windows.forEach { $0.close() } }
    var controllers: [String: AppController] = [:]
    var states: [String: AppState] = [:]

    // Edited in array order — A, then B — so B carries the higher `lastEditGeneration`.
    for (name, body) in [("A", bodyA), ("B", bodyB)] {
      let windowState = AppState()
      states[name] = windowState
      let store = DocumentStore(
        autosaver: autosaver,
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveEditRecency\(name)Bookmarks")),
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery-\(name)", isDirectory: true)),
        writeDocument: { text, url in
          log.append("save:\(name)")
          try text.write(to: url, atomically: true, encoding: .utf8)
        }
      )
      windowState.documents = [sharedRef]
      windowState.documentSession.load(document: sharedRef, text: originalBody)
      windowState.activeDocumentText = body
      // The ONE edit funnel, which is where the marker is stamped. Going through it rather than
      // setting `isDirty` by hand is the point: a pin that stamped the generation itself would prove
      // nothing about the path a keystroke takes.
      store.documentDidChange(appState: windowState)

      let controller = AppController(
        appState: windowState,
        folderManager: folderManager,
        documentStore: store,
        indexDatabase: database,
        documentWindowRegistry: registry)
      controllers[name] = controller
      let window = makeWindow()
      windows.append(window)
      registry.registerController(controller, for: window)
    }

    let controllerA = try XCTUnwrap(controllers["A"])
    let controllerB = try XCTUnwrap(controllers["B"])
    XCTAssertGreaterThan(
      controllerB.lastEditGeneration, controllerA.lastEditGeneration,
      "fixture precondition: window B must be the more recently EDITED of the two, or there is no "
        + "recency for the flush to follow")
    XCTAssertTrue(
      try XCTUnwrap(states["A"]).documentSession.isDirty
        && XCTUnwrap(states["B"]).documentSession.isDirty,
      "fixture precondition: both windows must be dirty — one clean buffer is a no-op save and the "
        + "ordering would be untestable")

    let sequence = TerminationSequence(
      registry: registry,
      indexDatabase: database,
      folderManager: folderManager,
      autosaver: autosaver,
      drainTimeout: Self.shrunkDrainBudget,
      pumpRunLoop: { _ in }
    )
    // ADVERSARIAL order: the older-edited window LAST, which is the slot that decides the file.
    sequence.flushPendingWindowSaves([controllerB, controllerA])
    autosaver.quiesceForTermination()
    await database.drainPendingIndexWrites()

    let events = log.events
    XCTAssertEqual(
      try String(contentsOf: sharedURL, encoding: .utf8), bodyB,
      "the bytes that survive a quit must be the ones the user typed most recently, never the ones "
        + "belonging to whichever window a dictionary happened to hand over last (events: \(events))")
    XCTAssertEqual(
      events, ["save:A", "save:B"],
      "…which means the flush ran oldest-edit FIRST, regardless of the order it was handed")
    XCTAssertEqual(
      try indexHits(matching: "betaneedle", at: databaseURL), 1,
      "…and FTS must name the same winner as the disk, or search points at text nobody has")
    XCTAssertEqual(
      try indexHits(matching: "alphaneedle", at: databaseURL), 0,
      "…with the losing window's buffer nowhere in the index")
  }

  /// The control, and the half that keeps the reordering honest: two dirty windows over DIFFERENT
  /// files must each land their OWN bytes.
  ///
  /// Ordering across different documents is explicitly out of scope for the operator's rule — there is
  /// nothing to arbitrate, because no two saves target the same path — so the sort must be a
  /// permutation that changes nothing about what ends up on disk. A build that "won" the pin above by
  /// dropping saves, coalescing them, or letting the last writer overwrite everything would fail here.
  func testTwoDirtyWindowsOverDifferentFilesEachLandTheirOwnBytes() async throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let folderManager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "EditRecencyControl")
    let registry = DocumentWindowRegistry()

    var windows: [NSWindow] = []
    defer { windows.forEach { $0.close() } }
    var controllers: [String: AppController] = [:]
    var urls: [String: URL] = [:]

    for name in ["A", "B"] {
      let noteURL = folder.appendingPathComponent("own-file-\(name).md")
      try "before the quit".write(to: noteURL, atomically: true, encoding: .utf8)
      urls[name] = noteURL
      let ref = DocumentRef(id: noteURL.standardizedFileURL, isAdHoc: true)

      let windowState = AppState()
      let store = DocumentStore(
        autosaver: autosaver,
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveEditRecencyControl\(name)Bookmarks")),
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery-\(name)", isDirectory: true))
      )
      windowState.documents = [ref]
      windowState.documentSession.load(document: ref, text: "before the quit")
      windowState.activeDocumentText = "ownfileneedle\(name.lowercased()) in window \(name)"
      store.documentDidChange(appState: windowState)

      let controller = AppController(
        appState: windowState,
        folderManager: folderManager,
        documentStore: store,
        indexDatabase: database,
        documentWindowRegistry: registry)
      controllers[name] = controller
      let window = makeWindow()
      windows.append(window)
      registry.registerController(controller, for: window)
    }

    let sequence = TerminationSequence(
      registry: registry,
      indexDatabase: database,
      folderManager: folderManager,
      autosaver: autosaver,
      drainTimeout: Self.shrunkDrainBudget,
      pumpRunLoop: { _ in }
    )
    sequence.flushPendingWindowSaves([
      try XCTUnwrap(controllers["B"]), try XCTUnwrap(controllers["A"]),
    ])
    autosaver.quiesceForTermination()
    await database.drainPendingIndexWrites()

    for name in ["A", "B"] {
      XCTAssertEqual(
        try String(contentsOf: try XCTUnwrap(urls[name]), encoding: .utf8),
        "ownfileneedle\(name.lowercased()) in window \(name)",
        "windows over DIFFERENT files never race for the same bytes, so reordering the flush must "
          + "leave every one of them holding its own text")
      XCTAssertEqual(
        try indexHits(matching: "ownfileneedle\(name.lowercased())", at: databaseURL), 1,
        "…and each must be in FTS exactly once")
    }
  }

  // MARK: - R22 / P2 (thread r3682497443): hand-offs join the chain in REGISTRATION order

  /// Round 22 — the unordered hop in FRONT of the reservation.
  ///
  /// Round 15 made `reserveSupersedePosition(_:)` synchronous, so a DIRECT caller of
  /// `indexInBackground` takes its chain position before its own first suspension point. The save
  /// tail is not a direct caller: it hands the write to `scheduleIndexWrite`, whose task is
  /// UNSTRUCTURED, and Swift promises nothing about which of two unstructured tasks starts first.
  /// The reservation stayed synchronous; getting to it did not. Two saves of ONE document handed
  /// over back-to-back could therefore reserve in either order, and when the older one reserved
  /// second it overwrote the newer FTS row after the newer bytes were already on disk — search
  /// advertising text no file contains, and for an ad-hoc document there is no workspace reindex to
  /// ever repair it.
  ///
  /// The quit reaches this hardest, which is why the pin drives it rather than a synthetic caller:
  /// `flushPendingWindowSaves` writes each window's bytes SYNCHRONOUSLY and hands the index write
  /// off, with no suspension point in between, so two windows over one file register two hand-offs
  /// before either has started.
  ///
  /// Driving, not racing (round 9's lesson). The gate sits at the HEAD of the hand-off, so arrival
  /// order is executor order — not registration order — and a pin that assumed "arrival #2 is the
  /// second registration" would be asserting the executor rather than the contract. Registering the
  /// second save only once the first is demonstrably parked turns that into a fact. The second is
  /// then released ALONE, while the first is still held: the experiment is "given every chance to
  /// overtake, does it?".
  ///
  /// Both halves are asserted. STRUCTURAL: released alone, the newer hand-off must still be parked
  /// on its predecessor with nothing written. BEHAVIOURAL: disk and FTS name the same winner, and it
  /// is the newer bytes.
  func testTwoSavesOfOneDocumentJoinTheIndexChainInRegistrationOrder() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let sharedURL = folder.appendingPathComponent("one-file-two-windows.md")
    let originalBody = "the shared file before either save"
    try originalBody.write(to: sharedURL, atomically: true, encoding: .utf8)
    let sharedRef = DocumentRef(id: sharedURL.standardizedFileURL, isAdHoc: true)

    // Ad-hoc on purpose: this is the document class the finding calls PERMANENT, because no
    // workspace reindex will ever come back and correct a row the older save left behind.
    XCTAssertTrue(
      sharedRef.isAdHoc,
      "fixture precondition: the unrepairable case is the ad-hoc one — a workspace document would "
        + "be corrected by the next scan, which would hide the defect rather than pin it")

    // Both delays effectively infinite: nothing here may be written by a TIMER.
    let autosaver = Autosaver(saveDelayMilliseconds: 600_000, indexDelayMilliseconds: 600_000)
    let folderManager = makeIsolatedFolderManager(
      in: folder, database: database, prefix: "HandoffOrder")
    let registry = DocumentWindowRegistry()

    let bodyOlder = "alphaneedle the FIRST save, whose row must not outlive the second"
    let bodyNewer = "betaneedle the SECOND save, which is what the user last typed"

    var windows: [NSWindow] = []
    defer { windows.forEach { $0.close() } }
    var controllers: [String: AppController] = [:]

    for (name, body) in [("older", bodyOlder), ("newer", bodyNewer)] {
      let windowState = AppState()
      let store = DocumentStore(
        autosaver: autosaver,
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveHandoffOrder\(name)Bookmarks")),
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery-\(name)", isDirectory: true))
      )
      windowState.documents = [sharedRef]
      windowState.documentSession.load(document: sharedRef, text: originalBody)
      windowState.activeDocumentText = body
      store.documentDidChange(appState: windowState)

      let controller = AppController(
        appState: windowState,
        folderManager: folderManager,
        documentStore: store,
        indexDatabase: database,
        documentWindowRegistry: registry)
      controllers[name] = controller
      let window = makeWindow()
      windows.append(window)
      registry.registerController(controller, for: window)
    }

    let handoffGate = OrderedParkingGate()
    database.indexWriteHandoffGateOverride = { await handoffGate.arrive() }

    let sequence = TerminationSequence(
      registry: registry,
      indexDatabase: database,
      folderManager: folderManager,
      autosaver: autosaver,
      drainTimeout: Self.shrunkDrainBudget,
      pumpRunLoop: { _ in }
    )

    // 1 — the OLDER save, through the real quit flush. Its hand-off is registered first and is held
    //     at the head, before it can reserve anything.
    sequence.flushPendingWindowSaves([try XCTUnwrap(controllers["older"])])
    pumpMainRunLoop(until: { handoffGate.arrivalCount >= 1 }, timeout: 10)
    XCTAssertEqual(
      handoffGate.arrivalCount, 1,
      "fixture precondition: exactly one hand-off may be parked here, or the release indices below "
        + "name something other than the two saves under test")

    // 2 — the NEWER save. It is registered while the first is demonstrably parked, so arrival #2 is
    //     this one by construction rather than by executor courtesy.
    sequence.flushPendingWindowSaves([try XCTUnwrap(controllers["newer"])])
    pumpMainRunLoop(until: { handoffGate.arrivalCount >= 2 }, timeout: 10)
    XCTAssertEqual(
      handoffGate.arrivalCount, 2,
      "fixture precondition: both hand-offs must be registered and parked before either is released")
    XCTAssertEqual(
      try String(contentsOf: sharedURL, encoding: .utf8), bodyNewer,
      "fixture precondition: the DISK half is already settled — both saves write their bytes "
        + "synchronously inside the flush, so only the index is still in flight")
    XCTAssertEqual(
      try indexHits(matching: "alphaneedle", at: databaseURL)
        + indexHits(matching: "betaneedle", at: databaseURL), 0,
      "fixture precondition: neither hand-off may have written yet — both are held in front of the "
        + "reservation, which is the window the finding is about")

    // 3 — the experiment: release the SECOND registration ALONE, first one still held.
    Task { await handoffGate.open(only: 2) }
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)
    XCTAssertEqual(
      try indexHits(matching: "betaneedle", at: databaseURL), 0,
      "released alone and ahead of its predecessor, the newer hand-off must be parked on that "
        + "predecessor rather than running: a hand-off that can reach its reservation here has "
        + "taken a chain position out of registration order, and whichever save reserves second "
        + "wins the FTS row no matter which one the user typed last")

    // 4 — and now the first, plus whatever the chain owes behind it.
    let drained = CompletionFlag()
    Task { @MainActor in
      await database.drainPendingIndexWrites()
      drained.isSet = true
    }
    Task { await handoffGate.open(through: 2) }
    pumpMainRunLoop(until: { drained.isSet }, timeout: 20)
    XCTAssertTrue(
      drained.isSet,
      "fixture precondition: the drain must have returned, or the assertions below are reading a "
        + "database that is still being written")

    XCTAssertEqual(
      try String(contentsOf: sharedURL, encoding: .utf8), bodyNewer,
      "the newer save owns the file, which is the fact the index has to agree with")
    XCTAssertEqual(
      try indexHits(matching: "betaneedle", at: databaseURL), 1,
      "…so FTS must carry the SECOND registration's bytes: the hand-offs join the chain in the "
        + "order they were registered, not in the order the runtime happened to start them")
    XCTAssertEqual(
      try indexHits(matching: "alphaneedle", at: databaseURL), 0,
      "…with the older save's body gone, rather than reinstated by a write that reserved late")
  }

  /// Control 1 — DIFFERENT documents still all land, and a chain released BACKWARDS neither loses a
  /// write nor deadlocks the drain.
  ///
  /// Ordering hand-offs is only safe if it is a queue and not a trap. Three hand-offs are registered
  /// in a known order and then released in REVERSE — #3 first, #1 last — which is the release pattern
  /// a chain would wedge on if any link waited on a successor instead of a predecessor. The drain is
  /// started BEFORE the releases and awaited afterwards, so "the drain terminates under the new
  /// shape" is asserted rather than assumed: it snapshots `scheduledIndexWrites` in dictionary order,
  /// i.e. it may well await a successor before its predecessor, and that must still finish.
  func testHandoffsForDifferentDocumentsAllLandEvenWhenReleasedBackwards() throws {
    let folder = try makeTemporaryFolder()
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let hostState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: hostState)
    XCTAssertNil(hostState.lastError)

    let handoffGate = OrderedParkingGate()
    database.indexWriteHandoffGateOverride = { await handoffGate.arrive() }

    let names = ["one", "two", "three"]
    // Registered one at a time, each confirmed parked before the next is handed over — the same
    // reason the pin above stages its two saves: arrival index must be a fact.
    for (offset, name) in names.enumerated() {
      let ref = documentRef(root: root, name: "\(name).md")
      database.scheduleIndexWrite {
        _ = await database.indexInBackground(
          document: ref, body: "distinctneedle\(name) body", appState: nil)
      }
      pumpMainRunLoop(until: { handoffGate.arrivalCount >= offset + 1 }, timeout: 10)
      XCTAssertEqual(
        handoffGate.arrivalCount, offset + 1,
        "fixture precondition: hand-off \(offset + 1) must be parked before the next is registered")
    }

    let drained = CompletionFlag()
    Task { @MainActor in
      await database.drainPendingIndexWrites()
      drained.isSet = true
    }
    pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)
    XCTAssertFalse(
      drained.isSet,
      "fixture precondition: the drain must still be waiting — a drain that returned while three "
        + "hand-offs were parked would make the assertion below vacuous")

    // Backwards on purpose: the last registration is released first.
    for index in [3, 2, 1] {
      Task { await handoffGate.open(only: index) }
      pumpMainRunLoop(until: { false }, timeout: Self.settleSeconds)
    }
    pumpMainRunLoop(until: { drained.isSet }, timeout: 20)
    XCTAssertTrue(
      drained.isSet,
      "the drain must terminate under the chained shape: hand-offs wait only on hand-offs "
        + "registered EARLIER, so awaiting them in any order — which is what a dictionary snapshot "
        + "does — can never close a cycle")

    for name in names {
      XCTAssertEqual(
        try indexHits(matching: "distinctneedle\(name)", at: databaseURL), 1,
        "every hand-off must land its own document exactly once: ordering the queue must not drop, "
          + "coalesce or overwrite writes that were never in competition")
    }
  }

  // MARK: - Fixtures

  /// The drain budget under test, shrunk from the production 5 s through `TerminationSequence`'s own
  /// init seam. The contract is "returns once it expires", not "expires after exactly 5 s".
  private static let shrunkDrainBudget: TimeInterval = 0.4

  /// A budget so small that any real work outlasts it. Used where the assertion is "the deadline
  /// expired and the user's bytes were on disk anyway", so the expiry must be certain rather than
  /// probable.
  private static let spentInstantlyDrainBudget: TimeInterval = 0.05

  /// The injected slow volume: one window's synchronous write, on its own, outlasting the budget
  /// above by 3×. A duration, not a sleep-then-assert — the assertion is about which bytes reached
  /// the disk, never about how long anything took.
  private static let slowVolumeWriteSeconds: TimeInterval = 0.15

  /// How long a pin gives the run loop when it needs "everything that CAN run has run" before
  /// asserting that something has NOT happened. Generous on purpose: this suite already carries
  /// wall-clock flakes and a settle window must not become the next one.
  private static let settleSeconds: TimeInterval = 0.25

  /// How long the backoff ladder's retry sleeps in the late-waking pin. Long enough that the fixture
  /// (release the reader, install the seam, park the close's housekeeping, start the quit) finishes
  /// first on a loaded machine, and the pin says so out loud rather than passing for the wrong reason
  /// if it does not.
  private static let lateRetryDelayNanoseconds: UInt64 = 3_000_000_000

  /// Release valve for the wedged pool reader, far above every wait that depends on it: a wrong build
  /// must fail an assertion, not be rescued by a timeout.
  private static let readerWedgeReleaseSeconds: TimeInterval = 60

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

  private func treeContains(_ nodes: [WorkspaceNode], url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    return nodes.contains { node in
      node.url?.standardizedFileURL.path == path || treeContains(node.children ?? [], url: url)
    }
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

    /// Increments and reads back under ONE lock, so a seam that fires from two concurrent tasks can
    /// tell which arrival it is. `increment()` followed by `value` cannot: two callers can interleave
    /// between the two locks and both read the same number.
    func next() -> Int {
      lock.lock()
      defer { lock.unlock() }
      count += 1
      return count
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

  /// A `ParkingGate` whose waiters are released INDIVIDUALLY, in arrival order, instead of all at
  /// once. Needed wherever two writes must be told apart while both are held: releasing them together
  /// would make "the drain returned" and "the second write landed" two outcomes of the same instant,
  /// and the pin could then pass on scheduling luck rather than on the contract.
  private actor OrderedParkingGate {
    private var openedThrough = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Readable from a synchronous pump without awaiting the actor.
    private let arrivalCounter = Counter()

    nonisolated var arrivalCount: Int { arrivalCounter.value }

    func arrive() async {
      // Assigned inside the actor, so arrival order and index order are the same order.
      let index = arrivalCounter.next()
      guard index > openedThrough else { return }
      await withCheckedContinuation { continuation in
        waiters[index] = continuation
      }
    }

    func open(through index: Int) {
      openedThrough = max(openedThrough, index)
      let released = waiters.filter { $0.key <= openedThrough }
      for (waiterIndex, continuation) in released {
        waiters.removeValue(forKey: waiterIndex)
        continuation.resume()
      }
    }

    /// Releases EXACTLY one arrival, leaving earlier ones held. `open(through:)` cannot express this,
    /// and the supersede-ordering pin needs it: releasing the SECOND write while the first is still
    /// parked is the whole experiment — a build that orders by submission holds it behind its
    /// predecessor anyway, a build that does not lets it run ahead.
    func open(only index: Int) {
      guard let continuation = waiters.removeValue(forKey: index) else { return }
      continuation.resume()
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
