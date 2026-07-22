import Foundation
import XCTest

@testable import Pensieve

final class AIProviderRuntimeTests: XCTestCase {
  func testKeychainSecretLoadsLazilyOnlyWhenAIRequestStarts() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ASSISTIVE_ENDPOINT": "https://api.openai.com/v1/responses",
      "LLM_ASSISTIVE_MODEL": "gpt-test",
    ])
    let keychain = StubProviderKeychain(value: "saved-key")
    let recorder = RequestRecorder()
    let runtime = AIProviderRuntime(environment: environment, keychain: keychain) { request in
      recorder.record(request)
      return (
        Data(#"{"output_text":" next"}"#.utf8),
        Self.response(for: request, statusCode: 200)
      )
    }

    XCTAssertTrue(runtime.isConfigured)
    XCTAssertEqual(keychain.loadCount, 0)
    _ = try await runtime.complete(
      context: AutocompleteContext(beforeCursor: "text", afterCursor: ""), maxTokens: 16)

    XCTAssertEqual(keychain.loadCount, 1)
    XCTAssertEqual(recorder.request?.value(forHTTPHeaderField: "Authorization"), "Bearer saved-key")
  }

  func testRewriteUsesExplicitIntentPayloadAndReturnsRangeScopedCandidate() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ASSISTIVE_ENDPOINT": "https://api.openai.com/v1/responses",
      "LLM_ASSISTIVE_MODEL": "gpt-test",
      "LLM_ASSISTIVE_API_KEY": "key",
    ])
    let recorder = RequestRecorder()
    let runtime = AIProviderRuntime(environment: environment) { request in
      recorder.record(request)
      return (
        Data(#"{"id":"resp-rewrite","output_text":"Improved text."}"#.utf8),
        Self.response(for: request, statusCode: 200)
      )
    }

    let candidate = try await runtime.rewrite(
      context: RewriteContext(
        text: "Rough text.", rangeLocation: 12, rangeLength: 11, documentRevision: 9),
      intent: .improve,
      session: DocumentAISession(documentID: "doc"))

    XCTAssertEqual(candidate.text, "Improved text.")
    XCTAssertEqual(candidate.replacementRange, NSRange(location: 12, length: 11))
    XCTAssertEqual(candidate.documentRevision, 9)
    let body = try requestJSON(try XCTUnwrap(recorder.request))
    XCTAssertTrue((body["instructions"] as? String)?.contains("Markdown editing engine") == true)
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    let content = try XCTUnwrap(input.last?["content"] as? [[String: Any]])
    let payloadText = try XCTUnwrap(content.first?["text"] as? String)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any])
    XCTAssertEqual(payload["task"] as? String, "rewrite_document_selection")
    XCTAssertEqual(payload["rewrite_intent"] as? String, "improve")
    XCTAssertEqual(payload["selection"] as? String, "Rough text.")
  }

  func testCustomRewriteCarriesInstructionInPayloadAndKeepsRuntimeGuard() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ASSISTIVE_ENDPOINT": "https://api.openai.com/v1/responses",
      "LLM_ASSISTIVE_MODEL": "gpt-test",
      "LLM_ASSISTIVE_API_KEY": "key",
    ])
    let recorder = RequestRecorder()
    let runtime = AIProviderRuntime(
      environment: environment,
      rewritePromptStore: RewritePromptStore(baseDirectory: FileManager.default.temporaryDirectory)
    ) { request in
      recorder.record(request)
      return (
        Data(#"{"output_text":"A tiny rhyme."}"#.utf8),
        Self.response(for: request, statusCode: 200)
      )
    }

    _ = try await runtime.rewrite(
      context: RewriteContext(
        text: "Plain prose.", rangeLocation: 0, rangeLength: 12, documentRevision: 1),
      intent: .custom("Turn this into a tiny rhyme."),
      session: DocumentAISession(documentID: "doc"))

    let body = try requestJSON(try XCTUnwrap(recorder.request))
    let instructions = try XCTUnwrap(body["instructions"] as? String)
    XCTAssertTrue(instructions.hasPrefix(RewritePromptStore.guardPrefix))
    XCTAssertTrue(instructions.contains("Turn this into a tiny rhyme."))
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    let content = try XCTUnwrap(input.last?["content"] as? [[String: Any]])
    let payloadText = try XCTUnwrap(content.first?["text"] as? String)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any])
    XCTAssertEqual(payload["rewrite_intent"] as? String, "custom")
    XCTAssertEqual(payload["custom_instruction"] as? String, "Turn this into a tiny rhyme.")
    XCTAssertEqual(payload["selection"] as? String, "Plain prose.")
  }
  func testOpenAIUsesCommittedResponseIDAndFallsBackExactlyOnceOn404() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ASSISTIVE_PROVIDER": "openai-responses",
      "LLM_ASSISTIVE_ENDPOINT": "https://api.openai.com/v1/responses",
      "LLM_ASSISTIVE_MODEL": "gpt-test",
      "LLM_ASSISTIVE_API_KEY": "key",
    ])
    let recorder = RequestRecorder()
    let sender = SequencedRequestSender(responses: [
      (404, #"{"error":{"message":"not found"}}"#),
      (200, #"{"id":"resp-new","output_text":" continuation"}"#),
    ])
    let runtime = AIProviderRuntime(environment: environment) { request in
      recorder.record(request)
      return try sender.send(request)
    }
    let fingerprint = ProviderFingerprint(
      shape: .openAIResponses,
      endpoint: "https://api.openai.com/v1/responses",
      model: "gpt-test")
    let session = DocumentAISession(
      documentID: "doc",
      providerFingerprint: fingerprint,
      acceptedTurns: [AcceptedAITurn(input: "old-input", output: "old-output")],
      continuation: .openAI(previousResponseID: "resp-expired"))

    let candidate = try await runtime.complete(
      context: AutocompleteContext(beforeCursor: "New", afterCursor: " tail"),
      maxTokens: 32,
      session: session,
      documentRevision: 7,
      replacementRange: NSRange(location: 3, length: 0))

    XCTAssertEqual(recorder.requests.count, 2)
    let first = try requestJSON(recorder.requests[0])
    XCTAssertEqual(first["previous_response_id"] as? String, "resp-expired")
    let second = try requestJSON(recorder.requests[1])
    XCTAssertNil(second["previous_response_id"])
    XCTAssertEqual((second["input"] as? [[String: Any]])?.count, 3)
    XCTAssertTrue(candidate.invalidatedOpaqueContinuation)
    XCTAssertEqual(candidate.pendingContinuation, .openAI(previousResponseID: "resp-new"))
  }

  func testAnthropicReplaysAcceptedLedgerAndNeverUsesMessageIDAsContinuation() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ASSISTIVE_PROVIDER": "anthropic-messages",
      "LLM_ASSISTIVE_ENDPOINT": "https://api.anthropic.com/v1/messages",
      "LLM_ASSISTIVE_MODEL": "claude-test",
      "LLM_ANTHROPIC_API_KEY": "key",
    ])
    let recorder = RequestRecorder()
    let runtime = AIProviderRuntime(environment: environment) { request in
      recorder.record(request)
      return (
        Data(#"{"id":"msg_123","content":[{"type":"text","text":" next"}]}"#.utf8),
        Self.response(for: request, statusCode: 200)
      )
    }
    let session = DocumentAISession(
      documentID: "doc",
      providerFingerprint: ProviderFingerprint(
        shape: .anthropicMessages,
        endpoint: "https://api.anthropic.com/v1/messages",
        model: "claude-test"),
      acceptedTurns: [AcceptedAITurn(input: "one", output: "two")])

    let candidate = try await runtime.complete(
      context: AutocompleteContext(beforeCursor: "three", afterCursor: ""),
      maxTokens: 16,
      session: session,
      documentRevision: 1,
      replacementRange: NSRange(location: 5, length: 0))

    let body = try requestJSON(try XCTUnwrap(recorder.request))
    XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 3)
    XCTAssertEqual(candidate.pendingContinuation, .none)
  }
  func testRequestUsesCodeScribeResponsesContractWithoutUnsupportedSamplingOrTokenCap()
    async throws
  {
    let environment = StubProviderEnvironment([
      "LLM_ASSISTIVE_ENDPOINT": "https://api.example.test/v1",
      "LLM_ASSISTIVE_MODEL": "gpt-5",
      "LLM_ASSISTIVE_API_KEY": "test-key",
    ])
    let recorder = RequestRecorder()
    let responseData = Data(
      #"{"output":[{"type":"message","content":[{"type":"output_text","text":" useful continuation"}]}]}"#
        .utf8)
    let backend = OpenAIResponsesAutocompleteBackend(environment: environment) { request in
      recorder.record(request)
      return (responseData, Self.response(for: request, statusCode: 200))
    }

    let completion = try await backend.complete(
      context: AutocompleteContext(
        beforeCursor: "A useful question?", afterCursor: "\n\n## Next section"),
      maxTokens: 32)

    XCTAssertEqual(completion, " useful continuation")
    let request = try XCTUnwrap(recorder.request)
    XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")

    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["model"] as? String, "gpt-5")
    XCTAssertNil(json["temperature"])
    XCTAssertNil(json["max_output_tokens"])
    let instructions = try XCTUnwrap(json["instructions"] as? String)
    XCTAssertTrue(instructions.contains("not a chat assistant"))
    XCTAssertTrue(instructions.contains("questions"))
    XCTAssertTrue(instructions.contains("at most 32 visible tokens"))
    let input = try XCTUnwrap(json["input"] as? [[String: Any]])
    let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
    let payloadText = try XCTUnwrap(content.first?["text"] as? String)
    let payloadData = try XCTUnwrap(payloadText.data(using: .utf8))
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
    XCTAssertEqual(payload["task"] as? String, "continue_author_document")
    XCTAssertEqual(payload["before_cursor"] as? String, "A useful question?")
    XCTAssertEqual(payload["after_cursor"] as? String, "\n\n## Next section")
  }

  func testProviderErrorIsTypedAndReducedToOneLine() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ENDPOINT": "https://api.example.test/v1/responses",
      "LLM_MODEL": "gpt-5",
      "LLM_API_KEY": "test-key",
    ])
    let responseData = Data(
      #"{"error":{"message":"Unsupported parameter: temperature\nremove it"}}"#.utf8)
    let backend = OpenAIResponsesAutocompleteBackend(environment: environment) { request in
      (responseData, Self.response(for: request, statusCode: 400))
    }

    do {
      _ = try await backend.complete(
        context: AutocompleteContext(beforeCursor: "prefix", afterCursor: ""), maxTokens: 32)
      XCTFail("expected a typed provider failure")
    } catch VistaError.ModelError(let message) {
      XCTAssertEqual(
        message,
        "completion request failed: HTTP 400: Unsupported parameter: temperature remove it")
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testCancelledURLRequestRemainsCancellation() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ENDPOINT": "https://api.example.test/v1/responses",
      "LLM_MODEL": "gpt-5",
      "LLM_API_KEY": "test-key",
    ])
    let backend = OpenAIResponsesAutocompleteBackend(environment: environment) { _ in
      throw URLError(.cancelled)
    }

    do {
      _ = try await backend.complete(
        context: AutocompleteContext(beforeCursor: "prefix", afterCursor: ""), maxTokens: 32)
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected: cancellation must not become a visible autocomplete failure.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testAnthropicMessagesUsesNativeHeadersBodyAndParser() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ASSISTIVE_PROVIDER": "anthropic-messages",
      "LLM_ASSISTIVE_ENDPOINT": "https://api.anthropic.com/v1/messages",
      "LLM_ASSISTIVE_MODEL": "claude-sonnet-4-5",
      "LLM_ANTHROPIC_API_KEY": "anthropic-key",
    ])
    let recorder = RequestRecorder()
    let responseData = Data(
      #"{"content":[{"type":"text","text":" dalszy ciąg"}],"stop_reason":"end_turn"}"#.utf8)
    let backend = AIProviderRuntime(environment: environment) { request in
      recorder.record(request)
      return (responseData, Self.response(for: request, statusCode: 200))
    }

    let completion = try await backend.complete(
      context: AutocompleteContext(beforeCursor: "Czy to ma sens?", afterCursor: " Tak."),
      maxTokens: 24)

    XCTAssertEqual(completion, " dalszy ciąg")
    let request = try XCTUnwrap(recorder.request)
    XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let body = try XCTUnwrap(request.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-5")
    XCTAssertEqual(json["max_tokens"] as? Int, 24)
    XCTAssertTrue((json["system"] as? String)?.contains("not a chat assistant") == true)
  }

  func testDictationResponseUsesAnthropicMessagesRuntime() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ASSISTIVE_PROVIDER": "anthropic-messages",
      "LLM_ASSISTIVE_ENDPOINT": "https://api.anthropic.com/v1/messages",
      "LLM_ASSISTIVE_MODEL": "claude-sonnet-4-5",
      "LLM_ANTHROPIC_API_KEY": "anthropic-key",
    ])
    let recorder = RequestRecorder()
    let responseData = Data(
      #"{"content":[{"type":"text","text":"Poprawiony tekst."}],"stop_reason":"end_turn"}"#.utf8)
    let runtime = AIProviderRuntime(environment: environment) { request in
      recorder.record(request)
      return (responseData, Self.response(for: request, statusCode: 200))
    }

    let output = try await runtime.respond(
      input: "surowa transkrypcja", instructions: "Correct grammar only.")

    XCTAssertEqual(output, "Poprawiony tekst.")
    let body = try XCTUnwrap(recorder.request?.httpBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["system"] as? String, "Correct grammar only.")
    let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
    let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
    XCTAssertEqual(content.first?["text"] as? String, "surowa transkrypcja")
  }

  private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
  }

  private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
  }
}

