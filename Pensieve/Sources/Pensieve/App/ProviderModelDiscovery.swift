import Foundation

struct DiscoveredProviderModel: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let displayName: String
}

struct ProviderModelDiscoveryResult: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case fresh
    case cache(reason: String)
  }

  let models: [DiscoveredProviderModel]
  let source: Source
}

enum ProviderModelDiscoveryError: LocalizedError, Equatable {
  case apiKeyRequired
  case invalidEndpoint
  case request(String)
  case response(status: Int, detail: String)
  case invalidResponse(String)

  var errorDescription: String? {
    switch self {
    case .apiKeyRequired:
      return "Add an API key before discovering models."
    case .invalidEndpoint:
      return "The provider endpoint cannot be used for model discovery."
    case .request(let detail):
      return "Model discovery failed: \(detail)"
    case .response(let status, let detail):
      return "Model discovery failed (HTTP \(status)): \(detail)"
    case .invalidResponse(let detail):
      return "The provider returned an invalid model list: \(detail)"
    }
  }
}

protocol ProviderModelDiscovering: Sendable {
  func discover(
    shape: CompletionProviderShape,
    endpoint: String,
    apiKey: String
  ) async throws -> ProviderModelDiscoveryResult
}

final class ProviderModelDiscovery: ProviderModelDiscovering, @unchecked Sendable {
  typealias RequestSender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let defaults: UserDefaults
  private let sendRequest: RequestSender
  private let cachePrefix = "Pensieve.providerModelDiscovery.lastGood"

  init(
    defaults: UserDefaults = .standard,
    sendRequest: RequestSender? = nil
  ) {
    self.defaults = defaults
    self.sendRequest =
      sendRequest ?? { request in
        try await Self.liveRequest(request)
      }
  }

  func discover(
    shape: CompletionProviderShape,
    endpoint: String,
    apiKey: String
  ) async throws -> ProviderModelDiscoveryResult {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if shape == .anthropicMessages, key.isEmpty {
      throw ProviderModelDiscoveryError.apiKeyRequired
    }
    do {
      let models = try await fetch(shape: shape, endpoint: endpoint, apiKey: key)
      try Task.checkCancellation()
      let normalized = Self.normalize(models)
      if let data = try? JSONEncoder().encode(normalized) {
        defaults.set(data, forKey: cacheKey(for: shape, endpoint: endpoint))
      }
      return ProviderModelDiscoveryResult(models: normalized, source: .fresh)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if let cached = cachedModels(for: shape, endpoint: endpoint), !cached.isEmpty {
        return ProviderModelDiscoveryResult(
          models: cached,
          source: .cache(reason: error.localizedDescription))
      }
      throw error
    }
  }

  private func fetch(
    shape: CompletionProviderShape,
    endpoint: String,
    apiKey: String
  ) async throws -> [DiscoveredProviderModel] {
    guard let modelsURL = Self.modelsURL(for: endpoint) else {
      throw ProviderModelDiscoveryError.invalidEndpoint
    }
    switch shape {
    case .openAIResponses:
      var request = URLRequest(url: modelsURL)
      request.timeoutInterval = 15
      if !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      }
      let data = try await responseData(for: request)
      do {
        return try JSONDecoder().decode(OpenAIModelsResponse.self, from: data).data.map {
          DiscoveredProviderModel(id: $0.id, displayName: $0.id)
        }
      } catch {
        throw ProviderModelDiscoveryError.invalidResponse(error.localizedDescription)
      }
    case .anthropicMessages:
      var afterID: String?
      var models: [DiscoveredProviderModel] = []
      repeat {
        try Task.checkCancellation()
        var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)
        if let afterID {
          components?.queryItems = [URLQueryItem(name: "after_id", value: afterID)]
        }
        guard let pageURL = components?.url else {
          throw ProviderModelDiscoveryError.invalidEndpoint
        }
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data = try await responseData(for: request)
        let page: AnthropicModelsResponse
        do {
          page = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
        } catch {
          throw ProviderModelDiscoveryError.invalidResponse(error.localizedDescription)
        }
        models.append(
          contentsOf: page.data.map {
            DiscoveredProviderModel(
              id: $0.id,
              displayName: $0.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? $0.id)
          })
        afterID = page.hasMore ? page.lastID ?? page.data.last?.id : nil
      } while afterID != nil
      return models
    }
  }

  private func responseData(for request: URLRequest) async throws -> Data {
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await sendRequest(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
      throw CancellationError()
    } catch {
      throw ProviderModelDiscoveryError.request(error.localizedDescription)
    }
    guard (200..<300).contains(response.statusCode) else {
      let detail = String(data: data, encoding: .utf8) ?? "provider rejected the request"
      throw ProviderModelDiscoveryError.response(
        status: response.statusCode,
        detail: String(
          detail.split(whereSeparator: \Character.isNewline).joined(separator: " ").prefix(240)))
    }
    return data
  }

  private func cachedModels(
    for shape: CompletionProviderShape, endpoint: String
  ) -> [DiscoveredProviderModel]? {
    guard let data = defaults.data(forKey: cacheKey(for: shape, endpoint: endpoint)) else {
      return nil
    }
    return try? JSONDecoder().decode([DiscoveredProviderModel].self, from: data)
  }

  private func cacheKey(for shape: CompletionProviderShape, endpoint: String) -> String {
    let fingerprint = Data(shape.normalizeEndpoint(endpoint).utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
    return "\(cachePrefix).\(shape.rawValue).\(fingerprint)"
  }

  private static func normalize(_ models: [DiscoveredProviderModel])
    -> [DiscoveredProviderModel]
  {
    var seen = Set<String>()
    return
      models
      .filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .filter { seen.insert($0.id).inserted }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  private static func modelsURL(for endpoint: String) -> URL? {
    var base = endpoint.trimmingCharacters(
      in: .whitespacesAndNewlines.union(.init(charactersIn: "/")))
    for suffix in [
      "/v1/responses", "/v1/messages", "/v1/chat/completions", "/v1/completions",
    ] where base.hasSuffix(suffix) {
      base.removeLast(suffix.count)
      return URL(string: base + "/v1/models")
    }
    if base.hasSuffix("/v1") {
      base.removeLast(3)
    }
    return URL(string: base + "/v1/models")
  }

  private static func liveRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return (data, response)
  }

  private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
  }

  private struct OpenAIModel: Decodable {
    let id: String
  }

  private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModel]
    let hasMore: Bool
    let lastID: String?

    enum CodingKeys: String, CodingKey {
      case data
      case hasMore = "has_more"
      case lastID = "last_id"
    }
  }

  private struct AnthropicModel: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
      case id
      case displayName = "display_name"
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
