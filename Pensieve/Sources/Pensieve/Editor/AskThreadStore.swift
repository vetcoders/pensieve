import Combine
import Foundation
import Synchronization

/// UUID is the only conversation key. Context is captured when a UUID is born,
/// never replaced when a view asks for the same conversation again.
@MainActor
final class AskThreadStore: ObservableObject {
  private var threads: [UUID: AskThread] = [:]
  private let makeAgent: @Sendable () -> any AskAgentStreaming
  private let history: AskHistoryStore?
  private var createdAt: [UUID: Date] = [:]
  private let writer: AskHistoryWriter?
  private var saveRevisions: [UUID: Int] = [:]
  private var appliedRevisions: [UUID: Int] = [:]
  private var refusedHistoryIDs: Set<UUID> = []
  private var pendingSaves: [UUID: Task<Void, Never>] = [:]
  @Published private(set) var historyRecords: [AskHistoryRecord] = []
  @Published private(set) var historyError: String?

  init(
    makeAgent: @escaping @Sendable () -> any AskAgentStreaming = { DeferredCodescribeAgent() },
    history: AskHistoryStore? = nil
  ) {
    self.makeAgent = makeAgent
    self.history = history
    self.writer = history.map(AskHistoryWriter.init)
    refreshHistory()
  }

  func thread(for id: UUID, context: AskContext = .empty) -> AskThread {
    if let existing = threads[id] { return existing }
    if let history {
      do {
        if let record = try history.load(id: id) { return restore(record) }
      } catch {
        refusedHistoryIDs.insert(id)
        reportHistoryError(error)
      }
    }
    let thread = AskThread(id: id, context: context, makeAgent: makeAgent)
    register(thread, createdAt: Date())
    persist(thread)
    return thread
  }

  @discardableResult
  func newThread(context: AskContext = .empty) -> AskThread {
    thread(for: UUID(), context: context)
  }

  func existingThread(for id: UUID) -> AskThread? { threads[id] }

  @discardableResult
  func restore(_ record: AskHistoryRecord) -> AskThread {
    if let existing = threads[record.id] { return existing }
    let thread = AskThread(id: record.id, context: record.context, makeAgent: makeAgent)
    thread.restore(turns: record.turns, draft: record.draft)
    register(thread, createdAt: record.createdAt)
    return thread
  }

  @discardableResult
  func cancelAll() -> Bool {
    for thread in threads.values { thread.cancel() }
    return flushHistory()
  }

  /// The panel owner flushes before shutdown; coalescing avoids synchronous
  /// SQLite writes for every keystroke or individual streaming token.
  @discardableResult
  func flushHistory() -> Bool {
    for task in pendingSaves.values { task.cancel() }
    pendingSaves.removeAll()
    var saved = true
    for thread in threads.values { if !persist(thread) { saved = false } }
    return saved
  }

  func reportHistoryError(_ error: any Error) {
    historyError = "Ask history could not be saved or restored: \(error.localizedDescription)"
  }

  private func register(_ thread: AskThread, createdAt: Date) {
    threads[thread.id] = thread
    self.createdAt[thread.id] = createdAt
    thread.onChange = { [weak self] thread in self?.scheduleSave(thread) }
    objectWillChange.send()
  }

  private func scheduleSave(_ thread: AskThread) {
    guard let writer, !refusedHistoryIDs.contains(thread.id) else { return }
    // A fixed checkpoint interval persists continuous streaming too; a new
    // delta coalesces into the pending snapshot instead of postponing it.
    guard pendingSaves[thread.id] == nil else { return }
    let revision = nextRevision(for: thread.id)
    pendingSaves[thread.id] = Task { @MainActor [weak self, weak thread] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self, let thread else { return }
      self.pendingSaves.removeValue(forKey: thread.id)
      let record = self.snapshot(thread)
      do {
        let update = try await Task.detached(priority: .utility) {
          try writer.save(record, revision: revision)
        }.value
        self.accept(update)
      } catch { self.reportHistoryError(error) }
    }
  }

  private func nextRevision(for id: UUID) -> Int {
    let revision = (saveRevisions[id] ?? 0) + 1
    saveRevisions[id] = revision
    return revision
  }

  private func snapshot(_ thread: AskThread) -> AskHistoryRecord {
    AskHistoryRecord(
      id: thread.id, context: thread.context, turns: thread.turns, draft: thread.draft,
      createdAt: createdAt[thread.id] ?? Date(), updatedAt: Date())
  }

  @discardableResult
  private func persist(_ thread: AskThread) -> Bool {
    guard !refusedHistoryIDs.contains(thread.id) else { return false }
    guard let writer else { return historyError == nil }
    do {
      // Explicit flushes wait for earlier background writes and supersede any
      // older snapshot that arrives afterward. Shutdown has a durable receipt.
      accept(try writer.save(snapshot(thread), revision: nextRevision(for: thread.id)))
      return true
    } catch {
      reportHistoryError(error)
      return false
    }
  }

  private func accept(_ update: AskHistoryWriter.Update?) {
    guard let update,
      update.revision > (appliedRevisions[update.record.id] ?? 0)
    else { return }
    appliedRevisions[update.record.id] = update.revision
    historyRecords.removeAll { $0.id == update.record.id }
    historyRecords.append(update.record)
    historyRecords.sort { first, second in
      if first.updatedAt != second.updatedAt { return first.updatedAt > second.updatedAt }
      return first.id.uuidString < second.id.uuidString
    }
  }

  private func refreshHistory() {
    guard let history else { return }
    do { historyRecords = try history.list() } catch { reportHistoryError(error) }
  }
}

/// Coalesced token/draft writes run off MainActor. A flush uses the same lock,
/// so a late old snapshot cannot overwrite the final shutdown snapshot.
private final class AskHistoryWriter: Sendable {
  struct Update: Sendable {
    let revision: Int
    let record: AskHistoryRecord
  }
  private struct State: Sendable {
    var revisions: [UUID: Int] = [:]
  }
  private let history: AskHistoryStore
  private let state = Mutex(State())

  init(history: AskHistoryStore) { self.history = history }

  func save(_ record: AskHistoryRecord, revision: Int) throws -> Update? {
    try state.withLock { current in
      guard revision > (current.revisions[record.id] ?? 0) else { return nil }
      try history.save(record)
      current.revisions[record.id] = revision
      return Update(revision: revision, record: record)
    }
  }
}
