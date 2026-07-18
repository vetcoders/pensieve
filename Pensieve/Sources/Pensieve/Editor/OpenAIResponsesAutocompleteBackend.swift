import Foundation

protocol AITextResponding: Sendable {
  var isConfigured: Bool { get }
  func respond(input: String, instructions: String) async throws -> String
}

/// The provider-safe Responses API seam shared by editor autocomplete and
/// dictation AI actions. Speech recognition stays in qube-ffi; provider text
/// requests live here because the vendored bridge hard-codes sampling and token
/// fields that current reasoning models reject or consume before emitting text.
/// CodeScribe's working contract omits both fields and constrains visible output
/// in the instruction instead.
final class OpenAIResponsesAutocompleteBackend: AutocompleteCompleting, AITextResponding,
  @unchecked Sendable
{
  typealias RequestSender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let environment: ProviderEnvironmentManaging
  private let sendRequest: RequestSender

  init(
    environment: ProviderEnvironmentManaging = ProcessProviderEnvironment(),
    sendRequest: RequestSender? = nil
  ) {
    self.environment = environment
    if let sendRequest {
      self.sendRequest = sendRequest
    } else {
      self.sendRequest = { request in
        try await OpenAIResponsesAutocompleteBackend.liveRequest(request)
      }
    }
  }

  var isConfigured: Bool {
    (try? resolveConfiguration()) != nil
  }

  func complete(prefix: String, maxTokens: UInt32) async throws -> String {
    try await respond(input: prefix, instructions: Self.instructions(maxTokens: maxTokens))
  }

  func respond(input: String, instructions: String) async throws -> String {
    let configuration = try resolveConfiguration()
    let body = ResponsesRequest(
      model: configuration.model,
      input: [
        InputItem(
          role: "user",
          content: [InputContent(type: "input_text", text: input)])
      ],
      instructions: instructions
    )

    var request = URLRequest(url: configuration.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey = configuration.apiKey {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      // CodeScribe deliberately sends both headers so OpenAI-compatible gateways
      // and OpenAI itself share one request path.
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    }

    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw VistaError.ModelError(
        msg: "completion request failed: could not encode the provider request")
    }

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await sendRequest(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
      throw CancellationError()
    } catch {
      throw VistaError.ModelError(
        msg: "completion request failed: \(Self.singleLine(error.localizedDescription))")
    }

    guard (200..<300).contains(response.statusCode) else {
      let detail = Self.providerErrorMessage(from: data)
      throw VistaError.ModelError(
        msg: "completion request failed: HTTP \(response.statusCode): \(detail)")
    }

    do {
      let decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
      guard let completion = decoded.completionText else {
        throw VistaError.ModelError(
          msg: "completion response parse failed: response did not contain output text")
      }
      return completion
    } catch let error as VistaError {
      throw error
    } catch {
      throw VistaError.ModelError(
        msg: "completion response parse failed: \(Self.singleLine(error.localizedDescription))")
    }
  }

  private func resolveConfiguration() throws -> Configuration {
    guard let endpointValue = firstNonEmptyValue(for: ProviderSettings.endpointEnvironmentKeys),
      let model = firstNonEmptyValue(for: ProviderSettings.modelEnvironmentKeys)
    else {
      throw VistaError.ModelError(
        msg: "completion LLM unavailable: endpoint and model are required")
    }

    let normalizedEndpoint = ProviderSettings.normalizeOpenAIResponsesEndpoint(endpointValue)
    guard
      let endpoint = URL(string: normalizedEndpoint),
      let scheme = endpoint.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    else {
      throw VistaError.ModelError(msg: "completion LLM unavailable: endpoint is invalid")
    }

    return Configuration(
      endpoint: endpoint,
      model: model,
      apiKey: firstNonEmptyValue(for: ProviderSettings.apiKeyEnvironmentKeys)
    )
  }

  private func firstNonEmptyValue(for keys: [String]) -> String? {
    for key in keys {
      guard
        let value = environment.value(forKey: key)?.trimmingCharacters(
          in: .whitespacesAndNewlines), !value.isEmpty
      else { continue }
      return value
    }
    return nil
  }

  private static func instructions(maxTokens: UInt32) -> String {
    """
    You are an inline editor autocomplete engine. Return only text to insert immediately after the \
    user's prefix. Use at most \(maxTokens) visible tokens. No quotes, Markdown fences, or explanation.
    """
  }

  private static func liveRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return (data, response)
  }

  private static func providerErrorMessage(from data: Data) -> String {
    if let envelope = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data),
      let message = envelope.error?.message, !message.isEmpty
    {
      return singleLine(message)
    }
    if let body = String(data: data, encoding: .utf8), !body.isEmpty {
      return String(singleLine(body).prefix(320))
    }
    return "provider rejected the request"
  }

  private static func singleLine(_ value: String) -> String {
    value.split(whereSeparator: \Character.isNewline).joined(separator: " ")
  }
}

extension OpenAIResponsesAutocompleteBackend {
  fileprivate struct Configuration {
    let endpoint: URL
    let model: String
    let apiKey: String?
  }

  fileprivate struct ResponsesRequest: Encodable {
    let model: String
    let input: [InputItem]
    let instructions: String
  }

  fileprivate struct InputItem: Encodable {
    let role: String
    let content: [InputContent]
  }

  fileprivate struct InputContent: Encodable {
    let type: String
    let text: String
  }

  fileprivate struct ResponsesResponse: Decodable {
    let outputText: String?
    let output: [OutputItem]?

    enum CodingKeys: String, CodingKey {
      case outputText = "output_text"
      case output
    }

    var completionText: String? {
      if let outputText, !outputText.isEmpty { return outputText }
      return output?
        .flatMap { $0.content ?? [] }
        .first { $0.type == "output_text" && !($0.text ?? "").isEmpty }?
        .text
    }
  }

  fileprivate struct OutputItem: Decodable {
    let content: [OutputContent]?
  }

  fileprivate struct OutputContent: Decodable {
    let type: String?
    let text: String?
  }

  fileprivate struct ProviderErrorEnvelope: Decodable {
    let error: ProviderError?
  }

  fileprivate struct ProviderError: Decodable {
    let message: String?
  }
}
