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
/// 1. flush every window's pending edit (do not wait for `willCloseNotification` — it is too late),
/// 2. drain every index write the app owes, including the ones those flushes just scheduled,
/// 3. take the truncating checkpoint,
/// 4. return, and let AppKit tear the windows down.
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
  private let drainTimeout: TimeInterval
  private let pumpRunLoop: (Date) -> Void
  private var didFinish = false

  init(
    registry: DocumentWindowRegistry,
    indexDatabase: IndexDatabase,
    drainTimeout: TimeInterval = TerminationSequence.defaultDrainTimeout,
    pumpRunLoop: @escaping (Date) -> Void = { limit in
      RunLoop.current.run(mode: .default, before: limit)
    }
  ) {
    self.registry = registry
    self.indexDatabase = indexDatabase
    self.drainTimeout = drainTimeout
    self.pumpRunLoop = pumpRunLoop
  }

  /// The termination contract itself.
  func run() async {
    // The last document window closing during Quit must not resurrect a launcher; tell the registry
    // the app is going away before anything else touches its windows.
    registry.beginTermination()
    flushPendingWindowSaves()
    await indexDatabase.drainPendingIndexWrites()
    indexDatabase.checkpointOnTerminate()
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
  func runBlockingMainRunLoop() {
    didFinish = false
    // Strongly captured on purpose. The caller typically builds this object inline and drops it the
    // moment this method returns, so a weak capture is resolved against an object ARC is already
    // free to release — the sequence would silently do nothing. Nothing here stores the task on
    // `self`, so there is no cycle to break.
    let sequence = Task { @MainActor in
      await self.run()
      self.didFinish = true
    }

    let deadline = Date().addingTimeInterval(drainTimeout)
    while !didFinish, Date() < deadline {
      pumpRunLoop(Date(timeIntervalSinceNow: Self.pumpInterval))
    }
    guard !didFinish else { return }

    // Budget spent. Stop waiting for the drain — and do NOT then call the blocking
    // `checkpointOnTerminate()`, which is what this used to do. The budget only ever expires because
    // an index write is stuck inside the pool, and the checkpoint takes the SAME barrier that write
    // is holding, synchronously, on this thread: the escape hatch would have parked the quit on the
    // exact stall it exists to escape, so quitting during a wedged reindex could hang indefinitely
    // despite the timeout.
    //
    // So past the deadline the checkpoint is best-effort and unwaited. It still truncates the WAL if
    // the pool frees up while the process is alive, and it can never delay the quit again. A WAL left
    // at its high-water mark is reclaimed by the next launch's workspace-close maintenance; a quit
    // that never returns is not recoverable at all.
    sequence.cancel()
    NSLog(
      "Pensieve quit: index drain exceeded its %.1f s budget; leaving the checkpoint best-effort",
      drainTimeout)
    indexDatabase.checkpointOnTerminateWithoutWaiting()
  }

  private func flushPendingWindowSaves() {
    for controller in registry.liveDocumentControllers() {
      controller.savePendingChangesOnClose()
    }
  }
}