private struct StubProviderEnvironment: ProviderEnvironmentManaging {
  let values: [String: String]

  init(_ values: [String: String]) {
    self.values = values
  }

  func value(forKey key: String) -> String? { values[key] }
  func setValue(_ value: String, forKey key: String) throws {}
  func removeValue(forKey key: String) throws {}
}

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequests: [URLRequest] = []

  func record(_ request: URLRequest) {
    lock.lock()
    storedRequests.append(request)
    lock.unlock()
  }

  var request: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return storedRequests.last
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return storedRequests
  }
}

private final class SequencedRequestSender: @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [(Int, String)]

  init(responses: [(Int, String)]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    lock.lock()
    defer { lock.unlock() }
    guard !responses.isEmpty else { throw URLError(.badServerResponse) }
    let next = responses.removeFirst()
    return (
      Data(next.1.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: next.0, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}

private final class StubProviderKeychain: ProviderAPIKeyStoring, @unchecked Sendable {
  private let lock = NSLock()
  private let value: String?
  private var loads = 0

  init(value: String?) {
    self.value = value
  }

  func loadAPIKey() throws -> String? {
    lock.withLock { loads += 1 }
    return value
  }

  func storeAPIKey(_ apiKey: String) throws {}
  func deleteAPIKey() throws {}

  var loadCount: Int { lock.withLock { loads } }
}
