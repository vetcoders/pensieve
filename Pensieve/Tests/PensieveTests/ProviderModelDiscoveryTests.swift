import Foundation
import XCTest

@testable import Pensieve

final class ProviderModelDiscoveryTests: XCTestCase {
  func testOpenAIDiscoversNormalizesAndCachesModels() async throws {
    let defaults = makeDiscoveryDefaults()
    let recorder = ModelRequestRecorder()
    let discovery = ProviderModelDiscovery(defaults: defaults) { request in
      recorder.record(request)
      let data = Data(#"{"data":[{"id":"gpt-z"},{"id":"gpt-a"},{"id":"gpt-a"}]}"#.utf8)
      return (data, Self.response(for: request, statusCode: 200))
    }

    let result = try await discovery.discover(
      shape: .openAIResponses,
      endpoint: "https://api.openai.com/v1/responses",
      apiKey: "openai-key")

    XCTAssertEqual(result.source, .fresh)
    XCTAssertEqual(result.models.map(\.id), ["gpt-a", "gpt-z"])
    let request = try XCTUnwrap(recorder.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-key")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "openai-key")
  }

  func testOpenAICompatibleLocalDiscoveryAllowsKeylessEndpoint() async throws {
    let defaults = makeDiscoveryDefaults()
    let recorder = ModelRequestRecorder()
    let discovery = ProviderModelDiscovery(defaults: defaults) { request in
      recorder.record(request)
      return (
        Data(#"{"data":[{"id":"local-model"}]}"#.utf8),
        Self.response(for: request, statusCode: 200)
      )
    }

    let result = try await discovery.discover(
      shape: .openAIResponses,
      endpoint: "http://127.0.0.1:11434/v1/responses",
      apiKey: "")

    XCTAssertEqual(result.models.map(\.id), ["local-model"])
    XCTAssertNil(recorder.requests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testAnthropicDiscoveryFollowsPaginationWithNativeHeaders() async throws {
    let defaults = makeDiscoveryDefaults()
    let recorder = ModelRequestRecorder()
    let discovery = ProviderModelDiscovery(defaults: defaults) { request in
      recorder.record(request)
      let body: String
      if request.url?.query?.contains("after_id=model-1") == true {
        body =
          #"{"data":[{"id":"model-2","display_name":"Claude Two"}],"has_more":false,"last_id":"model-2"}"#
      } else {
        body =
          #"{"data":[{"id":"model-1","display_name":"Claude One"}],"has_more":true,"last_id":"model-1"}"#
      }
      return (Data(body.utf8), Self.response(for: request, statusCode: 200))
    }

    let result = try await discovery.discover(
      shape: .anthropicMessages,
      endpoint: "https://api.anthropic.com/v1/messages",
      apiKey: "anthropic-key")

    XCTAssertEqual(result.models.map(\.id), ["model-1", "model-2"])
    XCTAssertEqual(recorder.requests.count, 2)
    XCTAssertEqual(recorder.requests.last?.url?.query, "after_id=model-1")
    for request in recorder.requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
  }

  func testDiscoveryFallsBackToLastGoodCache() async throws {
    let defaults = makeDiscoveryDefaults()
    let successful = ProviderModelDiscovery(defaults: defaults) { request in
      let data = Data(#"{"data":[{"id":"gpt-cached"}]}"#.utf8)
      return (data, Self.response(for: request, statusCode: 200))
    }
    _ = try await successful.discover(
      shape: .openAIResponses,
      endpoint: "https://api.openai.com/v1/responses",
      apiKey: "key")

    let offline = ProviderModelDiscovery(defaults: defaults) { _ in
      throw URLError(.notConnectedToInternet)
    }
    let result = try await offline.discover(
      shape: .openAIResponses,
      endpoint: "https://api.openai.com/v1/responses",
      apiKey: "key")

    guard case .cache = result.source else { return XCTFail("expected cached result") }
    XCTAssertEqual(result.models.map(\.id), ["gpt-cached"])
  }

  private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
  }

  private func makeDiscoveryDefaults() -> UserDefaults {
    makeEphemeralDefaults(prefix: "ProviderModelDiscoveryTests")
  }
}

private final class ModelRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequests: [URLRequest] = []

  func record(_ request: URLRequest) {
    lock.lock()
    storedRequests.append(request)
    lock.unlock()
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return storedRequests
  }
}
