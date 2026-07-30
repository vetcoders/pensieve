import Foundation

/// The app's two debounces — a 1.5 s file save and a 5 s index write — held PER OWNER.
///
/// Round 15, blocker 1 (P1, user-data loss). This object used to hold exactly ONE armed save and ONE
/// armed index write, and every arming unconditionally cancelled whatever was there. Rounds 7, 8 and
/// 11 narrowed every CANCEL to its owner, which was the reachable half; the ARMING side was named as
/// the residual and deferred. It is the more expensive half: typing in window B within 1.5 s of an
/// edit in window A deleted A's pending save — no close, no quit, no user action involved — leaving
/// A's bytes in memory with nothing scheduled to write them. A crash, a force-quit or a log-out then
/// lost the edit outright, and for a FILE-BACKED document there is no recovery draft behind it. The
/// same replacement one debounce over dropped A's index write, which for an ad-hoc document is a
/// permanently stale FTS row (no workspace signature ⇒ no cold-open self-heal).
///
/// So each owner gets its own entry on each side. Arming for B is invisible to A: it replaces B's
/// own previous entry and nothing else. Every existing ownership rule survives unchanged, now as a
/// lookup instead of a comparison against the one slot.
///
/// Ownership is the SESSION OBJECT on BOTH sides — weakly held, compared by identity — because the
/// question is always "is this the same window?": two untitled windows have no URL at all, and two
/// windows on one file share theirs. The index side used to key on the document URL, which is why
/// round 8 had to name "two windows on the same file are indistinguishable" as a residual; keying on
/// the session closes it. The document the index entry would write is still recorded, because the
/// call sites that supersede a write (`saveExisting(indexNow: true)`) ask about the DOCUMENT, not
/// about the window. Weak, so an owner that is gone reads as owned-by-nobody and cannot be
/// impersonated by a later allocation at the same address.
@MainActor
final class Autosaver {
  static let shared = Autosaver()

  /// One window's armed 1.5 s file save.
  private struct SaveEntry {
    weak var owner: AnyObject?
    var task: Task<Void, Never>?
    /// See `generationCounter`.
    var generation: UInt64
  }

  /// One window's armed 5 s index write.
  private struct IndexEntry {
    weak var owner: AnyObject?
    /// The document this body would index. Recorded because the supersede question at
    /// `saveExisting(indexNow: true)` is about the document, not about the window.
    var document: URL
    /// The armed BODY, kept next to its timer so the work can be run NOW instead of only when the
    /// sleep elapses. The entry is dropped before the body is invoked — by the timer or by a flush —
    /// so "flush this index debounce" means exactly once, never twice and never never.
    var body: (@MainActor () -> Void)?
    /// Live read of whether this entry's OWNER still holds unsaved text.
    ///
    /// A closure recorded at arm time, not a stored flag, on purpose: the answer must be the owner's
    /// state at the moment somebody asks — a close, a quit — not a snapshot from arming. The owner
    /// may have autosaved itself clean in between, and a stale `true` would defer a debounce that
    /// nothing is going to run. It captures the owning session weakly, exactly as the body does, so
    /// an owner whose window is already gone reads as NOT dirty: there is no save left to wait for,
    /// and running an orphaned body is the pre-existing semantics for orphaned debounces.
    var ownerIsDirty: (@MainActor () -> Bool)?
    var task: Task<Void, Never>?
    /// See `generationCounter`.
    var generation: UInt64
  }

  private let saveDelayNanoseconds: UInt64
  private let indexDelayNanoseconds: UInt64
  private var saveEntries: [SaveEntry] = []
  private var indexEntries: [IndexEntry] = []
  /// Hands every arming a value no other armed debounce in this process has held.
  ///
  /// The generation is how a timer that already slipped past its cancellation check finds ITS entry
  /// — and finds nothing when that entry has since been cancelled, flushed or re-armed. It therefore
  /// can neither run a body a newer schedule has replaced nor disarm ownership that newer schedule
  /// has recorded, which is the same guarantee the singleton's two counters gave, per entry. One
  /// counter for both sides: the two arrays are searched separately, so the only property that
  /// matters is that a value is never reused.
  private var generationCounter: UInt64 = 0
  /// One-way switch set by `quiesceForTermination()`. The app is going away; a debounce armed after
  /// that point could only fire during the quit's pumped run loop — after the drain has taken its
  /// snapshot — so arming is refused rather than raced.
  private(set) var isQuiescedForTermination = false

  init(saveDelayMilliseconds: UInt64 = 1_500, indexDelayMilliseconds: UInt64 = 5_000) {
    self.saveDelayNanoseconds = saveDelayMilliseconds * 1_000_000
    self.indexDelayNanoseconds = indexDelayMilliseconds * 1_000_000
  }

  // MARK: - Queries

