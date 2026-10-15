import CryptoKit
import Foundation

enum NanoRemoteTTSLaunchContract {
    static let bridgeLaunchArgument = "--run-jarvis-codex-bridge-loop"
    static let hudCoexistenceLaunchArgument = "--run-display-hud-coexistence"
    static let nanoSelectionArgument = "--run-jarvis-nano-bridge"

    static func isSatisfied(arguments: [String]) -> Bool {
        let bridgeModeSelected = arguments.contains(bridgeLaunchArgument)
            || arguments.contains(hudCoexistenceLaunchArgument)
        return bridgeModeSelected && arguments.contains(nanoSelectionArgument)
    }
}

struct NanoRemoteTTSConfiguration: Sendable {
    static let defaultVoice = "M1"
    static let defaultLanguage = "en"
    static let defaultSteps = 4
    static let maximumChunkCharacters = 160
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    let baseURL: URL
    let voice: String
    let language: String
    let steps: Int
    let timeoutSeconds: TimeInterval
    let requestHeaders: [String: String]

    init(
        baseURL: URL,
        voice: String = defaultVoice,
        language: String = defaultLanguage,
        steps: Int = defaultSteps,
        timeoutSeconds: TimeInterval = 15,
        requestHeaders: [String: String] = [:]
    ) throws {
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoice.isEmpty else { throw NanoRemoteTTSError.invalidConfiguration("voice_required") }
        guard !trimmedLanguage.isEmpty else { throw NanoRemoteTTSError.invalidConfiguration("language_required") }
        guard (2 ... 10).contains(steps) else {
            throw NanoRemoteTTSError.invalidConfiguration("steps_out_of_range")
        }
        guard timeoutSeconds > 0, timeoutSeconds <= 60 else {
            throw NanoRemoteTTSError.invalidConfiguration("timeout_out_of_range")
        }
        self.baseURL = baseURL
        self.voice = trimmedVoice
        self.language = trimmedLanguage
        self.steps = steps
        self.timeoutSeconds = timeoutSeconds
        self.requestHeaders = requestHeaders
    }
}

struct NanoRemoteTTSMetadata: Equatable, Sendable {
    let requestID: String
    let engine: String
    let voice: String
    let synthesisLatencySeconds: Double
    let audioDurationSeconds: Double
    let audioSHA256: String
    let sampleRate: Int
    let channels: Int
    let sampleWidthBits: Int
}

struct NanoRemoteTTSWave: Equatable, Sendable {
    let pcm16LittleEndian: Data
    let frameCount: Int
    let sampleRate: Int
    let channels: Int
    let sampleWidthBits: Int
}

struct NanoRemoteTTSValidatedAudio: Equatable, Sendable {
    let metadata: NanoRemoteTTSMetadata
    let wave: NanoRemoteTTSWave
}

enum NanoRemoteTTSError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case emptyText
    case textTooLong(maximum: Int)
    case invalidHTTPResponse
    case unexpectedStatus(Int)
    case unexpectedContentType(String)
    case responseTooLarge(maximum: Int)
    case contentLengthMismatch
    case missingHeader(String)
    case metadataMismatch(field: String)
    case invalidMetadata(field: String)
    case sha256Mismatch
    case malformedWave(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason):
            "Nano remote TTS configuration is invalid: \(reason)."
        case .emptyText:
            "Nano remote TTS rejected an empty chunk."
        case let .textTooLong(maximum):
            "Nano remote TTS chunk exceeds the \(maximum)-character limit."
        case .invalidHTTPResponse:
            "Nano remote TTS returned a non-HTTP response."
        case let .unexpectedStatus(status):
            "Nano remote TTS returned HTTP \(status)."
        case let .unexpectedContentType(contentType):
            "Nano remote TTS returned an unsupported content type: \(contentType)."
        case let .responseTooLarge(maximum):
            "Nano remote TTS response exceeds the \(maximum)-byte limit."
        case .contentLengthMismatch:
            "Nano remote TTS response length does not match Content-Length."
        case let .missingHeader(name):
            "Nano remote TTS response is missing \(name)."
        case let .metadataMismatch(field):
            "Nano remote TTS response metadata does not match \(field)."
        case let .invalidMetadata(field):
            "Nano remote TTS response contains invalid \(field) metadata."
        case .sha256Mismatch:
            "Nano remote TTS audio integrity validation failed."
        case let .malformedWave(reason):
            "Nano remote TTS returned malformed WAV audio: \(reason)."
        case .cancelled:
            "Nano remote TTS playback was cancelled."
        }
    }
}

