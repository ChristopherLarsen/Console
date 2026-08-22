import Foundation

/// LM Studio native REST API (`/api/v1/*`), introduced in LM Studio 0.4.
nonisolated enum LMStudioAPI {
    static let defaultOrigin = "http://127.0.0.1:1234"

    static func origin(from endpointURL: String) -> String {
        var value = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.isEmpty { return defaultOrigin }

        let suffixes = [
            "/v1/chat/completions",
            "/api/v1/chat/completions",
            "/api/v1/chat",
            "/api/v1/models",
            "/api/v1",
            "/v1/models",
            "/v1"
        ]
        let lowered = value.lowercased()
        for suffix in suffixes where lowered.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
            break
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value.isEmpty ? defaultOrigin : value
    }

    static func modelsURL(from endpointURL: String) -> URL? {
        URL(string: origin(from: endpointURL) + "/api/v1/models")
    }

    static func chatURL(from endpointURL: String) -> URL? {
        URL(string: origin(from: endpointURL) + "/api/v1/chat")
    }

    static func parseModels(_ data: Data) throws -> [AvailableModel] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw ModelFetchError.invalidResponse
        }

        let available = models.compactMap { model -> (AvailableModel, Bool)? in
            let type = (model["type"] as? String)?.lowercased()
            if type == "embedding" { return nil }

            guard let id = model["key"] as? String, !id.isEmpty else { return nil }
            let display = (model["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let loaded = ((model["loaded_instances"] as? [Any])?.isEmpty == false)
            return (AvailableModel(id: id, displayName: display), loaded)
        }

        return available.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 && !rhs.1 }
            return lhs.0.displayName.localizedCaseInsensitiveCompare(rhs.0.displayName) == .orderedAscending
        }.map(\.0)
    }

    static func extractChatText(_ data: Data) throws -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else {
            throw LLMGeneratorError.invalidResponse
        }

        let messages = output.compactMap { item -> String? in
            guard (item["type"] as? String) == "message" else { return nil }
            let content = item["content"] as? String
            return content?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        guard !messages.isEmpty else {
            throw LLMGeneratorError.invalidResponse
        }
        return messages.joined(separator: "\n")
    }

    static func isUnreachable(_ error: Error) -> Bool {
        let code = (error as? URLError)?.code ?? URLError.Code(rawValue: (error as NSError).code)
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
