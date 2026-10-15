import Foundation

enum ArtemisFastpathClientError: Error {
    case invalidResponse
    case badStatus(Int)
    case missingReply(String?)
}

struct ArtemisFastpathReply: Decodable {
    let schemaVersion: String
    let executed: Bool
    let status: String
    let provider: String?
    let model: String?
    let reasoningEffort: String?
    let replyText: String?
    let latencyMS: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case executed
        case status
        case provider
        case model
        case reasoningEffort = "reasoning_effort"
        case replyText = "reply_text"
        case latencyMS = "latency_ms"
        case error
    }

    var spokenText: String {
        replyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct ArtemisFastpathClient {
    let baseURL: URL
    var timeout: TimeInterval = 20

    func reply(
        transcript: String,
        context: [String: String],
        execute: Bool = true
    ) async throws -> ArtemisFastpathReply {
        let url = baseURL.appendingPathComponent("fastpath-reply")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "transcript": transcript,
                "context": context,
                "execute": execute
            ],
            options: [.sortedKeys]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ArtemisFastpathClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ArtemisFastpathClientError.badStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ArtemisFastpathReply.self, from: data)
        guard !decoded.executed || !decoded.spokenText.isEmpty || decoded.status != "ok" else {
            throw ArtemisFastpathClientError.missingReply(decoded.error)
        }
        return decoded
    }
}

enum ArtemisFastpathRuntime {
    static var baseURL: URL {
        if let value = ProcessInfo.processInfo.environment["ARTEMIS_FASTPATH_BASE_URL"],
           let url = URL(string: value) {
            return url
        }
        if let value = ProcessInfo.processInfo.environment["HUD_CONTROL_BASE_URL"],
           let url = URL(string: value) {
            return url
        }
        if let telemetryURL = Bundle.main.object(forInfoDictionaryKey: "ArtemisTelemetryEndpoints") as? [String],
           let firstEndpoint = telemetryURL.compactMap(URL.init(string:)).first,
           let host = firstEndpoint.host {
            var components = URLComponents()
            components.scheme = firstEndpoint.scheme ?? "http"
            components.host = host
            components.port = 8788
            if let url = components.url {
                return url
            }
        }
        return URL(string: "http://127.0.0.1:8788")!
    }
}
