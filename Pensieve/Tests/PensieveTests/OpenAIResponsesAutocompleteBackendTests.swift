import Foundation
import XCTest

@testable import Pensieve

final class OpenAIResponsesAutocompleteBackendTests: XCTestCase {
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

    let completion = try await backend.complete(prefix: "A useful prefix", maxTokens: 32)

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
    XCTAssertTrue((json["instructions"] as? String)?.contains("at most 32 visible tokens") == true)
  }

  func testProviderErrorIsTypedAndReducedToOneLine() async throws {
    let environment = StubProviderEnvironment([
      "LLM_ENDPOINT": "https://api.example.test/v1/responses",
      "LLM_MODEL": "gpt-5",
    ])
    let responseData = Data(
      #"{"error":{"message":"Unsupported parameter: temperature\nremove it"}}"#.utf8)
    let backend = OpenAIResponsesAutocompleteBackend(environment: environment) { request in
      (responseData, Self.response(for: request, statusCode: 400))
    }

    do {
      _ = try await backend.complete(prefix: "prefix", maxTokens: 32)
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
    ])
    let backend = OpenAIResponsesAutocompleteBackend(environment: environment) { _ in
      throw URLError(.cancelled)
    }

    do {
      _ = try await backend.complete(prefix: "prefix", maxTokens: 32)
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected: cancellation must not become a visible autocomplete failure.
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
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
  private var storedRequest: URLRequest?

  func record(_ request: URLRequest) {
    lock.lock()
    storedRequest = request
    lock.unlock()
  }

  var request: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return storedRequest
  }
}