enum NanoRemoteTTSTelemetry {
    static func chunkFields(
        metadata: NanoRemoteTTSMetadata,
        requestMilliseconds: Int,
        playbackFrames: Int,
        route: String,
        lifecycleEpoch: Int
    ) -> [String: String] {
        [
            "tts_engine": "supertonic_nano_remote",
            "tts_request_id": metadata.requestID,
            "tts_voice": metadata.voice,
            "request_ms": String(requestMilliseconds),
            "synthesis_latency_ms": String(Int((metadata.synthesisLatencySeconds * 1_000).rounded())),
            "audio_duration_ms": String(Int((metadata.audioDurationSeconds * 1_000).rounded())),
            "audio_sha256": metadata.audioSHA256,
            "audio_sample_rate": String(metadata.sampleRate),
            "audio_channels": String(metadata.channels),
            "audio_sample_width_bits": String(metadata.sampleWidthBits),
            "scheduled_frames": String(playbackFrames),
            "route": route,
            "lifecycle_epoch": String(lifecycleEpoch),
            "fallback_triggered": "false",
            "fallback_reason": "none"
        ]
    }
}

struct NanoRemoteTTSLookaheadPolicy: Equatable, Sendable {
    let maxScheduledOutstandingClips: Int

    init(maxScheduledOutstandingClips: Int = 2) {
        self.maxScheduledOutstandingClips = max(1, maxScheduledOutstandingClips)
    }

    func canStartGeneration(
        generationInFlight: Bool,
        scheduledOutstandingCount: Int
    ) -> Bool {
        !generationInFlight && scheduledOutstandingCount < maxScheduledOutstandingClips
    }
}

struct NanoRemoteTTSFailureCleanupDecision: Equatable, Sendable {
    let cancelRequest: Bool
    let stopPlayback: Bool
    let generationInFlight: Bool
    let scheduledOutstandingCount: Int

    static let failClosed = NanoRemoteTTSFailureCleanupDecision(
        cancelRequest: true,
        stopPlayback: true,
        generationInFlight: false,
        scheduledOutstandingCount: 0
    )
}