  /// Whether `session` has an armed save debounce of its own. `false` when it never armed one, when
  /// its own timer has already fired, or when it was cancelled — the cases in which there is nothing
  /// of this window's to cancel. Another window's armed save is not this window's business and never
  /// shows up here.
  func armedSaveIsOwned(by session: AnyObject) -> Bool {
    saveEntryIndex(ownedBy: session) != nil
  }

  /// The document `session`'s armed index debounce would write, or `nil` when it has none armed.
  ///
  /// The URL is the SUPERSEDE key, not the ownership key: a caller that has just written a document
  /// itself asks "is my armed debounce about to write this same document again?". Ownership is
  /// already settled by having asked through `session`.
  func armedIndexDocument(ownedBy session: AnyObject) -> URL? {
    indexEntryIndex(ownedBy: session).map { indexEntries[$0].document }
  }

  /// Whether `session`'s armed index debounce is holding text its owner has not saved yet. `false`
  /// when nothing of its own is armed or when its buffer is clean — in both cases the debounce owes
  /// a write for bytes that are already on disk.
  func armedIndexOwnerIsDirty(ownedBy session: AnyObject) -> Bool {
    guard let index = indexEntryIndex(ownedBy: session) else { return false }
    return indexEntries[index].ownerIsDirty?() ?? false
  }

  // MARK: - Arming

  /// `owner` is the session whose text this debounce would write — pass the window's `AppState`. It
  /// is required rather than defaulted for the same reason `scheduleIndex`'s `ownerIsDirty` is: an
  /// arm site that forgot it would leave an ownerless debounce that every close feels free to cancel,
  /// which is exactly the defect ownership exists to close.
  ///
  /// Replaces only THIS owner's armed save. A newer edit in the same window supersedes that window's
  /// own pending write; an edit in another window supersedes nothing, which is blocker 1 of round 15.
  func scheduleSave(owner: AnyObject, _ save: @escaping @MainActor () -> Void) {
    guard !isQuiescedForTermination else { return }
    pruneVanishedSaveOwners()
    let generation = nextGeneration()
    let task = Task { [saveDelayNanoseconds, weak self] in
      try? await Task.sleep(nanoseconds: saveDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.runPendingSave(generation: generation, save)
      }
    }
    if let index = saveEntryIndex(ownedBy: owner) {
      saveEntries[index].task?.cancel()
      saveEntries[index].task = task
      saveEntries[index].generation = generation
    } else {
      saveEntries.append(SaveEntry(owner: owner, task: task, generation: generation))
    }
  }

  /// `ownerIsDirty` is required rather than defaulted: an arm site that forgot to supply it would
  /// silently declare its owner clean, which is exactly the "flush somebody's unsaved text early"
  /// defect this parameter exists to close.
  ///
  /// Replaces only THIS owner's armed index write — including when another window is editing the
  /// SAME document, which is the round 8 residual this keying closes.
  func scheduleIndex(
    owner: AnyObject, document: URL, ownerIsDirty: @escaping @MainActor () -> Bool,
    _ index: @escaping @MainActor () -> Void
  ) {
    guard !isQuiescedForTermination else { return }
    let generation = nextGeneration()
    let task = Task { [indexDelayNanoseconds, weak self] in
      try? await Task.sleep(nanoseconds: indexDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.runPendingIndex(generation: generation)
      }
    }
    let entry = IndexEntry(
      owner: owner, document: document, body: index, ownerIsDirty: ownerIsDirty, task: task,
      generation: generation)
    if let existing = indexEntryIndex(ownedBy: owner) {
      indexEntries[existing].task?.cancel()
      indexEntries[existing] = entry
    } else {
      indexEntries.append(entry)
    }
  }

  // MARK: - Flushing

  /// Runs NOW, instead of waiting out its 5 s delay, every armed index write whose OWNER has nothing
  /// unsaved — because its own autosave already wrote the bytes and marked the buffer clean, or
  /// because its window is gone and there is no save left to wait for. An entry whose owner is still
  /// dirty is left ARMED, untouched.
  ///
  /// Flush rather than cancel, because a debounce armed here belongs to a window, not to the caller:
  /// cancelling would silently drop that window's index freshness, and for an AD-HOC document
  /// (outside every workspace root) there is no cold-open self-heal to recover it —
  /// `signature(from:)` is built from workspace scans only, so an ad-hoc file has no signature entry
  /// and its stale FTS row is never revisited. Running the write costs one small `documents` upsert.
  ///
  /// Withhold rather than flush for a DIRTY owner, because its body would publish text whose bytes
  /// are not on disk yet: submitting it here puts it in SQLite before that owner's file write has
  /// even been attempted, and no later cancel can retract an already-scheduled database task, so a
  /// write that fails (full volume, revoked permissions) would leave FTS advertising content that
  /// never reached the disk. Deferred means left ARMED — that owner's own close decides, or the
  /// debounce simply fires on its own schedule over bytes its own autosave has by then written.
  func flushIndexDebouncesWithSettledOwners() {
    for generation in indexEntries.filter({ !($0.ownerIsDirty?() ?? false) }).map(\.generation) {
      runPendingIndex(generation: generation)
    }
  }

