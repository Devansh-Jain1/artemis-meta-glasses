import Foundation

struct JarvisBridgeReply: Decodable, Sendable {
    let requestID: String
    let reply: String
    let sessionID: String?
    let elapsedMilliseconds: Int
    let streamed: Bool?
    let streamedSentenceCount: Int?
    let relayPending: Bool?
    let route: String?
}

struct JarvisInboundMessage: Decodable, Sendable {
    let id: UInt64
    let text: String
    let createdAt: TimeInterval
    let source: String
    let requestID: String?
    let sequence: Int?
}

enum JarvisSpecialChannelPolicy {
    static let source = "microbit_special_channel"
    static let requestIDPrefix = "special:"
    static let maximumActivationAge: TimeInterval = 30

    static func accepts(
        _ message: JarvisInboundMessage,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard message.source == source,
              let requestID = message.requestID,
              requestID.hasPrefix(requestIDPrefix) else {
            return false
        }
        let age = now - message.createdAt
        return age >= 0 && age <= maximumActivationAge
    }
}

enum JarvisBridgeError: LocalizedError {
    case invalidResponse
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Jarvis returned an invalid response."
        case let .unavailable(message):
            return "Jarvis is unavailable: \(message)"
        }
    }
}

enum JarvisBridgeRuntime {
    static var baseURL: URL {
        if let value = ProcessInfo.processInfo.environment["JARVIS_BRIDGE_BASE_URL"],
           let url = URL(string: value) {
            return url
        }
        if let telemetryEndpoints = Bundle.main.object(
            forInfoDictionaryKey: "ArtemisTelemetryEndpoints"
        ) as? [String],
           let endpoint = telemetryEndpoints.compactMap(URL.init(string:)).first,
           let host = endpoint.host {
            var components = URLComponents()
            components.scheme = endpoint.scheme ?? "http"
            components.host = host
            components.port = 8788
            if let url = components.url {
                return url
            }
        }
        return URL(string: "http://127.0.0.1:8788")!
    }
}

/// Explicit connector from the validated phone voice loop to the active
/// Mac-side Codex manager. It is enabled only by Jarvis bridge modes.
actor JarvisBridgeClient {
    private struct Request: Encodable {
        let requestID: String
        let transcript: String
        let recentConversation: [String]
    }

    private let baseURL: URL
    private let session: URLSession
    private var isEnabled: Bool

    init(
        baseURL: URL = JarvisBridgeRuntime.baseURL,
        session: URLSession = .shared,
        enabled: Bool = false
    ) {
        self.baseURL = baseURL
        self.session = session
        isEnabled = enabled
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func health() async -> Bool {
        guard isEnabled else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/health"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func send(
        requestID: String,
        transcript: String,
        recentConversation: [String]
    ) async throws -> JarvisBridgeReply {
        guard isEnabled else {
            throw JarvisBridgeError.unavailable("development bridge is disabled")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/turn"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(
            requestID: requestID,
            transcript: transcript,
            recentConversation: recentConversation
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JarvisBridgeError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw JarvisBridgeError.unavailable(message)
        }
        return try JSONDecoder().decode(JarvisBridgeReply.self, from: data)
    }

    func inbox(after messageID: UInt64) async throws -> [JarvisInboundMessage] {
        guard isEnabled else { return [] }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/inbox"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "after", value: String(messageID))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw JarvisBridgeError.invalidResponse
        }
        struct Inbox: Decodable { let messages: [JarvisInboundMessage] }
        return try JSONDecoder().decode(Inbox.self, from: data).messages
    }

    func report(event: String, fields: [String: String] = [:]) async {
        guard isEnabled else { return }
        var payload = fields
        payload["event"] = event
        guard let body = try? JSONEncoder().encode(payload) else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/telemetry"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await session.data(for: request)
    }
}