enum NanoRemoteTTSResponseValidator {
    static func validate(
        data: Data,
        response: URLResponse,
        expectedRequestID: String,
        expectedVoice: String
    ) throws -> NanoRemoteTTSValidatedAudio {
        guard let http = response as? HTTPURLResponse else {
            throw NanoRemoteTTSError.invalidHTTPResponse
        }
        guard http.statusCode == 200 else {
            throw NanoRemoteTTSError.unexpectedStatus(http.statusCode)
        }
        guard data.count <= NanoRemoteTTSConfiguration.maximumResponseBytes else {
            throw NanoRemoteTTSError.responseTooLarge(
                maximum: NanoRemoteTTSConfiguration.maximumResponseBytes
            )
        }
        if let rawLength = http.value(forHTTPHeaderField: "Content-Length")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawLength.isEmpty {
            guard let declaredLength = Int(rawLength), declaredLength >= 0 else {
                throw NanoRemoteTTSError.invalidMetadata(field: "content_length")
            }
            guard declaredLength <= NanoRemoteTTSConfiguration.maximumResponseBytes else {
                throw NanoRemoteTTSError.responseTooLarge(
                    maximum: NanoRemoteTTSConfiguration.maximumResponseBytes
                )
            }
            guard declaredLength == data.count else {
                throw NanoRemoteTTSError.contentLengthMismatch
            }
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let mimeType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard mimeType == "audio/wav" else {
            throw NanoRemoteTTSError.unexpectedContentType(contentType)
        }

        func requiredHeader(_ name: String) throws -> String {
            guard let value = http.value(forHTTPHeaderField: name),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NanoRemoteTTSError.missingHeader(name)
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let requestID = try requiredHeader("X-Request-ID")
        guard requestID == expectedRequestID else {
            throw NanoRemoteTTSError.metadataMismatch(field: "request_id")
        }
        let engine = try requiredHeader("X-TTS-Engine")
        guard engine == "supertonic-local" else {
            throw NanoRemoteTTSError.metadataMismatch(field: "tts_engine")
        }
        let voice = try requiredHeader("X-TTS-Voice")
        guard voice == expectedVoice else {
            throw NanoRemoteTTSError.metadataMismatch(field: "voice")
        }
        let synthesisLatency = try positiveDouble(
            requiredHeader("X-Synthesis-Latency-Seconds"),
            field: "synthesis_latency_seconds",
            allowZero: true
        )
        let audioDuration = try positiveDouble(
            requiredHeader("X-Audio-Duration-Seconds"),
            field: "audio_duration_seconds",
            allowZero: false
        )
        let declaredSHA = try requiredHeader("X-Audio-SHA256").lowercased()
        guard declaredSHA.count == 64,
              declaredSHA.allSatisfy({ $0.isHexDigit }) else {
            throw NanoRemoteTTSError.invalidMetadata(field: "audio_sha256")
        }
        let actualSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard constantTimeEqual(declaredSHA, actualSHA) else {
            throw NanoRemoteTTSError.sha256Mismatch
        }
        let sampleRate = try exactIntegerHeader(http, name: "X-Audio-Sample-Rate", expected: 24_000)
        let channels = try exactIntegerHeader(http, name: "X-Audio-Channels", expected: 1)
        let sampleWidth = try exactIntegerHeader(http, name: "X-Audio-Sample-Width-Bits", expected: 16)
        let wave = try parseWave(data)
        guard wave.sampleRate == sampleRate else {
            throw NanoRemoteTTSError.metadataMismatch(field: "wave_sample_rate")
        }
        guard wave.channels == channels else {
            throw NanoRemoteTTSError.metadataMismatch(field: "wave_channels")
        }
        guard wave.sampleWidthBits == sampleWidth else {
            throw NanoRemoteTTSError.metadataMismatch(field: "wave_sample_width_bits")
        }
        let waveDuration = Double(wave.frameCount) / Double(wave.sampleRate)
        guard abs(waveDuration - audioDuration) <= max(0.05, waveDuration * 0.02) else {
            throw NanoRemoteTTSError.metadataMismatch(field: "audio_duration_seconds")
        }

        return NanoRemoteTTSValidatedAudio(
            metadata: NanoRemoteTTSMetadata(
                requestID: requestID,
                engine: engine,
                voice: voice,
                synthesisLatencySeconds: synthesisLatency,
                audioDurationSeconds: audioDuration,
                audioSHA256: actualSHA,
                sampleRate: sampleRate,
                channels: channels,
                sampleWidthBits: sampleWidth
            ),
            wave: wave
        )
    }

    static func parseWave(_ data: Data) throws -> NanoRemoteTTSWave {
        guard data.count >= 44 else { throw NanoRemoteTTSError.malformedWave("header_too_short") }
        guard ascii(data, offset: 0, length: 4) == "RIFF" else {
            throw NanoRemoteTTSError.malformedWave("missing_riff")
        }
        let declaredRIFFSize = Int(try uint32(data, at: 4)) + 8
        guard declaredRIFFSize == data.count else {
            throw NanoRemoteTTSError.malformedWave("riff_size_mismatch")
        }
        guard ascii(data, offset: 8, length: 4) == "WAVE" else {
            throw NanoRemoteTTSError.malformedWave("missing_wave")
        }

        var offset = 12
        var format: (sampleRate: Int, channels: Int, bits: Int)?
        var pcmData: Data?
        while offset + 8 <= data.count {
            let chunkID = ascii(data, offset: offset, length: 4)
            let chunkSize = Int(try uint32(data, at: offset + 4))
            let payloadOffset = offset + 8
            guard chunkSize >= 0, payloadOffset + chunkSize <= data.count else {
                throw NanoRemoteTTSError.malformedWave("chunk_bounds")
            }
            if chunkID == "fmt " {
                guard format == nil else { throw NanoRemoteTTSError.malformedWave("duplicate_fmt") }
                guard chunkSize >= 16 else { throw NanoRemoteTTSError.malformedWave("short_fmt") }
                let audioFormat = Int(try uint16(data, at: payloadOffset))
                let channels = Int(try uint16(data, at: payloadOffset + 2))
                let sampleRate = Int(try uint32(data, at: payloadOffset + 4))
                let byteRate = Int(try uint32(data, at: payloadOffset + 8))
                let blockAlign = Int(try uint16(data, at: payloadOffset + 12))
                let bits = Int(try uint16(data, at: payloadOffset + 14))
                guard audioFormat == 1 else { throw NanoRemoteTTSError.malformedWave("not_pcm") }
                guard channels == 1 else { throw NanoRemoteTTSError.malformedWave("not_mono") }
                guard sampleRate == 24_000 else {
                    throw NanoRemoteTTSError.malformedWave("sample_rate_not_24000")
                }
                guard bits == 16 else { throw NanoRemoteTTSError.malformedWave("not_pcm16") }
                guard blockAlign == 2, byteRate == 48_000 else {
                    throw NanoRemoteTTSError.malformedWave("invalid_pcm_geometry")
                }
                format = (sampleRate, channels, bits)
            } else if chunkID == "data" {
                guard pcmData == nil else { throw NanoRemoteTTSError.malformedWave("duplicate_data") }
                pcmData = data.subdata(in: payloadOffset ..< payloadOffset + chunkSize)
            }
            offset = payloadOffset + chunkSize + (chunkSize % 2)
        }

        guard let format else { throw NanoRemoteTTSError.malformedWave("missing_fmt") }
        guard let pcmData, !pcmData.isEmpty else {
            throw NanoRemoteTTSError.malformedWave("missing_audio_data")
        }
        guard pcmData.count.isMultiple(of: 2) else {
            throw NanoRemoteTTSError.malformedWave("odd_pcm_byte_count")
        }
        return NanoRemoteTTSWave(
            pcm16LittleEndian: pcmData,
            frameCount: pcmData.count / 2,
            sampleRate: format.sampleRate,
            channels: format.channels,
            sampleWidthBits: format.bits
        )
    }

    private static func exactIntegerHeader(
        _ response: HTTPURLResponse,
        name: String,
        expected: Int
    ) throws -> Int {
        guard let raw = response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw NanoRemoteTTSError.missingHeader(name)
        }
        guard let value = Int(raw) else {
            throw NanoRemoteTTSError.invalidMetadata(field: name)
        }
        guard value == expected else {
            throw NanoRemoteTTSError.metadataMismatch(field: name)
        }
        return value
    }

    private static func positiveDouble(
        _ value: String,
        field: String,
        allowZero: Bool
    ) throws -> Double {
        guard let parsed = Double(value), parsed.isFinite,
              allowZero ? parsed >= 0 : parsed > 0 else {
            throw NanoRemoteTTSError.invalidMetadata(field: field)
        }
        return parsed
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func ascii(_ data: Data, offset: Int, length: Int) -> String {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return "" }
        return String(data: data.subdata(in: offset ..< offset + length), encoding: .ascii) ?? ""
    }

    private static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw NanoRemoteTTSError.malformedWave("uint16_bounds")
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw NanoRemoteTTSError.malformedWave("uint32_bounds")
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

actor NanoRemoteTTSClient {
    private struct RequestBody: Encodable {
        let text: String
        let voice: String
        let language: String
        let steps: Int
        let requestID: String

        enum CodingKeys: String, CodingKey {
            case text, voice, language, steps
            case requestID = "request_id"
        }
    }

    private let configuration: NanoRemoteTTSConfiguration
    private let session: URLSession

    init(configuration: NanoRemoteTTSConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func synthesize(text: String, requestID: String) async throws -> NanoRemoteTTSValidatedAudio {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NanoRemoteTTSError.emptyText }
        guard trimmed.count <= NanoRemoteTTSConfiguration.maximumChunkCharacters else {
            throw NanoRemoteTTSError.textTooLong(maximum: NanoRemoteTTSConfiguration.maximumChunkCharacters)
        }
        try Task.checkCancellation()
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/tts"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        for (name, value) in configuration.requestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(
            text: trimmed,
            voice: configuration.voice,
            language: configuration.language,
            steps: configuration.steps,
            requestID: requestID
        ))
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            return try NanoRemoteTTSResponseValidator.validate(
                data: data,
                response: response,
                expectedRequestID: requestID,
                expectedVoice: configuration.voice
            )
        } catch is CancellationError {
            throw NanoRemoteTTSError.cancelled
        }
    }
}