  /// Runs every armed index body NOW, dirty owners included, and disarms them all.
  ///
  /// The unconditional form, used only on the quit path: `TerminationSequence` has already run
  /// `savePendingChangesOnClose` over every live controller, so every window's bytes are on disk and
  /// the dirty-owner reservation above has nothing left to protect. Idempotent — each body is
  /// dropped before it is invoked — because the sequence flushes through the window closes AND
  /// through `quiesceForTermination()`, and both may reach the same debounce.
  func flushIndex() {
    for generation in indexEntries.map(\.generation) {
      runPendingIndex(generation: generation)
    }
  }

  /// Termination command, issued by `TerminationSequence` in the flush phase: land every armed index
  /// write, then stop both debounces for good. After this returns nothing can re-arm — which is what
  /// makes the drain that follows a wait for a FINITE set of work rather than a moving target.
  ///
  /// The `cancel()` here stays UNCONDITIONAL, unlike the ownership-scoped cancels on the close path:
  /// `TerminationSequence` has already run `flushPendingWindowSaves` over every live controller, so
  /// each window's bytes are on disk and no armed save — whoever owns it — has anything left to
  /// contribute.
  func quiesceForTermination() {
    flushIndex()
    isQuiescedForTermination = true
    cancel()
  }

  // MARK: - Cancelling

  /// Cancels `session`'s own armed save and nothing else. A no-op when it has none armed.
  func cancelSave(ownedBy session: AnyObject) {
    guard let index = saveEntryIndex(ownedBy: session) else { return }
    saveEntries[index].task?.cancel()
    saveEntries.remove(at: index)
  }

  /// Cancels `session`'s own armed index write and nothing else. A no-op when it has none armed.
  ///
  /// Cancel, not flush, is right ONLY for your own entry: every caller is either replacing the
  /// session's document (and the paths that publish text index it explicitly afterwards) or has just
  /// written those exact bytes and is re-issuing the index write itself.
  func cancelIndex(ownedBy session: AnyObject) {
    guard let index = indexEntryIndex(ownedBy: session) else { return }
    discardIndexEntry(at: index)
  }

  /// Process-wide teardown: every owner's save and every owner's index debounce. Reserved for the
  /// quit path (behind the quiescence latch, where nothing may re-arm) and for test teardown; a
  /// caller that means "mine" must say so through the `ownedBy:` forms, and an ownerless cancel on a
  /// live app is the defect rounds 7, 8, 11 and 15 exist to forbid.
  func cancel() {
    cancelAllSaves()
    cancelAllIndexDebounces()
  }

  private func cancelAllSaves() {
    for entry in saveEntries { entry.task?.cancel() }
    saveEntries.removeAll()
  }

  private func cancelAllIndexDebounces() {
    for entry in indexEntries { entry.task?.cancel() }
    indexEntries.removeAll()
  }

  // MARK: - Internals

  private func nextGeneration() -> UInt64 {
    generationCounter &+= 1
    return generationCounter
  }

  private func saveEntryIndex(ownedBy session: AnyObject) -> Int? {
    saveEntries.firstIndex { $0.owner === session }
  }

  private func indexEntryIndex(ownedBy session: AnyObject) -> Int? {
    indexEntries.firstIndex { $0.owner === session }
  }

  /// Drops entries whose window is gone. Their bodies capture the session weakly and would write
  /// nothing, and a vanished owner already answers `false` to every ownership question — so this is
  /// bookkeeping, not behaviour. The index side is deliberately NOT pruned this way: an orphaned
  /// index body is still owed a flush, which is the pre-existing semantics for orphaned debounces.
  private func pruneVanishedSaveOwners() {
    for entry in saveEntries where entry.owner == nil { entry.task?.cancel() }
    saveEntries.removeAll { $0.owner == nil }
  }

  /// Disarms the save bookkeeping BEFORE running the body, so the write that follows sees "nothing
  /// armed" rather than an ownership record its own timer has already consumed. Generation-guarded
  /// for the same reason the index side is: a timer that slipped past its cancellation check must not
  /// clear ownership a newer schedule has since recorded.
  private func runPendingSave(generation: UInt64, _ save: @MainActor () -> Void) {
    guard let index = saveEntries.firstIndex(where: { $0.generation == generation }) else { return }
    saveEntries.remove(at: index)
    save()
  }

  private func runPendingIndex(generation: UInt64) {
    guard let index = indexEntries.firstIndex(where: { $0.generation == generation }),
      let body = indexEntries[index].body
    else { return }
    discardIndexEntry(at: index)
    body()
  }

  /// Removes the entry FIRST and cancels its timer afterwards: the body must be unreachable before
  /// anyone runs it, which is what makes a flush exactly once even when the timer is mid-fire.
  private func discardIndexEntry(at index: Int) {
    let entry = indexEntries.remove(at: index)
    entry.task?.cancel()
  }
}
