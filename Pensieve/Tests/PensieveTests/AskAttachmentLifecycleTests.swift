import CodescribeBridge
import XCTest

@testable import Pensieve

/// Lifecycle of the pending attachment set: Pensieve-owned staging for
/// clipboard images, honest rejection of what this wave cannot send, and
/// cleanup that never touches user-owned files.
@MainActor
final class AskAttachmentLifecycleTests: XCTestCase {
  private var scratch: URL!

  override func setUp() {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ask-attachment-lifecycle-\(UUID().uuidString)", isDirectory: true)
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

  private func writeFile(_ name: String, bytes: Int) throws -> URL {
    let url = scratch.appendingPathComponent(name)
    try Data(repeating: 0x89, count: bytes).write(to: url)
    return url
  }

  /// Run an async mutation that must throw, then inspect the error.
  private func assertRejects(
    operation: () async throws -> AskAttachment,
    inspect: (any Error) -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await operation()
      XCTFail("expected the attachment to be rejected", file: file, line: line)
    } catch {
      inspect(error)
    }
  }

  private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

  /// Staged-file deletion runs off the UI actor; poll for it instead of
  /// racing it.
  private func waitForFileRemoval(_ path: String, timeout: TimeInterval = 2.0) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !FileManager.default.fileExists(atPath: path) { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return !FileManager.default.fileExists(atPath: path)
  }

