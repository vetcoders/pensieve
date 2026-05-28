import Foundation

@MainActor
final class Autosaver {
  static let shared = Autosaver()

  private let saveDelayNanoseconds: UInt64
  private let indexDelayNanoseconds: UInt64
  private var saveTask: Task<Void, Never>?
  private var indexTask: Task<Void, Never>?

  init(saveDelayMilliseconds: UInt64 = 1_500, indexDelayMilliseconds: UInt64 = 5_000) {
    self.saveDelayNanoseconds = saveDelayMilliseconds * 1_000_000
    self.indexDelayNanoseconds = indexDelayMilliseconds * 1_000_000
  }

  func scheduleSave(_ save: @escaping @MainActor () -> Void) {
    saveTask?.cancel()
    saveTask = Task { [saveDelayNanoseconds] in
      try? await Task.sleep(nanoseconds: saveDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        save()
      }
    }
  }

  func scheduleIndex(_ index: @escaping @MainActor () -> Void) {
    indexTask?.cancel()
    indexTask = Task { [indexDelayNanoseconds] in
      try? await Task.sleep(nanoseconds: indexDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        index()
      }
    }
  }

  func cancelSave() {
    saveTask?.cancel()
    saveTask = nil
  }

  func cancelIndex() {
    indexTask?.cancel()
    indexTask = nil
  }

  func cancel() {
    cancelSave()
    cancelIndex()
  }
}
