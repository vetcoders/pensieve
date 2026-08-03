import Foundation
import GRDB

@MainActor
final class IndexDatabase {
  static let shared = IndexDatabase()

  private var databasePool: DatabasePool?
  private(set) var databaseURL: URL?
  private let configuredDatabaseURL: URL?
  private let searchIndexBatchSize: Int
  private let didInsertSearchIndexBatch: (@Sendable (Int) -> Void)?

  /// Narrow test seam, the READ-side sibling of `didInsertSearchIndexBatch`: fired from INSIDE a
  /// background backlink query's `pool.read`, on the reading connection's own thread. It exists so a
  /// test can hold a GENUINE pool reader open and prove the quit stays bounded while
  /// `barrierWriteWithoutTransaction` — which excludes the pool's readers, not just its writer —
  /// waits for it. A gate parked before the read would prove nothing: the block has to hold while the
  /// reader is inside the pool. `nil` in production.
  private let didOpenBacklinkRead: (@Sendable () -> Void)?

  /// Tracks the in-flight background index write (full reindex OR incremental
  /// delta apply). Each new background update chains onto this task before
  /// starting its own `pool.write`, so writes are serialized in submission
  /// order: a newer delta cannot start until the prior one has finished, and a
  /// stale update can never overwrite the rows a later one already wrote.
  /// Tests await it via `waitForPendingReindex()` instead of sleeping.
  private var pendingIndexUpdateTask: Task<Void, Never>?

  /// Index writes that are SCHEDULED but have not joined `pendingIndexUpdateTask` yet. A save must
  /// not stall on SQLite, so it hands its index write to an unstructured task that only chains
  /// itself onto the supersede queue once it starts running. Anything that has to establish "no
  /// index write is still owed" — the quit sequence, the workspace-close housekeeping — therefore
  /// cannot read the chain alone: at that instant the write it just caused may still be sitting
  /// here, invisible to `waitForPendingReindex()`.
  private var scheduledIndexWrites: [UUID: Task<Void, Never>] = [:]

  /// Tail of the HAND-OFF chain: the most recently registered `.registrationOrdered` scheduled
  /// write. Sibling of `pendingIndexUpdateTask` one storey up, and it exists for the same reason —
  /// see `ScheduledWriteOrdering` for why the storey below is not enough on its own.
  ///
  /// Deliberately never cleared, exactly like `pendingIndexUpdateTask`. Awaiting a finished task
  /// returns immediately, and a task that has finished no longer retains ITS predecessor, so at most
  /// one completed handle is held here and the chain does not accumulate across an editing session.
  private var scheduledIndexWriteTail: Task<Void, Never>?

  /// The outstanding HOT-PATH (`.indexBatch`) maintenance pass, or `nil` when none is armed.
  ///
  /// Storage hygiene must never stall functional writes, and until round 11 it could: the batch
  /// maintenance call was `await`ed INSIDE the write task that `pendingIndexUpdateTask` points at, so
  /// its `barrierWriteWithoutTransaction` — which excludes the pool's READERS, that being the whole
  /// reason the truncate needs it — sat in the supersede tail. One slow or wedged search/backlink
  /// query therefore blocked not just the truncate but every reindex, watcher delta and save
  /// submitted afterwards, for the rest of the running session. It is scheduled as its own tracked
  /// write instead (see `scheduleIndexBatchMaintenance()`).
  ///
  /// COALESCED to at most one outstanding pass: maintenance is idempotent housekeeping, and without
  /// this a wedged reader would let every subsequent index write pile another blocked barrier behind
  /// the first. `.workspaceClose` maintenance is unaffected — it stays chained and awaited, because
  /// there is nothing left to index by then and the close is what has to wait.
  private var pendingIndexBatchMaintenance: Task<Void, Never>?

  /// The armed RETRY of a hot-path truncate that a reader would not let through, or `nil` when none
  /// is owed. Round 12: the hot-path pass no longer waits readers out, so something has to bring it
  /// back — see `deferIndexBatchTruncation()`. Round 14: while it is installed it also SUPPRESSES
  /// hot-path arming, so the backoff cannot be bypassed by ordinary writes.
  private var pendingIndexBatchTruncationRetry: Task<Void, Never>?

  /// A hot-path maintenance request that arrived while a pass was ALREADY in flight, and therefore
  /// coalesced into the handle above rather than armed on its own.
  ///
  /// Round 13. Coalescing is only sound while the active pass still covers the requester's frames,
  /// and it stops covering them the moment it has checkpointed: an index write that commits after
  /// the pass truncated but before its task clears `pendingIndexBatchMaintenance` adds WAL frames no
  /// pass has seen. Dropping that request left the log over the 16 MiB bound with nothing owed —
  /// disk space, not durability, but held until the next index write or close/quit happened to come
  /// along. So the request is REMEMBERED here and honoured when the handle clears
  /// (`rearmIndexBatchMaintenanceIfRequestedWhileActive()`).
  private var indexBatchMaintenanceRequestedWhileActive = false

  /// How many times in a row a hot-path truncate has been deferred, which is what the backoff ladder
  /// in `effectiveIndexBatchTruncationRetryDelayNanoseconds` reads. Reset the moment a pass truncates
  /// or finds the WAL already under the bound.
  private var indexBatchTruncationRetryAttempt = 0

  /// Hot-path truncates deferred because a reader still held WAL frames. Production never reads it;
  /// it is the seam a test uses to prove the pass GAVE UP AND RE-ARMED rather than waited — the same
  /// role `terminationRejectedEntryPoints` plays for the latch.
  private(set) var indexBatchTruncationDeferrals = 0

  /// Close passes that decided to exclude readers and then took it back at barrier acquisition,
  /// because a workspace opened inside their detached prologue. Production never reads it; it is the
  /// only seam that can tell a BARRIER-TIME downgrade from a call-time one, since the latter is
  /// visible in the `MaintenanceReason` that reaches `maintenanceGateOverride` and the former by
  /// construction is not — it happens after that seam.
  private(set) var barrierTimeMaintenanceDowngrades = 0

  /// One-way switch set by `quiesceIndexBatchTruncationRetry()`. The backoff ladder is the ONE index
  /// producer the termination drain cannot see — it sleeps outside `scheduledIndexWrites` on purpose,
  /// so the drain never has to wait out a timer — which also means the drain cannot bound it. This
  /// flag is what turns "no pass is registered right now" into "no pass can BE registered", and it is
  /// therefore what makes the stability drain in `TerminationSequence.runIndexPhases()` terminate.
  private(set) var isIndexBatchTruncationRetryQuiesced = false

  /// Narrow test seam: awaited at the head of every background index write, before it waits for its
  /// predecessor and long before it touches the pool. It exists so a test can hold write #1 open and
  /// prove write #2 is GENUINELY still queued when a close or a quit runs — GRDB's
  /// `barrierWriteWithoutTransaction` usually queues behind an already submitted `pool.write`, so an
  /// unordered close passes a settle-first test by accident. `nil` in production.
  var backgroundWriteGateOverride: (@Sendable () async -> Void)?

  /// Narrow test seam, sibling of the one above but one storey up: awaited at the head of every
  /// `.registrationOrdered` hand-off, BEFORE it waits for the hand-off registered ahead of it and
  /// long before `work()` runs.
  ///
  /// The position is the whole point. Parked here a hand-off is REGISTERED — the drain can see it —
  /// and has not entered `work()`, so it has not reserved a supersede position either. That gap is
  /// exactly what the hand-off ordering contract covers, and it is the only place from which a test
  /// can hold the FIRST hand-off and give the second a genuine chance to overtake it. `nil` in
  /// production.
  var indexWriteHandoffGateOverride: (@Sendable () async -> Void)?

  /// Narrow test seam, sibling of the one above: awaited INSIDE the open task, on its detached
  /// executor, immediately before `makeDatabasePool` builds the pool and runs the migrations.
  ///
  /// The position is the whole point. Parked here the open has already passed the funnel gate and
  /// already registered `openTask`, which is exactly the state the termination drain has to cope
  /// with; a wedge placed before the gate would only prove that a refused open refuses. `nil` in
  /// production.
  var databaseOpenGateOverride: (@Sendable () async -> Void)?

  /// Narrow test seam, third sibling of the two above: awaited INSIDE `performMaintenanceInBackground`,
  /// after every early return and immediately before the detached vacuum + truncate.
  ///
  /// The position is again the whole point. Parked here a maintenance pass is GENUINELY in flight —
  /// past its guards, holding work the terminal checkpoint must not overtake — which is the state
  /// `waitForPendingIndexMaintenance()` has to cope with when a second workspace close arms another
  /// pass behind it. A wedge placed before the scheduling would only prove that a task nobody has
  /// created yet has not run. `nil` in production.
  /// Carries the pass's `MaintenanceReason` so a test can tell the two apart WITHOUT guessing from
  /// arrival order. The quit runs both kinds through this one seam — a `.workspaceClose` pass the
  /// sequence awaits, and a `.indexBatch` pass the backoff ladder may register underneath it — and a
  /// pin about their ORDERING cannot be built on "the second arrival is probably the retry".
  var maintenanceGateOverride: (@Sendable (MaintenanceReason) async -> Void)?

  /// Narrow test seam, fourth sibling: awaited inside the hot-path pass's OWN task, after
  /// `performMaintenanceInBackground` has returned — so after the truncate and after the pool writer
  /// was released — and immediately before that task clears `pendingIndexBatchMaintenance`.
  ///
  /// The position is the whole point, and it is a different window from `maintenanceGateOverride`'s.
  /// Parked here the pass has already DONE its work while the coalescing handle is still installed,
  /// which is exactly the state round 13's finding describes: an index write committing now adds WAL
  /// frames the pass cannot have covered, and its maintenance request would previously be dropped by
  /// the coalescing guard. A wedge before the truncate could not reach that state — there the
  /// coalescing is still correct, because the pass has yet to checkpoint. `nil` in production.
  var maintenanceCompletionGateOverride: (@Sendable () async -> Void)?

  /// Narrow test seam, fifth sibling: awaited inside the single-document index write
  /// (`indexInBackground`), after `ensureOpenInBackground` has already handed the pool over and
  /// immediately BEFORE the detached task carrying its `pool.write` is submitted.
  ///
  /// The position is the whole point, and it is the only window this entry point actually has. Its
  /// three earlier suspensions — `awaitBackgroundWriteGate()`, `await previous?.value`, the open —
  /// are all covered by `ensureOpenInBackground`'s own post-await latch consultation, so a wedge
  /// placed at `backgroundWriteGateOverride` would only prove that a refused open refuses. What
  /// remains is the detached hop plus the wait for the pool's SERIALIZED WRITER, and a write parked
  /// here is in exactly that state: accepted, holding a published pool, holding no lock, and about to
  /// commit into a database whose terminal checkpoint may already have been taken. `nil` in
  /// production.
  var singleDocumentIndexWriteGateOverride: (@Sendable () async -> Void)?

  /// Narrow test seam: fired on the main actor INSIDE the open task, in the SAME step that publishes
  /// the pool and before that task returns to the caller which owns it.
  ///
  /// It exists because the window the owner-path recheck closes cannot be reached from a test any
  /// other way. That window is "the latch closed AFTER publication but BEFORE the owning
  /// continuation was scheduled", and which of the continuations parked on the open task runs first
  /// is the scheduler's business — measured, the drain wins most but not all of the time, so a pin
  /// built on that race asserts the scheduler rather than the contract. Fired here a test reaches
  /// exactly that state synchronously, with no continuation able to interleave. `nil` in production.
  var didPublishDatabasePool: (@MainActor @Sendable () -> Void)?

  /// Coalesces concurrent off-main opens: the first `ensureOpenInBackground` that finds no pool
  /// starts the migration on a detached executor and parks this task; later callers await the SAME
  /// task instead of racing a second `DatabasePool`/migration. Cleared once the open resolves.
  private var openTask: Task<DatabasePool, Error>?

  /// The termination latch. One-way, and it is SET BY `TerminationSequence` — never by this class on
  /// its own, never unset, and never earlier than the sequence's drain. Position matters: the flush
  /// phase PRODUCES index writes that must be accepted, so a latch armed at the start of the quit
  /// would throw away exactly the work the quit exists to save.
  ///
  /// Past this point the funnel is closed. Every write entry point refuses, and so does lazy open —
  /// "a read can write": the first search / backlink / count after a fresh install creates the
  /// directory, builds the `DatabasePool` and runs every migration, which is a pile of DDL and an
  /// FTS backfill. Gating only the twelve domain methods would leave that door open.
  /// `startCheckpointOnTerminate()` is the one operation still allowed — it goes straight to
  /// `databasePool` and never asks to open anything.
  ///
  /// This is the second of two layers and they cover different failures. Quiescing the producers
  /// (`FolderManager.quiesceForTermination`, `Autosaver.quiesceForTermination`) protects DATA
  /// COMPLETENESS — work that should land, lands, and the drain sees a finite snapshot. The latch
  /// protects ORDER and CLOSURE: it makes a late write impossible by construction for producers the
  /// inventory missed or that have not been written yet. Enumeration cannot promise that; refusal
  /// can.
  private(set) var isClosedForTermination = false

  /// The same latch, readable WITHOUT the main actor — and it exists because a `Bool` on a
  /// `@MainActor` class is unreadable from the one place that has to consult it.
  ///
  /// `isClosedForTermination` gates ENTRY. Every write entry point checks it before it starts, and
  /// that is all the protection an accepted write ever had: once `reindexInBackground` has passed
  /// the guard and its detached `replaceSearchIndex` holds the pool's writer, nothing can stop it.
  /// `sequence.cancel()` does not — the write is a `Task.detached` no cancellation reaches, and
  /// SQLite work is not cancellation-aware anyway. So a large reindex that outlives the quit's
  /// budget commits AFTER the fallback checkpoint that was supposed to be the last word on the WAL.
  ///
  /// Closing that needs a check INSIDE the transaction, on the writer's own thread, between batches
  /// — a synchronous read from a `nonisolated static` context, which the main-actor flag cannot
  /// serve. Hence a lock-guarded mirror, set by the same one-way `closeForTermination()`.
  private let terminationLatch = TerminationLatch()

  /// Entry points refused since the latch closed, in call order. Production never reads this; it is
  /// the seam a test uses to prove a post-latch producer was REFUSED rather than quietly swallowed.
  private(set) var terminationRejectedEntryPoints: [String] = []

  init(
    databaseURL: URL? = nil,
    searchIndexBatchSize: Int = 32,
    didInsertSearchIndexBatch: (@Sendable (Int) -> Void)? = nil,
    didOpenBacklinkRead: (@Sendable () -> Void)? = nil
  ) {
    self.configuredDatabaseURL = databaseURL
    self.searchIndexBatchSize = max(1, searchIndexBatchSize)
    self.didInsertSearchIndexBatch = didInsertSearchIndexBatch
    self.didOpenBacklinkRead = didOpenBacklinkRead
  }

  // MARK: - Termination latch

  /// Closes the funnel. Called by `TerminationSequence` AFTER its drain and BEFORE the terminal
  /// checkpoint, and by the post-deadline fallback — a spent budget stops the waiting, it does not
  /// put the app back into a running state.
  ///
  /// The deferred hot-path truncate is dropped here rather than left to be refused when it fires: it
  /// is a sleeping timer, it is the one piece of index work the drain deliberately does not track,
  /// and the terminal checkpoint that follows this latch truncates the WAL anyway.
  /// Stops the hot-path backoff ladder, WITHOUT closing the funnel. Issued by `TerminationSequence`
  /// from INSIDE its stability drain, at the first moment everything visible has landed — the one
  /// point at which "nothing is owed" is about to be decided and the ladder is the only producer that
  /// can contradict it afterwards.
  ///
  /// The ladder sleeps OUTSIDE `scheduledIndexWrites` by design (`deferIndexBatchTruncation()`: the
  /// drain must never have to wait out a timer). That is what made it invisible to both drains the
  /// quit already ran: a retry waking during `waitForPendingIndexMaintenance()` cleared its handle,
  /// re-entered `scheduleIndexBatchMaintenance()` and registered a maintenance pass AFTER the last
  /// thing that would have awaited it — a plain `pool.write` doing `incremental_vacuum` + truncate,
  /// which the latch and the terminal checkpoint could then overtake, leaving WAL frames behind the
  /// checkpoint that is supposed to be final.
  ///
  /// Cancelling on the main actor is exact rather than lucky: the retry body is `@MainActor` and runs
  /// its guard, its handle clear and its re-entry synchronously after the sleep resumes. So at this
  /// call the retry has either already registered its pass — in `scheduledIndexWrites`, which the
  /// drain that follows covers — or it has not resumed at all, and the cancellation makes sure it
  /// never will. Nothing in between.
  ///
  /// One-way, and separate from `closeForTermination()` on purpose: the latch must stay AFTER the
  /// drain (the flush phase produces writes that have to be accepted), while the ladder has to stop
  /// BEFORE it, or the drain is bounding a target that can still move. A truncate refused after this
  /// point is not owed to anyone — `startCheckpointOnTerminate()` takes the WAL to zero under the
  /// barrier regardless of what the ladder had planned.
  func quiesceIndexBatchTruncationRetry() {
    isIndexBatchTruncationRetryQuiesced = true
    pendingIndexBatchTruncationRetry?.cancel()
    pendingIndexBatchTruncationRetry = nil
  }

  func closeForTermination() {
    isClosedForTermination = true
    // Set in the same one-way step, so "the funnel is closed" and "an accepted write must stop
    // building" can never disagree. See `terminationLatch`.
    terminationLatch.close()
    pendingIndexBatchTruncationRetry?.cancel()
    pendingIndexBatchTruncationRetry = nil
    // Past the latch nothing is owed: `scheduleIndexBatchMaintenance()` refuses anyway, so a
    // remembered request could only ever be refused when the re-arm fired. Cleared so "latched
    // ⇒ no maintenance outstanding" is literally true rather than true by downstream accident.
    indexBatchMaintenanceRequestedWhileActive = false
  }

  /// The gate every write entry point and both open paths consult. Returns `true` when the caller
  /// must refuse, and names the refused entry point in the log so a late producer is auditable
  /// rather than invisible.
  ///
  /// Note what is NOT gated here and why: the bare `Task { }` index writes in `DocumentStore`
  /// (`removeRoot`'s delete, the live-refresh and cold-open deltas) are deliberately left as they
  /// are. Their work is workspace CHURN — recomputable from disk — so post-latch refusal costs a
  /// freshness that the next launch's cold-open delta rebuilds anyway, and funnelling all six
  /// through a registration mechanism is a refactor this termination contract does not need. What
  /// the contract does need is that they cannot land BEHIND the checkpoint, and refusal gives
  /// exactly that.
  private func isRefusedAfterTermination(_ entryPoint: String) -> Bool {
    guard isClosedForTermination else { return false }
    terminationRejectedEntryPoints.append(entryPoint)
    NSLog(
      "Pensieve quit: index entry point refused after the termination latch closed (%@)", entryPoint)
    return true
  }

