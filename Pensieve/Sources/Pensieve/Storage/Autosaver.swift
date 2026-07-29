import Foundation

@MainActor
final class Autosaver {
  static let shared = Autosaver()

  private let saveDelayNanoseconds: UInt64
  private let indexDelayNanoseconds: UInt64
  private var saveTask: Task<Void, Never>?
  private var indexTask: Task<Void, Never>?
  /// Which session armed the save debounce, or `nil` when nothing is armed.
  ///
  /// Same singleton problem as `armedIndexOwner`, one debounce over: this object holds at most ONE
  /// save debounce and it belongs to the LAST edited session, not necessarily the one asking. A close
  /// that cancels whatever happens to be armed therefore deletes ANOTHER window's pending 1.5 s
  /// autosave — and since round 7 that window's 5 s index debounce is deliberately left armed to wait
  /// for exactly that save, it would then fire over text whose write was just taken away: FTS ahead
  /// of disk in a RUNNING app, with no recovery draft behind a file-backed document. So a caller may
  /// cancel only its OWN armed save; a foreign one stays armed and fires on its own schedule.
  ///
  /// The session object itself rather than its URL, because the question is "is this the same
  /// window?": two untitled windows have no URL at all, and two windows on one file share theirs.
  /// Held WEAKLY, so an owner that is gone reads as owned-by-nobody and cannot be impersonated by a
  /// later allocation at the same address — and nothing is lost by leaving that orphan armed, since
  /// the body captures its session weakly too and no-ops.
  private weak var armedSaveOwner: AnyObject?
  /// Bumped by every arm/cancel so a save timer that already slipped past its cancellation check can
  /// neither run its body nor clear the ownership a newer schedule has since recorded.
  private var saveGeneration: UInt64 = 0
  /// The armed index-debounce BODY, kept next to its timer so the work can be run NOW instead of
  /// only when the sleep elapses. Cleared the instant the body runs — by the timer or by a flush —
  /// so "flush the index debounce" means exactly once, never twice and never never.
  private var pendingIndex: (@MainActor () -> Void)?
  /// Which document the armed body would index, or `nil` when nothing is armed.
  ///
  /// This object is a process-wide SINGLETON holding at most one index debounce, and that debounce
  /// belongs to the LAST edited session — not necessarily the one asking. A closing window therefore
  /// cannot tell from `flushIndex()` alone whether it is landing already-saved text or text that is
  /// still only in some window's buffer, and the two need opposite treatment: a debounce whose owner
  /// has nothing unsaved is owed unconditionally, while one whose owner is still dirty must not reach
  /// the index until THAT owner's file write has succeeded — whether the owner is the window closing
  /// or another one. `DocumentStore.savePendingChangesOnClose` reads this to tell the two apart.
  private(set) var armedIndexOwner: URL?
  /// Live read of whether the armed debounce's OWNER still holds unsaved text.
  ///
  /// A closure recorded at arm time, not a stored flag, on purpose: the answer must be the owner's
  /// state at the moment somebody asks — a close, a quit — not a snapshot from arming. The owner may
  /// have autosaved itself clean in between, and a stale `true` would defer a debounce that nothing
  /// is going to run. It captures the owning session weakly, exactly as the body does, so an owner
  /// whose window is already gone reads as NOT dirty: there is no save left to wait for, and running
  /// an orphaned body is the pre-existing semantics for orphaned debounces.
  private var armedIndexOwnerDirtiness: (@MainActor () -> Bool)?
  /// Bumped by every arm/cancel/flush so a timer that already slipped past its cancellation check
  /// cannot run a body a newer schedule has since replaced.
  private var indexGeneration: UInt64 = 0
  /// One-way switch set by `quiesceForTermination()`. The app is going away; a debounce armed after
  /// that point could only fire during the quit's pumped run loop — after the drain has taken its
  /// snapshot — so arming is refused rather than raced.
  private(set) var isQuiescedForTermination = false

  /// Whether the armed debounce's owner is holding unsaved text RIGHT NOW. `false` when nothing is
  /// armed, when the owner has since been saved, or when the owning session is gone.
  var armedIndexOwnerIsDirty: Bool { armedIndexOwnerDirtiness?() ?? false }

  /// Whether the armed save debounce belongs to `session`. `false` when nothing is armed, when the
  /// debounce belongs to another window, or when its owner is already gone — the three cases in which
  /// a caller must NOT cancel it. See `armedSaveOwner`.
  func armedSaveIsOwned(by session: AnyObject) -> Bool {
    armedSaveOwner === session
  }

  init(saveDelayMilliseconds: UInt64 = 1_500, indexDelayMilliseconds: UInt64 = 5_000) {
    self.saveDelayNanoseconds = saveDelayMilliseconds * 1_000_000
    self.indexDelayNanoseconds = indexDelayMilliseconds * 1_000_000
  }

