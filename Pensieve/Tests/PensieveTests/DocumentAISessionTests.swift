import Foundation
import XCTest

@testable import Pensieve

final class DocumentAISessionTests: XCTestCase {
  func testAcceptanceRequiresMatchingDocumentAndBoundsLedger() {
    let fingerprint = ProviderFingerprint(
      shape: .openAIResponses,
      endpoint: "https://api.openai.com/v1/responses",
      model: "gpt-test")
    var session = DocumentAISession(documentID: "doc-a")

    session.accept(candidate(documentID: "doc-b", fingerprint: fingerprint, output: "wrong"))
    XCTAssertTrue(session.acceptedTurns.isEmpty)

    for index in 0..<(DocumentAISession.maximumTurns + 3) {
      session.accept(
        candidate(documentID: "doc-a", fingerprint: fingerprint, output: "out-\(index)"))
    }
    XCTAssertEqual(session.acceptedTurns.count, DocumentAISession.maximumTurns)
    XCTAssertEqual(session.acceptedTurns.last?.output, "out-14")
  }

  func testProviderSwitchPreservesLedgerButClearsOpaqueContinuation() {
    let openAI = ProviderFingerprint(
      shape: .openAIResponses, endpoint: "https://openai.test/v1/responses", model: "gpt")
    let anthropic = ProviderFingerprint(
      shape: .anthropicMessages,
      endpoint: "https://anthropic.test/v1/messages",
      model: "claude")
    var session = DocumentAISession(documentID: "doc")
    session.accept(candidate(documentID: "doc", fingerprint: openAI, output: "accepted"))
    guard case .openAI = session.continuation else {
      return XCTFail("expected committed OpenAI continuation")
    }

    session.prepare(for: anthropic)

    XCTAssertEqual(session.acceptedTurns.map(\.output), ["accepted"])
    XCTAssertEqual(session.continuation, .none)
    XCTAssertEqual(session.providerFingerprint, anthropic)
  }

  func testStorePersistsOnlyHashedIdentityAndOpaqueContinuation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DocumentAISessionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sessions.json")
    let store = DocumentAISessionStore(fileURL: file)
    let fingerprint = ProviderFingerprint(
      shape: .openAIResponses, endpoint: "https://provider.test/v1/responses", model: "model")
    var session = DocumentAISession(documentID: "doc")
    session.accept(
      candidate(
        documentID: "doc", fingerprint: fingerprint, output: "secret-author-text",
        responseID: "resp-opaque"))
    store.save(session)

    let restored = DocumentAISessionStore(fileURL: file).session(for: "doc")
    XCTAssertTrue(restored.acceptedTurns.isEmpty)
    XCTAssertEqual(restored.continuation, session.continuation)
    var prepared = restored
    prepared.prepare(for: fingerprint)
    XCTAssertEqual(prepared.continuation, session.continuation)
    var mismatched = DocumentAISessionStore(fileURL: file).session(for: "doc")
    mismatched.prepare(
      for: ProviderFingerprint(
        shape: .anthropicMessages,
        endpoint: "https://api.anthropic.com/v1/messages",
        model: "other-model"))
    XCTAssertEqual(mismatched.continuation, .none)
    let persisted = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(persisted.contains("doc"))
    XCTAssertFalse(persisted.contains("input"))
    XCTAssertFalse(persisted.contains("secret-author-text"))
    XCTAssertFalse(persisted.contains("provider.test"))
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
  }

  func testStoreDeletesLegacyPlaintextSessionFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "DocumentAISessionLegacyTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("sessions.json")
    let legacy =
      #"{"file:///private/note.md":{"acceptedTurns":["#
      + #"{"input":"private","output":"text"}]}}"#
    try Data(legacy.utf8).write(to: file)

    let restored = DocumentAISessionStore(fileURL: file).session(for: "file:///private/note.md")

    XCTAssertTrue(restored.acceptedTurns.isEmpty)
    XCTAssertEqual(restored.continuation, .none)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  private func candidate(
    documentID: String,
    fingerprint: ProviderFingerprint,
    output: String,
    responseID: String? = nil
  ) -> AICandidate {
    AICandidate(
      documentID: documentID,
      text: output,
      providerInput: "input",
      providerFingerprint: fingerprint,
      pendingContinuation: .openAI(previousResponseID: responseID ?? "resp-\(output)"),
      invalidatedOpaqueContinuation: false,
      documentRevision: 1,
      replacementRange: NSRange(location: 3, length: 0))
  }
}