  /// Synchronous open — retained for the legacy synchronous workspace path and for tests that drive
  /// the index directly. The LIVE app (background import path) opens via `openInBackground` so the
  /// migration never blocks the main run loop. Building the pool + migrating is the heaviest cost
  /// (incl. the FTS5 content-link rebuild migration), so this must not be on the hot import path.
  func open(into appState: AppState? = nil) {
    guard !isRefusedAfterTermination("open") else { return }
    do {
      let url = try resolveDatabaseURL()
      let pool = try Self.makeDatabasePool(at: url)
      databasePool = pool
      databaseURL = url
    } catch {
      reportOpenFailure(error, appState: appState)
    }
  }

  /// Opens the index off the main thread. Idempotent and concurrency-safe: returns the existing pool
  /// immediately, joins an in-flight open, or starts one whose `DatabasePool(path:)` + migrations run
  /// on a detached background executor. Only the cheap pool/url assignment happens back on the main
  /// actor. This is the keystone of the P0 fix — every background DB path routes its first-open here.
  func openInBackground(into appState: AppState? = nil) async {
    _ = await ensureOpenInBackground(into: appState)
  }

  /// Thrown by the open task when the termination latch closed while the pool was still being built.
  /// It is deliberately NOT an open failure — nothing is wrong with the database — so it never
  /// reaches `reportOpenFailure` and never surfaces to the user; the caller simply gets `nil`, the
  /// same answer the gate at the top of `ensureOpenInBackground` would have given it a moment
  /// earlier.
  private struct OpenRefusedAfterTermination: Error {}

  private func ensureOpenInBackground(into appState: AppState?) async -> DatabasePool? {
    guard !isRefusedAfterTermination("ensureOpenInBackground") else { return nil }
    if let databasePool { return databasePool }
    if let openTask {
      let pool = try? await openTask.value
      // Re-consulted AFTER the await, for the same reason the OWNER path below does it — the full
      // argument lives there: this caller slept through an unknown amount of the quit, and handing
      // back a pool the latch has since refused would let it write behind the terminal checkpoint.
      guard !isRefusedAfterTermination("ensureOpenInBackground") else { return nil }
      return pool
    }

    let url: URL
    do {
      url = try resolveDatabaseURL()
    } catch {
      reportOpenFailure(error, appState: appState)
      return nil
    }

    // The task PUBLISHES as well as builds, and that is not a tidiness choice. `openTask` is what the
    // termination drain awaits, so "the open finished" and "the pool is visible" have to be the SAME
    // event: with the publication left in the caller's continuation, the drain could resume from
    // `openTask.value` first, report nothing owed, and let the latch close over a database that then
    // appeared underneath it — the review finding this addresses.
    let openGate = databaseOpenGateOverride
    let task = Task<DatabasePool, Error> { @MainActor in
      let pool = try await Task.detached(priority: .userInitiated) {
        await openGate?()
        return try Self.makeDatabasePool(at: url)
      }.value
      guard !self.isRefusedAfterTermination("ensureOpenInBackground") else {
        Self.discardPoolRefusedByTermination(pool)
        throw OpenRefusedAfterTermination()
      }
      self.databasePool = pool
      self.databaseURL = url
      self.didPublishDatabasePool?()
      return pool
    }
    openTask = task
    defer { openTask = nil }

    do {
      let pool = try await task.value
      // Re-consulted AFTER the await, and NOT a duplicate of the check inside the task: that one
      // refuses a latch which closed BEFORE publication, this one a latch which closed AFTER it.
      // The window is the termination drain, which awaits this very task — so the instant the task
      // publishes, the drain's continuation can resume first, find nothing else owed, close the
      // latch and take the terminal checkpoint, all before this continuation is ever scheduled.
      //
      // The asymmetry with the in-task refusal is deliberate: nothing is discarded and nothing is
      // torn down here. The pool IS published (publication and the in-task latch check are a single
      // main-actor step, so a published pool always precedes the latch), which means the terminal
      // checkpoint that just ran SAW it and truncated it. The one thing refused is handing that
      // pool to a caller who would then write behind a checkpoint already taken.
      guard !isRefusedAfterTermination("ensureOpenInBackground") else { return nil }
      return pool
    } catch is OpenRefusedAfterTermination {
      return nil
    } catch {
      reportOpenFailure(error, appState: appState)
      return nil
    }
  }

  /// Disposes of a pool whose publication the termination latch refused.
  ///
  /// The migrations that just ran are committed work sitting in the WAL, and this pool is the only
  /// connection that will ever see it — `databasePool` stays nil, so `startCheckpointOnTerminate()`
  /// finds nothing to checkpoint and the WAL would otherwise be left at its high-water mark. Rather
  /// than lean on GRDB's deinit-time connection teardown (whose SQLite auto-checkpoint is real but
  /// implicit, and whose timing is ARC's business), the truncate is asked for explicitly.
  ///
  /// Detached rather than inline: this runs inside the quit's pumped run loop, where a synchronous
  /// barrier write would park the pump — the exact failure mode the third Round 6 finding is about.
  /// The task keeps the pool alive until the checkpoint returns and then drops it. Named residual: a
  /// process that exits first leaves the WAL for the next launch's workspace-close maintenance to
  /// reclaim, which is the same bound the post-deadline best-effort checkpoint already carries.
  private nonisolated static func discardPoolRefusedByTermination(_ pool: DatabasePool) {
    Task.detached(priority: .utility) {
      do {
        try pool.barrierWriteWithoutTransaction { db in
          _ = try db.checkpoint(.truncate)
        }
      } catch {
        NSLog(
          "Pensieve quit: could not checkpoint a database whose open the termination latch refused: %@",
          error.localizedDescription)
      }
    }
  }

