import AppKit
import Foundation

/// The single owner of what happens between "the user quit" and "the process is gone".
///
/// There used to be two half-owners and no order. The custom "Quit Pensieve" menu item checkpointed
/// the index before calling `terminate:`; `applicationWillTerminate` checkpointed it again for every
/// other quit path (Dock, logout, shutdown). Neither owned the SEQUENCE, and the sequence is where
/// the data lives: `applicationWillTerminate` fires BEFORE the windows tear down, so each window's
/// `NSWindow.willCloseNotification` save ran after the checkpoint — and that save's index write, a
/// background hand-off, landed after it again, if the process survived long enough to run it at all.
///
/// So the order is written down once, here, and it is the only one:
///
/// 1. QUIESCE — tell the producers the app is going away: the window registry, each window's
///    controller, and the workspace manager (watcher stopped, refresh/build tasks cancelled),
/// 2. FLUSH — land everything the user already owns: every window's pending edit, and the armed
///    autosave index debounce, run NOW rather than when its 5 s timer says so,
/// 3. DRAIN — wait for every index write the app owes, including the ones step 2 just scheduled,
///    and for the post-close index housekeeping, all under one budget,
/// 4. LATCH — close the index funnel one way; from here every write entry point and lazy open
///    refuses, and the terminal checkpoint is the only DB operation left that can run,
/// 5. take the truncating checkpoint,
/// 6. return, and let AppKit tear the windows down.
///
/// Steps 1 and 4 are the difference between "the writes we knew about are safe" and "no new managed
/// write can arise". Five review rounds each found another producer that was still alive during the
/// quit; the answer was never a sixth patch but the missing phase — and a refusal at the funnel for
/// whatever the inventory missed. This class is the SINGLE owner of that phase state: no other type
/// keeps a termination flag of its own, they execute commands (`quiesceForTermination`) or are
/// switched by this one (`IndexDatabase.closeForTermination`).
///
/// The order above is one thing; WHICH of it the `drainTimeout` bounds is another, and the two are
/// not the same question. Steps 1–2 are the user's own bytes; steps 3–5 are index bookkeeping. Only
/// the latter can wedge (SQLite, a background pool), only the latter is what the budget was built
/// for, and a buffer that misses the disk is gone for good while a WAL left long is reclaimed by the
/// next launch. So the split is: `runUserFlushPhases()` runs OUTSIDE any task and outside the
/// deadline, `runIndexPhases()` runs inside both. Phase order is unchanged — Q → F → D → L → C.
///
/// Deliberately prompt-free and non-destructive: nothing here asks the user anything and nothing
/// discards a buffer. A dirty untitled session is persisted as a recovery draft by the same
/// `savePendingChangesOnClose` an ordinary window close uses.
@MainActor
final class TerminationSequence {
  /// A quit must never hang on a wedged index write. Generous next to a checkpoint the batch and
  /// workspace-close maintenance already keep cheap, and small next to the watchdog macOS applies to
  /// a logout/shutdown quit.
  nonisolated static let defaultDrainTimeout: TimeInterval = 5

  /// How long each run-loop pump is allowed to park before the deadline is re-checked.
  private nonisolated static let pumpInterval: TimeInterval = 0.005

  private let registry: DocumentWindowRegistry
  private let indexDatabase: IndexDatabase
  private let folderManager: FolderManager
  private let autosaver: Autosaver
  private let drainTimeout: TimeInterval
  private let pumpRunLoop: (Date) -> Void
  private var didFinish = false

  /// Whether `run()` got as far as starting the terminal checkpoint. Read by the post-deadline
  /// fallback so a budget that expires while the checkpoint is ALREADY running (a wedged pool reader)
  /// does not start a second, redundant barrier. Both sides are main-actor, so this needs no lock.
  private var didStartTerminalCheckpoint = false

  init(
    registry: DocumentWindowRegistry,
    indexDatabase: IndexDatabase,
    // Resolved inside the (main-actor) body rather than as `= .shared` defaults: a default argument
    // is evaluated in a nonisolated context, which cannot read a main-actor-isolated `shared`.
    folderManager: FolderManager? = nil,
    autosaver: Autosaver? = nil,
    drainTimeout: TimeInterval = TerminationSequence.defaultDrainTimeout,
    pumpRunLoop: @escaping (Date) -> Void = { limit in
      RunLoop.current.run(mode: .default, before: limit)
    }
  ) {
    self.registry = registry
    self.indexDatabase = indexDatabase
    self.folderManager = folderManager ?? .shared
    self.autosaver = autosaver ?? .shared
    self.drainTimeout = drainTimeout
    self.pumpRunLoop = pumpRunLoop
  }

