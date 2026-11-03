import CodescribeBridge
import Darwin
import Synchronization
import XCTest

@testable import Pensieve

/// Delivery of attachments through both scoped Ask lanes: validated images
/// reach the provider seam with their exact paths, failures keep the user's
/// input, and a completed send consumes its attachments exactly once.
@MainActor
final class AskAttachmentDeliveryTests: XCTestCase {
  private var scratch: URL!

  override func setUp() {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ask-attachment-delivery-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: scratch)
    scratch = nil
  }

  private func makeStore() -> AskAttachmentStore {
    AskAttachmentStore(
      stagingDirectory: scratch.appendingPathComponent("staging", isDirectory: true))
  }

  private func makeDocumentThread(
    agent: any CodescribeAgentStreaming, store: AskAttachmentStore
  ) -> DocumentAskThread {
    DocumentAskThread(id: UUID(), agent: agent, attachmentStore: store)
  }

  private func makeWorkspaceHost() -> WorkspaceToolHost {
    WorkspaceToolHost(
      search: { _, _ in #"{"matches":[]}"# },
      containsPath: { _ in false },
      readFile: { _ in throw CsError.Agent(msg: "no files in this fixture") })
  }

  private func waitUntil(
    timeout: TimeInterval = 2.0, predicate: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
  }

  /// Staged-file deletion runs off the UI actor; poll for it instead of
  /// racing it.
  private func waitForFileRemoval(_ path: String) async -> Bool {
    await waitUntil { !FileManager.default.fileExists(atPath: path) }
  }

  // MARK: Document lane

  func testDocumentSendDeliversExactPathsAndConsumesAttachments() async throws {
    let agent = RecordingAttachmentAgent()
    let store = makeStore()
    let thread = makeDocumentThread(agent: agent, store: store)
    let attachment = try await store.stageImage(
      data: Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png")
    let stagedPath = attachment.url.path
    thread.draft = "What does this sketch say?"

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let completed = await waitUntil { thread.phase == .completed }
    XCTAssertTrue(completed, "stream should complete")

    XCTAssertEqual(agent.attachmentSends.count, 1)
    XCTAssertEqual(agent.attachmentSends.first?.text, "What does this sketch say?")
    XCTAssertEqual(agent.attachmentSends.first?.threadId, thread.id.uuidString.lowercased())
    XCTAssertEqual(
      agent.attachmentSends.first?.paths, [stagedPath],
      "the provider seam receives the exact validated path")
    XCTAssertEqual(agent.plainSends, 0, "an attachment send uses the attachment entrypoint")
    let userTurn = try XCTUnwrap(thread.turns.first { $0.role == .user })
    XCTAssertEqual(
      userTurn.attachmentIDs, [attachment.id],
      "the sent turn carries the exact attachment IDs")
    XCTAssertTrue(
      store.attachments.isEmpty, "a completed send consumes its attachments")
    let stagedRemoved = await waitForFileRemoval(stagedPath)
    XCTAssertTrue(
      stagedRemoved,
      "the staged copy is released after the successful send")
    XCTAssertEqual(thread.draft, "")
    XCTAssertNil(thread.lastError)
  }

  func testDocumentSendWithoutAttachmentsKeepsThePlainEntrypoint() async throws {
    let agent = RecordingAttachmentAgent()
    let thread = makeDocumentThread(agent: agent, store: makeStore())
    thread.draft = "Plain question."

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let completed = await waitUntil { thread.phase == .completed }
    XCTAssertTrue(completed)

    XCTAssertEqual(agent.plainSends, 1)
    XCTAssertEqual(agent.attachmentSends.count, 0)
    XCTAssertEqual(thread.turns.first { $0.role == .user }?.attachmentIDs, [])
  }

  func testInvalidAttachmentFailsBeforeSendAndKeepsDraftAndAttachments() async throws {
    let agent = RecordingAttachmentAgent()
    let store = makeStore()
    let thread = makeDocumentThread(agent: agent, store: store)
    let external = scratch.appendingPathComponent("volatile.png")
    try Data([0x89, 0x50]).write(to: external)
    _ = try await store.addExternal(url: external)
    try FileManager.default.removeItem(at: external)
    thread.draft = "Read this figure."

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let settled = await waitUntil { thread.phase != .streaming }
    XCTAssertTrue(settled, "the failed turn should settle")

    guard case .failed(let message) = thread.phase else {
      return XCTFail("expected a failed phase, got \(thread.phase)")
    }
    XCTAssertTrue(message.contains("volatile.png"), "names the missing file: \(message)")
    XCTAssertEqual(agent.attachmentSends.count, 0, "nothing reaches the provider seam")
    XCTAssertEqual(agent.plainSends, 0)
    XCTAssertEqual(thread.draft, "Read this figure.", "a failed send keeps the draft")
    XCTAssertEqual(store.attachments.count, 1, "a failed send keeps the attachments")
  }

  func testProviderFailureKeepsDraftAndAttachments() async throws {
    let agent = RecordingAttachmentAgent()
    agent.failure = CsError.Agent(msg: "The selected model can't read images.")
    let store = makeStore()
    let thread = makeDocumentThread(agent: agent, store: store)
    _ = try await store.stageImage(data: Data([0x89, 0x50]), fileExtension: "png")
    thread.draft = "Caption this."

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let settled = await waitUntil { thread.phase != .streaming }
    XCTAssertTrue(settled)

    guard case .failed(let message) = thread.phase else {
      return XCTFail("expected a failed phase, got \(thread.phase)")
    }
    XCTAssertTrue(message.contains("read images"), "surfaces the honest error: \(message)")
    XCTAssertEqual(agent.attachmentSends.count, 1, "the seam was reached before failing")
    XCTAssertEqual(thread.draft, "Caption this.")
    XCTAssertEqual(store.attachments.count, 1)
    XCTAssertEqual(thread.turns.first { $0.role == .user }?.attachmentIDs.count, 1)
  }

  /// A failure reported through listener events (no throw) is still a failed
  /// send: draft and attachments stay, nothing is released.
  func testEventOnlyFailureKeepsDraftAndAttachments() async throws {
    let agent = RecordingAttachmentAgent()
    agent.eventFailure = "provider stream stalled"
    let store = makeStore()
    let thread = makeDocumentThread(agent: agent, store: store)
    _ = try await store.stageImage(data: Data([0x89, 0x50]), fileExtension: "png")
    thread.draft = "Describe the diagram."

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let settled = await waitUntil { thread.phase != .streaming }
    XCTAssertTrue(settled)

    guard case .failed(let message) = thread.phase else {
      return XCTFail("expected a failed phase, got \(thread.phase)")
    }
    XCTAssertEqual(message, "provider stream stalled")
    XCTAssertEqual(thread.draft, "Describe the diagram.")
    XCTAssertEqual(store.attachments.count, 1, "an event-only failure releases nothing")
  }

  func testEngineWithoutAttachmentSupportFailsExplicitly() async throws {
    let agent = PlainOnlyAgent()
    let store = makeStore()
    let thread = makeDocumentThread(agent: agent, store: store)
    _ = try await store.stageImage(data: Data([0x89, 0x50]), fileExtension: "png")
    thread.draft = "Look at this."

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let settled = await waitUntil { thread.phase != .streaming }
    XCTAssertTrue(settled)

    guard case .failed(let message) = thread.phase else {
      return XCTFail("expected a failed phase, got \(thread.phase)")
    }
    XCTAssertTrue(
      message.contains("cannot send attachments"),
      "an engine without the seam says so instead of dropping the images: \(message)")
    XCTAssertEqual(agent.plainSends, 0, "attachments never take the text-only path")
    XCTAssertEqual(store.attachments.count, 1)
    XCTAssertEqual(thread.draft, "Look at this.")
  }

  func testSuccessfulSendPreventsDuplicateSubmission() async throws {
    let agent = RecordingAttachmentAgent()
    let store = makeStore()
    let thread = makeDocumentThread(agent: agent, store: store)
    _ = try await store.stageImage(data: Data([0x89, 0x50]), fileExtension: "png")
    thread.draft = "First."

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let firstCompleted = await waitUntil { thread.phase == .completed }
    XCTAssertTrue(firstCompleted)
    thread.draft = "Second."
    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let secondCompleted = await waitUntil { agent.plainSends == 1 }
    XCTAssertTrue(secondCompleted)

    XCTAssertEqual(agent.attachmentSends.count, 1, "the consumed images are not resent")
    XCTAssertEqual(agent.plainSends, 1, "the follow-up send is text-only")
    let userTurns = thread.turns.filter { $0.role == .user }
    XCTAssertEqual(userTurns.count, 2)
    XCTAssertEqual(userTurns[0].attachmentIDs.count, 1, "the first turn carries the images")
    XCTAssertEqual(userTurns[1].attachmentIDs.count, 0, "the second cannot resubmit them")
  }

  // MARK: Workspace lane

  func testWorkspaceSendDeliversAttachmentsThroughTheScopedSeam() async throws {
    let agent = RecordingWorkspaceAttachmentAgent()
    let store = makeStore()
    let thread = WorkspaceAskThread(
      identity: WorkspaceIdentity.make(rootURL: scratch, bookmarkData: nil),
      makeAgent: { agent }, attachmentStore: store)
    let attachment = try await store.stageImage(
      data: Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png")
    let stagedPath = attachment.url.path

    XCTAssertTrue(
      thread.send(
        text: "Summarize the screenshot.", host: makeWorkspaceHost(),
        provider: .apiKey("sk-test")))
    let settled = await waitUntil { !thread.isStreaming }
    XCTAssertTrue(settled)

    XCTAssertEqual(agent.attachmentSends.count, 1)
    XCTAssertEqual(agent.attachmentSends.first?.paths, [stagedPath])
    XCTAssertEqual(agent.attachmentSends.first?.threadId, thread.id.uuidString.lowercased())
    XCTAssertEqual(agent.plainSends, 0)
    XCTAssertEqual(thread.turns.first { $0.role == .user }?.attachmentIDs, [attachment.id])
    XCTAssertTrue(store.attachments.isEmpty)
    let stagedRemoved = await waitForFileRemoval(stagedPath)
    XCTAssertTrue(stagedRemoved)
    XCTAssertNil(thread.lastError)
  }

  /// Workspace lane: an event-only failure preserves the user's input too.
  func testWorkspaceEventOnlyFailureKeepsDraftAndAttachments() async throws {
    let agent = RecordingWorkspaceAttachmentAgent()
    agent.eventFailure = "workspace provider stream stalled"
    let store = makeStore()
    let thread = WorkspaceAskThread(
      identity: WorkspaceIdentity.make(rootURL: scratch, bookmarkData: nil),
      makeAgent: { agent }, attachmentStore: store)
    _ = try await store.stageImage(data: Data([0x89, 0x50]), fileExtension: "png")

    XCTAssertTrue(
      thread.send(
        text: "Inspect the screenshot.", host: makeWorkspaceHost(),
        provider: .apiKey("sk-test")))
    let settled = await waitUntil { !thread.isStreaming }
    XCTAssertTrue(settled)

    XCTAssertEqual(thread.lastError, "workspace provider stream stalled")
    XCTAssertEqual(thread.draft, "Inspect the screenshot.")
    XCTAssertEqual(store.attachments.count, 1, "an event-only failure releases nothing")
  }

  func testWorkspaceSendWithoutAttachmentsKeepsThePlainEntrypoint() async throws {
    let agent = RecordingWorkspaceAttachmentAgent()
    let thread = WorkspaceAskThread(
      identity: WorkspaceIdentity.make(rootURL: scratch, bookmarkData: nil),
      makeAgent: { agent }, attachmentStore: makeStore())

    XCTAssertTrue(
      thread.send(text: "Plain question.", host: makeWorkspaceHost(), provider: .apiKey("k")))
    let settled = await waitUntil { !thread.isStreaming }
    XCTAssertTrue(settled)

    XCTAssertEqual(agent.plainSends, 1)
    XCTAssertEqual(agent.attachmentSends.count, 0)
  }

  func testCancelledSendKeepsDraftAndAttachmentsPending() async throws {
    let agent = SuspendedAttachmentAgent()
    let store = makeStore()
    let thread = makeDocumentThread(agent: agent, store: store)
    _ = try await store.stageImage(data: Data([0x89, 0x50]), fileExtension: "png")
    thread.draft = "Hold this thought."

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let started = await waitUntil { agent.started }
    XCTAssertTrue(started)
    thread.cancel()
    agent.finish()

    XCTAssertEqual(thread.phase, .idle)
    XCTAssertEqual(thread.draft, "Hold this thought.", "a stopped turn keeps the draft")
    XCTAssertEqual(store.attachments.count, 1, "a stopped turn keeps the attachments pending")
    XCTAssertEqual(
      agent.attachmentSends, 1, "the seam was entered but nothing was released or delivered")
  }

  /// Stop while validation is suspended must never start a provider request:
  /// the finished validator re-checks cancellation and generation first. The
  /// regression observes the send task's actual completion — not a yield
  /// budget — so a not-yet-resumed validator cannot pass vacuously.
  func testCancelDuringValidationNeverStartsTheProviderAndKeepsInput() async throws {
    let agent = RecordingAttachmentAgent()
    let gate = ValidationGate()
    let store = makeStore()
    store.validationProbe = { await gate.wait() }
    let thread = makeDocumentThread(agent: agent, store: store)
    _ = try await store.stageImage(data: Data([0x89, 0x50]), fileExtension: "png")
    thread.draft = "Pause here."

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let sentTask = thread.lastSendTask
    XCTAssertNotNil(sentTask, "the send task exists before Stop")
    let probing = await waitUntil { gate.entered }
    XCTAssertTrue(probing, "validation should be in flight before the Stop")
    thread.cancel()
    gate.open()
    await sentTask?.value

    XCTAssertEqual(agent.attachmentSends.count, 0, "no attachment request after Stop")
    XCTAssertEqual(agent.plainSends, 0, "no provider request at all after Stop")
    XCTAssertEqual(thread.phase, .idle)
    XCTAssertEqual(thread.draft, "Pause here.", "Stop keeps the draft")
    XCTAssertEqual(store.attachments.count, 1, "Stop keeps the attachments pending")
  }

  /// Workspace lane: the same cancel-during-validation boundary, observed
  /// through the send task's completion.
  func testWorkspaceCancelDuringValidationNeverStartsTheProviderAndKeepsInput() async throws {
    let agent = RecordingWorkspaceAttachmentAgent()
    let gate = ValidationGate()
    let store = makeStore()
    store.validationProbe = { await gate.wait() }
    let thread = WorkspaceAskThread(
      identity: WorkspaceIdentity.make(rootURL: scratch, bookmarkData: nil),
      makeAgent: { agent }, attachmentStore: store)
    _ = try await store.stageImage(data: Data([0x89, 0x50]), fileExtension: "png")

    XCTAssertTrue(
      thread.send(
        text: "Pause here too.", host: makeWorkspaceHost(), provider: .apiKey("sk-test")))
    let sentTask = thread.lastSendTask
    XCTAssertNotNil(sentTask, "the send task exists before Stop")
    let probing = await waitUntil { gate.entered }
    XCTAssertTrue(probing, "validation should be in flight before the Stop")
    thread.cancel()
    gate.open()
    await sentTask?.value

    XCTAssertEqual(agent.attachmentSends.count, 0, "no attachment request after Stop")
    XCTAssertEqual(agent.plainSends, 0, "no provider request at all after Stop")
    XCTAssertFalse(thread.isStreaming)
    XCTAssertEqual(thread.draft, "Pause here too.", "Stop keeps the draft")
    XCTAssertEqual(store.attachments.count, 1, "Stop keeps the attachments pending")
  }

  // MARK: Vendored payload

  /// The scoped attachment entrypoints must exist in the delivered library,
  /// independently of any Swift-level test double.
  func testVendoredLibraryExposesScopedAttachmentEntrypoints() throws {
    let package = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for profile in ["debug", "release"] {
      let library = package.appendingPathComponent(
        "Vendor/codescribe-ffi/\(profile)/libcodescribe_ffi.dylib")
      let handle = try XCTUnwrap(dlopen(library.path, RTLD_LAZY | RTLD_LOCAL))
      defer { dlclose(handle) }
      XCTAssertNotNil(
        dlsym(
          handle,
          "uniffi_codescribe_ffi_fn_method_codescribeagent_stream_document_with_attachments"),
        "document attachment entrypoint missing from \(profile) payload")
      XCTAssertNotNil(
        dlsym(
          handle,
          "uniffi_codescribe_ffi_fn_method_codescribeagent_stream_workspace_with_attachments"),
        "workspace attachment entrypoint missing from \(profile) payload")
    }
  }
}

// MARK: - Test doubles

/// Controllable suspension for send-time validation: `wait` blocks until
/// `open`, so a test can cancel precisely while validation is in flight.
private final class ValidationGate: @unchecked Sendable {
  private struct State: Sendable {
    var entered = false
    var release: (@Sendable () -> Void)?
  }

  private let state = Mutex(State())
  var entered: Bool { state.withLock { $0.entered } }

  func wait() async {
    await withCheckedContinuation { continuation in
      state.withLock {
        $0.entered = true
        $0.release = { continuation.resume() }
      }
    }
  }

  func open() {
    let release = state.withLock { current -> (@Sendable () -> Void)? in
      let pending = current.release
      current.release = nil
      return pending
    }
    release?()
  }
}

/// Records both entrypoints; an injected failure simulates a provider-side
/// rejection after validation (e.g. the vision gate).
private final class RecordingAttachmentAgent: CodescribeAgentAttachmentStreaming,
  @unchecked Sendable
{
  struct AttachmentSend: Equatable, Sendable {
    var text: String
    var threadId: String
    var paths: [String]
  }

  private struct State: Sendable {
    var attachmentSends: [AttachmentSend] = []
    var plainSends: Int = 0
  }

  private let state = Mutex(State())
  private let failureBox = Mutex<(any Error)?>(nil)
  private let eventFailureBox = Mutex<String?>(nil)

  var attachmentSends: [AttachmentSend] { state.withLock { $0.attachmentSends } }
  var plainSends: Int { state.withLock { $0.plainSends } }
  var failure: (any Error)? {
    get { failureBox.withLock { $0 } }
    set { failureBox.withLock { $0 = newValue } }
  }
  var eventFailure: String? {
    get { eventFailureBox.withLock { $0 } }
    set { eventFailureBox.withLock { $0 = newValue } }
  }

  func streamDocument(
    text: String, threadId: String, document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock { $0.plainSends += 1 }
    listener.onTextDone(text: "plain reply")
    listener.onDone()
    return "plain reply"
  }

  func streamDocumentWithAttachments(
    text: String, threadId: String, attachments: [CsAttachment], document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock {
      $0.attachmentSends.append(
        AttachmentSend(text: text, threadId: threadId, paths: attachments.map(\.path)))
    }
    if let failure { throw failure }
    if let eventFailure { listener.onError(message: eventFailure) }
    listener.onTextDone(text: "image reply")
    listener.onDone()
    return "image reply"
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}

/// Only the pre-attachment protocol: the thread must refuse explicitly rather
/// than silently dropping the images onto the text-only path.
private final class PlainOnlyAgent: CodescribeAgentStreaming, @unchecked Sendable {
  private let sends = Mutex(0)
  var plainSends: Int { sends.withLock { $0 } }

  func streamDocument(
    text: String, threadId: String, document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    sends.withLock { $0 += 1 }
    return "plain"
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}

/// Workspace twin of `RecordingAttachmentAgent`.
private final class RecordingWorkspaceAttachmentAgent: WorkspaceAgentAttachmentStreaming,
  @unchecked Sendable
{
  private struct State: Sendable {
    var attachmentSends: [RecordingAttachmentAgent.AttachmentSend] = []
    var plainSends: Int = 0
  }

  private let state = Mutex(State())
  private let eventFailureBox = Mutex<String?>(nil)
  var attachmentSends: [RecordingAttachmentAgent.AttachmentSend] {
    state.withLock { $0.attachmentSends }
  }
  var plainSends: Int { state.withLock { $0.plainSends } }
  var eventFailure: String? {
    get { eventFailureBox.withLock { $0 } }
    set { eventFailureBox.withLock { $0 = newValue } }
  }

  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock { $0.plainSends += 1 }
    listener.onTextDone(text: "plain workspace reply")
    listener.onDone()
    return "plain workspace reply"
  }

  func streamWorkspaceWithAttachments(
    text: String, threadId: String, attachments: [CsAttachment], workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock {
      $0.attachmentSends.append(
        .init(text: text, threadId: threadId, paths: attachments.map(\.path)))
    }
    if let eventFailure { listener.onError(message: eventFailure) }
    listener.onTextDone(text: "workspace image reply")
    listener.onDone()
    return "workspace image reply"
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}

/// Never replies until told; proves cancel keeps the user's input.
private final class SuspendedAttachmentAgent: CodescribeAgentAttachmentStreaming,
  @unchecked Sendable
{
  private struct State: Sendable {
    var attachmentSends: Int = 0
    var continuation: CheckedContinuation<String, Never>?
  }

  private let state = Mutex(State())
  var started: Bool { state.withLock { $0.continuation != nil } }
  var attachmentSends: Int { state.withLock { $0.attachmentSends } }

  func streamDocument(
    text: String, threadId: String, document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    await withCheckedContinuation { continuation in
      state.withLock { $0.continuation = continuation }
    }
  }

  func streamDocumentWithAttachments(
    text: String, threadId: String, attachments: [CsAttachment], document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock { $0.attachmentSends += 1 }
    return await withCheckedContinuation { continuation in
      state.withLock { $0.continuation = continuation }
    }
  }

  func finish() {
    let continuation = state.withLock { current -> CheckedContinuation<String, Never>? in
      let pending = current.continuation
      current.continuation = nil
      return pending
    }
    continuation?.resume(returning: "late")
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}