  /// `owner` is the session whose text this debounce would write — pass the window's `AppState`. It
  /// is required rather than defaulted for the same reason `scheduleIndex`'s `ownerIsDirty` is: an
  /// arm site that forgot it would leave an ownerless debounce that every close feels free to cancel,
  /// which is exactly the defect ownership exists to close.
  func scheduleSave(owner: AnyObject, _ save: @escaping @MainActor () -> Void) {
    guard !isQuiescedForTermination else { return }
    saveTask?.cancel()
    saveGeneration &+= 1
    let generation = saveGeneration
    armedSaveOwner = owner
    saveTask = Task { [saveDelayNanoseconds, weak self] in
      try? await Task.sleep(nanoseconds: saveDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.runPendingSave(generation: generation, save)
      }
    }
  }

  /// `ownerIsDirty` is required rather than defaulted: an arm site that forgot to supply it would
  /// silently declare its owner clean, which is exactly the "flush somebody's unsaved text early"
  /// defect this parameter exists to close.
  func scheduleIndex(
    owner: URL?, ownerIsDirty: @escaping @MainActor () -> Bool,
    _ index: @escaping @MainActor () -> Void
  ) {
    guard !isQuiescedForTermination else { return }
    indexTask?.cancel()
    indexGeneration &+= 1
    let generation = indexGeneration
    pendingIndex = index
    armedIndexOwner = owner
    armedIndexOwnerDirtiness = ownerIsDirty
    indexTask = Task { [indexDelayNanoseconds, weak self] in
      try? await Task.sleep(nanoseconds: indexDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.runPendingIndex(generation: generation)
      }
    }
  }

  /// Runs the armed index debounce NOW instead of waiting out its 5 s delay, then clears the timer.
  /// A no-op when nothing is armed, and idempotent: the body is dropped before it is invoked, so a
  /// second flush (or the timer firing afterwards) cannot repeat the write.
  ///
  /// Flush, not cancel, because this object is a process-wide SINGLETON: at most one index debounce
  /// exists at a time and it belongs to the LAST edited session, which may be a different window
  /// than the one asking. Cancelling would silently drop that window's index freshness, and for an
  /// AD-HOC document (outside every workspace root) there is no cold-open self-heal to recover it —
  /// `signature(from:)` is built from workspace scans only, so an ad-hoc file has no signature entry
  /// and its stale FTS row is never revisited. Running the write costs one small `documents` upsert.
  func flushIndex() {
    let index = pendingIndex
    pendingIndex = nil
    armedIndexOwner = nil
    armedIndexOwnerDirtiness = nil
    indexGeneration &+= 1
    indexTask?.cancel()
    indexTask = nil
    index?()
  }

  /// Termination command, issued by `TerminationSequence` in the flush phase: land the armed index
  /// write, then stop both debounces for good. After this returns nothing can re-arm — which is what
  /// makes the drain that follows a wait for a FINITE set of work rather than a moving target.
  ///
  /// The `cancel()` here stays UNCONDITIONAL, unlike the ownership-scoped cancels on the close path:
  /// `TerminationSequence` has already run `flushPendingWindowSaves` over every live controller, so
  /// each window's bytes are on disk and no armed save — whoever owns it — has anything left to
  /// contribute. Nothing may re-arm afterwards either, which is what makes the drain that follows a
  /// wait for a finite set of work.
  func quiesceForTermination() {
    flushIndex()
    isQuiescedForTermination = true
    cancel()
  }

  func cancelSave() {
    saveTask?.cancel()
    saveTask = nil
    armedSaveOwner = nil
    saveGeneration &+= 1
  }

  func cancelIndex() {
    indexTask?.cancel()
    indexTask = nil
    pendingIndex = nil
    armedIndexOwner = nil
    armedIndexOwnerDirtiness = nil
    indexGeneration &+= 1
  }

  func cancel() {
    cancelSave()
    cancelIndex()
  }

  /// Disarms the save bookkeeping BEFORE running the body, so the write that follows sees "nothing
  /// armed" rather than an ownership record its own timer has already consumed. Generation-guarded
  /// for the same reason the index side is: a timer that slipped past its cancellation check must not
  /// clear ownership a newer schedule has since recorded.
  private func runPendingSave(generation: UInt64, _ save: @MainActor () -> Void) {
    guard generation == saveGeneration else { return }
    saveTask = nil
    armedSaveOwner = nil
    save()
  }

  private func runPendingIndex(generation: UInt64) {
    guard generation == indexGeneration, let index = pendingIndex else { return }
    pendingIndex = nil
    armedIndexOwner = nil
    armedIndexOwnerDirtiness = nil
    index()
  }
}