  /// The whole contract, for callers that can await it — tests, and any future async quit hook.
  /// `runBlockingMainRunLoop()` runs these same two halves; what it adds is the budget, and it puts
  /// the budget around the second half only.
  func run() async {
    runUserFlushPhases()
    await runIndexPhases()
  }

  /// Phases Q and F — the half that owns the user's bytes, and synchronous on purpose.
  ///
  /// Quiescence is a handful of O(1) cancels and the flush is the app's ordinary save primitive,
  /// which is itself synchronous: `String.write(_:atomically:)` on the main actor, the very same call
  /// ⌘S and every window close make. Nothing here needs the pump, so nothing here needs to be inside
  /// the budgeted task — and it must not be. A cancelled task's continuation is not guaranteed to
  /// resume before AppKit tears the process down, so a save loop parked behind a suspension point at
  /// the moment the deadline expires can lose the windows it had not reached yet. User bytes are not
  /// budgeted work.
  func runUserFlushPhases() {
    // ---- Q: quiescence. Producers first, before anything is flushed or drained, so the drain below
    // waits for a FINITE set of work rather than a target the watcher and the debounces keep moving.
    let controllers = registry.liveDocumentControllers()
    // The last document window closing during Quit must not resurrect a launcher; tell the registry
    // the app is going away before anything else touches its windows.
    registry.beginTermination()
    for controller in controllers {
      controller.quiesceForTermination()
    }
    folderManager.quiesceForTermination()

    // ---- F: flush. Everything the user already owns lands now, not when a timer says so. Both
    // steps PRODUCE index writes, which is precisely why the latch cannot be armed yet.
    flushPendingWindowSaves(controllers)
    autosaver.quiesceForTermination()
  }

  /// Phases D, L and C — the half `drainTimeout` was actually built to bound, and the only half that
  /// can wedge: SQLite, a background pool, a producer that outlived its owner. Every wait here is an
  /// `await` — see `runBlockingMainRunLoop()`: a synchronous wait would park the pump and make the
  /// deadline dead.
  func runIndexPhases() async {
    // ---- D: drain. The accepted work first, then the post-close index housekeeping — which is a
    // barrier vacuum + truncate and, until now, was awaited only by tests. `Close Folder` followed by
    // a fast ⌘Q raced that vacuum against this quit's own checkpoint, and GRDB serializes the two
    // without ordering them: the vacuum could land last and leave WAL frames behind the checkpoint
    // that was supposed to be final. Housekeeping goes second because it re-drains internally, so
    // nothing accepted can still be owed once it returns.
    await indexDatabase.drainPendingIndexWrites()
    await folderManager.waitForPendingIndexMaintenance()

    // ---- L: latch. Everything owed has landed; from here the funnel refuses, so a producer this
    // sequence never knew about cannot write behind the checkpoint.
    indexDatabase.closeForTermination()

    // ---- C: checkpoint. Started off-main and AWAITED, not taken on this thread. The order is
    // unchanged — the checkpoint still happens here, after the drain, before this returns — but the
    // wait is a suspension point, which is what keeps it inside the budget.
    didStartTerminalCheckpoint = true
    await indexDatabase.startCheckpointOnTerminate()?.value
  }