  /// Pool configuration carrying the storage-hygiene pragmas.
  ///
  /// `auto_vacuum` decides whether freed pages can ever be handed back to the filesystem, and SQLite
  /// only accepts a mode change while the database file is still EMPTY — afterwards it silently
  /// ignores the pragma until a full `VACUUM` rewrites the file. "Empty" is stricter than it looks:
  /// flipping the journal into WAL already materializes the header, so ordering matters. Verified on
  /// SQLite 3.51: `journal_mode=WAL` → `auto_vacuum=INCREMENTAL` → `CREATE TABLE` still reports
  /// `auto_vacuum = 0`, while the reverse order reports `2`. GRDB runs `prepareDatabase` when it
  /// opens each connection and only afterwards calls `setUpWALMode()` on the writer, so setting the
  /// pragma here is the one hook that lands before the header exists — every FRESH index.db is born
  /// INCREMENTAL and can be compacted by `PRAGMA incremental_vacuum` alone (no whole-file rewrite).
  ///
  /// Pool readers are read-only connections (`DatabasePool.readerConfiguration`); the pragma would be
  /// meaningless there, so it is skipped explicitly rather than left to SQLite's tolerance.
  /// Databases created BEFORE this change stay `auto_vacuum = 0` — see
  /// `convertToIncrementalAutoVacuumIfNeeded` for the one-shot migration path.
  private nonisolated static func makeConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      guard !db.configuration.readonly else { return }
      try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
    }
    return configuration
  }

  private func resolveDatabaseURL() throws -> URL {
    if let configuredDatabaseURL {
      return configuredDatabaseURL
    }
    let directory = try applicationSupportDirectory()
    return directory.appendingPathComponent("index.db", isDirectory: false)
  }

  private func reportOpenFailure(_ error: Error, appState: AppState?) {
    let message = "Could not open Pensieve index database: \(error.localizedDescription)"
    appState?.lastError = message
    NSLog("%@", message)
  }

  /// Builds the GRDB pool and runs all migrations. `nonisolated static` so it can execute on a
  /// detached background executor (off main). `DatabasePool` already serializes its own reads/writes
  /// across a managed thread pool; migrations are idempotent (`DatabaseMigrator` runs each once).
  private nonisolated static func makeDatabasePool(at url: URL) throws -> DatabasePool {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let pool = try DatabasePool(path: url.path, configuration: makeConfiguration())

    var migrator = DatabaseMigrator()
    migrator.registerMigration("mvp_workspace_search_fts") { db in
      try db.execute(
        sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS workspace_search_documents
          USING fts5(
              path UNINDEXED,
              title,
              display_path,
              body,
              is_ad_hoc UNINDEXED,
              updated_at UNINDEXED,
              tokenize = 'unicode61'
          )
          """)
    }
    registerIndexV2Migrations(&migrator)
    try migrator.migrate(pool)
    return pool
  }

  /// B-2 IndexDatabase v2 schema (I-01, Wave A foundation).
  ///
  /// Registered AFTER `mvp_workspace_search_fts` so the existing FTS table is
  /// created first; the `b2_v2_*` namespace stays separate from the MVP
  /// migration for clarity. `DatabaseMigrator` runs each registered migration
  /// exactly once per database, so adding these alongside the MVP migration is
  /// idempotent by construction.
  ///
  /// Order matters: `documents` is created before the tables that FK to it
  /// (`document_revisions`, `document_chunks`), and `workspaces` before the
  /// tables that FK to it (`documents`, `scan_sessions`, `workspace_stats`).
  ///
  /// Active writers land in later waves — `workspaces`/`documents` in W-B-1
  /// (I-02), FTS5 content-link in W-C-1 (I-03), `scan_sessions`/
  /// `workspace_stats` in W-D-1 (I-04). `document_revisions` and
  /// `document_chunks` are scaffolding DDL only this wave (writers in H-1 and
  /// C-3 respectively). No FTS scaffolding migration is needed here — W-C-1
  /// owns the full FTS5 content-link rebuild as a self-contained migration.
  private nonisolated static func registerIndexV2Migrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("b2_v2_workspaces") { db in
      try db.execute(
        sql: """
          CREATE TABLE workspaces (
              workspace_id TEXT PRIMARY KEY,
              canonical_path TEXT NOT NULL,
              volume_resource_id TEXT,
              bookmark_hash TEXT,
              first_seen_at INTEGER NOT NULL,
              last_seen_at INTEGER NOT NULL,
              status TEXT NOT NULL
          )
          """)
    }

    migrator.registerMigration("b2_v2_documents") { db in
      try db.execute(
        sql: """
          CREATE TABLE documents (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
              path TEXT NOT NULL,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              mtime INTEGER NOT NULL,
              size INTEGER NOT NULL,
              is_ad_hoc INTEGER NOT NULL,
              indexed_at INTEGER NOT NULL,
              UNIQUE(workspace_id, path)
          )
          """)
      try db.execute(sql: "CREATE INDEX idx_documents_workspace ON documents(workspace_id)")
      try db.execute(sql: "CREATE INDEX idx_documents_path ON documents(workspace_id, path)")
    }

    // Scaffolding DDL only; writer added in future H-1 version history pack.
    migrator.registerMigration("b2_v2_document_revisions") { db in
      try db.execute(
        sql: """
          CREATE TABLE document_revisions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              document_id INTEGER NOT NULL REFERENCES documents(id),
              revision_at INTEGER NOT NULL,
              body_hash TEXT NOT NULL
          )
          """)
    }

    // Scaffolding DDL only; chunker writer + embedding column added in future
    // C-3 vector layer pack.
    migrator.registerMigration("b2_v2_document_chunks") { db in
      try db.execute(
        sql: """
          CREATE TABLE document_chunks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              document_id INTEGER NOT NULL REFERENCES documents(id),
              chunk_index INTEGER NOT NULL,
              chunk_text TEXT NOT NULL,
              chunk_hash TEXT NOT NULL
          )
          """)
    }

    migrator.registerMigration("b2_v2_scan_sessions") { db in
      try db.execute(
        sql: """
          CREATE TABLE scan_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
              started_at INTEGER NOT NULL,
              finished_at INTEGER,
              trigger TEXT NOT NULL,
              scanner_version INTEGER NOT NULL,
              fingerprint_hash TEXT,
              file_count INTEGER,
              folder_count INTEGER,
              duration_ms INTEGER
          )
          """)
      try db.execute(
        sql: "CREATE INDEX idx_scan_sessions_workspace ON scan_sessions(workspace_id, started_at)")
    }

    migrator.registerMigration("b2_v2_workspace_stats") { db in
      try db.execute(
        sql: """
          CREATE TABLE workspace_stats (
              workspace_id TEXT PRIMARY KEY REFERENCES workspaces(workspace_id),
              file_count INTEGER NOT NULL,
              folder_count INTEGER NOT NULL,
              last_scan_at INTEGER,
              last_indexed_at INTEGER,
              index_health TEXT NOT NULL
          )
          """)
    }

    // I-03 (W-C-1) v1 (RETIRED by `b2_v2_external_content_fts` below): the
    // original documents->`workspace_search_documents` mirroring triggers. KEPT
    // REGISTERED (not deleted) so the applied-migration history is preserved on
    // the operator's existing DB (DatabaseMigrator keys migrations by identifier;
    // removing this one would orphan its recorded identifier). On a FRESH DB it
    // recreates these triggers and the next migration immediately drops them
    // (wasteful but correct); on the operator's DB it was already applied and is
    // a no-op. The CONTENTFUL `workspace_search_documents` table itself is
    // created by the MVP `mvp_workspace_search_fts` migration and retired in the
    // external-content migration below.
    migrator.registerMigration("b2_v2_fts_documents_triggers") { db in
      try db.execute(
        sql: """
          CREATE TRIGGER documents_after_insert_fts
          AFTER INSERT ON documents
          WHEN NEW.is_ad_hoc = 0
          BEGIN
              DELETE FROM workspace_search_documents
               WHERE path = (
                   SELECT canonical_path FROM workspaces
                    WHERE workspace_id = NEW.workspace_id
               ) || '/' || NEW.path;
              INSERT INTO workspace_search_documents
                  (path, title, display_path, body, is_ad_hoc, updated_at)
              VALUES (
                  (SELECT canonical_path FROM workspaces
                    WHERE workspace_id = NEW.workspace_id) || '/' || NEW.path,
                  NEW.title,
                  NEW.path,
                  NEW.body,
                  NEW.is_ad_hoc,
                  NEW.mtime
              );
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_after_update_fts
          AFTER UPDATE OF body, title, mtime ON documents
          WHEN NEW.is_ad_hoc = 0
          BEGIN
              DELETE FROM workspace_search_documents
               WHERE path = (
                   SELECT canonical_path FROM workspaces
                    WHERE workspace_id = OLD.workspace_id
               ) || '/' || OLD.path;
              INSERT INTO workspace_search_documents
                  (path, title, display_path, body, is_ad_hoc, updated_at)
              VALUES (
                  (SELECT canonical_path FROM workspaces
                    WHERE workspace_id = NEW.workspace_id) || '/' || NEW.path,
                  NEW.title,
                  NEW.path,
                  NEW.body,
                  NEW.is_ad_hoc,
                  NEW.mtime
              );
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_after_delete_fts
          AFTER DELETE ON documents
          WHEN OLD.is_ad_hoc = 0
          BEGIN
              DELETE FROM workspace_search_documents
               WHERE path = (
                   SELECT canonical_path FROM workspaces
                    WHERE workspace_id = OLD.workspace_id
               ) || '/' || OLD.path;
          END
          """)
    }

    // I-03 (W-C-1) v2: EXTERNAL-CONTENT FTS5 over `documents`.
    //
    // STAGE 1 (external-content FTS): `documents` is the SINGLE source of truth
    // for every searchable row — workspace docs AND ad-hoc out-of-workspace docs
    // (the latter live under the reserved `__adhoc__` workspace, see below).
    // `document_fts` is an external-content FTS5 index over `documents`: it
    // stores ONLY the inverted index, never the body text (the old contentful
    // `workspace_search_documents` stored the full body, doubling on-disk size
    // since `documents.body` already holds it). The FTS rowid IS `documents.id`
    // (an INTEGER PRIMARY KEY alias for the SQLite rowid), so a search joins
    // `document_fts.rowid = documents.id` and reads title/display_path/body and
    // the workspace scope directly from `documents`.
    //
    // Column mapping (matches the prior FTS columns the search reads):
    //   title <- documents.title, display_path <- documents.path,
    //   body <- documents.body. `is_ad_hoc`/`updated_at`/full-`path` are NOT FTS
    //   columns anymore — they are read from `documents` (is_ad_hoc, mtime) and
    //   reconstructed (full path = canonical_path || '/' || path for workspace
    //   docs, or `path` verbatim for ad-hoc) in the search SQL.
    //
    // Tokenizer: `unicode61` with the default `remove_diacritics = 1` — byte-for-
    // byte the same tokenize spec the old `workspace_search_documents` used, so
    // tokenization (and therefore MATCH/bm25 hit sets) is identical.
    // `columnsize=0`: we never need per-column sizes (bm25 with default weights
    // does not require them here), which shrinks the index further.
    //
    // The three triggers below follow the canonical FTS5 external-content
    // contract (sqlite.org/fts5.html): AFTER INSERT inserts (rowid, cols); AFTER
    // DELETE / AFTER UPDATE issue the special `'delete'` command with the OLD
    // column values so the inverted-index entries for the removed document are
    // located and removed (the delete command REQUIRES the original text the row
    // held — `old.*` provides exactly that). They fire for ALL documents rows
    // (workspace + ad-hoc): every `documents` row is searchable, scoped in SQL.
    //
    // The migration is registered AFTER `b2_v2_documents` (the content table must
    // exist first) and is idempotent by construction (DatabaseMigrator runs it
    // once per DB). On an EXISTING populated DB it: (1) reserves the `__adhoc__`
    // workspace, (2) backfills `documents` from the legacy contentful FTS for any
    // body that lived ONLY in `workspace_search_documents` (ad-hoc rows, and any
    // legacy inline-indexed row not in `documents`) so nothing searchable is
    // lost, (3) creates `document_fts` + triggers + `'rebuild'` backfill from
    // `documents`, then (4) RETIRES the old contentful table and its triggers.
    migrator.registerMigration("b2_v2_external_content_fts") { db in
      // (1) Reserved sentinel workspace for ad-hoc / out-of-workspace docs so they
      // satisfy `documents.workspace_id NOT NULL REFERENCES workspaces`. Empty
      // canonical_path: ad-hoc `documents.path` is the FULL standardized path, so
      // the search full-path reconstruction uses `path` verbatim for them. Created
      // LAZILY — only when the legacy FTS holds rows that will be migrated as
      // ad-hoc (step 2) — so a DB with no ad-hoc docs keeps a clean `workspaces`
      // table. At runtime `ensureWorkspaceRow` re-creates it on the first ad-hoc
      // write. (DROP TABLE on the legacy FTS happens AFTER the backfill below.)
      let legacyAdHocCount =
        (try? Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM workspace_search_documents f
            WHERE NOT EXISTS (
                SELECT 1 FROM documents d
                JOIN workspaces w ON w.workspace_id = d.workspace_id
                WHERE w.canonical_path || '/' || d.path = f.path
            )
            """)) ?? 0
      if legacyAdHocCount > 0 {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO workspaces
                (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
                 first_seen_at, last_seen_at, status)
            VALUES (?, '', NULL, NULL, 0, 0, 'adhoc')
            """,
          arguments: [Self.adHocWorkspaceID])
      }

      // (2) Migrate any body that lived ONLY in the legacy contentful FTS into
      // `documents` so it stays searchable under external content. This covers
      // ad-hoc rows (never in `documents`) and any legacy inline-indexed
      // workspace row that predates the documents writer. Workspace rows already
      // in `documents` (matched by reconstructed full path) are skipped — their
      // body is authoritative in `documents` already.
      //
      // The legacy `path` column is the FULL standardized path. A row maps to an
      // existing workspace doc when `canonical_path || '/' || documents.path`
      // equals it; otherwise it is treated as ad-hoc and inserted under the
      // sentinel workspace with `path` = the full path. `mtime`/`size` come from
      // the legacy `updated_at` (best-effort; size is the body byte length).
      // `INSERT OR IGNORE` + `GROUP BY f.path` keep the migration safe on a messy
      // operator DB: any legacy duplicate full path (or a collision with the
      // reserved workspace's `UNIQUE(workspace_id, path)`) is collapsed instead
      // of aborting the migration.
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO documents
              (workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at)
          SELECT
              ?,
              f.path,
              f.title,
              f.body,
              CAST(f.updated_at AS INTEGER),
              length(f.body),
              1,
              CAST(f.updated_at AS INTEGER)
          FROM workspace_search_documents f
          WHERE NOT EXISTS (
              SELECT 1 FROM documents d
              JOIN workspaces w ON w.workspace_id = d.workspace_id
              WHERE w.canonical_path || '/' || d.path = f.path
          )
          GROUP BY f.path
          """,
        arguments: [Self.adHocWorkspaceID])

      // (3) External-content FTS5 index over `documents`, then triggers + rebuild.
      // FTS5 external content reads the indexed columns from the content table BY
      // NAME (the 'rebuild' command + implicit reads issue `SELECT id, <fts cols>
      // FROM documents`), so the FTS column names MUST match `documents` columns:
      // title, path (the workspace-relative or full ad-hoc path; the old
      // contentful table's separate `display_path` is reconstructed at search
      // time), body. is_ad_hoc / mtime / workspace scope are read from
      // `documents`, not indexed.
      try db.execute(
        sql: """
          CREATE VIRTUAL TABLE document_fts USING fts5(
              title,
              path,
              body,
              content='documents',
              content_rowid='id',
              columnsize=0,
              tokenize='unicode61'
          )
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_ai AFTER INSERT ON documents BEGIN
              INSERT INTO document_fts(rowid, title, path, body)
              VALUES (new.id, new.title, new.path, new.body);
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
              INSERT INTO document_fts(document_fts, rowid, title, path, body)
              VALUES ('delete', old.id, old.title, old.path, old.body);
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_au AFTER UPDATE ON documents BEGIN
              INSERT INTO document_fts(document_fts, rowid, title, path, body)
              VALUES ('delete', old.id, old.title, old.path, old.body);
              INSERT INTO document_fts(rowid, title, path, body)
              VALUES (new.id, new.title, new.path, new.body);
          END
          """)
      // Backfill the inverted index from every existing `documents` row.
      try db.execute(sql: "INSERT INTO document_fts(document_fts) VALUES('rebuild')")

      // (4) Retire the legacy contentful FTS + its documents-mirroring triggers.
      // After this the body text lives ONLY in `documents.body`; `document_fts`
      // holds no body. Triggers may not exist on a fresh DB — DROP IF EXISTS.
      try db.execute(sql: "DROP TRIGGER IF EXISTS documents_after_insert_fts")
      try db.execute(sql: "DROP TRIGGER IF EXISTS documents_after_update_fts")
      try db.execute(sql: "DROP TRIGGER IF EXISTS documents_after_delete_fts")
      try db.execute(sql: "DROP TABLE IF EXISTS workspace_search_documents")
    }
  }

  /// Reserved workspace_id under which ad-hoc / out-of-workspace open files live
  /// in `documents`, so they satisfy the `workspace_id NOT NULL REFERENCES
  /// workspaces` FK while staying searchable. Their `documents.path` is the FULL
  /// standardized URL path (they have no workspace-relative path); the search
  /// full-path reconstruction uses that verbatim (canonical_path is empty).
  nonisolated static let adHocWorkspaceID = "__adhoc__"

  func reindex(documents: [DocumentRef], appState: AppState? = nil) {
    guard let pool = ensureOpen(into: appState) else { return }
    reindex(documents: documents, pool: pool, appState: appState)
  }

  /// Returns `true` when the off-main FTS write committed, `false` when it threw (the error is
  /// still reported to the user via `report(...)`). Callers gate the on-disk `.md` search
  /// signature persist on this result so a FAILED write never leaves a signature claiming the
  /// index is current — which would make the next cold-start skip-gate silently skip over a
  /// stale/partial index. The result is discardable for callers that do not persist a signature.
  ///
  /// The `pendingIndexUpdateTask` chain returns `Void` (its supersede contract is unchanged); the
  /// success flag is observed by awaiting the dedicated `write` task this call owns.
  @discardableResult
  func reindexInBackground(documents: [DocumentRef], appState: AppState? = nil) async -> Bool {
    guard !isRefusedAfterTermination("reindexInBackground") else { return false }
    let batchSize = searchIndexBatchSize
    let didInsertBatch = didInsertSearchIndexBatch
    let latch = terminationLatch
    // Chain position RESERVED before this call's first suspension point — see
    // `reserveSupersedePosition(_:)`. The open moved INSIDE the task for exactly that reason.
    let previous = pendingIndexUpdateTask

    let write = Task { @MainActor [weak self] () -> Bool in
      await self?.awaitBackgroundWriteGate()
      await previous?.value
      guard let self, let pool = await self.ensureOpenInBackground(into: appState) else {
        return false
      }
      do {
        try await Task.detached(priority: .utility) {
          try Self.replaceSearchIndex(
            with: documents,
            pool: pool,
            batchSize: batchSize,
            didInsertBatch: didInsertBatch,
            latch: latch
          )
        }.value
        await self.refreshSearchResultsInBackground(in: appState)
        // A full reindex is the single biggest WAL producer in the app; bound the log afterwards.
        // ARMED, not awaited: keeping the barrier inside this task put it in the supersede tail, so a
        // pool reader that blocked the truncate blocked every write submitted behind it. Tests sync
        // on it through `drainPendingIndexWrites()`, which tracks it, rather than through
        // `waitForPendingReindex()`, which no longer does.
        self.scheduleIndexBatchMaintenance()
        return true
      } catch is IndexWriteAbandonedAfterTermination {
        Self.logAbandonedWriteAfterTermination("reindexInBackground")
        return false
      } catch {
        self.report(error, appState: appState, action: "rebuild Pensieve search index")
        return false
      }
    }
    // Keep the supersede chain `Void`-typed: a later update awaits "the prior write finished",
    // not its boolean result.
    reserveSupersedePosition(write)
    return await write.value
  }

  private func reindex(documents: [DocumentRef], pool: DatabasePool, appState: AppState?) {
    do {
      try Self.replaceSearchIndex(
        with: documents,
        pool: pool,
        batchSize: searchIndexBatchSize,
        didInsertBatch: didInsertSearchIndexBatch,
        latch: terminationLatch
      )
      refreshSearchResults(in: appState)
    } catch is IndexWriteAbandonedAfterTermination {
      Self.logAbandonedWriteAfterTermination("reindex")
    } catch {
      report(error, appState: appState, action: "rebuild Pensieve search index")
    }
  }

  /// An abandoned write is auditable, like a refused one, and for the same reason: it is a decision
  /// the quit made about the user's index, not an error the user can act on. Deliberately NOT routed
  /// through `report(...)` — surfacing "could not rebuild the search index" while the app is closing
  /// would turn a correct rollback into an alert nobody can answer.
  private nonisolated static func logAbandonedWriteAfterTermination(_ entryPoint: String) {
    NSLog(
      "Pensieve quit: an accepted index write was abandoned mid-transaction after the termination "
        + "latch closed (%@); it rolled back, so no frames land behind the terminal checkpoint",
      entryPoint)
  }

  /// Awaits the in-flight background index write (full reindex OR incremental
  /// delta apply) so tests can drive `updateSearchIndexInBackground` /
  /// `reindexInBackground` deterministically without sleeping. Returns
  /// immediately when nothing is pending.
  func waitForPendingReindex() async {
    await pendingIndexUpdateTask?.value
  }

  private func awaitBackgroundWriteGate() async {
    guard let gate = backgroundWriteGateOverride else { return }
    await gate()
  }

  /// Installs `write`'s `Void`-typed tail as the newest link of the supersede chain, SYNCHRONOUSLY —
  /// in the very same main-actor step in which its caller read `previous`.
  ///
  /// That pairing IS the ordering contract, and until now a suspension point sat between its two
  /// halves: all three background entry points captured `previous = pendingIndexUpdateTask`, then
  /// `await ensureOpenInBackground(...)`, and installed their own tail only afterwards. Two writes
  /// suspended on the same INITIAL open therefore captured the SAME predecessor — neither had
  /// installed a tail yet — and, resuming in whatever order the scheduler chose, ran unordered:
  /// each awaited a predecessor that was not the other, so the older body could overwrite the newer
  /// one's row in `documents`/FTS. GRDB serializes the two `pool.write`s but does not order them,
  /// which is precisely what this chain exists to add.
  ///
  /// Reserving here — before the call's first `await` — makes submission order the chain order by
  /// construction, and the open moves INSIDE the task, behind `await previous?.value`, where it is
  /// just more of the work being serialized.
  ///
  /// SCOPE, corrected in round 22. "Submission order by construction" holds for a DIRECT caller of
  /// an entry point — the reservation really is synchronous, in the same main-actor step that read
  /// `previous`. It does NOT reach across an unordered hop placed in FRONT of the entry point, and
  /// `scheduleIndexWrite` used to be exactly that: two saves handed over back-to-back became two
  /// independent unstructured tasks, whose START order Swift does not promise, so the later save
  /// could reach this reservation FIRST and the older body could then overwrite the newer row. The
  /// reservation point is synchronous; getting to it was not. Registration order is restored one
  /// storey up — see `ScheduledWriteOrdering`.
  ///
  /// The reserved position always RESOLVES. A refused or failed open returns `false` out of the
  /// task instead of escaping it, so a successor parked on this tail is released rather than wedged
  /// — the failure mode a reservation could otherwise introduce.
  private func reserveSupersedePosition(_ write: Task<Bool, Never>) {
    pendingIndexUpdateTask = Task { _ = await write.value }
  }

  /// How a scheduled hand-off relates to the hand-offs registered before it.
  ///
  /// The problem this exists for: `scheduleIndexWrite` hands work to an UNSTRUCTURED task, and Swift
  /// promises nothing about the order in which two such tasks start. The supersede position is
  /// reserved synchronously — but inside `work()`, i.e. on the far side of that hop — so for a
  /// hand-off the reservation point ITSELF raced. Two saves of the same document handed over
  /// back-to-back could reserve in either order, and when the older one reserved second it
  /// overwrote the newer FTS row after the newer bytes were already on disk: search advertising text
  /// no file contains, permanently for an ad-hoc document with no workspace repair path to correct
  /// it. Registration order is the one order the caller actually controls, so it becomes the
  /// contract.
  enum ScheduledWriteOrdering {
    /// Joins the hand-off chain: `work()` does not begin until every hand-off registered EARLIER has
    /// finished. Everything FUNCTIONAL wants this — save/autosave tails, the cold-scan workspace
    /// upsert, created-document reindexes — and it is close to free, because those paths already
    /// serialize on `pendingIndexUpdateTask` once they get there. All the chain adds is WHICH order
    /// they serialize in, and it adds it deterministically rather than by executor luck.
    case registrationOrdered
    /// Chained to nothing; runs as soon as the runtime starts it. Reserved for STORAGE HYGIENE,
    /// which round 11 deliberately took OUT of the supersede chain: its
    /// `barrierWriteWithoutTransaction` excludes the pool's READERS, so a serial queue shared with
    /// functional writes lets one wedged reader block every write submitted afterwards, for the rest
    /// of the session. Chaining the hand-offs would rebuild that defect one storey up — a save
    /// stuck behind a maintenance pass — so maintenance stays out of the queue here too. Pinned by
    /// round 11's own control, `testHotPathMaintenanceCannotStallTheIndexWritesSubmittedBehindIt`:
    /// it submits a hand-off while a pass is wedged at its barrier, which never completes if this
    /// case is removed.
    case independent
  }

  /// Hands an index write to a background task WITHOUT losing track of it. Same shape as the bare
  /// `Task` the save tail used to spawn inline — the save still returns before the write commits —
  /// except the task is recorded here, so `drainPendingIndexWrites()` can await work that is
  /// scheduled but has not reached the supersede chain yet. The task removes itself when it
  /// finishes, so an editing session does not accumulate handles.
  ///
  /// Ordered hand-offs additionally join the chain in REGISTRATION order (see
  /// `ScheduledWriteOrdering`): the predecessor is read in the same main-actor step that installs
  /// this hand-off's own tail, which is the same pairing `reserveSupersedePosition(_:)` relies on
  /// one storey down, for the same reason.
  ///
  /// The drain is unaffected by the chaining, in both directions. Nothing new is created that
  /// `scheduledIndexWrites` cannot see — the links are references to tasks already registered here —
  /// and awaiting the snapshot in whatever order a dictionary hands it over still terminates: the
  /// chain is linear and points only BACKWARDS, so awaiting a successor first simply waits out its
  /// predecessor and the predecessor is then already finished. A refusal past the latch returns
  /// before the tail is installed, so it can never leave a link nobody resolves.
  ///
  /// One invariant the callers owe: an ordered hand-off's `work()` must not AWAIT another ordered
  /// hand-off it registers itself — that would be a task waiting for its own successor. No caller
  /// does; the only write that schedules from inside a write is maintenance, which is `.independent`
  /// and fire-and-forget.
  @discardableResult
  func scheduleIndexWrite(
    ordering: ScheduledWriteOrdering = .registrationOrdered,
    _ work: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    // Refused post-latch at the hand-off itself, not merely inside the work: the drain has already
    // finished, so a task recorded here would never be awaited by anyone.
    guard !isRefusedAfterTermination("scheduleIndexWrite") else { return Task {} }
    let id = UUID()
    let isOrdered = ordering == .registrationOrdered
    let previous = isOrdered ? scheduledIndexWriteTail : nil
    let task = Task { @MainActor [weak self] in
      if isOrdered, let gate = self?.indexWriteHandoffGateOverride { await gate() }
      await previous?.value
      await work()
      self?.scheduledIndexWrites.removeValue(forKey: id)
    }
    scheduledIndexWrites[id] = task
    if isOrdered { scheduledIndexWriteTail = task }
    return task
  }

  /// Awaits EVERY index write this database currently owes: an open still building the pool, then
  /// the scheduled hand-offs (which join the supersede chain only once they start running), then the
  /// chain itself. Awaiting
  /// `pendingIndexUpdateTask` alone is not enough — it reads a tail that a just-scheduled save has
  /// not joined yet, which is exactly how a final save's write ended up landing after the quit
  /// checkpoint. The loop covers hand-offs scheduled BY the drain (a write can schedule a refresh
  /// of its own); it terminates because nothing re-arms once the workspace/app is going away.
  ///
  /// All three are read until they are SIMULTANEOUSLY stable, and the tail is no exception. It used
  /// to be a single snapshot taken after the loop, and that snapshot has the same hole the other two
  /// were looped for: two background updates parked on the initial open both get admitted, one
  /// installs its tail before this drain reads it and the other installs its tail while the drain is
  /// already awaiting the first. A snapshot returns as soon as the first finishes, the quit latches
  /// and checkpoints, and the second — already accepted, so the funnel will not refuse it — adds WAL
  /// frames behind that checkpoint. These background entry points do not re-check cancellation after
  /// the open, so quiescence cannot cover it either. Awaiting by identity until the tail stops moving
  /// can, and it still terminates for the same reason the rest of the loop does: nothing re-arms once
  /// quiescence has run, and the latch that follows this drain refuses whatever tries.
  func drainPendingIndexWrites() async {
    // Each distinct open is awaited exactly once, tracked by identity rather than by clearing
    // `openTask` — clearing it here would break the coalescing contract and let a later joiner start
    // a second `DatabasePool` over the same file. The supersede tail is tracked the same way: it is
    // never cleared, so identity is what tells "already awaited" from "moved while I waited".
    var awaitedOpen: Task<DatabasePool, Error>?
    var awaitedTail: Task<Void, Never>?
    while true {
      // An in-flight OPEN is work this drain can see nowhere else. It registers in neither collection
      // below, so without this the drain could report "nothing owed", the latch could close, and the
      // completed open would publish a pool whose caller writes behind the terminal checkpoint —
      // which, with `databasePool` still nil at latch time, `startCheckpointOnTerminate()` would have
      // skipped entirely. Awaited first, because the callers parked on it schedule their writes the
      // instant it resolves.
      if let openTask, openTask != awaitedOpen {
        awaitedOpen = openTask
        _ = try? await openTask.value
        continue
      }
      // Awaited in dictionary order, which is no order at all — and round 22's hand-off chain does
      // not change that. An ordered hand-off waits only for hand-offs registered BEFORE it, so the
      // links point strictly backwards: awaiting a successor first waits its predecessor out and
      // then finds it already finished. No cycle is reachable, so the snapshot always drains.
      if !scheduledIndexWrites.isEmpty {
        let scheduled = Array(scheduledIndexWrites.values)
        scheduledIndexWrites.removeAll()
        for task in scheduled {
          await task.value
        }
        continue
      }
      // Last, because a scheduled hand-off joins the chain only once it runs: reading the tail before
      // the collection above is empty would read a tail that is still growing. Re-read on every pass
      // — a tail that changed while this drain was parked on the previous one is a write the drain
      // accepted and has not waited for yet.
      guard let tail = pendingIndexUpdateTask, tail != awaitedTail else { break }
      awaitedTail = tail
      await tail.value
    }
  }

  /// Synchronous incremental index update: re-upsert each `upserting` doc
  /// (reading its body from disk) and delete the FTS rows for each `deletingPaths`
  /// entry, all inside a single serialized `pool.write` transaction. The update
  /// is proportional to the CHANGE, not to the workspace size — only the
  /// supplied docs/paths are touched; every other FTS row is left intact.
  ///
  /// Per-doc upsert mirrors `index(document:body:)` (DELETE-by-path + INSERT) so
  /// a modified doc's stale row is replaced and a brand-new doc is added.
  /// `deletingPaths` are the FULL standardized paths (== the search join key /
  /// the FTS `path` column) of removed files.
  ///
  /// Used by the explicit one-shot callers (file create/exclusion edits, tests).
  /// The watcher path uses `updateSearchIndexInBackground` so the body reads +
  /// write run off the main actor.
  func updateSearchIndex(
    upserting documents: [DocumentRef],
    deletingPaths: [String],
    appState: AppState? = nil
  ) {
    guard let pool = ensureOpen(into: appState) else { return }
    do {
      try Self.applySearchIndexDelta(
        upserting: documents,
        deletingPaths: deletingPaths,
        pool: pool,
        batchSize: searchIndexBatchSize,
        didInsertBatch: didInsertSearchIndexBatch,
        latch: terminationLatch
      )
      refreshSearchResults(in: appState)
    } catch is IndexWriteAbandonedAfterTermination {
      Self.logAbandonedWriteAfterTermination("updateSearchIndex")
    } catch {
      report(error, appState: appState, action: "update Pensieve search index")
    }
  }

  /// Off-main incremental index update mirroring `reindexInBackground`'s
  /// detached/`.utility`/batched pattern. The body reads + the single
  /// `pool.write` transaction run on a detached background task; only the
  /// `appState`-touching search refresh hops back to the main actor.
  ///
  /// Supersede-safe: each call chains onto `pendingIndexUpdateTask` before it
  /// starts its own write, so concurrent updates are serialized in submission
  /// order. GRDB already serializes `pool.write`; the chaining additionally
  /// guarantees a stale delta cannot land AFTER a newer one. Because the apply
  /// runs in one transaction, a cancelled/failed update either commits wholly or
  /// not at all — it can never leave the FTS index half-written.
  ///
  /// Returns `true` when the off-main delta write committed, `false` when it threw (still
  /// reported). Mirrors `reindexInBackground`: callers persist the on-disk `.md` signature ONLY on
  /// `true`, so a failed delta never advances the persisted cross-launch baseline. Discardable for
  /// non-persisting callers.
  @discardableResult
  func updateSearchIndexInBackground(
    upserting documents: [DocumentRef],
    deletingPaths: [String],
    appState: AppState? = nil
  ) async -> Bool {
    guard !isRefusedAfterTermination("updateSearchIndexInBackground") else { return false }
    let batchSize = searchIndexBatchSize
    let didInsertBatch = didInsertSearchIndexBatch
    let latch = terminationLatch
    // Chain position RESERVED before this call's first suspension point — see
    // `reserveSupersedePosition(_:)`.
    let previous = pendingIndexUpdateTask

    let write = Task { @MainActor [weak self] () -> Bool in
      await self?.awaitBackgroundWriteGate()
      await previous?.value
      guard let self, let pool = await self.ensureOpenInBackground(into: appState) else {
        return false
      }
      do {
        try await Task.detached(priority: .utility) {
          try Self.applySearchIndexDelta(
            upserting: documents,
            deletingPaths: deletingPaths,
            pool: pool,
            batchSize: batchSize,
            didInsertBatch: didInsertBatch,
            latch: latch
          )
        }.value
        await self.refreshSearchResultsInBackground(in: appState)
        // Watcher deltas are small individually but relentless in aggregate; the WAL-size throttle
        // inside `performMaintenanceInBackground` keeps this to a no-op until the log actually grows.
        // Armed rather than awaited — see `scheduleIndexBatchMaintenance()`.
        self.scheduleIndexBatchMaintenance()
        return true
      } catch is IndexWriteAbandonedAfterTermination {
        Self.logAbandonedWriteAfterTermination("updateSearchIndexInBackground")
        return false
      } catch {
        self.report(error, appState: appState, action: "update Pensieve search index")
        return false
      }
    }
    // Supersede chain stays `Void`-typed (see `reindexInBackground`).
    reserveSupersedePosition(write)
    return await write.value
  }

  // MARK: - Storage hygiene (WAL bound + compaction)

  /// Named lifecycle points at which the index is allowed to reclaim disk space. The index is a
  /// WAL database (`DatabasePool` implies WAL): SQLite's own auto-checkpoint is PASSIVE, so it
  /// recycles WAL frames but NEVER shrinks the `-wal` file — under a reindex storm the log keeps its
  /// high-water mark for the rest of the process (measured on this project: 3.7 GB index.db next to
  /// a 2.2 GB index.db-wal). Only an explicit TRUNCATE checkpoint gives the space back, and it must
  /// run when nothing is mid-write, hence the named points instead of a timer.
  enum MaintenanceReason: Sendable {
    /// A background index write (full reindex or incremental delta) just committed. Throttled by
    /// WAL size so the watcher's small deltas do not pay for a barrier checkpoint each time.
    case indexBatch
    /// The workspace is being closed (also covers "last root removed"). Nothing is being indexed,
    /// so this is the one point where the heavier compaction work is allowed to run.
    case workspaceClose
    /// A workspace close whose housekeeping is no longer running into the quiet index it was armed
    /// for: ANOTHER workspace opened while this pass was still queued behind the close's drain.
    ///
    /// `Close Folder` immediately followed by `Open Folder` is an ordinary two-second sequence, and
    /// the pass `closeWorkspace` arms is unawaited by every open path — so the heavy variant below
    /// (full-freelist `incremental_vacuum`, a one-off `VACUUM` conversion, and a truncate under
    /// `barrierWriteWithoutTransaction`) used to land in the middle of the NEW workspace's opening
    /// searches. The barrier is the part that hurts: in GRDB 6.29.3 it excludes the pool's READER
    /// checkouts, so every search, backlink and count in the fresh workspace waits it out.
    ///
    /// Downgraded rather than cancelled, because cancelling would silently drop the WAL bound the
    /// close pass exists to provide. This reason runs the SAME hygiene the app already runs while
    /// the operator types — plain write, `busy_timeout = 0`, `SQLITE_BUSY` means "not now" and
    /// re-arms the backoff ladder — so the bound is deferred and still enforced, and no reader is
    /// ever excluded for it.
    ///
    /// Reachable in two ways since round 20, with identical semantics. A pass may CARRY this reason
    /// from the moment it is called (the open had already happened by then), or it may carry
    /// `.workspaceClose` and be downgraded to this behaviour at BARRIER ACQUISITION, when the open
    /// happened inside its detached prologue instead. The second case never appears in the `reason`
    /// value — see `performMaintenanceInBackground(reason:exclusionRemainsWarranted:)` and the
    /// `barrierTimeMaintenanceDowngrades` counter.
    case workspaceCloseIntoOpenWorkspace

    /// Whether this pass may take `barrierWriteWithoutTransaction` — the one GRDB lock that
    /// excludes the pool's reader connections and not merely its writer. The real axis behind the
    /// three cases: "is anybody left who would notice being locked out of the index?"
    var mayExcludeReaders: Bool { self == .workspaceClose }
  }

  /// A background batch only triggers a checkpoint once the log is worth truncating. 16 MiB is ~4×
  /// SQLite's default 1000-page auto-checkpoint threshold: small enough that the WAL can never creep
  /// towards the gigabytes we measured, large enough that a save or a two-file watcher delta does
  /// not take the barrier lock.
  private nonisolated static let walCheckpointThresholdBytes: Int64 = 16 * 1024 * 1024

  /// Narrow test seam for the threshold above. The production constant is 16 MiB, and a unit test
  /// that had to actually write 16 MiB of WAL to reach the batch checkpoint would be a minute-long
  /// disk-bound test — so the two sides of the throttle (below → left alone, above → checkpoint)
  /// are pinned by lowering the bar instead. `nil` everywhere in production.
  var walCheckpointThresholdBytesOverride: Int64?

  private var effectiveWalCheckpointThresholdBytes: Int64 {
    walCheckpointThresholdBytesOverride ?? Self.walCheckpointThresholdBytes
  }

  /// First retry delay for a deferred hot-path truncate, doubling per consecutive deferral up to
  /// `indexBatchTruncationRetryMaximumDelayNanoseconds`. A second is short next to the reader it is
  /// waiting out and long next to the ~0.2 ms a refused checkpoint costs, and the ceiling keeps a
  /// reader that never lets go from turning into a busy poll for the rest of the session.
  private nonisolated static let indexBatchTruncationRetryBaseDelayNanoseconds: UInt64 = 1_000_000_000
  private nonisolated static let indexBatchTruncationRetryMaximumDelayNanoseconds: UInt64 =
    30_000_000_000

  /// Narrow test seam for the ladder above, same shape as `walCheckpointThresholdBytesOverride`: a
  /// pin that had to wait real seconds for the re-arm would be a wall-clock flake. `nil` in
  /// production.
  var indexBatchTruncationRetryDelayNanosecondsOverride: UInt64?

  private var effectiveIndexBatchTruncationRetryDelayNanoseconds: UInt64 {
    if let indexBatchTruncationRetryDelayNanosecondsOverride {
      return indexBatchTruncationRetryDelayNanosecondsOverride
    }
    // Shift clamped so a long-lived wedge cannot overflow the doubling before the cap applies.
    let shift = min(indexBatchTruncationRetryAttempt, 30)
    return min(
      Self.indexBatchTruncationRetryBaseDelayNanoseconds << shift,
      Self.indexBatchTruncationRetryMaximumDelayNanoseconds)
  }

  /// Below this much slack (256 pages ≈ 1 MiB at the default 4 KiB page size) compaction is not
  /// worth the write amplification — freed pages are reused by the next indexing pass anyway.
  private nonisolated static let freelistCompactionThresholdPages = 256

  /// Per-pass page budget for `incremental_vacuum` on the hot-ish batch path (≈16 MiB at 4 KiB
  /// pages), so a single maintenance pass cannot turn into an unbounded file rewrite. Workspace
  /// close reclaims everything.
  private nonisolated static let incrementalVacuumPageBudget = 4096

  /// Ceiling for the ONE-SHOT `auto_vacuum` conversion of a pre-existing database. The conversion is
  /// a full `VACUUM` (whole-file rewrite + peak disk usage of roughly 2× the file), so it is only
  /// attempted on databases where that cost is seconds, not minutes. Larger legacy files keep
  /// `auto_vacuum = 0` and are still WAL-bounded by the checkpoints; compacting those is an operator
  /// decision (delete-and-reindex is cheaper), deliberately out of this scope.
  private nonisolated static let autoVacuumConversionByteLimit: Int64 = 256 * 1024 * 1024

  /// Narrow test seam for the ceiling above, in the same instance-level shape as
  /// `walCheckpointThresholdBytesOverride`: a test that had to build a genuinely 256 MiB database to
  /// reach the decline branch would be a minute-long disk-bound test, so the bar is lowered instead.
  /// `nil` everywhere in production.
  var autoVacuumConversionByteLimitOverride: Int64?

  private var effectiveAutoVacuumConversionByteLimit: Int64 {
    autoVacuumConversionByteLimitOverride ?? Self.autoVacuumConversionByteLimit
  }

  /// The legacy-database conversion is attempted at most once per process — a failed or skipped
  /// conversion must not re-run a multi-second VACUUM on every workspace close.
  ///
  /// Readable from outside for the same reason `indexBatchTruncationDeferrals` is: a pass that gave
  /// way to a reopen must DEFER the conversion rather than retire it, and proving something did not
  /// happen needs the flag itself — there is no VACUUM to observe.
  private(set) var didAttemptAutoVacuumConversion = false

  /// How many close passes gave the one-shot conversion up to a workspace that opened while the
  /// conversion was still queuing for the pool's writer.
  ///
  /// Round 21, finding 2, and it needs a counter of its own for the reason round 20's
  /// `barrierTimeMaintenanceDowngrades` did: `didAttemptAutoVacuumConversion == false` is reached by
  /// three different roads — a pass downgraded before the conversion (round 20), a pass that never
  /// ran one, and this one — so the flag alone cannot tell them apart. This is the only seam that
  /// says the conversion was abandoned AT the writer rather than declined before it.
  private(set) var autoVacuumConversionsDeferredByOpen = 0

  /// Arms hot-path storage hygiene as its OWN tracked index write, instead of awaiting it inside the
  /// write task the supersede chain points at. Round 11's liveness fix, and the SINGLE hot-path entry
  /// point: the three background index writes call this, and nothing else reaches
  /// `performMaintenanceInBackground(reason: .indexBatch)` — including round 12's deferred retry,
  /// which comes back through here precisely so it re-checks the latch, the coalescing and the WAL
  /// threshold instead of re-running a pass on its own authority.
  ///
  /// Coalesced to at most one outstanding pass (see `pendingIndexBatchMaintenance`), which is also
  /// what keeps the round-12 deferral cheap: a pass that could not truncate re-arms exactly one
  /// successor rather than leaving a fan of retries behind. Coalesced is not DISCARDED, though —
  /// round 13: a request that finds a pass in flight is recorded and honoured when that pass's task
  /// clears the handle, because a pass which has already checkpointed cannot cover frames committed
  /// after it.
  ///
  /// ABSORBED by an armed backoff ladder, which is round 14 and the arming-side twin of round 13's
  /// trap. While `pendingIndexBatchTruncationRetry` owes a successor, a reader has just refused a
  /// truncate — so a request arriving here would arm a pass that the same reader refuses again in
  /// ~0.2 ms, having paid for an `incremental_vacuum` first. Once per save or watcher delta, for as
  /// long as the wedge lasts: the 1 s → 30 s backoff defeated from the outside. The ladder's own
  /// successor comes back through this method, re-stats the WAL and therefore covers these newer
  /// frames too, so the request is deferred (bounded by the 30 s cap) rather than dropped — the same
  /// contract round 13 wrote, reached from the other side.
  ///
  /// That branch deliberately does NOT set `indexBatchMaintenanceRequestedWhileActive`. That flag
  /// means "coalesced into a pass which had already checkpointed", and re-arming is the only way to
  /// cover such a request; here the ladder's successor covers it by construction, so setting the flag
  /// would only arm a redundant extra pass once the ladder's pass completed.
  ///
  /// Still covered by the termination drain, and by construction rather than by convention:
  /// `scheduleIndexWrite` registers the task in `scheduledIndexWrites`, which
  /// `drainPendingIndexWrites()` awaits to stability before phase L latches the funnel. Refused past
  /// the latch on both sides — here, and inside `performMaintenanceInBackground` itself. Neither does
  /// the absorption weaken the quit: `closeForTermination()` cancels the ladder and
  /// `startCheckpointOnTerminate()` enforces WAL→0 under the barrier regardless of what was owed.
  private func scheduleIndexBatchMaintenance() {
    guard !isClosedForTermination else { return }
    guard pendingIndexBatchMaintenance == nil else {
      indexBatchMaintenanceRequestedWhileActive = true
      return
    }
    // The ladder's OWN retry re-enters here, and must not be absorbed by its own handle — see the
    // clearing order in `deferIndexBatchTruncation()`, which this guard makes load-bearing.
    guard pendingIndexBatchTruncationRetry == nil else { return }
    // `.independent` is the round-11 contract restated at the hand-off storey: this pass takes a
    // reader-excluding barrier, so it must never sit in a queue that functional index writes also
    // sit in. Ordered here, one wedged reader would hold up every save registered behind it — the
    // exact defect round 11 removed from the supersede chain. It stays fully visible to the drain:
    // ordering and registration are separate properties, and this is still recorded in
    // `scheduledIndexWrites`.
    pendingIndexBatchMaintenance = scheduleIndexWrite(ordering: .independent) { [weak self] in
      await self?.performMaintenanceInBackground(reason: .indexBatch)
      if let gate = self?.maintenanceCompletionGateOverride { await gate() }
      self?.pendingIndexBatchMaintenance = nil
      self?.rearmIndexBatchMaintenanceIfRequestedWhileActive()
    }
  }

  /// Honours a maintenance request that the coalescing guard folded into a pass which had already
  /// checkpointed by then. Called by that pass's task the instant it clears the handle, so the
  /// successor is armed with nothing else needed to trigger it — no later index write, no lifecycle
  /// event. That is the round-13 contract: a request either RUNS, coalesces into a pass that will
  /// still cover its frames, or re-arms a successor. Never silently dropped.
  ///
  /// The one case that must NOT re-arm promptly is a pass the reader refused, and the two mechanisms
  /// compose through this guard. `deferIndexBatchTruncation()` has already armed a successor on the
  /// backoff ladder (1 s → ×2 → cap 30 s), and that successor comes back through
  /// `scheduleIndexBatchMaintenance()`, so it re-stats the WAL and covers the coalesced request's
  /// frames as well — the request is absorbed, not lost. Re-arming here on top of that would put a
  /// pass in flight IMMEDIATELY after a refusal, which the reader would refuse again in ~0.2 ms:
  /// the ladder exists precisely so a wedged reader cannot be polled, and prompt re-arming would
  /// bypass it once per write for as long as the wedge lasts.
  private func rearmIndexBatchMaintenanceIfRequestedWhileActive() {
    guard indexBatchMaintenanceRequestedWhileActive else { return }
    indexBatchMaintenanceRequestedWhileActive = false
    guard pendingIndexBatchTruncationRetry == nil else { return }
    scheduleIndexBatchMaintenance()
  }

  /// Reclaims index disk space off the main actor. No-op when the pool was never opened: maintenance
  /// must never be the thing that CREATES/migrates a database.
  ///
  /// Order is deliberate — compact first, checkpoint second: `incremental_vacuum` writes its page
  /// moves into the WAL, so truncating afterwards is what actually returns the bytes to the
  /// filesystem.
  ///
  /// The reasons deliberately take DIFFERENT locks, and that is round 12's fix, generalised in
  /// round 16 to the axis `MaintenanceReason.mayExcludeReaders` names:
  ///
  /// - `.workspaceClose` (like the terminal checkpoint) keeps `barrierWriteWithoutTransaction`. In
  ///   GRDB 6.29.3 that is `readerPool.barrier { writer.sync }`: it waits for the readers in flight
  ///   to be returned and blocks every reader CHECKOUT until it is done. By close/quit time there is
  ///   nothing left to index and the close is the thing that has to wait, so excluding readers is
  ///   correct there — and it is what makes the quit's WAL→0 guarantee unconditional.
  /// - `.indexBatch` runs while the operator is typing, searching and saving, where that same
  ///   exclusion makes storage hygiene wait for a reader and every LATER read wait for the
  ///   hygiene. So the hot path takes a plain `writeWithoutTransaction` and treats a refused
  ///   checkpoint as "not now": the truncate is DEFERRED and re-armed, never waited out.
  /// - `.workspaceCloseIntoOpenWorkspace` is a close pass that discovered it is no longer running
  ///   into a quiet index — a NEW workspace opened while it was queued behind the close's drain —
  ///   so "by close time there is nothing left" stopped being true and the exclusion stopped being
  ///   correct. It therefore takes the hot path's lock, for the hot path's reason. Since round 20
  ///   that discovery is made twice: once by the caller before this method is entered, and once by
  ///   this method immediately before the barrier, because the prologue in between is long enough
  ///   to contain a whole-file `VACUUM`. Round 21 added a third reading INSIDE that `VACUUM`'s own
  ///   write, because the queue for the pool's writer sits between the first reading and the first
  ///   byte of the rewrite — see `convertToIncrementalAutoVacuumIfNeeded`.
  ///
  /// Measured on GRDB 6.29.3 / SQLite on macOS 15 (round-12 probe, recorded because both halves are
  /// counter-intuitive):
  ///
  /// - With the barrier pending on a wedged reader, a `pool.write` submitted behind it COMPLETES,
  ///   while a `pool.read` BLOCKS. The writer is only taken once the readers have drained, so the
  ///   damage a hot-path barrier does is to READS — searches, backlinks, counts — not to saves.
  /// - A plain-write `db.checkpoint(.truncate)` does NOT silently degrade to a no-op, which is what
  ///   the comment here used to claim. With a reader on an older snapshot it returns `SQLITE_BUSY`
  ///   in ~0.2 ms and leaves the `-wal` file exactly as it was; once that reader is gone the same
  ///   call truncates the file to zero. Silent recycling is what a PASSIVE checkpoint does (see
  ///   `MaintenanceReason`), which is why the deferral keeps retrying a TRUNCATE: the 16 MiB bound
  ///   has to be enforced eventually, not quietly retired.
  /// `exclusionRemainsWarranted` is round 20's half of the same axis, and it is a SECOND reading of
  /// the question `reason` already answered once. The caller decides the reason on the main actor
  /// immediately before this call, but the lock is taken much later — after the seam below, after the
  /// detached hop, and (on the undowngraded path) after a `VACUUM` conversion that rewrites the whole
  /// file. An `Open Folder` landing anywhere in that prologue would leave a `.workspaceClose` pass
  /// excluding the readers of a workspace that opened after it decided. So a pass that MAY exclude
  /// readers asks again immediately before the barrier; a `false` there downgrades it in place, with
  /// the same semantics a call-time downgrade has — obligation kept, exclusion dropped, conversion
  /// not retired. `nil` (the default) means "no revalidation available", which is what the hot path
  /// and the tests that drive this method directly pass.
  func performMaintenanceInBackground(
    reason: MaintenanceReason,
    exclusionRemainsWarranted: (@Sendable () -> Bool)? = nil
  ) async {
    guard !isRefusedAfterTermination("performMaintenanceInBackground") else { return }
    guard let pool = databasePool, let databaseURL else { return }
    if !reason.mayExcludeReaders,
      Self.walFileSize(for: databaseURL) < effectiveWalCheckpointThresholdBytes
    {
      // Under the bound nothing is owed, so a ladder built up by earlier deferrals starts over.
      indexBatchTruncationRetryAttempt = 0
      return
    }

    // The one-off `VACUUM` conversion stays on the undowngraded close and nowhere else: it is the
    // single most expensive thing this method can do, it is unbounded in the sense that matters
    // (a full rewrite of the logical database), and `didAttemptAutoVacuumConversion` is NOT set on
    // the downgraded path — so a close that gave way to a reopen defers the conversion to the next
    // real close rather than retiring it.
    let attemptConversion = reason == .workspaceClose && !didAttemptAutoVacuumConversion
    if attemptConversion { didAttemptAutoVacuumConversion = true }
    let conversionByteLimit = effectiveAutoVacuumConversionByteLimit
    if let gate = maintenanceGateOverride { await gate(reason) }

    if !reason.mayExcludeReaders {
      let pageBudget = Self.incrementalVacuumPageBudget
      let outcome = await Task.detached(priority: .utility) {
        Self.compactAndTruncateWithoutExcludingReaders(pool: pool, pageBudget: pageBudget)
      }.value
      switch outcome {
      case .truncated, .failed:
        indexBatchTruncationRetryAttempt = 0
      case .readerHeldTheWal:
        deferIndexBatchTruncation()
      }
      return
    }

    let pageBudget = Self.incrementalVacuumPageBudget
    let result = await Task.detached(priority: .utility) { () -> ClosePassResult in
      // Revalidation, first reading: BEFORE the conversion, so a pass that has already lost its
      // quiet index never pays for the whole-file rewrite the downgraded reason is defined to skip.
      if let exclusionRemainsWarranted, !exclusionRemainsWarranted() {
        return ClosePassResult(
          outcome: .downgraded(
            Self.compactAndTruncateWithoutExcludingReaders(pool: pool, pageBudget: pageBudget),
            didAttemptConversion: false),
          conversionDeferredByOpen: false)
      }
      // Round 21, finding 2: the reading above is NOT the last word on the conversion. Between it
      // and the first byte of the rewrite sit a `pool.read` for the pragma, two file stats, and —
      // the unbounded part — the wait for the pool's SERIALIZED WRITER, which a save or a reindex
      // already in flight can hold for as long as it likes. So the conversion carries the predicate
      // INTO its write and reads it once more with the writer already in hand.
      var conversion = AutoVacuumConversionOutcome.notOwed
      if attemptConversion {
        conversion = Self.convertToIncrementalAutoVacuumIfNeeded(
          pool: pool, databaseURL: databaseURL, byteLimit: conversionByteLimit,
          exclusionRemainsWarranted: exclusionRemainsWarranted)
      }
      let conversionDeferredByOpen = conversion == .deferredByOpen
      // Revalidation, second reading: immediately before the lock, which is what shrinks the
      // residual to the barrier's own duration. The conversion above can take seconds, and an open
      // arriving during it would otherwise still meet a reader-excluding barrier.
      if let exclusionRemainsWarranted, !exclusionRemainsWarranted() {
        return ClosePassResult(
          outcome: .downgraded(
            Self.compactAndTruncateWithoutExcludingReaders(pool: pool, pageBudget: pageBudget),
            didAttemptConversion: attemptConversion && !conversionDeferredByOpen),
          conversionDeferredByOpen: conversionDeferredByOpen)
      }
      do {
        try pool.barrierWriteWithoutTransaction { db in
          try Self.reclaimFreePages(in: db, pageBudget: nil)
          try db.checkpoint(.truncate)
        }
      } catch {
        NSLog("Pensieve index maintenance failed: %@", error.localizedDescription)
      }
      return ClosePassResult(
        outcome: .excludedReaders, conversionDeferredByOpen: conversionDeferredByOpen)
    }.value

    if result.conversionDeferredByOpen {
      autoVacuumConversionsDeferredByOpen += 1
      // Deferred, never retired — the same contract both revalidation downgrades keep. The flag was
      // set optimistically on the main actor before the hand-off, and this is where a conversion
      // that gave way at the writer hands it back to the next real close.
      didAttemptAutoVacuumConversion = false
    }

    switch result.outcome {
    case .excludedReaders:
      break
    case .downgraded(let hotPathOutcome, let didAttemptConversion):
      barrierTimeMaintenanceDowngrades += 1
      // A conversion the pass never ran must not be retired by it — same contract as the call-time
      // downgrade, which simply never sets the flag.
      if attemptConversion, !didAttemptConversion { didAttemptAutoVacuumConversion = false }
      switch hotPathOutcome {
      case .truncated, .failed:
        indexBatchTruncationRetryAttempt = 0
      case .readerHeldTheWal:
        // The obligation survives the downgrade: the bound is deferred onto the backoff ladder,
        // exactly as it is when the downgrade was decided at call time.
        deferIndexBatchTruncation()
      }
    }
  }

  /// What a `.workspaceClose` pass actually did once it reached its lock — the two outcomes barrier-
  /// time revalidation created. `downgraded` carries the hot-path result so the caller can re-arm the
  /// truncation ladder on the main actor, and whether the one-off `VACUUM` conversion was paid for,
  /// so a pass that gave way before it does not retire it.
  private enum ClosePassOutcome {
    case excludedReaders
    case downgraded(IndexBatchMaintenanceOutcome, didAttemptConversion: Bool)
  }

  /// The close pass's result, carried out of the detached closure. `conversionDeferredByOpen` rides
  /// alongside the outcome rather than inside it because the two answer different questions — what
  /// the pass did at its lock, and whether the one-shot conversion is still owed — and round 21 made
  /// the second reachable on its own.
  private struct ClosePassResult {
    var outcome: ClosePassOutcome
    var conversionDeferredByOpen: Bool
  }

  /// What the one-shot `auto_vacuum` conversion did. `notOwed` folds together "already incremental",
  /// "over the byte ceiling" and "the attempt failed": all three are answers this process is not
  /// going to improve on, so all three retire the obligation. `deferredByOpen` is the one that keeps
  /// it — see `autoVacuumConversionsDeferredByOpen`.
  private enum AutoVacuumConversionOutcome: Equatable {
    case converted
    case notOwed
    case deferredByOpen
  }

  /// What one hot-path hygiene pass achieved. `readerHeldTheWal` is the state that has to be told
  /// apart from the other two: it is not a failure and not a success, it is "come back later".
  private enum IndexBatchMaintenanceOutcome {
    case truncated
    case readerHeldTheWal
    case failed
  }

  /// The hot-path pass: compaction plus a truncating checkpoint taken from a PLAIN pool write, so it
  /// can neither be blocked by a reader nor block one. Never waits: a reader holding WAL frames comes
  /// back as `readerHeldTheWal` for the caller to re-arm.
  private nonisolated static func compactAndTruncateWithoutExcludingReaders(
    pool: DatabasePool, pageBudget: Int
  ) -> IndexBatchMaintenanceOutcome {
    do {
      return try pool.writeWithoutTransaction { db in
        try reclaimFreePages(in: db, pageBudget: pageBudget)
        return try truncateWalWithoutWaitingForReaders(db) ? .truncated : .readerHeldTheWal
      }
    } catch {
      NSLog("Pensieve index maintenance failed: %@", error.localizedDescription)
      return .failed
    }
  }

  /// Takes the truncating checkpoint with the connection's busy handler OFF, so SQLite ANSWERS
  /// instead of waiting. `false` means a reader still holds WAL frames (`SQLITE_BUSY`, the extended
  /// codes included since `resultCode` is the primary one); every other error is thrown on.
  ///
  /// The writer carries no busy handler as this project configures GRDB (`Configuration.busyMode`
  /// defaults to `.immediateError`, and `DatabasePool` gives the 10 s timeout to READERS only), so
  /// zeroing it is belt and braces — and it is what keeps fail-fast a property of THIS code instead
  /// of a GRDB default that a later configuration change could flip into a blocking wait. Restored
  /// afterwards because the connection goes back into the pool for ordinary writes.
  private nonisolated static func truncateWalWithoutWaitingForReaders(_ db: Database) throws -> Bool
  {
    let previousBusyTimeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
    try db.execute(sql: "PRAGMA busy_timeout = 0")
    defer { try? db.execute(sql: "PRAGMA busy_timeout = \(previousBusyTimeout)") }
    do {
      try db.checkpoint(.truncate)
      return true
    } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
      return false
    }
  }

  /// Re-arms a hot-path truncate a reader would not let through.
  ///
  /// What this enforces is a SIZE bound, so giving up would retire it silently: once the reindex
  /// storm ends, nothing else is coming to bring the WAL back under 16 MiB before the workspace
  /// closes — and the reader that refused the checkpoint can be a single long backlink query. So the
  /// pass re-arms itself on a backoff ladder and comes back through
  /// `scheduleIndexBatchMaintenance()`, which re-checks the latch, the coalescing and the threshold.
  /// It therefore stops on its own the moment the truncate lands or the WAL is back under the bound,
  /// and while it does not, each attempt costs a file stat plus a ~0.2 ms refused checkpoint.
  ///
  /// Deliberately NOT registered in `scheduledIndexWrites`: the drain must never have to wait out a
  /// sleep. The quit does not need it either — `startCheckpointOnTerminate()` truncates the WAL
  /// itself under the drain budget — and `closeForTermination()` cancels this so a latched process is
  /// not left holding a timer that would only be refused when it fires.
  private func deferIndexBatchTruncation() {
    indexBatchTruncationDeferrals += 1
    guard !isClosedForTermination, !isIndexBatchTruncationRetryQuiesced,
      pendingIndexBatchTruncationRetry == nil
    else { return }
    let delay = effectiveIndexBatchTruncationRetryDelayNanoseconds
    indexBatchTruncationRetryAttempt += 1
    pendingIndexBatchTruncationRetry = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      guard let self, !Task.isCancelled else { return }
      // Clearing BEFORE re-entering is load-bearing since round 14: `scheduleIndexBatchMaintenance()`
      // now absorbs a request while this handle is installed, so re-entering first would make the
      // ladder absorb its own retry and hygiene would never run again. Ordering, not luck — pinned.
      self.pendingIndexBatchTruncationRetry = nil
      self.scheduleIndexBatchMaintenance()
    }
  }

  /// STARTS the truncating checkpoint for the quit path — the LAST step of `TerminationSequence`,
  /// which is the only thing allowed to call it. Ordering the window flushes and the index drain
  /// BEFORE it is the sequence's job, not this method's. No-op when the index was never opened.
  ///
  /// The checkpoint runs on a detached task and this method returns its handle instead of running the
  /// barrier on the caller's thread. That is the whole point, and it is not an optimisation:
  /// `barrierWriteWithoutTransaction` is the only GRDB entry point that excludes the pool's READER
  /// connections too (which is exactly why the truncate needs it — see
  /// `performMaintenanceInBackground`), so it waits for a slow background search or backlink query
  /// just as it waits for a stuck writer. Taken synchronously from the quit's main-actor task, that
  /// wait can never yield: the run-loop pump in `TerminationSequence.runBlockingMainRunLoop()` only
  /// regains control when that task SUSPENDS, so a synchronous barrier parks the pump, the drain
  /// deadline stops being checked, and the quit hangs for as long as the reader holds the pool. A
  /// returned task turns the wait into an `await` — a suspension point — so the pump keeps running
  /// and the same deadline that bounds the drain also bounds the checkpoint.
  ///
  /// The caller therefore chooses how long to wait, and both callers are in `TerminationSequence`:
  /// the happy path awaits the handle under the drain budget, while the post-deadline fallback starts
  /// it and deliberately does NOT await. Unawaited it is still worth starting: it truncates the WAL if
  /// the pool frees up while the process is alive, and the process exit reaps the thread if it never
  /// does. A WAL left at its high-water mark is reclaimed by the next launch's workspace-close
  /// maintenance; a quit that never returns is not recoverable at all.
  @discardableResult
  func startCheckpointOnTerminate() -> Task<Void, Never>? {
    guard let pool = databasePool else { return nil }
    return Task.detached(priority: .utility) {
      do {
        try pool.barrierWriteWithoutTransaction { db in
          _ = try db.checkpoint(.truncate)
        }
      } catch {
        NSLog("Pensieve index checkpoint on terminate failed: %@", error.localizedDescription)
      }
    }
  }

  /// Hands freed pages back to the filesystem. Only meaningful in `auto_vacuum = INCREMENTAL` (mode
  /// 2); in mode 0 SQLite keeps free pages inside the file for reuse and `incremental_vacuum` is a
  /// no-op, so the mode is checked rather than assumed.
  private nonisolated static func reclaimFreePages(in db: Database, pageBudget: Int?) throws {
    guard try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") == 2 else { return }
    let freePages = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
    guard freePages >= freelistCompactionThresholdPages else { return }
    let pages = pageBudget.map { min($0, freePages) } ?? freePages
    try db.execute(sql: "PRAGMA incremental_vacuum(\(pages))")
  }

  /// Migration path for databases created before the `auto_vacuum` pragma existed here. SQLite only
  /// switches modes through a full `VACUUM`, and the pragma has to be in force on the connection
  /// running it — `makeConfiguration`'s `prepareDatabase` guarantees that for every writer, so the
  /// conversion is literally "VACUUM once". Best-effort by design: a failure (no disk space, busy
  /// database) leaves the database perfectly usable, just uncompacted.
  ///
  /// `exclusionRemainsWarranted` is round 21's half, and it is read at the LAST instruction before
  /// the rewrite — inside the write, with the pool's writer already held. Everything this method
  /// does before that point can wait an unbounded time on somebody else's write, and a workspace
  /// opened during that wait would have its own first index writes queued behind a whole-file
  /// rewrite (measured at roughly 1.3 s for a database at the 256 MiB ceiling on an SSD). Reading
  /// the predicate here means the conversion is abandoned for anything that arrives before the
  /// writer is taken, and `deferredByOpen` hands the obligation to the next real close rather than
  /// retiring it. `nil` means "no revalidation available" — the hot path and the tests that drive
  /// this directly — and is treated as still warranted.
  ///
  /// Named residual, and it is irreducible: `VACUUM` is atomic and not abortable, so an open that
  /// arrives after the rewrite has BEGUN still waits it out. That window is now exactly the
  /// rewrite's own duration, bounded by `autoVacuumConversionByteLimit`, and it is paid at most once
  /// per database.
  private nonisolated static func convertToIncrementalAutoVacuumIfNeeded(
    pool: DatabasePool, databaseURL: URL, byteLimit: Int64,
    exclusionRemainsWarranted: (@Sendable () -> Bool)?
  ) -> AutoVacuumConversionOutcome {
    do {
      let mode = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0 }
      guard mode != 2 else { return .notOwed }
      // The bound has to be the LOGICAL database, not the main file. `VACUUM` rewrites everything
      // SQLite considers committed, and in WAL mode a large slice of that can still be sitting in
      // `index.db-wal` — a reader holding a snapshot is enough to keep checkpoints from moving it
      // back. Measuring `index.db` alone let a small main file next to a multi-gigabyte WAL sail
      // past a limit that exists precisely to bound the rewrite cost and the ~2× peak disk usage.
      let logicalSize = fileSize(at: databaseURL) + walFileSize(for: databaseURL)
      guard logicalSize <= byteLimit else {
        NSLog("Pensieve index too large for auto_vacuum conversion; keeping WAL checkpoints only")
        return .notOwed
      }
      // `writeWithoutTransaction` rather than `pool.vacuum()` — the same call GRDB's own `vacuum()`
      // makes — so the last reading of the predicate happens with the writer in hand instead of
      // before the queue for it.
      return try pool.writeWithoutTransaction { db -> AutoVacuumConversionOutcome in
        if let exclusionRemainsWarranted, !exclusionRemainsWarranted() { return .deferredByOpen }
        try db.execute(sql: "VACUUM")
        return .converted
      }
    } catch {
      NSLog("Pensieve index auto_vacuum conversion failed: %@", error.localizedDescription)
      return .notOwed
    }
  }

  private nonisolated static func walFileSize(for databaseURL: URL) -> Int64 {
    fileSize(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
  }

  private nonisolated static func fileSize(at url: URL) -> Int64 {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? Int64
    else { return 0 }
    return size
  }

  /// Cheap content guard for the cold-open skip decision: how many indexed
  /// documents already live under any of `rootPaths`. The cold-open path must
  /// NEVER skip the reindex when the index is empty/missing for this workspace
  /// (e.g. after the operator nuked Application Support) — a non-zero count here
  /// is the proof that skipping is safe. Counts `documents` rows (the single
  /// source of truth post-external-content migration) whose RECONSTRUCTED full
  /// path (`canonical_path || '/' || path`) is a descendant of a root
  /// (`<root>/…`). Returns 0 when the index cannot be opened (treated as empty →
  /// caller full-reindexes).
  func indexedDocumentCount(forRootPaths rootPaths: [String], appState: AppState? = nil) -> Int {
    guard !rootPaths.isEmpty, let pool = ensureOpen(into: appState) else { return 0 }
    do {
      return try Self.indexedDocumentCount(forRootPaths: rootPaths, pool: pool)
    } catch {
      report(error, appState: appState, action: "count Pensieve search index rows")
      return 0
    }
  }

  /// Off-main twin of `indexedDocumentCount`. The cold-open skip-gate consults this on the background
  /// workspace-build task; routing it through `ensureOpenInBackground` + a detached `pool.read` keeps
  /// the "Scanning…" decision from blocking the run loop.
  func indexedDocumentCountInBackground(forRootPaths rootPaths: [String], appState: AppState? = nil)
    async -> Int
  {
    guard !rootPaths.isEmpty, let pool = await ensureOpenInBackground(into: appState) else {
      return 0
    }
    do {
      return try await Task.detached(priority: .userInitiated) {
        try Self.indexedDocumentCount(forRootPaths: rootPaths, pool: pool)
      }.value
    } catch {
      report(error, appState: appState, action: "count Pensieve search index rows")
      return 0
    }
  }

  private nonisolated static func indexedDocumentCount(
    forRootPaths rootPaths: [String], pool: DatabasePool
  ) throws -> Int {
    try pool.read { db in
      var total = 0
      for rootPath in rootPaths {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let count =
          try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*) FROM documents d
              JOIN workspaces w ON w.workspace_id = d.workspace_id
              WHERE (w.canonical_path || '/' || d.path) LIKE ? ESCAPE '\\'
              """,
            arguments: [Self.likePrefixPattern(prefix) + "%"]
          ) ?? 0
        total += count
      }
      return total
    }
  }

  /// Escapes LIKE wildcards (`%`, `_`) and the escape char itself in a literal path prefix so a
  /// path containing them cannot widen the match. Pairs with `ESCAPE '\\'` in the query.
  private nonisolated static func likePrefixPattern(_ prefix: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(prefix.count)
    for character in prefix {
      if character == "\\" || character == "%" || character == "_" {
        escaped.append("\\")
      }
      escaped.append(character)
    }
    return escaped
  }

  /// Single-doc index entry (ad-hoc open files, explicit one-shot, tests). Writes the doc as
  /// a `documents` row — the single FTS source — so the AI/AU triggers sync
  /// `document_fts`. An ad-hoc / rootless doc lands under the reserved
  /// `__adhoc__` workspace (full standardized path as its `documents.path`); a
  /// workspace doc lands under its own workspace row (relative path). The body is
  /// provided by the caller (the live editor text) rather than re-read from disk.
  ///
  /// SYNC: runs `ensureOpen` + `pool.write` + `refreshSearchResults` (a `pool.read`) on the calling
  /// actor. The production autosave/save tail does NOT use this — it routes through the off-main
  /// `indexInBackground` twin so a save never stalls the run loop on SQLite. Kept for the explicit
  /// one-shot/test callers that want a synchronous, immediately-queryable write (the same
  /// sync/background duality as `reindex` / `reindexInBackground` and `updateSearchIndex` /
  /// `updateSearchIndexInBackground`).
  func index(document: DocumentRef, body: String, appState: AppState? = nil) {
    guard let pool = ensureOpen(into: appState) else { return }
    let record = Self.documentWriteRecord(from: document, body: body)

    do {
      try pool.write { db in
        try Self.ensureWorkspaceRow(for: record, in: db)
        try Self.upsertDocument(record, in: db)
      }
      refreshSearchResults(in: appState)
    } catch {
      report(error, appState: appState, action: "update Pensieve search index")
    }
  }

  /// Off-main twin of `index(document:body:)` — the single-doc index entry the production autosave /
  /// save tail uses. The sync `index` ran `ensureOpen` + `pool.write` (ensure-workspace + upsert) AND
  /// `refreshSearchResults` (a `pool.read`) ON THE MAIN ACTOR on every persisted edit — a synchronous
  /// SQLite stall on the run loop per save. This routes the write through the shared supersede chain
  /// (`pendingIndexUpdateTask`) on a detached `.utility` task and hops back to the main actor only to
  /// publish the refreshed search results, so a save never blocks typing/scrolling. Mirrors
  /// `updateSearchIndexInBackground`'s detached/chained/`refreshSearchResultsInBackground` shape, so
  /// concurrent index writes serialize in submission order and a failed write can never leave the FTS
  /// index half-applied (single transaction).
  ///
  /// Returns `true` when the off-main write committed, `false` when it threw (still reported) and
  /// `false` when the termination latch abandoned it mid-transaction (logged, deliberately NOT
  /// reported — see `abandonIfClosedForTermination(_:)`). Tests sync on completion via
  /// `waitForPendingReindex()` instead of sleeping.
  @discardableResult
  func indexInBackground(
    document: DocumentRef, body: String, appState: AppState? = nil
  ) async -> Bool {
    guard !isRefusedAfterTermination("indexInBackground") else { return false }
    let record = Self.documentWriteRecord(from: document, body: body)
    // Chain position RESERVED before this call's first suspension point — see
    // `reserveSupersedePosition(_:)`. This entry point is the one the ordering defect bites
    // hardest: two saves of the SAME document parked on the initial open would resume unordered,
    // and the loser is the user's NEWER text.
    let previous = pendingIndexUpdateTask

    let write = Task { @MainActor [weak self] () -> Bool in
      await self?.awaitBackgroundWriteGate()
      await previous?.value
      guard let self, let pool = await self.ensureOpenInBackground(into: appState) else {
        return false
      }
      // The no-loop member of the class rounds 16 and 17 closed for the batch paths. "No loop" only
      // rules out MID-transaction consultations; the one at transaction ENTRY is owed here just as
      // much, because this call can be ACCEPTED before the latch closes and still COMMIT after it.
      // Its entry guard and `ensureOpenInBackground` cover every suspension up to the open; what they
      // cannot cover is the detached hop below and the wait for the pool's serialized writer, and a
      // save queued behind a long reindex spends the whole quit exactly there.
      let latch = self.terminationLatch
      if let transactionGate = self.singleDocumentIndexWriteGateOverride { await transactionGate() }
      do {
        try await Task.detached(priority: .utility) {
          try pool.write { db in
            try Self.abandonIfClosedForTermination(latch)
            try Self.ensureWorkspaceRow(for: record, in: db)
            try Self.upsertDocument(record, in: db)
          }
        }.value
        await self.refreshSearchResultsInBackground(in: appState)
        // The ordinary save/autosave tail is an index write like any other: a single large document
        // (or a long editing session's worth of small ones) grows the WAL just as a watcher delta
        // does, and without this hook nothing here would ever bound it — the declared 16 MiB
        // ceiling would only be enforced on reindex/delta paths a plain "edit and save" never
        // takes. The WAL-size throttle keeps a small save free: it stats one file and returns.
        // Armed rather than awaited — see `scheduleIndexBatchMaintenance()`.
        self.scheduleIndexBatchMaintenance()
        return true
      } catch is IndexWriteAbandonedAfterTermination {
        // R17 routing: an abandonment is a decision the quit made, not an error the user can act on,
        // so it is LOGGED rather than surfaced as "could not update Pensieve search index" on an app
        // nobody can answer any more. `false` is still the right answer to the caller — it is what
        // keeps the save tail from persisting an on-disk signature for an index write that rolled
        // back.
        Self.logAbandonedWriteAfterTermination("indexInBackground")
        return false
      } catch {
        self.report(error, appState: appState, action: "update Pensieve search index")
        return false
      }
    }
    // Supersede chain stays `Void`-typed (see `reindexInBackground`).
    reserveSupersedePosition(write)
    return await write.value
  }

  func searchInBackground(
    query: String,
    documents: [DocumentRef],
    limit: Int = 50,
    appState: AppState? = nil
  ) async -> [WorkspaceSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }
    guard let pool = await ensureOpenInBackground(into: appState) else { return [] }

    do {
      return try await Task.detached(priority: .userInitiated) {
        try Self.performSearch(
          query: trimmedQuery,
          documents: documents,
          limit: limit,
          pool: pool
        )
      }.value
    } catch {
      report(error, appState: appState, action: "search Pensieve index")
      return []
    }
  }

  func backlinksInBackground(
    to target: DocumentRef,
    documents: [DocumentRef],
    limit: Int = 50,
    appState: AppState? = nil
  ) async -> [WorkspaceBacklinkResult] {
    guard let pool = await ensureOpenInBackground(into: appState) else { return [] }
    let didOpenRead = didOpenBacklinkRead

    do {
      return try await Task.detached(priority: .userInitiated) {
        try Self.performBacklinkSearch(
          to: target,
          documents: documents,
          limit: limit,
          pool: pool,
          didOpenRead: didOpenRead
        )
      }.value
    } catch {
      report(error, appState: appState, action: "read Pensieve backlinks")
      return []
    }
  }

  func refreshSearchResults(in appState: AppState?) {
    guard let appState else { return }
    appState.workspaceSearchResults = search(
      query: appState.workspaceSearchQuery,
      documents: appState.allDocuments,
      appState: appState
    )
  }

  /// Off-main twin of `refreshSearchResults`. The background index writers used to call the sync
  /// `refreshSearchResults` on return — which runs `search` (a `pool.read`) ON THE MAIN ACTOR after
  /// every reindex/delta. This reads the query/documents on the main actor, runs the actual FTS read
  /// off-main via `searchInBackground`, then publishes the results back on the main actor.
  func refreshSearchResultsInBackground(in appState: AppState?) async {
    guard let appState else { return }
    let query = appState.workspaceSearchQuery
    let documents = appState.allDocuments
    let results = await searchInBackground(query: query, documents: documents, appState: appState)
    appState.workspaceSearchResults = results
  }

  func search(
    query: String,
    documents: [DocumentRef],
    limit: Int = 50,
    appState: AppState? = nil
  ) -> [WorkspaceSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }
    guard let pool = ensureOpen(into: appState) else { return [] }

    do {
      return try Self.performSearch(
        query: trimmedQuery,
        documents: documents,
        limit: limit,
        pool: pool
      )
    } catch {
      report(error, appState: appState, action: "search Pensieve index")
      return []
    }
  }

  func backlinks(
    to target: DocumentRef,
    documents: [DocumentRef],
    limit: Int = 50,
    appState: AppState? = nil
  ) -> [WorkspaceBacklinkResult] {
    guard let pool = ensureOpen(into: appState) else { return [] }

    do {
      return try Self.performBacklinkSearch(
        to: target,
        documents: documents,
        limit: limit,
        pool: pool
      )
    } catch {
      report(error, appState: appState, action: "read Pensieve backlinks")
      return []
    }
  }

  func upsertWorkspace(
    identity: WorkspaceIdentity,
    roots: [URL],
    lastSeenAt: Date = Date(),
    documents: [DocumentRef],
    appState: AppState? = nil
  ) async {
    guard !isRefusedAfterTermination("upsertWorkspace") else { return }
    // Same seam, same position, same reason as in the reindex/delta twins: the workspace-metadata
    // write is an index write like any other, and a test proving it is genuinely still owed at close
    // time needs to hold it here, before it touches the pool.
    await awaitBackgroundWriteGate()
    guard let pool = await ensureOpenInBackground(into: appState) else { return }
    let didInsertBatch = didInsertSearchIndexBatch
    let batchSize = searchIndexBatchSize
    // The third write path that builds document/FTS rows in a loop, and the entry guard above is
    // exactly as insufficient here as it was for the reindex/delta twins: once this call has passed
    // it, the write is a detached task holding the pool's writer, and nothing on the quit's
    // budget-expiry path reaches it. See `abandonIfClosedForTermination(_:)`.
    let latch = terminationLatch

    do {
      // Build per-document write records keyed on each doc's OWN root identity
      // (workspace docs → `WorkspaceIdentity.make(rootURL:)`, ad-hoc → `__adhoc__`),
      // exactly as the cold reindex (`replaceSearchIndex`) and every reader (search,
      // `indexedDocumentCount`) key the `documents` table. Keying the document rows
      // under the MERGED multi-root `identity.workspaceID` instead would write a
      // SECOND copy of every doc that the reindex can NOT collapse (its records carry
      // the per-root workspace_id, so the `(workspace_id, path)` skip never matches) —
      // an N-root cold open double-indexed (20 rows for 10 docs) and leaked duplicate
      // search hits. For single-root the per-root id IS `identity.workspaceID`
      // byte-for-byte, so this is a no-op there. The merged identity still anchors the
      // workspaces REGISTRY row below (manifest / scan_session / stats key on it).
      let records = await Task.detached(priority: .utility) {
        documents.compactMap(Self.documentWriteRecord)
      }.value
      guard
        databaseURL.map({ FileManager.default.fileExists(atPath: $0.path) }) ?? true
      else {
        return
      }
      try await Task.detached(priority: .utility) {
        try pool.write { db in
          try Self.abandonIfClosedForTermination(latch)
          // The REGISTRY row for the whole N-root workspace (manifest / scan_session /
          // stats anchor). Document rows below live under their per-root workspace_ids.
          try Self.upsertWorkspace(identity: identity, roots: roots, lastSeenAt: lastSeenAt, in: db)

          // Group the documents by their per-root workspace_id, then run the SAME
          // per-workspace writer the single-root path always used (`indexed_at =
          // lastSeenAt`, unchanged-row skip, batched `didInsertBatch` observability) —
          // once per group instead of once under the merged identity. Single-root has
          // exactly one group whose id IS `identity.workspaceID`, so its write is
          // byte-identical; multi-root fans out to one group per root.
          let recordsByWorkspace = Dictionary(grouping: records, by: \.workspaceID)
          for (workspaceID, group) in recordsByWorkspace {
            try Self.abandonIfClosedForTermination(latch)
            // FK target: the per-root workspaces row, mapped to its real canonical_path
            // so the search full-path reconstruction (canonical_path || '/' || path)
            // stays correct for every root.
            try Self.ensureWorkspaceRow(
              workspaceID: workspaceID, canonicalPath: group[0].canonicalPath, in: db)
            try Self.upsertDocuments(
              records: group.map {
                IndexDocumentRecord(
                  path: $0.path, title: $0.title, body: $0.body,
                  mtime: $0.mtime, size: $0.size, isAdHoc: $0.isAdHoc)
              },
              workspaceID: workspaceID,
              indexedAt: lastSeenAt,
              batchSize: batchSize,
              didInsertBatch: didInsertBatch,
              latch: latch,
              in: db
            )
            try Self.tombstoneDocumentsNotIn(
              paths: group.map(\.path), workspaceID: workspaceID, in: db)
          }
          if recordsByWorkspace.isEmpty {
            // No documents this commit: preserve the legacy empty-wipe under the
            // workspace identity (single-root → its own rows; multi-root W_AB owns
            // no document rows, so this is a harmless no-op).
            try Self.tombstoneDocumentsNotIn(
              paths: [], workspaceID: identity.workspaceID, in: db)
          }
        }
      }.value
    } catch is IndexWriteAbandonedAfterTermination {
      Self.logAbandonedWriteAfterTermination("upsertWorkspace")
    } catch {
      report(error, appState: appState, action: "update Pensieve workspace index")
    }
  }

  private func applicationSupportDirectory() throws -> URL {
    if let overrideRoot = AppSupportLocation.overrideRoot() { return overrideRoot }
    return try FileManager.default
      .url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      .appendingPathComponent("Pensieve", isDirectory: true)
  }

  /// Sync sibling of `ensureOpenInBackground`, gated for the same reason — and it is what covers the
  /// synchronous legacy trio (`index(document:body:)`, `updateSearchIndex`, `reindex`) without those
  /// three needing a guard of their own: they cannot reach the pool except through here.
  private func ensureOpen(into appState: AppState?) -> DatabasePool? {
    guard !isRefusedAfterTermination("ensureOpen") else { return nil }
    if databasePool == nil {
      open(into: appState)
    }
    return databasePool
  }

  /// Full reindex, documents-as-source. Resolves every `DocumentRef` to a
  /// `documents` row (workspace docs under their own workspace_id + relative
  /// path; ad-hoc / rootless docs under the reserved `__adhoc__` workspace + full
  /// path), upserts each, then tombstones the documents in the TOUCHED workspaces
  /// that are no longer present. The AI/AU/AD triggers keep `document_fts` in
  /// sync — no body is ever written into the FTS. Runs in a single `pool.write`
  /// transaction (commits wholly or not at all).
  ///
  /// `didInsertBatch` fires per batch of ACTUALLY-WRITTEN upserts. A doc whose
  /// existing `documents` row already byte-matches (same title/body/mtime/size)
  /// is skipped and NOT counted — this preserves the cold-open skip semantics
  /// (a re-reindex of an unchanged, already-populated index writes ZERO records)
  /// and collapses the double-write when `commitWorkspaceManifest` already wrote
  /// the same rows. A doc whose body cannot be read from disk is skipped
  /// entirely (never write a partial record).
  ///
  /// Tombstoning is scoped to the workspaces this reindex touched, so an
  /// unrelated workspace's rows (and the `__adhoc__` rows when reindexing a
  /// workspace) are never collected. The cold/refresh callers only ever pass a
  /// single workspace's docs (plus ad-hoc open files), so this matches the prior
  /// "clear-and-rebuild the non-trigger-owned set" scope.
  private nonisolated static func replaceSearchIndex(
    with documents: [DocumentRef],
    pool: DatabasePool,
    batchSize: Int,
    didInsertBatch: (@Sendable (Int) -> Void)?,
    latch: TerminationLatch
  ) throws {
    let records = documents.compactMap { documentWriteRecord(from: $0) }

    try pool.write { db in
      try abandonIfClosedForTermination(latch)
      // Workspaces represented in this reindex (so tombstoning is scoped to them),
      // each mapped to its REAL canonical_path so the search full-path
      // reconstruction (canonical_path || '/' || path) is correct.
      var canonicalByWorkspace: [String: String] = [:]
      for record in records where canonicalByWorkspace[record.workspaceID] == nil {
        canonicalByWorkspace[record.workspaceID] = record.canonicalPath
      }
      let touchedWorkspaces = Set(canonicalByWorkspace.keys)
      for (workspaceID, canonicalPath) in canonicalByWorkspace {
        try ensureWorkspaceRow(workspaceID: workspaceID, canonicalPath: canonicalPath, in: db)
      }

      var batch: [DocumentWriteRecord] = []
      batch.reserveCapacity(batchSize)
      var keptPathsByWorkspace: [String: Set<String>] = [:]

      for record in records {
        keptPathsByWorkspace[record.workspaceID, default: []].insert(record.path)
        // Skip the write (and the count) when the stored row already matches —
        // the unchanged-relaunch / double-write-collapse case.
        if try existingDocumentMatches(record, in: db) {
          continue
        }
        batch.append(record)
        if batch.count == batchSize {
          try abandonIfClosedForTermination(latch)
          try upsertDocuments(batch, in: db)
          didInsertBatch?(batch.count)
          batch.removeAll(keepingCapacity: true)
        }
      }
      if !batch.isEmpty {
        try abandonIfClosedForTermination(latch)
        try upsertDocuments(batch, in: db)
        didInsertBatch?(batch.count)
      }

      // Tombstone removed docs ONLY within the workspaces this reindex covered.
      for workspaceID in touchedWorkspaces {
        try tombstoneDocumentsNotIn(
          paths: Array(keptPathsByWorkspace[workspaceID] ?? []),
          workspaceID: workspaceID,
          in: db)
      }
    }
  }

  /// Incremental apply, documents-as-source: upserts ONLY the supplied docs and
  /// deletes ONLY the `deletingPaths`, leaving every other `documents` row (and
  /// thus FTS row) intact. Single `pool.write` transaction — commits wholly or
  /// not at all. The triggers sync `document_fts`.
  ///
  /// `deletingPaths` are FULL standardized URL paths (the prior search join key).
  /// They are resolved back to `documents` rows by matching the reconstructed
  /// full path (`canonical_path || '/' || path`) for workspace docs OR the
  /// verbatim `path` for ad-hoc rows. Deleting the `documents` row fires the AD
  /// trigger, removing the FTS entry.
  ///
  /// `didInsertBatch` fires per upsert batch (same batching contract as
  /// `replaceSearchIndex`). A pure removal upserts nothing → 0 counted, matching
  /// the prior behaviour.
  private nonisolated static func applySearchIndexDelta(
    upserting documents: [DocumentRef],
    deletingPaths: [String],
    pool: DatabasePool,
    batchSize: Int,
    didInsertBatch: (@Sendable (Int) -> Void)?,
    latch: TerminationLatch
  ) throws {
    // Read bodies off the write transaction so a slow/failed disk read can't
    // hold the write lock open. A doc whose body cannot be read is skipped.
    let records = documents.compactMap { documentWriteRecord(from: $0) }

    try pool.write { db in
      try abandonIfClosedForTermination(latch)
      for fullPath in deletingPaths {
        try deleteDocumentByFullPath(fullPath, in: db)
      }

      var batch: [DocumentWriteRecord] = []
      batch.reserveCapacity(batchSize)
      for record in records {
        try ensureWorkspaceRow(for: record, in: db)
        // Skip (and don't count) a doc whose stored row already byte-matches —
        // e.g. the cold-open flow where `commitWorkspaceManifest` already wrote
        // the changed docs before this delta runs (the double-write collapse).
        // A genuine delta (watcher/refresh) almost always sees a real change, so
        // this only suppresses redundant re-writes.
        if try existingDocumentMatches(record, in: db) {
          continue
        }
        batch.append(record)
        if batch.count == batchSize {
          try abandonIfClosedForTermination(latch)
          try upsertDocuments(batch, in: db)
          didInsertBatch?(batch.count)
          batch.removeAll(keepingCapacity: true)
        }
      }
      if !batch.isEmpty {
        try abandonIfClosedForTermination(latch)
        try upsertDocuments(batch, in: db)
        didInsertBatch?(batch.count)
      }
    }
  }

  /// The in-transaction half of the termination latch: throws once the funnel has closed, so the
  /// enclosing `pool.write` ROLLS BACK instead of committing behind the terminal checkpoint.
  ///
  /// Entry gating alone cannot give this. `reindexInBackground` / `updateSearchIndexInBackground`
  /// re-check the latch only at entry (through `ensureOpenInBackground`); past that point the write
  /// is a detached task holding the pool's writer, and the quit's budget-expiry path
  /// (`sequence.cancel()` → `closeForTermination()` → best-effort `startCheckpointOnTerminate()`)
  /// reaches none of it. A 20 000-document cold reindex that entered before the latch therefore kept
  /// building through the quit and committed after the checkpoint — the WAL→0 the quit promises was
  /// simply untrue, and by exactly the frames the biggest WAL producer in the app writes.
  ///
  /// Rolling the WHOLE transaction back rather than committing what was built so far is the correct
  /// half of the trade, and it costs nothing that is owed to anyone:
  ///
  /// - a `documents`/FTS write is recomputable from disk — it is workspace churn, not user bytes,
  ///   and phases Q/F have already landed everything the user owns;
  /// - the abandoned write returns `false`, so its caller does NOT persist the on-disk `.md`
  ///   signature, and the next launch's cold-start skip-gate re-indexes rather than skipping over a
  ///   partial index (the same contract a FAILED write already relies on);
  /// - a torn-down process has no use for the rest of the reindex anyway.
  ///
  /// In a BATCH writer it is placed BEFORE each `upsertDocuments` rather than after, so the
  /// granularity of the abort is one batch of work not started, not one batch of work wasted. In a
  /// SINGLE-statement writer there is no such interior, so the consultation goes at transaction
  /// ENTRY — the first statement inside the `pool.write` closure. Round 20 closed that half of the
  /// class (`indexInBackground`, `appendScanSession`, `refreshWorkspaceStats`): "no loop" only ever
  /// ruled out mid-transaction consultations, never the entry one, and the window a single write
  /// needs is the same one the batch writers had — the detached hop plus the wait for the pool's
  /// serialized writer, which a save queued behind a long reindex spends the whole quit inside.
  ///
  /// `upsertWorkspace` is the third path consulting this, and it returns `Void` — so its
  /// abandonment cannot be propagated through a result, and it does not need to be. Its manifest and
  /// tree fingerprint are written by `commitWorkspaceManifest` BEFORE the index write is even handed
  /// off, so no return value could retract them; what must not happen is the rest of that hand-off
  /// recording the workspace as freshly scanned. Round 17 argued that `appendScanSession` and
  /// `refreshWorkspaceStats` (which would write a `cold_scan` row and an `index_health` of `green`
  /// over rows this transaction rolled back) were covered because they are their own entry points and
  /// the funnel refuses both. That is true only of a call that ARRIVES after the latch closed —
  /// round 20 measured the other case, where the call was accepted first and its detached
  /// `pool.write` was still queued when the funnel closed, and both now consult this latch at
  /// transaction entry like every other write. The `.md` search signature remains a separate
  /// mechanism, gated on the reindex/delta/index `Bool` that already covers it.
  private nonisolated static func abandonIfClosedForTermination(_ latch: TerminationLatch) throws {
    guard latch.isClosedForTermination else { return }
    throw IndexWriteAbandonedAfterTermination()
  }

  /// Deletes the `documents` row whose RECONSTRUCTED full path matches `fullPath`
  /// — a workspace doc (`canonical_path || '/' || path`) or an ad-hoc row (the
  /// `__adhoc__` workspace, where `path` IS the full standardized path). The AD
  /// trigger removes the matching `document_fts` entry.
  private nonisolated static func deleteDocumentByFullPath(_ fullPath: String, in db: Database)
    throws
  {
    try db.execute(
      sql: """
        DELETE FROM documents
        WHERE id IN (
            SELECT d.id FROM documents d
            JOIN workspaces w ON w.workspace_id = d.workspace_id
            WHERE (w.canonical_path || '/' || d.path) = ?
               OR (d.workspace_id = ? AND d.path = ?)
        )
        """,
      arguments: [fullPath, Self.adHocWorkspaceID, fullPath])
  }

  /// True when the stored `documents` row for `(workspace_id, path)` already
  /// byte-matches the candidate (title/body/mtime/size) — i.e. an upsert would be
  /// a no-op. Used by `replaceSearchIndex` to skip (and not count) unchanged docs.
  private nonisolated static func existingDocumentMatches(
    _ record: DocumentWriteRecord, in db: Database
  ) throws -> Bool {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT title, body, mtime, size FROM documents
        WHERE workspace_id = ? AND path = ? LIMIT 1
        """,
      arguments: [record.workspaceID, record.path])
    guard let row else { return false }
    return (row["title"] as String) == record.title
      && (row["body"] as String) == record.body
      && (row["mtime"] as Int) == record.mtime
      && (row["size"] as Int) == record.size
  }

  /// Resolves a `DocumentRef` (+ on-disk body) to a `DocumentWriteRecord`. Returns
  /// nil when the body cannot be read (never write a partial record). Use the
  /// `body:` overload when the caller already holds the live text (autosave).
  private nonisolated static func documentWriteRecord(from document: DocumentRef)
    -> DocumentWriteRecord?
  {
    let url = document.url.standardizedFileURL
    guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return documentWriteRecord(from: document, body: body)
  }

  private nonisolated static func documentWriteRecord(from document: DocumentRef, body: String)
    -> DocumentWriteRecord
  {
    let url = document.url.standardizedFileURL
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modifiedAt =
      values?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    let size = values?.fileSize ?? Data(body.utf8).count
    let title = title(fromMarkdown: body, fallback: document.title)

    // Workspace doc (scanned): under its own workspace_id + relative path.
    // Ad-hoc / rootless / explicitly ad-hoc: under the reserved __adhoc__
    // workspace with the FULL standardized path as `documents.path`.
    if !document.isAdHoc, let rootURL = document.rootURL {
      let identity = WorkspaceIdentity.make(rootURL: rootURL, bookmarkData: nil)
      let storedPath = document.relativePath ?? url.lastPathComponent
      return DocumentWriteRecord(
        workspaceID: identity.workspaceID,
        canonicalPath: identity.canonicalRootURL.path,
        path: storedPath,
        title: title,
        body: body,
        mtime: Int(modifiedAt),
        size: size,
        isAdHoc: false)
    }
    return DocumentWriteRecord(
      workspaceID: Self.adHocWorkspaceID,
      canonicalPath: "",
      path: url.path,
      title: title,
      body: body,
      mtime: Int(modifiedAt),
      size: size,
      isAdHoc: true)
  }

  /// Ensures the `workspaces` row exists for a write record (FK target). Ad-hoc
  /// records reference the reserved `__adhoc__` row (canonical_path ''); workspace
  /// records reference their own row, refreshing `canonical_path`/`last_seen_at`.
  private nonisolated static func ensureWorkspaceRow(
    for record: DocumentWriteRecord, in db: Database
  ) throws {
    if record.isAdHoc {
      try ensureWorkspaceRow(workspaceID: Self.adHocWorkspaceID, canonicalPath: "", in: db)
    } else {
      try ensureWorkspaceRow(
        workspaceID: record.workspaceID, canonicalPath: record.canonicalPath, in: db)
    }
  }

  /// Idempotently inserts a minimal `workspaces` row so `documents` writes satisfy
  /// the FK. `canonicalPath == nil` looks the path up from the record set (it is
  /// only nil in the reindex pre-pass where the per-record canonical path is
  /// applied by the subsequent upsert path-join); when a real path is supplied it
  /// is (re)written. The reserved `__adhoc__` row uses status 'adhoc'; real
  /// workspaces use 'active'. Never downgrades an existing row's canonical_path to
  /// a placeholder.
  private nonisolated static func ensureWorkspaceRow(
    workspaceID: String, canonicalPath: String?, in db: Database
  ) throws {
    let isAdHoc = workspaceID == Self.adHocWorkspaceID
    let status = isAdHoc ? "adhoc" : "active"
    let now = Int(Date().timeIntervalSince1970)
    if let canonicalPath {
      try db.execute(
        sql: """
          INSERT INTO workspaces
              (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
               first_seen_at, last_seen_at, status)
          VALUES (?, ?, NULL, NULL, ?, ?, ?)
          ON CONFLICT(workspace_id) DO UPDATE SET
              canonical_path = excluded.canonical_path,
              last_seen_at = excluded.last_seen_at
          """,
        arguments: [workspaceID, canonicalPath, now, now, status])
    } else {
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO workspaces
              (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
               first_seen_at, last_seen_at, status)
          VALUES (?, '', NULL, NULL, ?, ?, ?)
          """,
        arguments: [workspaceID, now, now, status])
    }
  }

  private nonisolated static func upsertDocuments(
    _ records: [DocumentWriteRecord], in db: Database
  ) throws {
    for record in records {
      try upsertDocument(record, in: db)
    }
  }

  private nonisolated static func upsertDocument(_ record: DocumentWriteRecord, in db: Database)
    throws
  {
    let now = Int(Date().timeIntervalSince1970)
    try db.execute(
      sql: """
        INSERT INTO documents
            (workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(workspace_id, path) DO UPDATE SET
            title = excluded.title,
            body = excluded.body,
            mtime = excluded.mtime,
            size = excluded.size,
            is_ad_hoc = excluded.is_ad_hoc,
            indexed_at = excluded.indexed_at
        """,
      arguments: [
        record.workspaceID,
        record.path,
        record.title,
        record.body,
        record.mtime,
        record.size,
        record.isAdHoc ? 1 : 0,
        now,
      ])
  }

  private nonisolated static func upsertWorkspace(
    identity: WorkspaceIdentity,
    roots: [URL],
    lastSeenAt: Date,
    in db: Database
  ) throws {
    let timestamp = Int(lastSeenAt.timeIntervalSince1970)
    try db.execute(
      sql: """
        INSERT INTO workspaces
            (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
             first_seen_at, last_seen_at, status)
        VALUES (?, ?, ?, ?, ?, ?, 'active')
        ON CONFLICT(workspace_id) DO UPDATE SET
            canonical_path = excluded.canonical_path,
            volume_resource_id = excluded.volume_resource_id,
            bookmark_hash = excluded.bookmark_hash,
            last_seen_at = excluded.last_seen_at,
            status = 'active'
        """,
      arguments: [
        identity.workspaceID,
        identity.canonicalRootURL.path,
        identity.volumeResourceID,
        identity.rootBookmarkHash,
        timestamp,
        timestamp,
      ]
    )
  }

  private nonisolated static func upsertDocuments(
    records: [IndexDocumentRecord],
    workspaceID: String,
    indexedAt: Date,
    batchSize: Int = 1,
    didInsertBatch: (@Sendable (Int) -> Void)? = nil,
    latch: TerminationLatch,
    in db: Database
  ) throws {
    let timestamp = Int(indexedAt.timeIntervalSince1970)
    var changedInBatch = 0
    for record in records {
      // INCREMENTAL: only (re)write a row whose indexed content (title/body/mtime/
      // size) is new or changed. An unchanged re-upsert is not just a no-op for the
      // content — its `ON CONFLICT DO UPDATE` still fires the `documents` AU trigger,
      // which deletes + reinserts the row's entry in the external-content
      // `document_fts`. Re-committing all N documents on a cold open therefore
      // re-tokenizes the WHOLE workspace even when a single file changed — the
      // "Indexing N" reindex storm. Skipping the matching rows means only the
      // genuinely added/modified file fires a trigger, so a file add/remove is cheap.
      // Removed paths are tombstoned by the caller's `tombstoneDocumentsNotIn`.
      let changed = try !workspaceDocumentMatches(record, workspaceID: workspaceID, in: db)
      guard changed else { continue }
      try db.execute(
        sql: """
          INSERT INTO documents
              (workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(workspace_id, path) DO UPDATE SET
              title = excluded.title,
              body = excluded.body,
              mtime = excluded.mtime,
              size = excluded.size,
              is_ad_hoc = excluded.is_ad_hoc,
              indexed_at = excluded.indexed_at
          """,
        arguments: [
          workspaceID,
          record.path,
          record.title,
          record.body,
          record.mtime,
          record.size,
          record.isAdHoc ? 1 : 0,
          timestamp,
        ]
      )
      changedInBatch += 1
      if changedInBatch == batchSize {
        didInsertBatch?(changedInBatch)
        changedInBatch = 0
        // The workspace-manifest twin of the reindex/delta batch consultation, and the same
        // granularity: a batch is never STARTED after the latch closed. Placed here rather than at
        // the head of the loop because this writer batches per WRITTEN row — an unchanged row is
        // skipped before it counts, so "start of a batch" is the boundary, not the iteration.
        try abandonIfClosedForTermination(latch)
      }
    }
    if changedInBatch > 0 {
      didInsertBatch?(changedInBatch)
    }
  }

  /// True when the stored `documents` row for `(workspaceID, record.path)` already
  /// byte-matches the candidate's indexed content (title/body/mtime/size).
  private nonisolated static func workspaceDocumentMatches(
    _ record: IndexDocumentRecord, workspaceID: String, in db: Database
  ) throws -> Bool {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT title, body, mtime, size FROM documents
        WHERE workspace_id = ? AND path = ? LIMIT 1
        """,
      arguments: [workspaceID, record.path])
    guard let row else { return false }
    return (row["title"] as String) == record.title
      && (row["body"] as String) == record.body
      && (row["mtime"] as Int) == record.mtime
      && (row["size"] as Int) == record.size
  }

  private nonisolated static func tombstoneDocumentsNotIn(
    paths: [String],
    workspaceID: String,
    in db: Database
  ) throws {
    guard !paths.isEmpty else {
      try db.execute(sql: "DELETE FROM documents WHERE workspace_id = ?", arguments: [workspaceID])
      return
    }

    let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ", ")
    var arguments: StatementArguments = [workspaceID]
    arguments += StatementArguments(paths)
    try db.execute(
      sql: """
        DELETE FROM documents
        WHERE workspace_id = ?
          AND path NOT IN (\(placeholders))
        """,
      arguments: arguments
    )
  }

  private nonisolated static func title(fromMarkdown body: String, fallback: String) -> String {
    for line in body.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("# ") else { continue }
      let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
      if !title.isEmpty {
        return title
      }
    }
    return fallback
  }

  private nonisolated static func performSearch(
    query: String,
    documents: [DocumentRef],
    limit: Int,
    pool: DatabasePool
  ) throws -> [WorkspaceSearchResult] {
    let documentsByPath = Dictionary(
      uniqueKeysWithValues: documents.map { ($0.url.standardizedFileURL.path, $0) }
    )
    guard !documentsByPath.isEmpty else { return [] }

    // SQL-level workspace scoping by ROOT canonical path (not by recomputed
    // workspace_id): the caller's docs belong to workspaces whose
    // `canonical_path` is one of their roots, plus the reserved `__adhoc__`
    // scope when any ad-hoc / rootless open file is present. Scoping on the
    // stored `canonical_path` (rather than re-deriving the workspace_id hash)
    // keeps the join correct regardless of how the workspace_id was minted. A
    // search in workspace A therefore never reads workspace B's rows out of
    // `documents`. The in-memory `documentsByPath` join remains as a safety net
    // (it also maps each hit back to its live `DocumentRef`).
    let scope = searchScope(for: documents)
    let rootScopes = scope.rootScopes
    let includeAdHoc = scope.includeAdHoc
    guard !rootScopes.isEmpty || includeAdHoc else { return [] }

    let records = try fetchRecords(
      matching: query, rootScopes: Array(rootScopes), includeAdHoc: includeAdHoc,
      limit: max(limit * 3, limit), pool: pool)
    let results = records.compactMap { record -> WorkspaceSearchResult? in
      guard let document = documentsByPath[record.path] else { return nil }
      return makeResult(record: record, document: document, query: query)
    }
    return Array(
      results
        .sorted { lhs, rhs in
          if lhs.score != rhs.score { return lhs.score < rhs.score }
          if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
          return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
        }
        .prefix(limit)
    )
  }

  private nonisolated static func performBacklinkSearch(
    to target: DocumentRef,
    documents: [DocumentRef],
    limit: Int,
    pool: DatabasePool,
    didOpenRead: (@Sendable () -> Void)? = nil
  ) throws -> [WorkspaceBacklinkResult] {
    let documentsByPath = Dictionary(
      uniqueKeysWithValues: documents.map { ($0.url.standardizedFileURL.path, $0) }
    )
    guard !documentsByPath.isEmpty else { return [] }

    let scope = searchScope(for: documents)
    guard !scope.rootScopes.isEmpty || scope.includeAdHoc else { return [] }

    let targetPath = target.url.standardizedFileURL.path
    let records = try fetchBacklinkRecords(
      rootScopes: Array(scope.rootScopes),
      includeAdHoc: scope.includeAdHoc,
      targetPath: targetPath,
      pool: pool,
      didOpenRead: didOpenRead
    )
    let targetRecord = records.first(where: { $0.path == targetPath })
    let targetSlugs = backlinkTargetSlugs(for: target, indexedRecord: targetRecord)

    let results = records.compactMap { record -> WorkspaceBacklinkResult? in
      guard record.path != targetPath, let sourceDocument = documentsByPath[record.path] else {
        return nil
      }
      let links = MarkdownWikilinks.extract(from: record.body)
      guard let matchedLink = links.first(where: { targetSlugs.contains($0.slug) }) else {
        return nil
      }
      return WorkspaceBacklinkResult(
        sourceDocument: sourceDocument,
        displayPath: record.displayPath,
        snippet: backlinkSnippet(in: record.body, matching: targetSlugs),
        matchedTarget: matchedLink.target,
        updatedAt: Date(timeIntervalSince1970: record.updatedAt)
      )
    }

    return Array(
      results
        .sorted { lhs, rhs in
          if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
          return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
        }
        .prefix(limit)
    )
  }

  /// Fetches matching rows from the EXTERNAL-CONTENT `document_fts` joined back to
  /// `documents` (+ `workspaces` for the full-path reconstruction), scoped in SQL
  /// to workspaces whose `canonical_path` is one of `rootScopes`, plus the
  /// reserved `__adhoc__` workspace when `includeAdHoc`. The reconstructed full
  /// path (`canonical_path || '/' || path` for workspace docs, or `path` verbatim
  /// for ad-hoc) is returned as `path` — the same search join key the prior
  /// contentful table exposed. Body/title come from `documents`; `display_path`
  /// is the relative path (workspace) or last path component (ad-hoc);
  /// `updated_at <- documents.mtime`, `is_ad_hoc <- documents.is_ad_hoc`. Ordered
  /// by bm25 relevance so the `LIMIT` keeps the most relevant hits (the caller
  /// re-scores/re-sorts).
  ///
  /// Falls back to a LIKE scan over `documents` (same scope) when the FTS MATCH
  /// query is empty or errors — mirrors the prior fallback path.
  private nonisolated static func fetchRecords(
    matching query: String,
    rootScopes: [String],
    includeAdHoc: Bool,
    limit: Int,
    pool: DatabasePool
  ) throws -> [SearchDocumentRecord] {
    // For workspace docs `display_path` is the workspace-relative `d.path` (==
    // DocumentRef.displayPath); for ad-hoc rows (canonical_path '') the relative
    // notion is the last path component (DocumentRef.displayPath for ad-hoc), so
    // strip the directory prefix from the full path stored in `d.path`.
    let selectClause = """
      SELECT
          CASE WHEN w.canonical_path = '' THEN d.path
               ELSE w.canonical_path || '/' || d.path END AS path,
          d.title AS title,
          CASE WHEN w.canonical_path = ''
               THEN replace(d.path, rtrim(d.path, replace(d.path, '/', '')), '')
               ELSE d.path END AS display_path,
          d.body AS body,
          d.is_ad_hoc AS is_ad_hoc,
          d.mtime AS updated_at
      """

    let scope = scopePredicate(rootScopes: rootScopes, includeAdHoc: includeAdHoc)
    let scopePredicate = scope.predicate
    let scopeArgs = scope.arguments

    let ftsQuery = makeFTSQuery(from: query)
    if !ftsQuery.isEmpty {
      var matchArgs: StatementArguments = [ftsQuery]
      matchArgs += scopeArgs
      matchArgs += [limit]
      if let records = try? pool.read({ db in
        try SearchDocumentRecord.fetchAll(
          db,
          sql: """
            \(selectClause)
            FROM document_fts
            JOIN documents d ON d.id = document_fts.rowid
            JOIN workspaces w ON w.workspace_id = d.workspace_id
            WHERE document_fts MATCH ?
              AND \(scopePredicate)
            ORDER BY bm25(document_fts)
            LIMIT ?
            """,
          arguments: matchArgs
        )
      }), !records.isEmpty {
        // FTS hit set wins (ranked by bm25). When MATCH yields ZERO rows — e.g. an
        // infix query like "liczek" against the token "pliczek", which FTS5's
        // token-prefix matching can't satisfy — fall through to the substring LIKE
        // scan below so partial-name search still finds the file.
        return records
      }
    }

    let pattern = "%\(query.lowercased())%"
    var likeArgs = scopeArgs
    likeArgs += [pattern, pattern, pattern, limit]
    return try pool.read { db in
      try SearchDocumentRecord.fetchAll(
        db,
        sql: """
          \(selectClause)
          FROM documents d
          JOIN workspaces w ON w.workspace_id = d.workspace_id
          WHERE \(scopePredicate)
            AND (lower(d.title) LIKE ?
              OR lower(d.path) LIKE ?
              OR lower(d.body) LIKE ?)
          LIMIT ?
          """,
        arguments: likeArgs
      )
    }
  }

  private nonisolated static func fetchBacklinkRecords(
    rootScopes: [String],
    includeAdHoc: Bool,
    targetPath: String,
    pool: DatabasePool,
    didOpenRead: (@Sendable () -> Void)? = nil
  ) throws -> [BacklinkDocumentRecord] {
    let selectClause = """
      SELECT
          CASE WHEN w.canonical_path = '' THEN d.path
               ELSE w.canonical_path || '/' || d.path END AS path,
          d.title AS title,
          CASE WHEN w.canonical_path = ''
               THEN replace(d.path, rtrim(d.path, replace(d.path, '/', '')), '')
               ELSE d.path END AS display_path,
          d.body AS body,
          d.is_ad_hoc AS is_ad_hoc,
          d.mtime AS updated_at
      """
    let scope = scopePredicate(rootScopes: rootScopes, includeAdHoc: includeAdHoc)
    var arguments = scope.arguments
    arguments += ["%[[%"]
    arguments += [targetPath]

    return try pool.read { db in
      // Fires with the reader connection already checked out of the pool, so a test blocking here
      // holds the pool the way a slow backlink query does — which is precisely what the terminal
      // checkpoint's barrier has to wait for.
      didOpenRead?()
      return try BacklinkDocumentRecord.fetchAll(
        db,
        sql: """
          \(selectClause)
          FROM documents d
          JOIN workspaces w ON w.workspace_id = d.workspace_id
          WHERE \(scope.predicate)
            AND (
              d.body LIKE ?
              OR (CASE WHEN w.canonical_path = '' THEN d.path
                       ELSE w.canonical_path || '/' || d.path END) = ?
            )
          """,
        arguments: arguments
      )
    }
  }

  private nonisolated static func searchScope(for documents: [DocumentRef]) -> (
    rootScopes: Set<String>, includeAdHoc: Bool
  ) {
    var rootScopes = Set<String>()
    var includeAdHoc = false
    for document in documents {
      if !document.isAdHoc, let rootURL = document.rootURL {
        rootScopes.insert(rootURL.standardizedFileURL.path)
      } else {
        includeAdHoc = true
      }
    }
    return (rootScopes, includeAdHoc)
  }

  private nonisolated static func scopePredicate(
    rootScopes: [String],
    includeAdHoc: Bool
  ) -> (predicate: String, arguments: StatementArguments) {
    var scopeClauses: [String] = []
    var scopeArgs: [DatabaseValueConvertible] = []
    if !rootScopes.isEmpty {
      let placeholders = Array(repeating: "?", count: rootScopes.count).joined(separator: ", ")
      scopeClauses.append("w.canonical_path IN (\(placeholders))")
      scopeArgs.append(contentsOf: rootScopes)
    }
    if includeAdHoc {
      scopeClauses.append("d.workspace_id = ?")
      scopeArgs.append(Self.adHocWorkspaceID)
    }
    return (
      "(" + scopeClauses.joined(separator: " OR ") + ")",
      StatementArguments(scopeArgs)
    )
  }

  private nonisolated static func backlinkTargetSlugs(
    for target: DocumentRef,
    indexedRecord: BacklinkDocumentRecord?
  ) -> Set<String> {
    let candidates = [
      target.title,
      target.displayPath,
      (target.displayPath as NSString).deletingPathExtension,
      indexedRecord?.title,
      indexedRecord?.displayPath,
      indexedRecord.map { ($0.displayPath as NSString).deletingPathExtension },
    ]
    return Set(
      candidates
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map(MarkdownWikilinks.slug(for:))
        .filter { !$0.isEmpty }
    )
  }

  private nonisolated static func backlinkSnippet(
    in body: String,
    matching targetSlugs: Set<String>
  ) -> String? {
    for line in body.split(whereSeparator: \.isNewline) {
      let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
      let links = MarkdownWikilinks.extract(from: text)
      guard links.contains(where: { targetSlugs.contains($0.slug) }) else { continue }
      if text.count <= 180 { return text }
      return String(text.prefix(177)) + "..."
    }
    return nil
  }

  private nonisolated static func makeResult(
    record: SearchDocumentRecord,
    document: DocumentRef,
    query: String
  ) -> WorkspaceSearchResult {
    let normalizedQuery = normalize(query)
    let title = normalize(record.title)
    let path = normalize(record.displayPath)
    let body = normalize(record.body)
    let terms = searchTerms(in: query)

    let titleContainsPhrase = !normalizedQuery.isEmpty && title.contains(normalizedQuery)
    let pathContainsPhrase = !normalizedQuery.isEmpty && path.contains(normalizedQuery)
    let bodyContainsPhrase = !normalizedQuery.isEmpty && body.contains(normalizedQuery)
    let titleContainsTerms = containsAll(terms, in: title)
    let pathContainsTerms = containsAll(terms, in: path)
    let bodyContainsTerms = containsAll(terms, in: body)

    let matchKind: WorkspaceSearchResult.MatchKind
    let score: Int
    if titleContainsPhrase {
      matchKind = .title
      score = 0
    } else if pathContainsPhrase {
      matchKind = .path
      score = 1
    } else if titleContainsTerms {
      matchKind = .title
      score = 2
    } else if pathContainsTerms {
      matchKind = .path
      score = 3
    } else if bodyContainsPhrase {
      matchKind = .body
      score = 4
    } else if bodyContainsTerms {
      matchKind = .body
      score = 5
    } else {
      matchKind = .body
      score = 6
    }

    return WorkspaceSearchResult(
      document: document,
      displayPath: record.displayPath,
      snippet: (bodyContainsPhrase || bodyContainsTerms)
        ? snippet(in: record.body, query: query, terms: terms) : nil,
      matchKind: matchKind,
      score: score,
      updatedAt: Date(timeIntervalSince1970: record.updatedAt)
    )
  }

  private nonisolated static func makeFTSQuery(from query: String) -> String {
    searchTerms(in: query)
      .map { "\($0)*" }
      .joined(separator: " AND ")
  }

  private nonisolated static func searchTerms(in text: String) -> [String] {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  private nonisolated static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private nonisolated static func containsAll(_ terms: [String], in text: String) -> Bool {
    !terms.isEmpty && terms.allSatisfy { text.contains($0) }
  }

  private nonisolated static func snippet(
    in body: String,
    query: String,
    terms: [String]
  ) -> String? {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let matchRange =
      body.range(of: query, options: options)
      ?? terms.compactMap { body.range(of: $0, options: options) }.first

    guard let matchRange else { return nil }

    let start =
      body.index(matchRange.lowerBound, offsetBy: -70, limitedBy: body.startIndex)
      ?? body.startIndex
    let end =
      body.index(matchRange.upperBound, offsetBy: 90, limitedBy: body.endIndex) ?? body.endIndex
    let collapsed = body[start..<end]
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let prefix = start > body.startIndex ? "..." : ""
    let suffix = end < body.endIndex ? "..." : ""
    return "\(prefix)\(collapsed)\(suffix)"
  }

  private func report(_ error: Error, appState: AppState?, action: String) {
    let message = "Could not \(action): \(error.localizedDescription)"
    appState?.lastError = message
    NSLog("%@", message)
  }

  func appendScanSession(
    workspaceID: String,
    trigger: String,
    startedAt: Date,
    finishedAt: Date,
    scannerVersion: Int,
    fingerprintHash: String,
    fileCount: Int,
    folderCount: Int,
    durationMs: Int,
    appState: AppState? = nil
  ) async {
    guard !isRefusedAfterTermination("appendScanSession") else { return }
    guard let pool = await ensureOpenInBackground(into: appState) else { return }
    // Sweep member (round 20): accepted before the latch, committed after it. This row is the one
    // that says the workspace WAS freshly scanned, so writing it behind the terminal checkpoint over
    // an index write that rolled back is exactly the inconsistency the latch exists to prevent.
    let latch = terminationLatch
    do {
      try await Task.detached(priority: .utility) {
        try pool.write { db in
          try Self.abandonIfClosedForTermination(latch)
          try db.execute(
            sql: """
              INSERT INTO scan_sessions (
                workspace_id, started_at, finished_at, trigger,
                scanner_version, fingerprint_hash, file_count, folder_count, duration_ms
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
              """,
            arguments: [
              workspaceID,
              Int(startedAt.timeIntervalSince1970),
              Int(finishedAt.timeIntervalSince1970),
              trigger,
              scannerVersion,
              fingerprintHash,
              fileCount,
              folderCount,
              durationMs,
            ]
          )
        }
      }.value
    } catch is IndexWriteAbandonedAfterTermination {
      Self.logAbandonedWriteAfterTermination("appendScanSession")
    } catch {
      report(error, appState: appState, action: "append Pensieve scan session")
    }
  }

  func refreshWorkspaceStats(
    workspaceID: String,
    fileCount: Int,
    folderCount: Int,
    fingerprintMatches: Bool,
    appState: AppState? = nil
  ) async {
    guard !isRefusedAfterTermination("refreshWorkspaceStats") else { return }
    guard let pool = await ensureOpenInBackground(into: appState) else { return }
    // Sweep member (round 20), and the twin of `appendScanSession`'s: an `index_health` of `green`
    // committed after the terminal checkpoint would describe rows the same quit rolled back.
    let latch = terminationLatch
    do {
      try await Task.detached(priority: .utility) {
        try pool.write { db in
          try Self.abandonIfClosedForTermination(latch)
          let indexHealth = fileCount == 0 ? "empty" : (fingerprintMatches ? "green" : "stale")
          try db.execute(
            sql: """
              INSERT INTO workspace_stats (
                workspace_id, file_count, folder_count,
                last_scan_at, last_indexed_at, index_health
              ) VALUES (
                ?, ?, ?,
                (SELECT finished_at FROM scan_sessions WHERE workspace_id = ? ORDER BY finished_at DESC LIMIT 1),
                (SELECT max(indexed_at) FROM documents WHERE workspace_id = ?),
                ?
              )
              ON CONFLICT(workspace_id) DO UPDATE SET
                file_count = excluded.file_count,
                folder_count = excluded.folder_count,
                last_scan_at = excluded.last_scan_at,
                last_indexed_at = excluded.last_indexed_at,
                index_health = excluded.index_health
              """,
            arguments: [
              workspaceID,
              fileCount,
              folderCount,
              workspaceID,
              workspaceID,
              indexHealth,
            ]
          )
        }
      }.value
    } catch is IndexWriteAbandonedAfterTermination {
      Self.logAbandonedWriteAfterTermination("refreshWorkspaceStats")
    } catch {
      report(error, appState: appState, action: "refresh Pensieve workspace stats")
    }
  }
}

/// A search hit read from the `document_fts` JOIN `documents` JOIN `workspaces`
/// projection: `path` is the RECONSTRUCTED full standardized path (the search
/// join key), `display_path`/`title`/`body` come from `documents`, `is_ad_hoc`
/// from `documents.is_ad_hoc`, `updated_at` from `documents.mtime`.
private struct SearchDocumentRecord: FetchableRecord, Sendable {
  var path: String
  var title: String
  var displayPath: String
  var body: String
  var isAdHoc: Bool
  var updatedAt: TimeInterval

  init(row: Row) throws {
    path = row["path"]
    title = row["title"]
    displayPath = row["display_path"]
    body = row["body"]
    isAdHoc = (row["is_ad_hoc"] as Int) != 0
    updatedAt = row["updated_at"]
  }
}

private struct BacklinkDocumentRecord: FetchableRecord, Sendable {
  var path: String
  var title: String
  var displayPath: String
  var body: String
  var isAdHoc: Bool
  var updatedAt: TimeInterval

  init(row: Row) throws {
    path = row["path"]
    title = row["title"]
    displayPath = row["display_path"]
    body = row["body"]
    isAdHoc = (row["is_ad_hoc"] as Int) != 0
    updatedAt = row["updated_at"]
  }
}

/// A fully-resolved `documents`-row write derived from a `DocumentRef` + body:
/// the workspace_id it belongs to (its own, or the reserved `__adhoc__`), the
/// stored `documents.path` (relative for workspace docs, full standardized path
/// for ad-hoc), the workspace `canonical_path` (for the search full-path
/// reconstruction; '' for ad-hoc), and the indexed metadata.
private struct DocumentWriteRecord: Sendable {
  var workspaceID: String
  var canonicalPath: String
  var path: String
  var title: String
  var body: String
  var mtime: Int
  var size: Int
  var isAdHoc: Bool
}

private struct IndexDocumentRecord: Sendable {
  var path: String
  var title: String
  var body: String
  var mtime: Int
  var size: Int
  var isAdHoc: Bool
}

/// Lock-guarded mirror of `IndexDatabase.isClosedForTermination`, readable from the detached
/// executor an index write's `pool.write` runs on. See `IndexDatabase.terminationLatch` for why the
/// main-actor flag cannot serve that read.
///
/// One-way, like the flag it mirrors: `close()` has no counterpart, so a batch loop that reads
/// `false` can only be racing a latch that has not closed yet — never one that has re-opened.
private final class TerminationLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var isClosed = false

  var isClosedForTermination: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isClosed
  }

  func close() {
    lock.lock()
    isClosed = true
    lock.unlock()
  }
}

/// Thrown out of a multi-batch index write whose transaction was still building when the
/// termination latch closed. Not a failure, and deliberately not reported to the user: the rollback
/// is the POINT. See `IndexDatabase.abandonIfClosedForTermination(_:)`.
private struct IndexWriteAbandonedAfterTermination: Error {}