  func testStagedClipboardImageIsPensieveOwnedAndRemoveDeletesIt() async throws {
    let store = makeStore()
    let attachment = try await store.stageImage(data: pngBytes, fileExtension: "png")

    XCTAssertEqual(attachment.origin, .staged)
    XCTAssertEqual(
      attachment.url.deletingLastPathComponent().standardizedFileURL,
      store.stagingDirectory.standardizedFileURL,
      "clipboard images land in the Pensieve-owned staging root")
    XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.url.path))
    XCTAssertEqual(store.attachments.map(\.id), [attachment.id])

    store.remove(id: attachment.id)
    XCTAssertTrue(store.attachments.isEmpty)
    let removed = await waitForFileRemoval(attachment.url.path)
    XCTAssertTrue(
      removed,
      "removing a staged attachment deletes its Pensieve-owned copy")
  }

  func testExternalFileIsReferencedAndNeverDeleted() async throws {
    let store = makeStore()
    let external = try writeFile("figure.png", bytes: 32)
    let attachment = try await store.addExternal(url: external)

    XCTAssertEqual(attachment.origin, .external)
    XCTAssertEqual(attachment.url.standardizedFileURL, external.standardizedFileURL)

    store.remove(id: attachment.id)
    XCTAssertTrue(store.attachments.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: external.path),
      "an external path must survive removal from the pending set")
  }

  func testUnsupportedFormatsAreRejectedHonestly() async throws {
    let store = makeStore()
    let pdf = try writeFile("paper.pdf", bytes: 64)
    await assertRejects(
      operation: { try await store.addExternal(url: pdf) },
      inspect: { error in
        guard case AskAttachmentError.unsupportedFormat(let name) = error else {
          return XCTFail("expected unsupportedFormat, got \(error)")
        }
        XCTAssertEqual(name, "paper.pdf")
        XCTAssertTrue(
          error.localizedDescription.contains("images only"),
          "the message says what this wave sends: \(error.localizedDescription)")
      })
    await assertRejects(
      operation: { try await store.stageImage(data: pngBytes, fileExtension: "heic") },
      inspect: {
        error in
        guard case AskAttachmentError.unsupportedFormat = error else {
          return XCTFail("expected unsupportedFormat, got \(error)")
        }
      })
    XCTAssertTrue(store.attachments.isEmpty, "a rejected file never becomes a chip")
    let stagedContents =
      (try? FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path)) ?? []
    XCTAssertTrue(stagedContents.isEmpty, "an unsupported clipboard payload is not staged")
  }

  func testMissingEmptyAndOversizedFilesFailExplicitly() async throws {
    let store = makeStore()
    let missing = scratch.appendingPathComponent("gone.png")
    await assertRejects(
      operation: { try await store.addExternal(url: missing) },
      inspect: { error in
        guard case AskAttachmentError.missing(let name) = error else {
          return XCTFail("expected missing, got \(error)")
        }
        XCTAssertEqual(name, "gone.png")
      })

    let empty = try writeFile("empty.png", bytes: 0)
    await assertRejects(
      operation: { try await store.addExternal(url: empty) },
      inspect: { error in
        guard case AskAttachmentError.empty = error else {
          return XCTFail("expected empty, got \(error)")
        }
      })

    let oversized = try writeFile("huge.png", bytes: Int(AskAttachmentStore.maximumImageBytes) + 1)
    await assertRejects(
      operation: { try await store.addExternal(url: oversized) },
      inspect: { error in
        guard case AskAttachmentError.tooLarge(let name, let limit) = error else {
          return XCTFail("expected tooLarge, got \(error)")
        }
        XCTAssertEqual(name, "huge.png")
        XCTAssertEqual(limit, AskAttachmentStore.maximumImageBytes)
      })
    await assertRejects(
      operation: {
        try await store.stageImage(
          data: Data(repeating: 1, count: Int(AskAttachmentStore.maximumImageBytes) + 1),
          fileExtension: "png")
      },
      inspect: { error in
        guard case AskAttachmentError.tooLarge = error else {
          return XCTFail("expected tooLarge, got \(error)")
        }
      })
    XCTAssertTrue(store.attachments.isEmpty)
  }

  func testOverCountIsRejectedBeforeAnythingElse() async throws {
    let store = makeStore()
    for _ in 0..<AskAttachmentStore.maximumAttachments {
      _ = try await store.stageImage(data: pngBytes, fileExtension: "png")
    }
    XCTAssertEqual(store.attachments.count, AskAttachmentStore.maximumAttachments)
    await assertRejects(
      operation: { try await store.stageImage(data: pngBytes, fileExtension: "png") },
      inspect: {
        error in
        guard case AskAttachmentError.tooMany(let count, let limit) = error else {
          return XCTFail("expected tooMany, got \(error)")
        }
        XCTAssertEqual(count, AskAttachmentStore.maximumAttachments + 1)
        XCTAssertEqual(limit, AskAttachmentStore.maximumAttachments)
      })
    XCTAssertEqual(store.attachments.count, AskAttachmentStore.maximumAttachments)
  }

  func testValidateForSendCatchesAFileThatVanishedAfterAdding() async throws {
    let store = makeStore()
    let external = try writeFile("volatile.png", bytes: 16)
    _ = try await store.addExternal(url: external)
    try FileManager.default.removeItem(at: external)

    let pending = store.attachments
    do {
      try await Task.detached(priority: .userInitiated) {
        try AskAttachmentStore.validateForSend(pending)
      }.value
      XCTFail("expected the vanished file to fail validation")
    } catch {
      guard case AskAttachmentError.missing(let name) = error else {
        return XCTFail("expected missing, got \(error)")
      }
      XCTAssertEqual(name, "volatile.png")
    }
  }

  /// Send-time validation stats files, so it must refuse the UI actor
  /// outright; the threads reach it only through a detached executor.
  func testValidateForSendRefusesTheMainThread() {
    XCTAssertTrue(Thread.isMainThread)
    XCTAssertThrowsError(try AskAttachmentStore.validateForSend([])) { error in
      guard case CsError.Agent(let message) = error else {
        return XCTFail("expected a main-thread refusal, got \(error)")
      }
      XCTAssertTrue(message.contains("off the main thread"), message)
    }
  }

  func testReleaseSentDeletesOnlyStagedCopiesAndIgnoresUnknownIDs() async throws {
    let store = makeStore()
    let staged = try await store.stageImage(data: pngBytes, fileExtension: "png")
    let externalURL = try writeFile("kept.png", bytes: 16)
    let external = try await store.addExternal(url: externalURL)
    let stagedPath = staged.url.path

    store.releaseSent(ids: [staged.id, external.id, UUID()])
    XCTAssertTrue(store.attachments.isEmpty)
    let removed = await waitForFileRemoval(stagedPath)
    XCTAssertTrue(removed, "a sent staged copy is deleted")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: externalURL.path),
      "a sent external file is unreferenced, never deleted")
  }

  func testReleaseSentKeepsAttachmentsThatWereNotSent() async throws {
    let store = makeStore()
    let sent = try await store.stageImage(data: pngBytes, fileExtension: "png")
    let pending = try await store.stageImage(data: pngBytes, fileExtension: "png")

    store.releaseSent(ids: [sent.id])
    XCTAssertEqual(store.attachments.map(\.id), [pending.id])
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: pending.url.path),
      "an unsent staged copy stays for the next send")
  }

  /// Genuine owner destruction retires exactly this store's Pensieve-owned
  /// staged copies (off main); an external reference is never a file we own
  /// and must survive untouched.
  func testOwnerDestructionRetiresOnlyItsStagedCopies() async throws {
    var store: AskAttachmentStore? = makeStore()
    let staged = try await store!.stageImage(data: pngBytes, fileExtension: "png")
    let externalURL = try writeFile("keep.png", bytes: 16)
    _ = try await store!.addExternal(url: externalURL)
    let stagedPath = staged.url.path
    XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPath))

    store = nil
    let removed = await waitForFileRemoval(stagedPath)
    XCTAssertTrue(
      removed,
      "destroying the owner retires its still-pending staged copy")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: externalURL.path),
      "an external file is referenced, never owned — it survives")
  }

  /// A removed-then-released staged copy is not double-tracked: after
  /// `remove`, owner destruction has nothing left to retire.
  func testRemovedStagedCopyIsNotRetiredTwice() async throws {
    var store: AskAttachmentStore? = makeStore()
    let staged = try await store!.stageImage(data: pngBytes, fileExtension: "png")
    let stagedPath = staged.url.path
    store!.remove(id: staged.id)
    let removed = await waitForFileRemoval(stagedPath)
    XCTAssertTrue(removed)
    XCTAssertTrue(store!.stagedTracker.drain().isEmpty, "removal already untracked it")
    store = nil
  }
}
