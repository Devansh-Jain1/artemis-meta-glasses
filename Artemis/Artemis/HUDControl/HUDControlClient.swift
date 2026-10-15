import Foundation

enum HUDControlClientError: Error, Equatable {
    case invalidResponse
    case badStatus(Int)
}

struct HUDControlClient {
    var baseURL: URL
    var session: URLSession
    var timeout: TimeInterval

    init(
        baseURL: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 2.0
    ) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    func fetchDisplay() async throws -> HUDControlDisplayPayload {
        let request = makeRequest(path: "/display", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        ArtemisRemoteLogSink.send("[HUDControlClient] fetch_display ok url=\(request.url?.absoluteString ?? "-") bytes=\(data.count)")
        return try JSONDecoder.hudControl.decode(HUDControlDisplayPayload.self, from: data)
    }

    func invoke(
        action: HUDControlActionKind,
        targetID: String?,
        execute: Bool,
        question: String?
    ) async throws -> HUDControlActionResult {
        var body: [String: Any] = [
            "action": action == .draft ? "STEER" : action.rawValue,
            "execute": execute
        ]
        if let targetID {
            body["target_id"] = targetID
        }
        if let question {
            body["question"] = question
        }

        var request = makeRequest(path: "/action", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        try validate(response)
        ArtemisRemoteLogSink.send("[HUDControlClient] action ok action=\(action.rawValue) target=\(targetID ?? "-") bytes=\(data.count)")
        return try JSONDecoder.hudControl.decode(HUDControlActionResult.self, from: data)
    }

    func postInputEvent(_ event: HUDControlEvent) async {
        var request = makeRequest(path: "/input-event", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let envelope = HUDControlInputEventEnvelope(
            schemaVersion: "hud.input_event.v0",
            event: event
        )
        do {
            request.httpBody = try JSONEncoder.hudControl.encode(envelope)
            let (_, response) = try await session.data(for: request)
            try validate(response)
            ArtemisRemoteLogSink.send("[HUDControlClient] input_event ok source=\(event.inputSource.rawValue) kind=\(event.inputKind.rawValue) row=\(event.focusedRowID ?? "-") action=\(event.focusedAction?.rawValue ?? "-")")
        } catch {
            ArtemisRemoteLogSink.send("[HUDControlClient] input_event failed source=\(event.inputSource.rawValue) kind=\(event.inputKind.rawValue) url=\(request.url?.absoluteString ?? "-") error=\(error.localizedDescription) (\(String(describing: error)))")
        }
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HUDControlClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HUDControlClientError.badStatus(http.statusCode)
        }
    }
}

extension JSONDecoder {
    static var hudControl: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var hudControl: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
