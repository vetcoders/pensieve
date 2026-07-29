import Foundation

@MainActor
final class Autosaver {
  static let shared = Autosaver()

  private let saveDelayNanoseconds: UInt64
  private let indexDelayNanoseconds: UInt64
  private var saveTask: Task<Void, Never>?
  private var indexTask: Task<Void, Never>?
  /// The armed index-debounce BODY, kept next to its timer so the work can be run NOW instead of
  /// only when the sleep elapses. Cleared the instant the body runs — by the timer or by a flush —
  /// so "flush the index debounce" means exactly once, never twice and never never.
  private var pendingIndex: (@MainActor () -> Void)?
  /// Which document the armed body would index, or `nil` when nothing is armed.
  ///
  /// This object is a process-wide SINGLETON holding at most one index debounce, and that debounce
  /// belongs to the LAST edited session — not necessarily the one asking. A closing window therefore
  /// cannot tell from `flushIndex()` alone whether it is landing its OWN unsaved text or somebody
  /// else's already-saved text, and the two need opposite treatment: another document's write is owed
  /// unconditionally, while its own must not reach the index until its file write has succeeded.
  /// `DocumentStore.savePendingChangesOnClose` reads this to tell the two apart.
  private(set) var armedIndexOwner: URL?
  /// Bumped by every arm/cancel/flush so a timer that already slipped past its cancellation check
  /// cannot run a body a newer schedule has since replaced.
  private var indexGeneration: UInt64 = 0
  /// One-way switch set by `quiesceForTermination()`. The app is going away; a debounce armed after
  /// that point could only fire during the quit's pumped run loop — after the drain has taken its
  /// snapshot — so arming is refused rather than raced.
  private(set) var isQuiescedForTermination = false

  init(saveDelayMilliseconds: UInt64 = 1_500, indexDelayMilliseconds: UInt64 = 5_000) {
    self.saveDelayNanoseconds = saveDelayMilliseconds * 1_000_000
    self.indexDelayNanoseconds = indexDelayMilliseconds * 1_000_000
  }

  func scheduleSave(_ save: @escaping @MainActor () -> Void) {
    guard !isQuiescedForTermination else { return }
    saveTask?.cancel()
    saveTask = Task { [saveDelayNanoseconds] in
      try? await Task.sleep(nanoseconds: saveDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        save()
      }
    }
  }

  func scheduleIndex(owner: URL?, _ index: @escaping @MainActor () -> Void) {
    guard !isQuiescedForTermination else { return }
    indexTask?.cancel()
    indexGeneration &+= 1
    let generation = indexGeneration
    pendingIndex = index
    armedIndexOwner = owner
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
    indexGeneration &+= 1
    indexTask?.cancel()
    indexTask = nil
    index?()
  }

  /// Termination command, issued by `TerminationSequence` in the flush phase: land the armed index
  /// write, then stop both debounces for good. After this returns nothing can re-arm — which is what
  /// makes the drain that follows a wait for a FINITE set of work rather than a moving target.
  func quiesceForTermination() {
    flushIndex()
    isQuiescedForTermination = true
    cancel()
  }

  func cancelSave() {
    saveTask?.cancel()
    saveTask = nil
  }

  func cancelIndex() {
    indexTask?.cancel()
    indexTask = nil
    pendingIndex = nil
    armedIndexOwner = nil
    indexGeneration &+= 1
  }

  func cancel() {
    cancelSave()
    cancelIndex()
  }

  private func runPendingIndex(generation: UInt64) {
    guard generation == indexGeneration, let index = pendingIndex else { return }
    pendingIndex = nil
    armedIndexOwner = nil
    index()
  }
}
