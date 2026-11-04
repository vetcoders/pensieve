import Foundation
import Synchronization
import XCTest

@testable import Pensieve

final class AIProviderRuntimeTests: XCTestCase {
  func testRewriteRejectsUnfinishedResponseEvenWhenItContainsText() async throws {
    for status in ["failed", "incomplete", "cancelled", "in_progress", "queued"] {
      let runtime = AIProviderRuntime(
        environment: StubProviderEnvironment([
          "LLM_ASSISTIVE_ENDPOINT": "https://api.openai.com/v1/responses",
          "LLM_ASSISTIVE_MODEL": "gpt-test",
          "LLM_ASSISTIVE_API_KEY": "test-key",
        ])
      ) { request in
        let data = try JSONSerialization.data(withJSONObject: [
          "status": status, "id": "resp-unfinished", "output_text": "Only the first sentence.",
        ])
        return (data, Self.response(for: request, statusCode: 200))
      }
      do {
        _ = try await runtime.rewrite(
          context: RewriteContext(
            text: "A complete document.", rangeLocation: 0, rangeLength: 20, documentRevision: 1),
          intent: .improve,
          session: DocumentAISession(documentID: "doc"))
        XCTFail("\(status) text must not be offered as a complete replacement")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(status))
      }
    }
  }

  func testResponsePreservesEveryOutputTextPartInOrder() async throws {
    let runtime = AIProviderRuntime(
      environment: StubProviderEnvironment([
        "LLM_ASSISTIVE_ENDPOINT": "https://api.openai.com/v1/responses",
        "LLM_ASSISTIVE_MODEL": "gpt-test",
        "LLM_ASSISTIVE_API_KEY": "test-key",
      ])
    ) { request in
      let data = Data(
        #"{"status":"completed","output":[{"content":[{"type":"output_text","text":"First"},{"type":"output_text","text":" paragraph."}]},{"content":[{"type":"output_text","text":" Second paragraph."}]}]}"#
          .utf8)
      return (data, Self.response(for: request, statusCode: 200))
    }
    let text = try await runtime.respond(input: "Original document", instructions: "Improve it")
    XCTAssertEqual(text, "First paragraph. Second paragraph.")
  }

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
      "PENSIEVE_COMPLETION_PROVIDER": "anthropic-messages",
      "LLM_ASSISTIVE_PROVIDER": "xai-responses",
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

  func testCodexOAuthPrimaryTierStreamsAndAggregatesSSEWithoutAPIKey() async throws {
    let jwtClaims = try JSONSerialization.data(withJSONObject: [
      "https://api.openai.com/auth": ["chatgpt_account_id": "acct_codex_42"]
    ])
    let jwtPayload =
      jwtClaims.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let fakeJWT = "eyJhbGciOiJub25lIn0.\(jwtPayload).sig"
    let tokenJSON = """
      {"provider":"openai-responses","access_token":"codex-oauth-token","id_token":"\(fakeJWT)"}
      """
    let environment = StubProviderEnvironment([
      "LLM_OPENAI_ACCOUNT_TOKENS": tokenJSON
    ])
    let recorder = RequestRecorder()
    let sseBody = """
      event: response.created
      data: {"type":"response.created","response":{"id":"resp_codex_1"}}

      event: response.output_text.delta
      data: {"type":"response.output_text.delta","delta":" from"}

      event: response.output_text.delta
      data: {"type":"response.output_text.delta","delta":" codex"}

      event: response.completed
      data: {"type":"response.completed","response":{"id":"resp_codex_1","status":"completed"}}

      """
    let suite = "pensieve.tests.oauth-codex.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let runtime = AIProviderRuntime(
      environment: environment,
      laneChoiceSuiteName: suite
    ) { request in
      recorder.record(request)
      return (Data(sseBody.utf8), Self.response(for: request, statusCode: 200))
    }

    XCTAssertTrue(runtime.isConfigured)
    let completion = try await runtime.complete(
      context: AutocompleteContext(beforeCursor: "Hello", afterCursor: ""),
      maxTokens: 24)
    XCTAssertEqual(completion, " from codex")

    let request = try XCTUnwrap(recorder.request)
    XCTAssertEqual(
      request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"), "Bearer codex-oauth-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "acct_codex_42")
    XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
    XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "pensieve")
    let body = try requestJSON(request)
    XCTAssertEqual(body["model"] as? String, "gpt-5.4")
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["store"] as? Bool, false)
  }

  func testXAIGrokOAuthPrimaryTierCompletesOverResponsesEndpoint() async throws {
    let tokenJSON = #"{"provider":"xai-responses","access_token":"grok-oauth-token"}"#
    let environment = StubProviderEnvironment([
      "LLM_XAI_ACCOUNT_TOKENS": tokenJSON
    ])
    let recorder = RequestRecorder()
    let suite = "pensieve.tests.oauth-grok.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let runtime = AIProviderRuntime(
      environment: environment,
      laneChoiceSuiteName: suite
    ) { request in
      recorder.record(request)
      return (
        Data(#"{"id":"resp_grok","status":"completed","output_text":" from grok"}"#.utf8),
        Self.response(for: request, statusCode: 200)
      )
    }

    let completion = try await runtime.complete(
      context: AutocompleteContext(beforeCursor: "Hello", afterCursor: ""),
      maxTokens: 24)
    XCTAssertEqual(completion, " from grok")
    let request = try XCTUnwrap(recorder.request)
    XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/responses")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"), "Bearer grok-oauth-token")
    let body = try requestJSON(request)
    XCTAssertEqual(body["model"] as? String, "grok-4.6")
  }

  func testGoogleGeminiOAuthPrimaryTierUsesCloudCodeAssistEnvelopeAndSkipsThoughtParts()
    async throws
  {
    let tokenJSON = #"{"provider":"google-gemini","access_token":"gemini-oauth-token"}"#
    let environment = StubProviderEnvironment([
      "LLM_GOOGLE_ACCOUNT_TOKENS": tokenJSON
    ])
    let recorder = RequestRecorder()
    let ccaResponse = """
      {"response":{"candidates":[{"index":0,"content":{"parts":[{"text":"internal reasoning","thought":true},{"text":" from gemini"}]}}]}}
      """
    let suite = "pensieve.tests.oauth-gemini.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let runtime = AIProviderRuntime(
      environment: environment,
      laneChoiceSuiteName: suite
    ) { request in
      recorder.record(request)
      return (Data(ccaResponse.utf8), Self.response(for: request, statusCode: 200))
    }

    let completion = try await runtime.complete(
      context: AutocompleteContext(beforeCursor: "Hello", afterCursor: ""),
      maxTokens: 24)
    XCTAssertEqual(completion, " from gemini")
    let request = try XCTUnwrap(recorder.request)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://daily-cloudcode-pa.googleapis.com/v1internal:generateContent")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"), "Bearer gemini-oauth-token")
    let body = try requestJSON(request)
    XCTAssertEqual(body["project"] as? String, "rising-fact-p41fc")
    XCTAssertEqual(body["model"] as? String, "gemini-2.5-flash")
    XCTAssertEqual(body["userAgent"] as? String, "antigravity")
    XCTAssertEqual(body["requestType"] as? String, "agent")
  }

  func testCodescribeKeychainBundleV1Base64DecodesAllThreeOAuthProviders() throws {
    let rawBundle = """
      {"version":1,"keys":{"LLM_OPENAI_ACCOUNT_TOKENS":"{\\"access_token\\":\\"oa-tok\\"}","LLM_XAI_ACCOUNT_TOKENS":"{\\"access_token\\":\\"xai-tok\\"}","LLM_GOOGLE_ACCOUNT_TOKENS":"{\\"access_token\\":\\"gg-tok\\",\\"project_id\\":\\"proj-9\\"}"}}
      """
    let b64Bundle = "b64:\(Data(rawBundle.utf8).base64EncodedString())"
    let store = KeychainOAuthAccountTokenStore(
      allowSystemKeychain: true,
      keychainReader: { service, account in
        guard service == KeychainOAuthAccountTokenStore.codescribeService,
          account == KeychainOAuthAccountTokenStore.bundleAccount
        else { return nil }
        return b64Bundle
      })
    let env = StubProviderEnvironment([:])
    XCTAssertEqual(
      store.loadTokens(for: .openAIResponses, environment: env)?.accessToken, "oa-tok")
    XCTAssertEqual(
      store.loadTokens(for: .xAIResponses, environment: env)?.accessToken, "xai-tok")
    let google = try XCTUnwrap(store.loadTokens(for: .googleGemini, environment: env))
    XCTAssertEqual(google.accessToken, "gg-tok")
    XCTAssertEqual(google.projectID, "proj-9")
  }

  func testThreeTierChainFailsOverFromOAuthToLibraxisLocalToLibraxisCloudToOpenRouter()
    async throws
  {
    let environment = StubProviderEnvironment([
      "LLM_XAI_ACCOUNT_TOKENS": #"{"provider":"xai-responses","access_token":"grok-tok"}"#,
      "LIBRAXIS_API_KEY": "lx-key",
      "OPENROUTER_API_KEY": "or-key",
    ])
    let recorder = RequestRecorder()
    let sender = SequencedRequestSender(responses: [
      (503, #"{"error":{"message":"xAI unavailable"}}"#),
      (502, #"{"error":{"message":"dragon tunnel down"}}"#),
      (502, #"{"error":{"message":"libraxis cloud down"}}"#),
      (200, #"{"id":"resp_or","status":"completed","output_text":" from openrouter"}"#),
    ])
    let suite = "pensieve.tests.three-tier.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let runtime = AIProviderRuntime(
      environment: environment,
      includeDefaultFallbackChain: true,
      laneChoiceSuiteName: suite
    ) { request in
      recorder.record(request)
      return try sender.send(request)
    }

    let completion = try await runtime.complete(
      context: AutocompleteContext(beforeCursor: "Hello", afterCursor: ""),
      maxTokens: 24)
    XCTAssertEqual(completion, " from openrouter")
    XCTAssertEqual(recorder.requests.count, 4)
    XCTAssertEqual(recorder.requests[0].url?.absoluteString, "https://api.x.ai/v1/responses")
    XCTAssertEqual(
      recorder.requests[1].url?.absoluteString, "http://127.0.0.1:8100/v1/responses")
    let localBody = try requestJSON(recorder.requests[1])
    XCTAssertEqual(
      localBody["model"] as? String,
      "PocketAiHub/Qwen3.8-27B-Abliterated-MTPLX-Optimized-Speed")
    XCTAssertEqual(
      recorder.requests[2].url?.absoluteString, "https://api.libraxis.cloud/v1/responses")
    XCTAssertEqual(
      recorder.requests[3].url?.absoluteString, "https://openrouter.ai/api/v1/responses")
    XCTAssertEqual(
      recorder.requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
    let openRouterBody = try requestJSON(recorder.requests[3])
    XCTAssertEqual(openRouterBody["model"] as? String, "openai/gpt-5.4-mini")
  }

  func testOAuthRefreshesExpiredAccessTokenBeforeCompletionRequest() async throws {
    let expiredTokenJSON = """
      {"provider":"xai-responses","access_token":"expired-tok","refresh_token":"refresh-tok","expires_at_unix":100}
      """
    let environment = StubProviderEnvironment([
      "LLM_XAI_ACCOUNT_TOKENS": expiredTokenJSON
    ])
    let recorder = RequestRecorder()
    let sender = SequencedRequestSender(responses: [
      (200, #"{"access_token":"refreshed-grok-tok","expires_in":3600}"#),
      (200, #"{"id":"resp_refreshed","status":"completed","output_text":" refreshed output"}"#),
    ])
    let suite = "pensieve.tests.oauth-refresh.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let runtime = AIProviderRuntime(
      environment: environment,
      laneChoiceSuiteName: suite
    ) { request in
      recorder.record(request)
      return try sender.send(request)
    }

    let completion = try await runtime.complete(
      context: AutocompleteContext(beforeCursor: "Hello", afterCursor: ""),
      maxTokens: 16)
    XCTAssertEqual(completion, " refreshed output")
    XCTAssertEqual(recorder.requests.count, 2)
    XCTAssertEqual(
      recorder.requests[0].url?.absoluteString, "https://oes.x.ai/oauth2/token")
    XCTAssertEqual(
      recorder.requests[1].url?.absoluteString, "https://api.x.ai/v1/responses")
    XCTAssertEqual(
      recorder.requests[1].value(forHTTPHeaderField: "Authorization"),
      "Bearer refreshed-grok-tok")
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

private final class RequestRecorder: Sendable {
  private struct State: Sendable {
    var storedRequests: [URLRequest] = []
  }
  private let state = Mutex(State())

  func record(_ request: URLRequest) {
    state.withLock { state in
      state.storedRequests.append(request)
    }
  }

  var request: URLRequest? {
    return state.withLock { state in
      return state.storedRequests.last
    }
  }

  var requests: [URLRequest] {
    return state.withLock { state in
      return state.storedRequests
    }
  }
}

private final class SequencedRequestSender: Sendable {
  private let responses: Mutex<[(Int, String)]>
  init(responses: [(Int, String)]) { self.responses = Mutex(responses) }
  func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let next = try responses.withLock { responses in
      guard !responses.isEmpty else { throw URLError(.badServerResponse) }
      return responses.removeFirst()
    }
    return (
      Data(next.1.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: next.0,
        httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}

private final class StubProviderKeychain: ProviderAPIKeyStoring, Sendable {
  private struct State: Sendable {
    var loads = 0
  }
  private let state = Mutex(State())
  private let value: String?

  init(value: String?) {
    self.value = value
  }

  func loadAPIKey() throws -> String? {
    state.withLock { state in state.loads += 1 }
    return value
  }

  func storeAPIKey(_ apiKey: String) throws {}
  func deleteAPIKey() throws {}

  var loadCount: Int { state.withLock { state in state.loads } }
}