  /// Synchronous entry for `applicationWillTerminate`, which cannot await — and which is the ONLY
  /// termination hook this app receives, because `applicationShouldTerminate(_:)` is never invoked
  /// under `@NSApplicationDelegateAdaptor` (falsified at runtime on 2026-07-29), so AppKit's
  /// `.terminateLater` reply is not available to us.
  ///
  /// Blocking the main thread outright would deadlock: the index writes being waited for are
  /// main-actor jobs dispatched to this very thread. Pumping the run loop instead keeps servicing
  /// them while the quit waits. `RunLoop.run(mode:before:)` drains the main queue without pulling
  /// `NSEvent`s (`NSApplication`'s own loop owns those), so this waits without re-entering the UI.
  ///
  /// The pump is also what makes the deadline real, and that cuts both ways: control only comes back
  /// here when the main-actor task SUSPENDS. Anything the task does synchronously is therefore
  /// outside the budget no matter what this loop says — which is why the terminal checkpoint is
  /// started off-main and awaited rather than taken inline. Every wait in `runIndexPhases()` must be
  /// an `await`.
  ///
  /// Phases Q and F run BEFORE the task and before the deadline, on this thread. They are the user's
  /// own bytes and they are all synchronous, so there is nothing for the pump to service and nothing
  /// a cancellation could usefully stop — it could only strand the windows the loop had not reached.
  /// The named consequence, and it is deliberate: a pile of dirty windows on a slow volume delays the
  /// quit by however long those writes take, unbudgeted. That is the priority this contract keeps —
  /// bytes first, the deadline second — and it is the reason the deadline can never cost a save.
  func runBlockingMainRunLoop() {
    didFinish = false
    // Outside the task and outside the budget. See `runUserFlushPhases()`.
    runUserFlushPhases()

    // Strongly captured on purpose. The caller typically builds this object inline and drops it the
    // moment this method returns, so a weak capture is resolved against an object ARC is already
    // free to release — the sequence would silently do nothing. Nothing here stores the task on
    // `self`, so there is no cycle to break.
    let sequence = Task { @MainActor in
      await self.runIndexPhases()
      self.didFinish = true
    }

    let deadline = Date().addingTimeInterval(drainTimeout)
    while !didFinish, Date() < deadline {
      pumpRunLoop(Date(timeIntervalSinceNow: Self.pumpInterval))
    }
    guard !didFinish else { return }

    // Budget spent. Stop waiting and return — and do NOT take the checkpoint's barrier on this
    // thread, which is what this used to do. The budget expires because something is stuck inside the
    // pool, and the checkpoint takes the barrier that excludes exactly that: the escape hatch would
    // have parked the quit on the very stall it exists to escape, so quitting during a wedged reindex
    // could hang indefinitely despite the timeout.
    //
    // So past the deadline the checkpoint is best-effort and unwaited. It still truncates the WAL if
    // the pool frees up while the process is alive, and it can never delay the quit again. A WAL left
    // at its high-water mark is reclaimed by the next launch's workspace-close maintenance; a quit
    // that never returns is not recoverable at all.
    sequence.cancel()
    NSLog(
      "Pensieve quit: the index drain and checkpoint exceeded their %.1f s budget; leaving the "
        + "checkpoint best-effort",
      drainTimeout)
    // A spent budget stops the WAITING; it does not put the app back into a running state. Close the
    // funnel here too, so a producer that outlived the drain cannot slip a write in behind the
    // best-effort checkpoint. One-way and idempotent, so a sequence that latched already is unharmed.
    indexDatabase.closeForTermination()
    // Only when the sequence never reached it. A budget spent WAITING for the checkpoint (a wedged
    // pool reader, not a wedged writer) already has one running; a second barrier would queue behind
    // the first for nothing.
    if !didStartTerminalCheckpoint {
      indexDatabase.startCheckpointOnTerminate()
    }
  }

  /// Lands every window's pending edit, in one uninterrupted synchronous loop.
  ///
  /// Each save is the app's ordinary save primitive and it is synchronous: `String.write(_:atomically:)`
  /// on the main actor, the very same call ⌘S and every window close make. Moving document and
  /// session state off the main actor is a save-path refactor this termination contract does not own,
  /// so the synchronous write stays.
  ///
  /// Round 6 briefly put an `await Task.yield()` between windows to make the budget enforceable at
  /// file granularity. That trade is off: the pump did regain control between files, but the price
  /// was that the deadline could now expire mid-loop, `runBlockingMainRunLoop()` would cancel and
  /// return, and the continuation holding the REMAINING windows would sit on a main actor nobody
  /// pumps again — the process exits and those buffers are gone. Observability of the budget is not
  /// worth a lost file, so the loop is uninterruptible again and the whole phase now runs outside the
  /// budget instead (see `runUserFlushPhases()`).
  ///
  /// Named residual, unchanged and deliberate: N dirty windows, or a single large one, on a slow
  /// volume delay the quit for as long as their writes take. Bounding that safely needs the save path
  /// itself to become suspending — a refactor this contract does not own — and until then a slow quit
  /// beats a lost buffer.
  private func flushPendingWindowSaves(_ controllers: [AppController]) {
    for controller in controllers {
      controller.savePendingChangesOnClose()
    }
  }
}
