import AVFoundation
import Combine
import CoreTransferable
import MediaPlayer
import MWDATCamera
import MWDATCore
import MWDATDisplay
import PhotosUI
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LiteRTLM
import LeapSDK
import MLX

enum ArtemisRemoteLogSink {
    private static let eventRemoteDenylist: Set<String> = [
        "voice_stt_audio_level",
        "display_hud_snapshot",
        "display_hud_coexistence_sample",
        "startup_greeting_skipped_inflight"
    ]

    private static let messageRemoteDenylist = [
        "agent_c_event voice_stt_audio_level",
        "agent_c_event display_hud_snapshot",
        "agent_c_event display_hud_coexistence_sample",
        "Startup greeting queue skipped"
    ]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 2.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func send(_ line: String) {
        guard !messageRemoteDenylist.contains(where: { line.contains($0) }) else { return }
        sendPayload([
            "source": "artemis-ios",
            "level": "info",
            "message": line,
            "app_time": ISO8601DateFormatter().string(from: .now)
        ])
    }

    static func sendEvent(_ event: String, payload: [String: Any]) {
        guard !eventRemoteDenylist.contains(event) else { return }
        var body = payload
        body["source"] = "artemis-ios"
        body["level"] = "info"
        body["event"] = event
        body["app_time"] = ISO8601DateFormatter().string(from: .now)
        if body["message"] == nil {
            body["message"] = "agent_c_event \(event)"
        }
        sendPayload(body)
    }

    private static func sendPayload(_ payload: [String: Any]) {
        let endpoints = Bundle.main.object(forInfoDictionaryKey: "ArtemisTelemetryEndpoints") as? [String] ?? []
        let urls = endpoints.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 1.0
            request.httpBody = body
            session.dataTask(with: request) { _, response, error in
                if let error {
                    NSLog("[ArtemisTelemetry] POST %@ failed: %@", url.absoluteString, error.localizedDescription)
                    return
                }
                if let statusCode = (response as? HTTPURLResponse)?.statusCode,
                   !(200..<300).contains(statusCode) {
                    NSLog("[ArtemisTelemetry] POST %@ returned HTTP %d", url.absoluteString, statusCode)
                }
            }.resume()
        }
    }
}

@MainActor
enum ArtemisVisionFramePublisher {
    private static let minimumPublishInterval: TimeInterval = 0.25
    private static var lastPublishAt: Date?
    private static var requestInFlight = false

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func maybePublish(_ image: UIImage) {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["ARTEMIS_VISION_FRAME_URL"].flatMap(URL.init(string:)),
              let token = environment["ARTEMIS_VISION_TOKEN"],
              !token.isEmpty else {
            return
        }
        guard !requestInFlight else { return }
        if let lastPublishAt,
           Date().timeIntervalSince(lastPublishAt) < minimumPublishInterval {
            return
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.45) else { return }

        let timestampMS = Int(Date().timeIntervalSince1970 * 1_000)
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let payload: [String: Any] = [
            "frame_id": timestampMS,
            "source_timestamp_ms": timestampMS,
            "source_device": "meta-ray-ban-display",
            "width": width,
            "height": height,
            "mime_type": "image/jpeg",
            "image_base64": jpeg.base64EncodedString()
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        requestInFlight = true
        lastPublishAt = .now
        session.dataTask(with: request) { _, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            Task { @MainActor in
                requestInFlight = false
                if let error {
                    NSLog("[ArtemisVision] publish failed: %@", error.localizedDescription)
                } else if let statusCode, !(200..<300).contains(statusCode) {
                    NSLog("[ArtemisVision] publish returned HTTP %d", statusCode)
                }
            }
        }.resume()
    }
}

enum ArtemisBenchmarkEventStore {
    static func clearResults() {
        do {
            let directory = try resultsDirectory()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            _ = try resultsDirectory()
        } catch {
            NSLog("[Artemis] Failed to clear benchmark results: \(error)")
        }
    }

    static func append(event: String, payload: [String: Any]) {
        do {
            let directory = try resultsDirectory()
            var body = payload
            body["source"] = "artemis-ios"
            body["event"] = event
            body["app_time"] = ISO8601DateFormatter().string(from: .now)
            body["message"] = body["message"] ?? "agent_c_event \(event)"
            body["received_locally_at"] = Date().timeIntervalSince1970
            guard JSONSerialization.isValidJSONObject(body) else { return }
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let line = data + Data("\n".utf8)
            let eventsFile = directory.appendingPathComponent("events.jsonl")
            if FileManager.default.fileExists(atPath: eventsFile.path) {
                let handle = try FileHandle(forWritingTo: eventsFile)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: eventsFile, options: .atomic)
            }

            if event.hasSuffix("_complete") || event.hasSuffix("_failed") {
                try data.write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
            }
        } catch {
            NSLog("[Artemis] Failed to persist benchmark event \(event): \(error)")
        }
    }

    static func writeFrame(_ data: Data, name: String) {
        do {
            let directory = try resultsDirectory()
                .appendingPathComponent("frames", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("[Artemis] Failed to persist benchmark frame \(name): \(error)")
        }
    }

    static func writeJSON(_ payload: [String: Any], name: String) {
        do {
            guard JSONSerialization.isValidJSONObject(payload) else { return }
            let directory = try resultsDirectory()
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("[Artemis] Failed to persist benchmark JSON \(name): \(error)")
        }
    }

    static func readJSON(name: String) throws -> [String: Any] {
        let directory = try resultsDirectory()
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let payload = object as? [String: Any] else {
            throw NSError(
                domain: "ArtemisBenchmarkEventStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Benchmark JSON \(name) is not an object."]
            )
        }
        return payload
    }

    private static func resultsDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("ArtemisBenchResults", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

func artemisFirstJSONObjectString(from text: String) -> String {
    let cleaned = text
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = cleaned.firstIndex(of: "{") else { return cleaned }

    var depth = 0
    var isInString = false
    var isEscaped = false
    var index = start

    while index < cleaned.endIndex {
        let character = cleaned[index]
        if isEscaped {
            isEscaped = false
        } else if character == "\\" {
            isEscaped = true
        } else if character == "\"" {
            isInString.toggle()
        } else if !isInString {
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(cleaned[start...index])
                }
            }
        }
        index = cleaned.index(after: index)
    }

    return cleaned
}

func artemisJSONDictionary(from text: String) -> [String: Any]? {
    let jsonText = artemisFirstJSONObjectString(from: text)
    guard let data = jsonText.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func artemisJSONStringValue(for key: String, in text: String) -> String? {
    let cleaned = text
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
    guard let keyRange = cleaned.range(of: "\"\(key)\""),
          let colonRange = cleaned.range(of: ":", range: keyRange.upperBound..<cleaned.endIndex),
          let startQuote = cleaned.range(of: "\"", range: colonRange.upperBound..<cleaned.endIndex)?.lowerBound else {
        return nil
    }

    var value = ""
    var index = cleaned.index(after: startQuote)
    var isEscaped = false
    while index < cleaned.endIndex {
        let character = cleaned[index]
        if isEscaped {
            value.append(character)
            isEscaped = false
        } else if character == "\\" {
            isEscaped = true
        } else if character == "\"" {
            return value
        } else {
            value.append(character)
        }
        index = cleaned.index(after: index)
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
}

@main
struct ArtemisApp: App {
    init() {
        GPU.set(cacheLimit: 50 * 1024 * 1024)
        GPU.set(memoryLimit: 900 * 1024 * 1024)

        do {
            try Wearables.configure()
        } catch {
            NSLog("[Artemis] Failed to configure Wearables SDK: \(error)")
        }
    }

    var body: some Scene {
                WindowGroup {
            HUDControlRootSwitch {
                ArtemisDashboard()
            }
                .onOpenURL { url in
                    Task {
                        do {
                            _ = try await Wearables.shared.handleUrl(url)
                            NSLog("[Artemis] Handled DAT callback URL: \(url.absoluteString)")
                        } catch {
                            NSLog("[Artemis] Failed to handle DAT callback URL: \(error)")
                        }
                    }
                }
        }
    }
}

enum PipelineMode: String, CaseIterable, Identifiable, Sendable {
    case standby = "Standby"
    case passive = "Passive"
    case query = "Query"
    case extraction = "Extract"

    var id: String { rawValue }
}

enum WearableConnectionState: String, Sendable {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case simulated = "Simulated"
    case connected = "Connected"
    case streaming = "Streaming"
    case degraded = "Degraded"
    case stale = "Stale"
    case failed = "Failed"
}

func describeDATPermissionError(_ error: Error) -> String {
    guard let permissionError = error as? PermissionError else {
        return "\(error.localizedDescription) (\(String(describing: error)))"
    }

    let recovery: String
    switch permissionError {
    case .noDevice:
        recovery = "No Meta wearable is visible to the permission flow."
    case .noDeviceWithConnection:
        recovery = "The phone has a wearable connection, but Meta DAT cannot find an eligible device for this permission. Open Meta AI, confirm glasses are connected, then return to Artemis and retry Camera Perm."
    case .connectionError:
        recovery = "Meta DAT could not communicate with the wearable/Meta AI connection."
    case .metaAINotInstalled:
        recovery = "Meta AI is not installed or not visible to the DAT permission flow."
    case .requestInProgress:
        recovery = "A previous Meta DAT permission request is still in progress."
    case .requestTimeout:
        recovery = "The Meta DAT permission request timed out."
    case .internalError:
        recovery = "Meta DAT reported an internal permission error."
    @unknown default:
        recovery = "Unknown Meta DAT permission error."
    }

    return "\(permissionError) [raw=\(permissionError.rawValue)]: \(recovery)"
}

func describeDATRuntimeError(_ error: Error) -> String {
    if error is PermissionError {
        return describeDATPermissionError(error)
    }

    guard let sessionError = error as? DeviceSessionError else {
        return "\(error.localizedDescription) (\(String(describing: error)))"
    }

    let recovery: String
    switch sessionError {
    case .noEligibleDevice:
        recovery = "No connected compatible DAT device is session-eligible. Check Meta AI connection, Developer Mode, registration, and whether the Display/Camera app on the glasses has updated."
    case .datAppOnTheGlassesUpdateRequired:
        recovery = "Meta says the DAT app on the glasses must be updated. Tap DAT App in Artemis or use Meta AI settings to update the app on glasses."
    case .thermalCritical, .thermalEmergency:
        recovery = "Glasses thermal state is too high for a stable session. Let the glasses cool before retrying."
    case .batteryCritical:
        recovery = "Glasses battery is too low for a stable session."
    case .peakPowerShutdown:
        recovery = "Glasses shut down the session due to peak power."
    case .sessionAlreadyExists:
        recovery = "Another DAT session is already active. Stop/relaunch Artemis or close the other glasses experience."
    case .sessionAlreadyStopped, .sessionIdle, .capabilityAlreadyActive, .capabilityNotFound, .dwaUnavailable:
        recovery = "DAT session lifecycle rejected the requested operation."
    case .unexpectedError(let description):
        recovery = "DAT session unexpected error: \(description)"
    @unknown default:
        recovery = "Unknown DAT session error."
    }

    return "\(sessionError): \(recovery)"
}

func describeSpeechRuntimeError(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(error.localizedDescription) [domain=\(nsError.domain), code=\(nsError.code)]"
}

enum SpeechOutputEngine: String, CaseIterable, Identifiable, Sendable {
    case apple = "Apple TTS"
    case kokoroLocal = "Kokoro"
    case supertonicLocal = "Supertonic"

    var id: String { rawValue }

    var isAvailable: Bool {
        switch self {
        case .apple:
            return true
        case .kokoroLocal:
            return true
        case .supertonicLocal:
            return false
        }
    }
}

struct VisionObservation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let scene: String
    let peopleCount: Int
    let objects: [String]
    let visibleText: String
    let notableChange: String
    let confidence: Double

    static let empty = VisionObservation(
        timestamp: .now,
        scene: "No frame analyzed",
        peopleCount: 0,
        objects: [],
        visibleText: "",
        notableChange: "none",
        confidence: 0
    )
}

struct BrainResponse: Equatable, Sendable {
    let text: String
    let shouldSendToDisplay: Bool
    let shouldSpeak: Bool
}

struct LiveVisionContext: Equatable, Sendable {
    let source: String
    let visionModel: String
    let promptMode: String
    let frameID: Int
    let timestampMS: Int
    let latencyMS: Int
    let summary: String
    let visibleText: String
    let uncertainty: String
    let confidence: Double

    static let empty = LiveVisionContext(
        source: "meta_dat",
        visionModel: "LFM2.5-VL-450M",
        promptMode: "live_json_1fps",
        frameID: 0,
        timestampMS: 0,
        latencyMS: 0,
        summary: "No live vision observation yet.",
        visibleText: "",
        uncertainty: "waiting_for_first_observation",
        confidence: 0
    )
}

struct GoldenTurnLedgerEntry: Equatable, Sendable {
    let role: String
    let text: String
    let timestampMS: Int
}

struct SpeechTranscriptMetadata: Equatable, Sendable {
    let segmentCount: Int
    let confidenceMean: Double
    let confidenceMin: Double
    let durationSeconds: Double
    let lastSegmentText: String

    static let empty = SpeechTranscriptMetadata(
        segmentCount: 0,
        confidenceMean: 0,
        confidenceMin: 0,
        durationSeconds: 0,
        lastSegmentText: ""
    )

    var hasUsableConfidence: Bool {
        segmentCount > 0 && confidenceMean > 0
    }
}

extension SpeechTranscriptMetadata {
    init(transcription: SFTranscription) {
        let segments = transcription.segments
        let confidences = segments.map { max(0, Double($0.confidence)) }
        let confidenceMean = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        let confidenceMin = confidences.min() ?? 0
        let durationSeconds = segments
            .map { Double($0.timestamp + $0.duration) }
            .max() ?? 0
        let lastSegmentText = segments.last?.substring.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            segmentCount: segments.count,
            confidenceMean: confidenceMean,
            confidenceMin: confidenceMin,
            durationSeconds: durationSeconds,
            lastSegmentText: lastSegmentText
        )
    }

    var turnFinalizationMetadata: STTTurnFinalizationMetadata {
        STTTurnFinalizationMetadata(
            segmentCount: segmentCount,
            confidenceMean: confidenceMean,
            confidenceMin: confidenceMin,
            durationSeconds: durationSeconds,
            lastSegmentText: lastSegmentText
        )
    }
}

struct GoldenBrainTurnResult: Sendable {
    let rawOutput: String
    let streamedOutput: String
    let spokenText: String
    let route: String
    let fallbackTriggered: Bool
    let fallbackReason: String
    let confidence: Double
    let firstResponseMilliseconds: Int
    let totalMilliseconds: Int
    let liteRTMetrics: LiteRTBenchmarkMetrics?
}

protocol SpeechOutputServiceDelegate: AnyObject {
    func speechOutputDidStart(text: String, engine: SpeechOutputEngine)
    func speechOutputDidGenerate(text: String, engine: SpeechOutputEngine, stats: KokoroSpeechPlaybackStats)
    func speechOutputDidFinish(text: String, engine: SpeechOutputEngine)
    func speechOutputDidFail(text: String, engine: SpeechOutputEngine, error: Error)
}

@MainActor
final class ArtemisSessionModel: NSObject, ObservableObject {
    @Published var mode: PipelineMode = .standby
    @Published var connectionState: WearableConnectionState = .disconnected
    @Published var selectedSpeechEngine: SpeechOutputEngine = .kokoroLocal
    @Published var transcript = ""
    @Published var voiceDraft = ""
    @Published var voiceBridgeEnabled = false
    @Published var voiceBridgeStatus = "Idle"
    @Published private(set) var jarvisBrainMode = JarvisBrainMode.launchSelection(
        arguments: ProcessInfo.processInfo.arguments
    )
    @Published var speechInputStatus = "Stopped"
    @Published var speechOutputStatus = "Idle"
    @Published var audioRouteSummary = "Audio route not sampled yet."
    @Published var turnTakingStateLabel = TurnState.idle.rawValue
    @Published var lastVoiceIncidentID = "None"
    @Published var lastObservation = VisionObservation.empty
    @Published var liveVisionContext = LiveVisionContext.empty
    @Published var lastBrainResponse = BrainResponse(
        text: "Ready for local-only wearable validation.",
        shouldSendToDisplay: false,
        shouldSpeak: false
    )
    @Published var liveGoldenModeEnabled = false
    @Published var hudState = "standby"
    @Published var hudTurnID = "none"
    @Published var hudSTTText = ""
    @Published var hudSTTFinalizationReason = "none"
    @Published var hudBrainImpl = "none"
    @Published var hudBrainModel = "none"
    @Published var hudBrainRuntime = "none"
    @Published var hudBrainText = ""
    @Published var hudBrainLatencyMS = 0
    @Published var hudVisionModel = "LFM2.5-VL-450M"
    @Published var hudVisionFrameID = 0
    @Published var hudVisionLatencyMS = 0
    @Published var hudVisionAgeMS = 0
    @Published var hudVisionFreshnessState = VisionFreshnessState.unavailable.rawValue
    @Published var hudVisionSummary = "No live vision observation yet."
    @Published var hudTTSVoice = "none"
    @Published var hudTTSText = ""
    @Published var hudTTSGenerationMS = 0
    @Published var hudFirstResponseMS = 0
    @Published var hudEndToEndMS = 0
    @Published var hudFallbackTriggered = false
    @Published var hudFallbackReason = "none"
    @Published var glassesHUDState = "off"
    @Published var glassesHUDLastUpdateReason = "none"
    @Published var framesReceived = 0
    @Published var framesAnalyzed = 0
    @Published var datDroppedFrames = 0
    @Published var datFrameAgeMS = -1
    @Published var datIngestLatencyMS = -1
    @Published var datDeviceUnavailableReason = "none"
    @Published var averageInferenceMS = 0
    @Published var endToEndLatencyMS = 0
    @Published var streamFPS = 0.0
    @Published var decodedFrameImages = 0
    @Published var latestPreviewImage: UIImage?
    @Published var latestPreviewFrameID = 0
    @Published var thermalState = ProcessInfo.processInfo.thermalState
    @Published var batteryLabel = "Unknown"
    @Published var powerModeLabel = "Normal"
    @Published var wearableBatteryLabel = "Unavailable"
    @Published var wearableThermalLabel = "unknown"
    @Published var wearablePowerModeLabel = WearablePowerMode.normal.label
    @Published var wearablePowerReason = "no_wearable_state"
    @Published var wearablePowerCameraFPS = "\(WearablePowerPolicy.defaultCameraFrameRate) fps"
    @Published var wearablePowerHUDInterval = "\(Int(WearablePowerPolicy.normalHUDIntervalSeconds))s"
    @Published var wearablePowerTestPhase: WearablePowerTestPhase = .bluetoothIdle
    @Published var wearableBatteryPercentInput = ""
    @Published var wearablePowerSampleStatus = "Record the Meta battery reading to establish a baseline."
    @Published var wearablePowerDrainLabel = "Need 2 checkpoints"
    @Published var wearablePowerSamples: [WearablePowerSample] = []
    @Published var selectedModelPath = ""
    @Published var selectedModelName = "No model selected"
    @Published var selectedBenchmarkVideoName = "No video selected"
    @Published var modelBenchmarkStatus = "Idle"
    @Published var modelBenchmarkOutput = "Import a video or use the existing phone video to run official LiteRT-LM Gemma locally."
    @Published var modelStorageSummary = "Model scan pending"
    @Published var sentinelEnabled = false
    @Published var sentinelStatus = "Off"
    @Published var sentinelDecision = "Live sentinel disabled."
    @Published var sentinelEscalationLabel = "No"
    @Published var sentinelLastInferenceMS = 0
    @Published var sentinelSamples = 0
    @Published var logs: [String] = []
    @Published var registrationStateLabel = "Unknown"
    @Published private(set) var isDATRegistered = false
    @Published var deviceDiagnostics: [String] = []
    @Published var datDeviceActionHint = "Waiting for DAT device diagnostics."
    @Published var isListening = false
    @Published var isRunning = false

    private let speechInput = AppleSpeechInput()
    private let speechOutput = SpeechOutputService()
    private let turnTaking = TurnTakingManager.shared
    private let wearable = MetaDATWearableSession()
    private let modelBenchmark = LocalModelBenchmarkService()
    private let lfmBenchmark = LocalLFMBenchmarkService()
    private let fastpathClient = ArtemisFastpathClient(baseURL: ArtemisFastpathRuntime.baseURL)
    private let validatedVoiceRuntime = VoiceSessionModel()
    private let validatedVoiceRuntimeActive = true
    private var cancellables = Set<AnyCancellable>()
    private var streamTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var offlineVideoBenchmarkTask: Task<Void, Never>?
    private var sentinelTask: Task<Void, Never>?
    private var compatibilityTokens: [DeviceIdentifier: AnyListenerToken] = [:]
    private var linkStateTokens: [DeviceIdentifier: AnyListenerToken] = [:]
    private var deviceStateTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
    private var wearableThermalLevels: [DeviceIdentifier: String] = [:]
    private var latestWearablePowerFault = "none"
    private var lastWearablePowerLogFingerprint = ""
    private var lastDeviceDiagnosticsFingerprint = ""
    private var firstFrameAt: Date?
    private var datRunID = "none"
    private var datRunStartedAt: Date?
    private var lastDATLifecycleFrameID = 0
    private var latestDATFrameSourceTimestampMS = 0
    private var latestDATFrameIngestTimestampMS = 0
    private var selectedBenchmarkVideoURL: URL?
    private var didAutoRunOfflineVideoBenchmark = false
    private var sentinelInFlight = false
    private var lastSentinelFrameID = 0
    private let sentinelFrameStride = 96
    private var pendingSentinelFrame: (frameID: Int, imageData: Data)?
    private var lastExpensiveVisionRequestAtMS: Int?
    private var brainTurnInFlight = false
    private var audioOutputInFlight = false
    private let gemmaRealtimeProbeEnabled = true
    private var shouldResumeListeningAfterTTS = false
    private var voiceAutoRouteTask: Task<Void, Never>?
    private var lastRoutedVoiceText = ""
    private var lastSpeechTranscriptMetadata = SpeechTranscriptMetadata.empty
    private var lastVoiceAutoRouteCandidateText = ""
    private var voiceAutoRouteStablePartialCount = 0
    private var voiceEventSequence = 0
    private let voiceAutoRouteCommandDelayNanoseconds: UInt64 = 700_000_000
    private let voiceAutoRouteShortUtteranceDelayNanoseconds: UInt64 = 1_800_000_000
    private let voiceAutoRouteReadyUtteranceDelayNanoseconds: UInt64 = 1_200_000_000
    private var pendingTurnFinalizationReason = "unknown"
    private var vadSpeechActive = false
    private var lastVADSpeechAt: Date?
    private var turnLedger: [GoldenTurnLedgerEntry] = []
    private let maxTurnLedgerEntries = 8
    private let liveGoldenContextTokenLimit = 512
    private var currentTurnID = ""
    private var pendingVoiceTurnID = ""
    private var currentTurnStartedAt: Date?
    private var shouldSpeakStartupGreeting = false
    private var didSpeakStartupGreeting = false
    private var shouldStartVoiceBridgeAfterStartupGreeting = false
    private var didStartVoiceBridgeAfterStartupGreeting = false
    private var isSpeechInputStartInFlight = false
    private var isStoppingSpeechInput = false
    private var speechRestartAfterTTSTask: Task<Void, Never>?
    private let liveGoldenQuietInputPeakThreshold: Float = 0.03
    private let liveGoldenVADSpeechPeakThreshold: Float = 0.045
    private let liveGoldenVADReleaseSeconds: TimeInterval = 1.0
    private let liveGoldenQuietInputWindowSeconds: TimeInterval = 4.0
    private let liveGoldenNoTranscriptWindowSeconds: TimeInterval = 8.0
    private var currentListenStartedAt: Date?
    private var currentListenMaxPeak: Float = 0
    private var didReportQuietInputForCurrentListen = false
    private var didReportNoTranscriptForCurrentListen = false
    private var lastSTTTranscriptAt: Date?
    private var lastVoiceAudioLevelEventAt: Date?
    private var lastStartupGreetingSkipLogAt: Date?
    private var lastStartupGreetingSkipKey = ""
    private var displayHUDModeEnabled = false
    private var webAppDisplayModeEnabled = false
    private var nativeDisplayHUDEnabled: Bool {
        (displayHUDModeEnabled || liveGoldenModeEnabled) && !webAppDisplayModeEnabled
    }
    private var appLifecycleState = "unknown"
    private var pendingKokoroSpeakerSmoke = false
    private var pendingAudioGoldenSmoke = false
    private var pendingSTTCalibration = false
    private var pendingSTTCalibrationRoute: SpeechInputRouteMode = .measurement
    private var pendingSTTRequiresOnDeviceRecognition = true
    private var sttCalibrationModeEnabled = false
    private var cerebrasFastpathModeEnabled = false
    private var pendingForegroundKokoroText: String?
    private var pendingPrivateAudioRetryText = ""
    private var lastPrivateAudioRouteBlockMS = 0
    private var audioRouteObserver: NSObjectProtocol?
    private var validatedVoicePausedForLifecycle = false
    private var pendingValidatedStartupProbe: String?
    #if os(iOS)
    private var liveGoldenProcessingBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    override init() {
        super.init()
        speechInput.delegate = self
        speechOutput.delegate = self
        turnTaking.delegate = self
        turnTaking.reset()
        validatedVoiceRuntime.configureVisualContextProvider { [weak self] transcript, turnID, decision in
            guard let self else { throw JarvisVisualContextError.providerUnavailable }
            return try await self.resolveValidatedVisualContext(
                transcript: transcript,
                turnID: turnID,
                decision: decision
            )
        }
        observeValidatedVoiceRuntime()
        addLog("Jarvis voice runtime selected: Parakeet EOU + Silero + explicit \(jarvisBrainMode.displayName) + on-demand LFM vision + eSpeak/Kokoro.")
        refreshLocalModels()
        observeAudioRouteChanges()
        observeWearablesRegistration()
        observeWearablesDevices()
    }

    private func observeValidatedVoiceRuntime() {
        validatedVoiceRuntime.$brainMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard let self else { return }
                self.jarvisBrainMode = mode
                self.hudBrainImpl = mode.brainImplementation
                self.hudBrainModel = mode.brainModel
                self.hudBrainRuntime = mode.brainRuntime
                self.pushDisplayHUD(reason: "validated_voice_brain_mode")
            }
            .store(in: &cancellables)

        validatedVoiceRuntime.$draftTranscript
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.transcript = text
                self.voiceDraft = text
                self.hudSTTText = text
                if !text.isEmpty {
                    self.hudState = "hearing"
                    self.pushDisplayHUD(reason: "validated_voice_partial")
                }
            }
            .store(in: &cancellables)

        validatedVoiceRuntime.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.isListening = self.validatedVoiceRuntime.microphoneReady
                self.isSpeechInputStartInFlight = phase == .starting
                self.speechInputStatus = self.validatedVoiceRuntime.sttRuntimeStatus
                self.speechOutputStatus = self.validatedVoiceRuntime.ttsStatus
                self.voiceBridgeStatus = self.validatedVoiceRuntime.jarvisStatus
                self.turnTakingStateLabel = self.validatedVoiceRuntime.visibleStatus
                switch phase {
                case .idle: self.hudState = "idle"
                case .starting: self.hudState = "voice_starting"
                case .listening:
                    self.validatedVoicePausedForLifecycle = false
                    self.hudState = "listening"
                    if let prompt = self.pendingValidatedStartupProbe {
                        self.pendingValidatedStartupProbe = nil
                        let startupTTSEngine = ProcessInfo.processInfo.arguments.contains(
                            "--run-jarvis-nano-bridge"
                        )
                            ? "supertonic_nano_remote"
                            : "supertonic_3_coreml"
                        let startupAudioProfile = ArtemisJarvisAudioLaunchPolicy()
                            .selection(arguments: ProcessInfo.processInfo.arguments)
                            .profile
                        self.emitVoiceBridgeEvent("live_assistant_startup_probe_requested", payload: [
                            "stt_source": "parakeet_eou_120m_coreml_160ms",
                            "brain_mode": self.jarvisBrainMode.rawValue,
                            "brain_impl": self.jarvisBrainMode.brainImplementation,
                            "brain_model": self.jarvisBrainMode.brainModel,
                            "brain_runtime": self.jarvisBrainMode.brainRuntime,
                            "tts_engine": startupTTSEngine,
                            "audio_route_target": startupAudioProfile.rawValue,
                            "model_api_calls": self.jarvisBrainMode == .codexBridge
                        ])
                        self.askBrain(prompt)
                    }
                case .userSpeaking:
                    self.validatedVoicePausedForLifecycle = false
                    self.hudState = "hearing"
                case .responding:
                    self.validatedVoicePausedForLifecycle = false
                    self.hudState = "responding"
                case .unavailable: self.hudState = "voice_unavailable"
                }
                self.pushDisplayHUD(reason: "validated_voice_phase")
            }
            .store(in: &cancellables)

        validatedVoiceRuntime.$conversation
            .receive(on: RunLoop.main)
            .sink { [weak self] lines in
                guard let self,
                      let latest = lines.last,
                      latest.role == .assistant,
                      !latest.text.isEmpty,
                      latest.text != self.hudBrainText else { return }
                self.hudBrainText = latest.text
                let mode = self.validatedVoiceRuntime.brainMode
                self.hudBrainImpl = mode.brainImplementation
                self.hudBrainModel = mode.brainModel
                self.hudBrainRuntime = mode.brainRuntime
                self.lastBrainResponse = BrainResponse(
                    text: latest.text,
                    shouldSendToDisplay: true,
                    shouldSpeak: true
                )
                self.pushDisplayHUD(reason: latest.state == .live
                    ? "validated_voice_response_stream"
                    : "validated_voice_response_complete")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .jarvisVoiceRuntimeEvent)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let event = notification.userInfo?["event"] as? String,
                      let fields = notification.userInfo?["fields"] as? [String: String] else { return }
                self.handleValidatedVoiceRuntimeEvent(event, fields: fields)
            }
            .store(in: &cancellables)
    }

    private func handleValidatedVoiceRuntimeEvent(_ event: String, fields: [String: String]) {
        var shouldPushHUD = false
        switch event {
        case "speech_started":
            audioRouteSummary = fields["route"] ?? audioRouteSummary
            speechInputStatus = "Parakeet EOU listening"
            shouldPushHUD = true
        case "stt_final":
            hudTurnID = fields["turn_id"] ?? hudTurnID
            hudSTTText = fields["transcript"] ?? hudSTTText
            hudSTTFinalizationReason = fields["turn_finalization_reason"] ?? "unknown"
            hudBrainImpl = fields["brain_impl"] ?? hudBrainImpl
            hudBrainModel = fields["brain_model"] ?? hudBrainModel
            hudBrainRuntime = fields["brain_runtime"] ?? hudBrainRuntime
            hudTTSVoice = fields["tts_engine"] ?? "supertonic_3_coreml"
            shouldPushHUD = true
        case "brain_first_fragment", "jarvis_result":
            hudFirstResponseMS = Int(fields["first_response_ms"] ?? "") ?? hudFirstResponseMS
            hudBrainLatencyMS = Int(fields["elapsed_ms"] ?? "") ?? hudBrainLatencyMS
            if let result = fields["result"], !result.isEmpty { hudBrainText = result }
            shouldPushHUD = true
        case "jarvis_inbound_received":
            if let text = fields["text"], !text.isEmpty {
                hudBrainText = hudBrainText.isEmpty ? text : "\(hudBrainText) \(text)"
            }
            shouldPushHUD = true
        case "tts_stream_chunk_generated", "tts_chunk_generated":
            hudTTSGenerationMS = Int(fields["generation_ms"] ?? "") ?? hudTTSGenerationMS
            hudTTSText = fields["text"] ?? hudTTSText
        case "tts_stream_finished", "tts_finished":
            hudEndToEndMS = Int(fields["end_to_end_ms"] ?? "") ?? hudEndToEndMS
            hudFallbackTriggered = false
            hudFallbackReason = "none"
            shouldPushHUD = true
        case "speech_start_failed", "speech_error", "brain_failed", "jarvis_failed", "tts_failed", "tts_stream_failed":
            hudFallbackTriggered = true
            hudFallbackReason = fields["error"] ?? fields["reason"] ?? event
            shouldPushHUD = true
        default:
            break
        }
        if shouldPushHUD {
            pushDisplayHUD(reason: "validated_voice_\(event)")
        }
    }

    deinit {
        if let audioRouteObserver {
            NotificationCenter.default.removeObserver(audioRouteObserver)
        }
    }

    func recordScenePhase(_ phase: ScenePhase) {
        let label: String
        switch phase {
        case .active:
            label = "active"
        case .inactive:
            label = "inactive"
        case .background:
            label = "background"
        @unknown default:
            label = "unknown"
        }
        guard appLifecycleState != label else { return }
        appLifecycleState = label
        addLog("App scene phase: \(label); audio=\(audioRuntimeStateSummary())")
        if (label == "inactive" || label == "background") && shouldPreserveLiveGoldenAudioAcrossLifecycle() {
            addLog("Preserving live golden audio across scene_\(label); audio=\(audioRuntimeStateSummary())")
            emitVoiceBridgeEvent("voice_lifecycle_preserved_for_live_golden", payload: [
                "reason": "scene_\(label)",
                "audio_runtime": audioRuntimeStateSummary(),
                "turn_state": turnTaking.currentState.rawValue,
                "brain_turn_in_flight": brainTurnInFlight,
                "audio_output_in_flight": audioOutputInFlight,
                "is_listening": isListening
            ])
        } else if label == "inactive" || label == "background" {
            pauseForegroundAudioForInactiveApp(reason: "scene_\(label)")
        }
        if label == "active", pendingKokoroSpeakerSmoke {
            runPendingKokoroSpeakerSmoke(reason: "scene_active")
        }
        if label == "active", pendingAudioGoldenSmoke {
            runPendingAudioGoldenSmoke(reason: "scene_active")
        }
        if label == "active", pendingSTTCalibration {
            runPendingSTTCalibration(reason: "scene_active")
        }
        if label == "active" {
            resumeForegroundAudioIfNeeded(reason: "scene_active")
            maybeQueueStartupGreeting(reason: "scene_active", previewImageAvailable: false, frameID: nil)
        }
    }

    private func canUseForegroundAudio() -> Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active && appLifecycleState == "active"
        #else
        return true
        #endif
    }

    private func shouldPreserveLiveGoldenAudioAcrossLifecycle() -> Bool {
        guard liveGoldenModeEnabled else { return false }
        return brainTurnInFlight
            || audioOutputInFlight
    }

    private func pauseForegroundAudioForInactiveApp(reason: String) {
        guard voiceBridgeEnabled else { return }
        guard !shouldPreserveLiveGoldenAudioAcrossLifecycle() else {
            addLog("Skipping STT pause for live golden lifecycle preserve; reason=\(reason); audio=\(audioRuntimeStateSummary())")
            return
        }
        if isListening || isSpeechInputStartInFlight {
            if validatedVoiceRuntimeActive {
                validatedVoicePausedForLifecycle = true
            }
            addLog("Pausing STT for inactive app; reason=\(reason); audio=\(audioRuntimeStateSummary())")
            emitVoiceBridgeEvent("voice_stt_paused_for_lifecycle", payload: [
                "reason": reason,
                "audio_runtime": audioRuntimeStateSummary()
            ])
            stopListening()
        }
    }

    private func resumeForegroundAudioIfNeeded(reason: String) {
        guard canUseForegroundAudio() else { return }
        if let text = pendingForegroundKokoroText {
            pendingForegroundKokoroText = nil
            addLog("Resuming deferred Kokoro speech; reason=\(reason); chars=\(text.count)")
            emitVoiceBridgeEvent("voice_tts_resuming_deferred_foreground", payload: [
                "reason": reason,
                "text_chars": text.count
            ])
            speakGoldenResponseWithBargeIn(text: text)
            return
        }

        if validatedVoiceRuntimeActive,
           validatedVoicePausedForLifecycle,
           voiceBridgeEnabled,
           !audioOutputInFlight,
           !brainTurnInFlight,
           !isListening,
           !isSpeechInputStartInFlight {
            addLog("Re-arming validated Parakeet runtime after active scene; reason=\(reason); audio=\(audioRuntimeStateSummary())")
            emitVoiceBridgeEvent("validated_voice_resuming_foreground", payload: [
                "reason": reason,
                "audio_runtime": audioRuntimeStateSummary(),
                "audio_route_target": "meta_glasses_hfp"
            ])
            startListening()
            return
        }

        guard voiceBridgeEnabled,
              !audioOutputInFlight,
              !brainTurnInFlight,
              !isListening,
              !isSpeechInputStartInFlight,
              turnTaking.currentState == .listening else {
            return
        }
        addLog("Re-arming STT after active scene; reason=\(reason); audio=\(audioRuntimeStateSummary())")
        emitVoiceBridgeEvent("voice_stt_resuming_foreground", payload: [
            "reason": reason,
            "turn_state": turnTaking.currentState.rawValue,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        startListening()
    }

    private func runPendingKokoroSpeakerSmoke(reason: String) {
        guard pendingKokoroSpeakerSmoke else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else {
            addLog("Kokoro speaker smoke waiting for active app; reason=\(reason); audio=\(audioRuntimeStateSummary())")
            return
        }
        #endif
        pendingKokoroSpeakerSmoke = false
        addLog("Kokoro speaker smoke starting; reason=\(reason); audio=\(audioRuntimeStateSummary())")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run {
                self?.speechOutput.speak(
                    "Kokoro speaker test. This should be clean speech from the iPhone speaker.",
                    engine: .kokoroLocal
                )
            }
        }
    }

    private func runPendingAudioGoldenSmoke(reason: String) {
        guard pendingAudioGoldenSmoke else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else {
            addLog("Audio golden smoke waiting for active app; reason=\(reason); audio=\(audioRuntimeStateSummary())")
            return
        }
        #endif
        pendingAudioGoldenSmoke = false
        addLog("Audio golden smoke starting; reason=\(reason); audio=\(audioRuntimeStateSummary())")
        startAudioGoldenSmoke()
    }

    private func runPendingSTTCalibration(reason: String) {
        guard pendingSTTCalibration else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else {
            addLog("STT calibration waiting for active app; reason=\(reason); audio=\(audioRuntimeStateSummary())")
            return
        }
        #endif
        pendingSTTCalibration = false
        sttCalibrationModeEnabled = true
        liveGoldenModeEnabled = false
        speechInput.forcedRouteMode = pendingSTTCalibrationRoute
        speechInput.requiresOnDeviceRecognition = pendingSTTRequiresOnDeviceRecognition
        selectedSpeechEngine = .kokoroLocal
        addLog("STT calibration starting; reason=\(reason); route=\(pendingSTTCalibrationRoute.rawValue); on_device=\(pendingSTTRequiresOnDeviceRecognition); speak a full sentence near the active input. audio=\(audioRuntimeStateSummary())")
        emitVoiceBridgeEvent("stt_calibration_started", payload: [
            "reason": reason,
            "route_mode": pendingSTTCalibrationRoute.rawValue,
            "requires_on_device_recognition": pendingSTTRequiresOnDeviceRecognition,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        startVoiceBridge()
    }

    private func beginLiveGoldenProcessingBackgroundTask(reason: String) {
        #if os(iOS)
        guard liveGoldenModeEnabled else { return }
        guard liveGoldenProcessingBackgroundTask == .invalid else { return }
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "ArtemisLiveGoldenTurn") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.addLog("Live golden background task expired; reason=\(reason); audio=\(self.audioRuntimeStateSummary())")
                self.emitVoiceBridgeEvent("live_golden_background_task_expired", payload: [
                    "reason": reason,
                    "audio_runtime": self.audioRuntimeStateSummary()
                ])
                self.endLiveGoldenProcessingBackgroundTask(reason: "expired")
            }
        }
        liveGoldenProcessingBackgroundTask = taskID
        addLog("Live golden background task started; reason=\(reason)")
        emitVoiceBridgeEvent("live_golden_background_task_started", payload: [
            "reason": reason,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        #endif
    }

    private func endLiveGoldenProcessingBackgroundTask(reason: String) {
        #if os(iOS)
        guard liveGoldenProcessingBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(liveGoldenProcessingBackgroundTask)
        liveGoldenProcessingBackgroundTask = .invalid
        addLog("Live golden background task ended; reason=\(reason)")
        emitVoiceBridgeEvent("live_golden_background_task_ended", payload: [
            "reason": reason,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        #endif
    }

    private func audioRuntimeStateSummary() -> String {
        #if os(iOS)
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active:
            appState = "active"
        case .inactive:
            appState = "inactive"
        case .background:
            appState = "background"
        @unknown default:
            appState = "unknown"
        }
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let routeCandidates = ArtemisAudioRoutePolicy.describeRouteCandidates(
            outputs: session.currentRoute.outputs.map {
                ArtemisAudioRouteEndpoint(portType: $0.portType.rawValue, portName: $0.portName)
            },
            availableInputs: (session.availableInputs ?? []).map {
                ArtemisAudioRouteEndpoint(portType: $0.portType.rawValue, portName: $0.portName)
            }
        )
        return "scene=\(appLifecycleState), app=\(appState), category=\(session.category.rawValue), mode=\(session.mode.rawValue), sr=\(Int(session.sampleRate)), inputs=[\(inputs)], \(routeCandidates), secondarySilenced=\(session.secondaryAudioShouldBeSilencedHint)"
        #else
        return "non-ios"
        #endif
    }

    func refreshAudioRouteDiagnostics() {
        let summary = audioRuntimeStateSummary()
        audioRouteSummary = summary
        addLog("Audio route diagnostics refreshed: \(summary)")
        emitVoiceBridgeEvent("audio_route_diagnostics_refreshed", payload: [
            "audio_runtime": summary
        ])
    }

    private func observeAudioRouteChanges() {
        #if os(iOS)
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAudioRouteChanged()
            }
        }
        #endif
    }

    private func handleAudioRouteChanged() {
        let summary = audioRuntimeStateSummary()
        audioRouteSummary = summary
        let decision = currentPrivateAudioRouteDecision()
        emitVoiceBridgeEvent("audio_route_changed", payload: [
            "audio_runtime": summary,
            "private_route_allowed": decision.isAllowed,
            "private_route_reason": decision.reason,
            "pending_private_retry": !pendingPrivateAudioRetryText.isEmpty
        ])
        addLog("Audio route changed: \(summary); private=\(decision.reason)")

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let availableInputs = (session.availableInputs ?? []).map {
            ArtemisAudioRouteEndpoint(portType: $0.portType.rawValue, portName: $0.portName)
        }
        let metaInputAvailable = ArtemisAudioRoutePolicy.metaGlassesOnly
            .preferredInput(from: availableInputs) != nil
        if validatedVoiceRuntimeActive,
           validatedVoicePausedForLifecycle,
           metaInputAvailable,
           canUseForegroundAudio() {
            resumeForegroundAudioIfNeeded(reason: "meta_audio_route_available")
        }
        #endif

        if liveGoldenModeEnabled,
           decision.isAllowed,
           shouldSpeakStartupGreeting,
           !didSpeakStartupGreeting {
            maybeQueueStartupGreeting(
                reason: "audio_route_changed",
                previewImageAvailable: latestPreviewImage != nil,
                frameID: latestPreviewFrameID > 0 ? latestPreviewFrameID : nil
            )
        }

        guard liveGoldenModeEnabled,
              decision.isAllowed,
              !pendingPrivateAudioRetryText.isEmpty,
              !audioOutputInFlight,
              !brainTurnInFlight else {
            return
        }

        let text = pendingPrivateAudioRetryText
        pendingPrivateAudioRetryText = ""
        emitVoiceBridgeEvent("voice_private_audio_auto_retry", payload: [
            "turn_id": currentTurnID,
            "text_chars": text.count,
            "audio_runtime": summary
        ])
        addLog("Auto-retrying private Kokoro audio after route changed to allowed glasses route.")
        speakGoldenResponseWithBargeIn(text: text, usePrivateGlassesRoute: true)
    }

    private func currentPrivateAudioRouteDecision() -> ArtemisAudioRouteDecision {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return ArtemisAudioRoutePolicy.metaGlassesOnly.decision(for: session.currentRoute.outputs.map {
            ArtemisAudioRouteEndpoint(portType: $0.portType.rawValue, portName: $0.portName)
        })
        #else
        return ArtemisAudioRouteDecision(isAllowed: false, reason: "Private glasses route is iOS-only.")
        #endif
    }

    private func prepareLiveGoldenDefaultAudioRoute(reason: String) -> Bool {
        guard liveGoldenModeEnabled else { return true }
        speechInput.requiredAudioRoutePolicy = nil
        speechInput.forcedRouteMode = nil
        speechInput.useDuplexVoiceRoute = false
        speechInput.requiresOnDeviceRecognition = true
        speechOutput.useSystemDefaultRoute()
        audioRouteSummary = audioRuntimeStateSummary()
        emitVoiceBridgeEvent("live_golden_audio_route_ready", payload: [
            "startup_reason": reason,
            "route_policy": "live_default_non_call",
            "audio_runtime": audioRouteSummary
        ])
        addLog("Live golden audio route ready using default non-call audio. Meta HFP microphone requires an explicit private-audio retry. audio=\(audioRouteSummary)")
        return true
    }

    private func prepareLiveGoldenPrivateAudioRoute(reason: String) -> Bool {
        guard liveGoldenModeEnabled else { return true }
        #if os(iOS)
        let now = nowMilliseconds()
        if reason != "audio_route_changed",
           lastPrivateAudioRouteBlockMS > 0,
           now - lastPrivateAudioRouteBlockMS < 5_000 {
            return false
        }
        do {
            let route = try ArtemisAudioRoutePolicy.activateMetaGlassesDuplexSession(resetActiveSession: true)
            audioRouteSummary = route
            lastPrivateAudioRouteBlockMS = 0
            emitVoiceBridgeEvent("private_audio_route_ready", payload: [
                "startup_reason": reason,
                "audio_runtime": audioRuntimeStateSummary(),
                "route": route
            ])
            addLog("Private Artemis audio route ready: \(route)")
            return true
        } catch {
            let detailedError = describeSpeechRuntimeError(error)
            let shouldEmit = now - lastPrivateAudioRouteBlockMS > 5_000
            lastPrivateAudioRouteBlockMS = now
            audioRouteSummary = audioRuntimeStateSummary()
            speechOutputStatus = "Blocked (private route)"
            speechInputStatus = "Blocked (private route)"
            voiceBridgeStatus = "Audio route blocked"
            hudState = "blocked_audio_route"
            hudBrainImpl = "GoldenBrainRouter"
            hudBrainText = "Select Meta RB Display audio route."
            hudFallbackTriggered = true
            hudFallbackReason = detailedError
            pushDisplayHUD(reason: "private_audio_route_blocked")
            if shouldEmit {
                emitVoiceBridgeEvent("private_audio_route_blocked", payload: [
                    "startup_reason": reason,
                    "reason": detailedError,
                    "audio_runtime": audioRuntimeStateSummary(),
                    "route_policy": "meta_glasses_only"
                ])
                addLog("Private Artemis audio route blocked before live turn: \(detailedError); audio=\(audioRuntimeStateSummary())")
            }
            return false
        }
        #else
        return false
        #endif
    }

    func startValidation() {
        guard !isRunning else { return }
        let preserveLiveGoldenTurn = liveGoldenModeEnabled
            && (brainTurnInFlight || audioOutputInFlight || didSpeakStartupGreeting)
        refreshLocalModels()
        isRunning = true
        mode = .passive
        connectionState = .connecting
        framesReceived = 0
        framesAnalyzed = 0
        datDroppedFrames = 0
        datFrameAgeMS = -1
        datIngestLatencyMS = -1
        datDeviceUnavailableReason = "none"
        lastDATLifecycleFrameID = 0
        latestDATFrameSourceTimestampMS = 0
        latestDATFrameIngestTimestampMS = 0
        decodedFrameImages = 0
        streamFPS = 0
        averageInferenceMS = 0
        endToEndLatencyMS = 0
        sentinelLastInferenceMS = 0
        sentinelSamples = 0
        sentinelStatus = sentinelEnabled ? "Waiting" : "Off"
        sentinelDecision = sentinelEnabled ? "Waiting for decoded frame." : "Live sentinel disabled."
        sentinelEscalationLabel = "No"
        sentinelInFlight = false
        sentinelTask?.cancel()
        sentinelTask = nil
        lastSentinelFrameID = 0
        pendingSentinelFrame = nil
        lastExpensiveVisionRequestAtMS = nil
        if preserveLiveGoldenTurn {
            addLog("Preserving live golden turn state while starting DAT stream; turn_id=\(currentTurnID); brain=\(brainTurnInFlight); audio=\(audioOutputInFlight).")
        } else {
            brainTurnInFlight = false
            audioOutputInFlight = false
        }
        latestPreviewImage = nil
        latestPreviewFrameID = 0
        liveVisionContext = .empty
        hudVisionFrameID = 0
        hudVisionLatencyMS = 0
        hudVisionAgeMS = 0
        hudVisionFreshnessState = VisionFreshnessState.unavailable.rawValue
        hudVisionSummary = LiveVisionContext.empty.summary
        hudBrainText = ""
        hudTurnID = "none"
        hudBrainLatencyMS = 0
        hudFirstResponseMS = 0
        hudEndToEndMS = 0
        hudTTSGenerationMS = 0
        hudTTSText = ""
        hudFallbackTriggered = false
        hudFallbackReason = "none"
        hudState = liveGoldenModeEnabled ? "live_golden_starting" : "stream_starting"
        firstFrameAt = nil
        datRunID = "dat-\(nowMilliseconds())"
        datRunStartedAt = Date()
        if !preserveLiveGoldenTurn {
            currentTurnID = ""
            pendingVoiceTurnID = ""
            currentTurnStartedAt = nil
            didSpeakStartupGreeting = false
            didStartVoiceBridgeAfterStartupGreeting = false
        }
        voiceBridgeStatus = voiceBridgeEnabled ? "Armed" : "Idle"
        speechInputStatus = isListening ? "Listening" : "Stopped"
        speechOutputStatus = "Idle"
        turnTakingStateLabel = turnTaking.getStateDescription()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let powerDecision = updateDeviceTelemetry(cameraRequested: true)
        guard powerDecision.allowsCameraStart else {
            hudState = "power_blocked"
            connectionState = .degraded
            addLog("DAT start blocked by wearable power policy: mode=\(powerDecision.mode.rawValue), reason=\(powerDecision.reason).")
            emitVoiceBridgeEvent(
                "wearable_power_start_blocked",
                payload: wearablePowerPayload(decision: powerDecision)
            )
            isRunning = false
            return
        }
        wearable.configureDisplayHUD(enabled: nativeDisplayHUDEnabled)
        wearable.configurePersistentEligibilityRetry(enabled: false)
        var runStartedPayload = DATRuntimeEnvironmentSnapshot.current().payload
        runStartedPayload["dat_run_id"] = datRunID
        runStartedPayload["registration_ready"] = isDATRegistered
        runStartedPayload["camera_frame_rate"] = powerDecision.cameraFrameRate
        runStartedPayload["display_hud_enabled"] = nativeDisplayHUDEnabled
        runStartedPayload["webapp_display_enabled"] = webAppDisplayModeEnabled
        emitVoiceBridgeEvent("dat_camera_run_started", payload: runStartedPayload)
        pushDisplayHUD(reason: "stream_starting")
        if liveGoldenModeEnabled, !voiceBridgeEnabled {
            startVoiceBridge()
        }
        addLog("Starting Meta DAT wearable stream.")

        streamTask = Task { [weak self] in
            guard let self else { return }
            for await frame in wearable.frames(
                onDiagnostic: { [weak self] message in
                    self?.addLog(message)
                },
                onPowerEvent: { [weak self] event in
                    self?.recordWearablePowerFault(event)
                },
                onPreviewImage: { [weak self] image, frameID in
                    guard let self else { return }
                    self.latestPreviewImage = image
                    self.latestPreviewFrameID = frameID
                    if self.webAppDisplayModeEnabled, let image {
                        ArtemisVisionFramePublisher.maybePublish(image)
                    }
                    self.maybeRunLiveSentinel(image: image, frameID: frameID)
                }
            ) {
                await MainActor.run {
                    if self.firstFrameAt == nil {
                        self.firstFrameAt = frame.timestamp
                    }
                    self.framesReceived += 1
                    if self.framesReceived == 1 {
                        DATRuntimeEnvironmentSnapshot.recordSuccessfulFrame(at: frame.timestamp)
                        var firstFramePayload = DATRuntimeEnvironmentSnapshot.current().payload
                        firstFramePayload["dat_run_id"] = self.datRunID
                        firstFramePayload["first_frame_ms"] = self.datRunStartedAt.map {
                            Int(frame.timestamp.timeIntervalSince($0) * 1000)
                        } ?? -1
                        firstFramePayload["frame_id"] = frame.id
                        firstFramePayload["preview_image_available"] = frame.previewImageAvailable
                        self.emitVoiceBridgeEvent("dat_camera_first_frame", payload: firstFramePayload)
                    }
                    if frame.previewImageAvailable {
                        self.decodedFrameImages += 1
                    }
                    if let firstFrameAt = self.firstFrameAt {
                        let elapsed = Date().timeIntervalSince(firstFrameAt)
                        if elapsed > 0 {
                            self.streamFPS = Double(self.framesReceived) / elapsed
                        }
                    }
                    let sourceTimestampMS = Int(frame.timestamp.timeIntervalSince1970 * 1000)
                    let ingestTimestampMS = self.nowMilliseconds()
                    let metrics = DATLifecyclePolicy.frameMetrics(
                        frameID: frame.id,
                        previousFrameID: self.lastDATLifecycleFrameID,
                        sourceTimestampMS: sourceTimestampMS,
                        ingestTimestampMS: ingestTimestampMS,
                        nowMS: ingestTimestampMS
                    )
                    self.latestDATFrameSourceTimestampMS = sourceTimestampMS
                    self.latestDATFrameIngestTimestampMS = ingestTimestampMS
                    self.lastDATLifecycleFrameID = frame.id
                    self.datDroppedFrames += metrics.droppedFrames
                    self.datFrameAgeMS = metrics.frameAgeMS
                    self.datIngestLatencyMS = metrics.ingestLatencyMS
                    let datDecision = DATLifecyclePolicy.transition(
                        from: self.datLifecycleState(for: self.connectionState),
                        event: metrics.isFresh ? .freshFrameReceived : .staleFrameObserved,
                        deviceUnavailableReason: "none",
                        thermalState: self.thermalLabelForEvent(self.thermalState),
                        appLifecycleState: self.appLifecycleState
                    )
                    self.datDeviceUnavailableReason = datDecision.deviceUnavailableReason
                    self.connectionState = self.wearableConnectionState(for: datDecision.state)
                    if self.framesReceived == 1 || self.framesReceived % 24 == 0 {
                        self.updateDeviceTelemetry(cameraRequested: true)
                        self.addLog(
                            "Received Meta DAT frame \(self.framesReceived), image=\(frame.previewImageAvailable ? "yes" : "no"), fps=\(String(format: "%.1f", self.streamFPS)), dat_state=\(datDecision.state.rawValue), dropped=\(self.datDroppedFrames)."
                        )
                        var payload = self.datLifecyclePayload(decision: datDecision, metrics: metrics)
                        payload["frames_received"] = self.framesReceived
                        payload["preview_image_available"] = frame.previewImageAvailable
                        payload["stream_fps"] = self.streamFPS
                        payload["latest_preview_frame_id"] = self.latestPreviewFrameID
                        payload["glasses_hud_state"] = self.glassesHUDState
                        self.emitVoiceBridgeEvent("display_hud_coexistence_sample", payload: payload)
                        self.emitVoiceBridgeEvent("dat_lifecycle_sample", payload: [
                            "frames_received": self.framesReceived,
                            "latest_preview_frame_id": self.latestPreviewFrameID,
                            "dat_lifecycle_state": datDecision.state.rawValue,
                            "dat_lifecycle_reason": datDecision.reason,
                            "dat_accept_live_visual_context": datDecision.acceptLiveVisualContext,
                            "dat_frame_age_ms": metrics.frameAgeMS,
                            "dat_ingest_latency_ms": metrics.ingestLatencyMS,
                            "dat_dropped_frames": self.datDroppedFrames,
                            "dat_frame_fresh": metrics.isFresh
                        ])
                        self.pushDisplayHUD(reason: "display_hud_coexistence_sample")
                    }
                    self.maybeSpeakStartupGreeting(frame: frame)
                }
            }
            await MainActor.run {
                guard self.isRunning else { return }
                let diagnostic = self.wearable.diagnosticSnapshot()
                let environment = DATRuntimeEnvironmentSnapshot.current()
                let durationMS = self.datRunStartedAt.map {
                    Int(Date().timeIntervalSince($0) * 1000)
                } ?? -1
                if self.framesReceived == 0 {
                    var incidentPayload = environment.payload
                    incidentPayload["incident_id"] = self.datRunID
                    incidentPayload["dat_run_id"] = self.datRunID
                    incidentPayload["failure_class"] = DATRuntimeEnvironmentSnapshot.classifyFailure(
                        registrationReady: self.isDATRegistered,
                        permissionState: diagnostic.permissionState,
                        eligibleDevice: diagnostic.eligibleDevice,
                        framesReceived: self.framesReceived,
                        errorDescription: diagnostic.lastError
                    )
                    incidentPayload["registration_ready"] = self.isDATRegistered
                    incidentPayload["registration_state"] = self.registrationStateLabel
                    incidentPayload["camera_permission_state"] = diagnostic.permissionState
                    incidentPayload["eligible_device"] = diagnostic.eligibleDevice
                    incidentPayload["device_eligibility"] = diagnostic.eligibilitySummary
                    incidentPayload["session_state"] = diagnostic.sessionState
                    incidentPayload["stream_state"] = diagnostic.streamState
                    incidentPayload["display_state"] = diagnostic.displayState
                    incidentPayload["last_error"] = diagnostic.lastError
                    incidentPayload["frames_received"] = self.framesReceived
                    incidentPayload["run_duration_ms"] = durationMS
                    incidentPayload["camera_frame_rate"] = self.wearablePowerCameraFPS
                    incidentPayload["model_api_calls"] = false
                    self.emitVoiceBridgeEvent("dat_camera_incident", payload: incidentPayload)
                }
                var endedPayload = environment.payload
                endedPayload["dat_run_id"] = self.datRunID
                endedPayload["frames_received"] = self.framesReceived
                endedPayload["run_duration_ms"] = durationMS
                endedPayload["last_error"] = diagnostic.lastError
                self.emitVoiceBridgeEvent("dat_camera_run_ended", payload: endedPayload)
                let datDecision = DATLifecyclePolicy.transition(
                    from: self.datLifecycleState(for: self.connectionState),
                    event: .streamStopped,
                    deviceUnavailableReason: "dat_stream_ended",
                    thermalState: self.thermalLabelForEvent(self.thermalState),
                    appLifecycleState: self.appLifecycleState
                )
                self.datDeviceUnavailableReason = datDecision.deviceUnavailableReason
                self.connectionState = self.wearableConnectionState(for: datDecision.state)
                self.addLog("Meta DAT stream ended; dat_state=\(datDecision.state.rawValue), reason=\(datDecision.reason).")
                self.emitVoiceBridgeEvent("dat_lifecycle_state_changed", payload: self.datLifecyclePayload(
                    decision: datDecision,
                    metrics: self.latestDATFrameMetrics()
                ))
                self.pushDisplayHUD(reason: "dat_stream_ended")
            }
        }
    }

    func stopValidation() {
        streamTask?.cancel()
        streamTask = nil
        sentinelTask?.cancel()
        sentinelTask = nil
        wearable.configureDisplayHUD(enabled: false)
        wearable.configurePersistentEligibilityRetry(enabled: false)
        wearable.stop()
        if validatedVoiceRuntimeActive {
            validatedVoiceRuntime.stopListening()
        } else {
            speechInput.stop()
            speechOutput.stop()
        }
        turnTaking.endConversation()
        shouldResumeListeningAfterTTS = false
        isListening = false
        voiceBridgeEnabled = false
        voiceBridgeStatus = "Idle"
        speechInputStatus = "Stopped"
        speechOutputStatus = "Idle"
        turnTakingStateLabel = TurnState.idle.rawValue
        hudState = "idle"
        brainTurnInFlight = false
        audioOutputInFlight = false
        speechRestartAfterTTSTask?.cancel()
        speechRestartAfterTTSTask = nil
        endLiveGoldenProcessingBackgroundTask(reason: "stop_validation")
        isRunning = false
        mode = .standby
        connectionState = .disconnected
        firstFrameAt = nil
        addLog("Stopped validation session.")
    }

    private func stopWearableCameraPreservingVoice(reason: String) {
        guard isRunning else { return }
        streamTask?.cancel()
        streamTask = nil
        sentinelTask?.cancel()
        sentinelTask = nil
        sentinelEnabled = false
        sentinelStatus = "Off"
        wearable.configureDisplayHUD(enabled: false)
        wearable.configurePersistentEligibilityRetry(enabled: false)
        wearable.stop()
        isRunning = false
        mode = .standby
        connectionState = .disconnected
        hudState = voiceBridgeEnabled ? "listening" : "idle"
        addLog("Stopped Meta DAT camera while preserving Jarvis voice; reason=\(reason).")
        emitVoiceBridgeEvent("dat_camera_stopped_voice_preserved", payload: [
            "reason": reason,
            "voice_bridge_enabled": voiceBridgeEnabled,
            "speech_input_running": isListening,
            "model_api_calls": false
        ])
    }

    func toggleLiveSentinel() {
        if sentinelEnabled {
            sentinelEnabled = false
            sentinelStatus = "Off"
            sentinelDecision = "Live sentinel disabled."
            sentinelEscalationLabel = "No"
            addLog("Live sentinel disabled.")
        } else {
            guard gemmaRealtimeProbeEnabled else {
                sentinelEnabled = false
                sentinelStatus = "Runtime blocked"
                sentinelDecision = "Realtime vision probe is disabled in this build."
                sentinelEscalationLabel = "No"
                addLog("Live sentinel blocked: realtime vision probe disabled in build.")
                return
            }
            sentinelEnabled = true
            sentinelStatus = "Waiting"
            sentinelDecision = "LFM2.5-VL-450M realtime probe armed. Artemis samples latest decoded frames with a bounded latest-frame-wins queue."
            sentinelEscalationLabel = "No"
            addLog("LFM realtime probe enabled with \(LocalLFMBenchmarkVariant.lfm450m.modelName), stride=\(sentinelFrameStride) frames.")
            emitAgentCEvent("lfm_realtime_enabled", payload: [
                "model": LocalLFMBenchmarkVariant.lfm450m.modelName,
                "runtime": "LEAP",
                "stride_frames": sentinelFrameStride
            ])
        }
    }

    func registerWearables() {
        guard Wearables.shared.registrationState != .registered else {
            isDATRegistered = true
            registrationStateLabel = String(describing: Wearables.shared.registrationState)
            addLog("DAT registration request ignored: app is already registered. Reconnect through Meta AI without starting registration again.")
            return
        }
        Task {
            do {
                addLog("Opening Meta AI registration flow.")
                try await Wearables.shared.startRegistration()
                await MainActor.run {
                    self.addLog("Started Meta DAT registration.")
                }
            } catch {
                await MainActor.run {
                    self.connectionState = .failed
                    self.addLog("DAT registration failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func unregisterWearables() {
        Task {
            do {
                addLog("Opening Meta AI unregistration flow.")
                try await Wearables.shared.startUnregistration()
                await MainActor.run {
                    self.addLog("Started Meta DAT unregistration.")
                }
            } catch {
                await MainActor.run {
                    self.addLog("DAT unregistration failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func requestCameraPermission() {
        Task {
            do {
                let current = try await Wearables.shared.checkPermissionStatus(.camera)
                await MainActor.run {
                    self.addLog("Camera permission before request: \(String(describing: current))")
                }

                let next = current == .granted ? current : try await Wearables.shared.requestPermission(.camera)
                await MainActor.run {
                    self.addLog("Camera permission after request: \(String(describing: next))")
                }
            } catch {
                await MainActor.run {
                    self.connectionState = .failed
                    self.addLog("Camera permission failed: \(describeDATPermissionError(error))")
                }
            }
        }
    }

    func openFirmwareUpdate() {
        Task {
            do {
                try await Wearables.shared.openFirmwareUpdate()
                await MainActor.run {
                    self.addLog("Opened Meta firmware update flow.")
                }
            } catch {
                await MainActor.run {
                    self.addLog("Firmware update flow failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func openDATGlassesAppUpdate() {
        Task {
            do {
                try await Wearables.shared.openDATGlassesAppUpdate()
                await MainActor.run {
                    self.addLog("Opened Meta DAT glasses app update flow.")
                }
            } catch {
                await MainActor.run {
                    self.addLog("DAT glasses app update failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    func toggleVoiceBridge() {
        if voiceBridgeEnabled {
            stopVoiceBridge()
        } else {
            startVoiceBridge()
        }
    }

    func selectJarvisBrainMode(_ mode: JarvisBrainMode) {
        if validatedVoiceRuntime.selectBrainMode(mode) {
            jarvisBrainMode = mode
            voiceBridgeStatus = mode == .codexBridge
                ? "Codex bridge selected"
                : "Local Gemma selected"
            addLog("Jarvis brain mode selected: \(mode.displayName).")
        } else {
            addLog("Jarvis brain mode change denied while a turn, playback, or incompatible Nano mode is active.")
        }
    }

    func startVoiceBridge(armListeningImmediately: Bool = true) {
        guard !voiceBridgeEnabled else { return }
        if validatedVoiceRuntimeActive {
            voiceBridgeEnabled = true
            voiceBridgeStatus = jarvisBrainMode == .codexBridge
                ? "Connecting Codex bridge"
                : "Warming local Gemma"
            hudState = armListeningImmediately ? "voice_starting" : "voice_armed"
            let selectedTTSEngine = ProcessInfo.processInfo.arguments.contains(
                "--run-jarvis-nano-bridge"
            )
                ? "supertonic_nano_remote"
                : "supertonic_3_coreml"
            emitVoiceBridgeEvent("validated_voice_runtime_started", payload: [
                "stt_source": "parakeet_eou_120m_coreml_160ms",
                "vad": "silero_coreml_shared_capture",
                "brain_mode": jarvisBrainMode.rawValue,
                "brain_impl": jarvisBrainMode.brainImplementation,
                "brain_model": jarvisBrainMode.brainModel,
                "brain_runtime": jarvisBrainMode.brainRuntime,
                "tts_engine": selectedTTSEngine,
                "audio_graph": "single_av_audio_engine_voice_processing_enabled",
                "meta_dat_ownership": "unchanged"
            ])
            addLog("Validated voice runtime armed; legacy Apple STT/GoldenBrain path bypassed, Meta DAT unchanged.")
            if armListeningImmediately {
                validatedVoiceRuntime.startListening()
            }
            return
        }
        voiceBridgeEnabled = true
        speechInput.requiredAudioRoutePolicy = nil
        if sttCalibrationModeEnabled {
            speechInput.useDuplexVoiceRoute = false
            speechOutput.useSystemDefaultRoute()
        } else if liveGoldenModeEnabled {
            speechInput.forcedRouteMode = nil
            speechInput.requiresOnDeviceRecognition = true
            speechInput.useDuplexVoiceRoute = false
            speechOutput.useSystemDefaultRoute()
        } else {
            speechInput.forcedRouteMode = nil
            speechInput.requiresOnDeviceRecognition = nil
            speechInput.useDuplexVoiceRoute = false
            speechOutput.useSystemDefaultRoute()
        }
        voiceBridgeStatus = armListeningImmediately ? "Armed" : "Armed for TTS"
        hudState = armListeningImmediately ? "listening" : "speaking_pending"
        lastRoutedVoiceText = ""
        lastVoiceAutoRouteCandidateText = ""
        voiceAutoRouteStablePartialCount = 0
        turnTaking.reset()
        if armListeningImmediately {
            turnTaking.startConversation()
        }
        emitVoiceBridgeEvent("voice_bridge_started", payload: [
            "audio_route_policy": liveGoldenModeEnabled ? "live_default_non_call" : "default"
        ])
        addLog("Voice bridge armed: Apple STT + TTS + turn-taking; audio_route_policy=\(liveGoldenModeEnabled ? "live_default_non_call" : "default").")
    }

    func stopVoiceBridge() {
        guard voiceBridgeEnabled else { return }
        if validatedVoiceRuntimeActive {
            validatedVoiceRuntime.stopListening()
            voiceBridgeEnabled = false
            isListening = false
            isSpeechInputStartInFlight = false
            voiceBridgeStatus = "Idle"
            speechInputStatus = "Stopped"
            speechOutputStatus = "Idle"
            hudState = "idle"
            emitVoiceBridgeEvent("validated_voice_runtime_stopped", payload: [:])
            addLog("Validated voice runtime stopped; Meta DAT ownership unchanged.")
            return
        }
        voiceBridgeEnabled = false
        speechInput.requiredAudioRoutePolicy = nil
        speechInput.forcedRouteMode = nil
        speechInput.requiresOnDeviceRecognition = nil
        speechInput.useDuplexVoiceRoute = false
        shouldResumeListeningAfterTTS = false
        speechRestartAfterTTSTask?.cancel()
        speechRestartAfterTTSTask = nil
        cancelVoiceAutoRoute()
        turnTaking.endConversation()
        stopListening()
        speechOutput.stop()
        voiceBridgeStatus = "Idle"
        hudState = "idle"
        sttCalibrationModeEnabled = false
        emitVoiceBridgeEvent("voice_bridge_stopped", payload: [:])
        addLog("Voice bridge stopped.")
    }

    func sendVoiceDraft() {
        let prompt = voiceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            addLog("Voice draft ignored: empty.")
            return
        }
        voiceBridgeStatus = "Routing typed prompt."
        voiceDraft = ""
        pendingTurnFinalizationReason = "manual"
        askBrain(prompt)
    }

    func speakTranscript() {
        let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            addLog("Speak transcript ignored: transcript empty.")
            return
        }
        speechOutput.speak(prompt, engine: selectedSpeechEngine)
    }

    func speakLastBrainResponse() {
        let response = lastBrainResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else {
            addLog("Speak response ignored: empty response.")
            return
        }
        speechOutput.speak(response, engine: selectedSpeechEngine)
    }

    func retryPrivateAudioRouteSpeech() {
        let pending = pendingPrivateAudioRetryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = pending.isEmpty ? lastBrainResponse.text.trimmingCharacters(in: .whitespacesAndNewlines) : pending
        guard !response.isEmpty else {
            addLog("Private audio retry ignored: empty response.")
            return
        }
        refreshAudioRouteDiagnostics()
        addLog("Retrying private Kokoro audio route for last GoldenBrainRouter response.")
        emitVoiceBridgeEvent("voice_private_audio_retry_requested", payload: [
            "turn_id": currentTurnID,
            "text_chars": response.count,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        speakGoldenResponseWithBargeIn(text: response, usePrivateGlassesRoute: true)
    }

    func stopSpeechOutput() {
        speechOutput.stop()
        speechOutputStatus = "Stopped"
        if voiceBridgeEnabled {
            emitVoiceBridgeEvent("voice_tts_stopped_manually", payload: [:])
        }
    }

    func runKokoroGenerationProbe() {
        modelBenchmarkStatus = "Kokoro generation probe"
        modelBenchmarkOutput = "Generating Kokoro samples without playback."
        addLog("Kokoro generation probe started without playback.")
        speechOutput.probeKokoroGeneration("Kokoro generation probe. Do not play audio.") { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(stats):
                self.modelBenchmarkStatus = "Kokoro generation ok"
                self.modelBenchmarkOutput = "voice=\(stats.voiceName), generation_ms=\(stats.generationMilliseconds), audio_s=\(String(format: "%.2f", stats.audioDurationSeconds)), raw_peak=\(String(format: "%.3f", stats.rawPeakSample)), gain=\(String(format: "%.3f", stats.normalizationGain)), peak=\(String(format: "%.3f", stats.peakSample)), clipped=\(stats.clippedSampleCount)"
                self.addLog("Kokoro generation probe complete: \(self.modelBenchmarkOutput)")
                self.emitVoiceBridgeEvent("kokoro_generation_probe_completed", payload: [
                    "playback": false,
                    "voice": stats.voiceName,
                    "generation_ms": stats.generationMilliseconds,
                    "audio_s": stats.audioDurationSeconds,
                    "raw_peak_sample": stats.rawPeakSample,
                    "normalization_gain": stats.normalizationGain,
                    "peak_sample": stats.peakSample,
                    "clipped_samples": stats.clippedSampleCount,
                    "audio_route": stats.audioRoute,
                    "session_sample_rate": stats.sessionSampleRate,
                    "output_latency_s": stats.outputLatencySeconds,
                    "sample_mode": stats.sampleMode,
                    "diagnostic_wav": stats.diagnosticWavPath ?? ""
                ])
            case let .failure(error):
                self.modelBenchmarkStatus = "Kokoro generation failed"
                self.modelBenchmarkOutput = error.localizedDescription
                self.addLog("Kokoro generation probe failed: \(error.localizedDescription)")
                self.emitVoiceBridgeEvent("kokoro_generation_probe_failed", payload: [
                    "playback": false,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    func clearTranscript() {
        transcript = ""
        lastRoutedVoiceText = ""
        lastVoiceAutoRouteCandidateText = ""
        voiceAutoRouteStablePartialCount = 0
        voiceBridgeStatus = voiceBridgeEnabled ? "Armed" : "Idle"
        addLog("Transcript cleared.")
    }

    func markVoiceIncident(label: String = "manual_marker") {
        let incidentID = "voice-\(Int(Date().timeIntervalSince1970 * 1000))"
        lastVoiceIncidentID = incidentID

        if let image = latestPreviewImage,
           let data = image.jpegData(compressionQuality: 0.62) {
            ArtemisBenchmarkEventStore.writeFrame(data, name: "\(incidentID)-preview.jpg")
        }

        emitVoiceBridgeEvent("voice_incident_marked", payload: [
            "incident_id": incidentID,
            "label": label,
            "transcript": transcript,
            "voice_draft": voiceDraft,
            "latest_preview_frame_id": latestPreviewFrameID,
            "last_observation_scene": lastObservation.scene,
            "last_observation_confidence": lastObservation.confidence,
            "sentinel_status": sentinelStatus,
            "sentinel_decision": sentinelDecision,
            "frames_received": framesReceived,
            "frames_analyzed": framesAnalyzed,
            "stream_fps": streamFPS
        ])
        addLog("Marked voice incident \(incidentID): \(label)")
    }

    private func pushDisplayHUD(reason: String) {
        guard nativeDisplayHUDEnabled else { return }
        glassesHUDLastUpdateReason = reason
        glassesHUDState = "queued"
        wearable.updateDisplayHUD(
            DisplayHUDSnapshot(
                mode: liveGoldenModeEnabled ? "live_golden" : "stream",
                streamState: connectionState.rawValue,
                framesReceived: framesReceived,
                decodedFrameImages: decodedFrameImages,
                streamFPS: streamFPS,
                sttText: hudSTTText.isEmpty ? transcript : hudSTTText,
                sttFinalizationReason: hudSTTFinalizationReason,
                assistantText: hudBrainText.isEmpty ? lastBrainResponse.text : hudBrainText,
                ttsText: hudTTSText,
                ttsVoice: hudTTSVoice,
                visionModel: hudVisionModel,
                visionFrameID: hudVisionFrameID,
                visionLatencyMS: hudVisionLatencyMS,
                visionSummary: hudVisionSummary,
                latencyText: "brain \(hudBrainLatencyMS)ms / first \(hudFirstResponseMS)ms / e2e \(hudEndToEndMS)ms / tts \(hudTTSGenerationMS)ms",
                powerLine: wearablePowerHUDLine(),
                stateText: hudState,
                updateReason: reason,
                updatedAtMS: nowMilliseconds()
            )
        )
    }

    private func startListening() {
        if validatedVoiceRuntimeActive {
            validatedVoiceRuntime.startListening()
            return
        }
        guard !isListening, !isSpeechInputStartInFlight else { return }
        guard canUseForegroundAudio() else {
            addLog("STT start deferred until active app; audio=\(audioRuntimeStateSummary())")
            emitVoiceBridgeEvent("voice_stt_deferred_for_lifecycle", payload: [
                "turn_id": pendingVoiceTurnID,
                "audio_runtime": audioRuntimeStateSummary()
            ])
            return
        }
        speechInput.requiredAudioRoutePolicy = nil
        if sttCalibrationModeEnabled {
            speechInput.forcedRouteMode = pendingSTTCalibrationRoute
            speechInput.requiresOnDeviceRecognition = pendingSTTRequiresOnDeviceRecognition
        } else {
            speechInput.forcedRouteMode = liveGoldenModeEnabled ? .bluetoothHFP : nil
            speechInput.requiresOnDeviceRecognition = liveGoldenModeEnabled ? true : nil
        }
        speechInput.useDuplexVoiceRoute = false
        isSpeechInputStartInFlight = true
        isStoppingSpeechInput = false
        speechInputStatus = "Starting"
        let routeDecision = ArtemisAudioRouteDecision(isAllowed: true, reason: liveGoldenModeEnabled ? "Live golden uses Bluetooth HFP duplex so the glasses mic can feed STT." : "No private route required.")
        addLog("STT starting; audio=\(audioRuntimeStateSummary())")
        emitVoiceBridgeEvent("voice_stt_start_requested", payload: [
            "turn_id": pendingVoiceTurnID,
            "required_route": sttCalibrationModeEnabled ? pendingSTTCalibrationRoute.rawValue : (liveGoldenModeEnabled ? "default_non_call" : "none"),
            "private_route_allowed": routeDecision.isAllowed,
            "private_route_reason": routeDecision.reason,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        Task {
            do {
                try await speechInput.start()
                await MainActor.run {
                    self.isSpeechInputStartInFlight = false
                    self.isListening = true
                    self.currentListenStartedAt = Date()
                    self.currentListenMaxPeak = 0
                    self.vadSpeechActive = false
                    self.lastVADSpeechAt = nil
                    self.didReportQuietInputForCurrentListen = false
                    self.didReportNoTranscriptForCurrentListen = false
                    self.lastSTTTranscriptAt = nil
                    self.lastVoiceAudioLevelEventAt = nil
                    self.speechInputStatus = "Listening"
                    self.hudState = "listening"
                    self.pushDisplayHUD(reason: "stt_listening")
                    self.addLog("Apple STT listening.")
                    self.emitVoiceBridgeEvent("voice_stt_started", payload: [
                        "turn_id": self.pendingVoiceTurnID,
                        "required_route": self.sttCalibrationModeEnabled ? self.pendingSTTCalibrationRoute.rawValue : (self.liveGoldenModeEnabled ? "default_non_call" : "none"),
                        "audio_runtime": self.audioRuntimeStateSummary()
                    ])
                }
            } catch {
                await MainActor.run {
                    self.isSpeechInputStartInFlight = false
                    self.speechInputStatus = "Failed"
                    self.emitVoiceBridgeEvent("voice_stt_failed_to_start", payload: [
                        "turn_id": self.pendingVoiceTurnID,
                        "required_route": self.sttCalibrationModeEnabled ? self.pendingSTTCalibrationRoute.rawValue : (self.liveGoldenModeEnabled ? "default_non_call" : "none"),
                        "error": describeSpeechRuntimeError(error),
                        "audio_runtime": self.audioRuntimeStateSummary()
                    ])
                    self.addLog("STT failed: \(describeSpeechRuntimeError(error)); audio=\(self.audioRuntimeStateSummary())")
                }
            }
        }
    }

    private func stopListening() {
        if validatedVoiceRuntimeActive {
            validatedVoiceRuntime.stopListening()
            isListening = false
            isSpeechInputStartInFlight = false
            speechInputStatus = "Stopped"
            return
        }
        guard isListening || isSpeechInputStartInFlight else { return }
        isStoppingSpeechInput = true
        isSpeechInputStartInFlight = false
        speechInput.stop()
        isListening = false
        currentListenStartedAt = nil
        currentListenMaxPeak = 0
        vadSpeechActive = false
        lastVADSpeechAt = nil
        didReportQuietInputForCurrentListen = false
        didReportNoTranscriptForCurrentListen = false
        speechInputStatus = "Stopped"
        cancelVoiceAutoRoute()
        addLog("Stopped Apple STT.")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.isStoppingSpeechInput = false
        }
    }

    private func restartListeningAfterSpeechOutput(reason: String) {
        guard voiceBridgeEnabled else { return }
        speechRestartAfterTTSTask?.cancel()
        let wasListening = isListening
        let wasStarting = isSpeechInputStartInFlight
        emitVoiceBridgeEvent("voice_stt_restart_after_tts_requested", payload: [
            "reason": reason,
            "was_listening": wasListening,
            "was_starting": wasStarting,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        if wasListening || wasStarting {
            emitVoiceBridgeEvent("voice_stt_restart_after_tts_skipped_already_armed", payload: [
                "reason": reason,
                "was_listening": wasListening,
                "was_starting": wasStarting,
                "audio_runtime": audioRuntimeStateSummary()
            ])
            addLog("Keeping STT armed after TTS; reason=\(reason); was_listening=\(wasListening); was_starting=\(wasStarting); audio=\(audioRuntimeStateSummary())")
            return
        }

        addLog("Starting STT after TTS; reason=\(reason); was_listening=\(wasListening); was_starting=\(wasStarting); audio=\(audioRuntimeStateSummary())")
        stopListening()
        speechRestartAfterTTSTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.voiceBridgeEnabled else { return }
            self.isStoppingSpeechInput = false
            self.emitVoiceBridgeEvent("voice_stt_restart_after_tts_starting", payload: [
                "reason": reason,
                "audio_runtime": self.audioRuntimeStateSummary()
            ])
            self.startListening()
            self.speechRestartAfterTTSTask = nil
        }
    }

    func askBrain(_ prompt: String? = nil, turnID: String? = nil) {
        let userPrompt = (prompt ?? transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        if validatedVoiceRuntimeActive {
            validatedVoiceRuntime.submitTypedText(
                userPrompt.isEmpty ? "Give a compact live status update." : userPrompt
            )
            return
        }
        routeGoldenTurn(
            userPrompt: userPrompt.isEmpty ? "Give a compact live status update." : userPrompt,
            finalizationReason: pendingTurnFinalizationReason == "unknown" ? "manual" : pendingTurnFinalizationReason,
            isStartup: false,
            turnID: turnID
        )
    }

    func startAudioGoldenSmoke() {
        liveGoldenModeEnabled = true
        selectedSpeechEngine = .kokoroLocal
        refreshLocalModels()
        guard !selectedModelPath.isEmpty else {
            failLiveGoldenTurn(
                reason: "No approved .litertlm text/router brain is installed in Documents/Models.",
                userPrompt: "audio_golden_smoke",
                finalizationReason: "startup_state",
                isStartup: true
            )
            return
        }
        didSpeakStartupGreeting = true
        shouldStartVoiceBridgeAfterStartupGreeting = true
        if !voiceBridgeEnabled {
            startVoiceBridge()
        }
        voiceBridgeStatus = "Audio golden smoke"
        hudState = "thinking"
        pushDisplayHUD(reason: "audio_golden_smoke_started")
        addLog("Audio golden smoke queued: GoldenBrainRouter + Kokoro + Voice Bridge, DAT disabled.")
        emitVoiceBridgeEvent("audio_golden_smoke_started", payload: [
            "brain_model": selectedModelName,
            "brain_runtime": "LiteRT-LM",
            "tts_engine": SpeechOutputEngine.kokoroLocal.rawValue,
            "dat_stream": false
        ])
        routeGoldenTurn(
            userPrompt: "Start an audio-only Artemis live test. Greet me briefly and ask what I want to test first.",
            finalizationReason: "startup_state",
            isStartup: true,
            allowVisionRefresh: false
        )
    }

    private func routeGoldenTurn(
        userPrompt: String,
        finalizationReason: String,
        isStartup: Bool,
        turnID requestedTurnID: String? = nil,
        allowVisionRefresh: Bool = true
    ) {
        pendingTurnFinalizationReason = "unknown"
        selectedSpeechEngine = .kokoroLocal
        mode = .query
        let turnID = requestedTurnID ?? "turn-\(nowMilliseconds())"
        currentTurnID = turnID
        hudTurnID = turnID
        currentTurnStartedAt = Date()

        if cerebrasFastpathModeEnabled {
            routeCerebrasFastpathTurn(
                userPrompt: userPrompt,
                finalizationReason: finalizationReason,
                isStartup: isStartup,
                turnID: turnID
            )
            return
        }

        refreshLocalModels()

        guard !selectedModelPath.isEmpty else {
            failLiveGoldenTurn(
                reason: "No approved .litertlm text/router brain is installed in Documents/Models.",
                userPrompt: userPrompt,
                finalizationReason: finalizationReason,
                isStartup: isStartup
            )
            return
        }

        if allowVisionRefresh, shouldRefreshVisionForTurn(userPrompt: userPrompt, isStartup: isStartup) {
            guard let image = latestPreviewImage,
                  let imageData = compressedSentinelJPEG(from: image) else {
                emitVoiceBridgeEvent("vision_refresh_skipped", payload: [
                    "turn_id": turnID,
                    "vision_refresh_reason": "visual_turn_no_latest_frame",
                    "transcript": userPrompt,
                    "latest_preview_frame_id": latestPreviewFrameID
                ])
                hudFallbackTriggered = true
                hudFallbackReason = "visual_turn_no_latest_frame"
                return routeGoldenTurn(
                    userPrompt: userPrompt,
                    finalizationReason: finalizationReason,
                    isStartup: isStartup,
                    turnID: turnID,
                    allowVisionRefresh: false
                )
            }

            if let metrics = latestDATFrameMetrics(), !metrics.isFresh {
                emitVoiceBridgeEvent("vision_refresh_skipped", payload: [
                    "turn_id": turnID,
                    "vision_refresh_reason": "visual_turn_dat_frame_stale",
                    "transcript": userPrompt,
                    "latest_preview_frame_id": latestPreviewFrameID,
                    "dat_frame_age_ms": metrics.frameAgeMS,
                    "dat_ingest_latency_ms": metrics.ingestLatencyMS,
                    "dat_frame_fresh": metrics.isFresh
                ])
                hudFallbackTriggered = true
                hudFallbackReason = "visual_turn_dat_frame_stale"
                return routeGoldenTurn(
                    userPrompt: userPrompt,
                    finalizationReason: finalizationReason,
                    isStartup: isStartup,
                    turnID: turnID,
                    allowVisionRefresh: false
                )
            }

            runOnDemandVisionForTurn(
                userPrompt: userPrompt,
                finalizationReason: finalizationReason,
                isStartup: isStartup,
                turnID: turnID,
                imageData: imageData,
                visionRefreshReason: "visual_turn_latest_frame"
            )
            return
        }

        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let benchmark = modelBenchmark
        let vision = liveVisionContext
        let visionFreshness = visionFreshnessVerdict(for: vision)
        let ledgerSnapshot = turnLedger.suffix(maxTurnLedgerEntries)
        let prompt = liveGoldenRouterPrompt(
            userPrompt: userPrompt,
            finalizationReason: finalizationReason,
            isStartup: isStartup,
            vision: vision,
            visionFreshness: visionFreshness,
            history: Array(ledgerSnapshot)
        )
        let started = Date()
        cancelLiveSentinelForBrainTurn()
        brainTurnInFlight = true
        beginLiveGoldenProcessingBackgroundTask(reason: isStartup ? "startup_turn" : "user_turn")

        hudState = isStartup ? "thinking_startup" : "thinking"
        hudSTTText = isStartup ? "(startup_state)" : userPrompt
        hudSTTFinalizationReason = finalizationReason
        hudBrainImpl = "GoldenBrainRouter"
        hudBrainModel = modelName
        hudBrainRuntime = "LiteRT-LM GPU"
        hudBrainText = ""
        hudBrainLatencyMS = 0
        hudVisionModel = vision.visionModel
        hudVisionFrameID = vision.frameID
        hudVisionLatencyMS = vision.latencyMS
        hudVisionAgeMS = visionAgeMS(for: vision)
        hudVisionFreshnessState = visionFreshness.state.rawValue
        hudVisionSummary = vision.summary
        hudFirstResponseMS = 0
        hudEndToEndMS = 0
        hudFallbackTriggered = false
        hudFallbackReason = "none"
        voiceBridgeStatus = "Routing via GoldenBrainRouter"
        pushDisplayHUD(reason: "golden_turn_started")

        if voiceBridgeEnabled {
            turnTaking.onProcessingStart()
        }

        emitVoiceBridgeEvent("golden_turn_started", payload: liveTurnEvidencePayload(
            turnID: turnID,
            userPrompt: userPrompt,
            finalizationReason: finalizationReason,
            brainLatencyMS: 0,
            firstResponseMS: 0,
            response: "",
            fallbackTriggered: false,
            fallbackReason: "none",
            vision: vision,
            extra: [
                "is_startup": isStartup,
                "prompt_chars": prompt.count,
                "turn_ledger_entries": ledgerSnapshot.count
            ]
        ))

        Task { [weak self] in
            do {
                let result = try await benchmark.runLiveGoldenTurn(
                    modelPath: modelPath,
                    modelName: modelName,
                    prompt: prompt,
                    maxNumTokens: liveGoldenContextTokenLimit,
                    onPartial: { partial, firstMS in
                        await MainActor.run {
                            guard let self else { return }
                            self.hudBrainText = partial
                            self.hudFirstResponseMS = firstMS
                            self.hudState = "generating"
                            self.pushDisplayHUD(reason: "brain_partial")
                        }
                    }
                )

                await MainActor.run {
                    guard let self else { return }
                    self.brainTurnInFlight = false
                    self.turnTaking.onProcessingComplete()
                    if !isStartup,
                       let invalidReason = self.invalidLiveUserResponseReason(result.spokenText, userPrompt: userPrompt) {
                        self.hudBrainText = result.spokenText
                        self.hudBrainLatencyMS = result.totalMilliseconds
                        self.hudFirstResponseMS = result.firstResponseMilliseconds
                        self.hudEndToEndMS = Int(Date().timeIntervalSince(started) * 1000)
                        self.addLog("GoldenBrainRouter rejected response for turn \(turnID): \(invalidReason); response=\(result.spokenText)")
                        self.failLiveGoldenTurn(
                            reason: invalidReason,
                            userPrompt: userPrompt,
                            finalizationReason: finalizationReason,
                            isStartup: isStartup
                        )
                        return
                    }
                    self.hudState = "speaking"
                    self.hudBrainText = result.spokenText
                    self.hudBrainLatencyMS = result.totalMilliseconds
                    self.hudFirstResponseMS = result.firstResponseMilliseconds
                    self.hudEndToEndMS = Int(Date().timeIntervalSince(started) * 1000)
                    self.hudFallbackTriggered = result.fallbackTriggered
                    self.hudFallbackReason = result.fallbackReason
                    self.endToEndLatencyMS = self.hudEndToEndMS
                    self.lastBrainResponse = BrainResponse(
                        text: result.spokenText,
                        shouldSendToDisplay: true,
                        shouldSpeak: true
                    )
                    if !isStartup {
                        self.appendTurnLedger(role: "user", text: userPrompt)
                        self.appendTurnLedger(role: "assistant", text: result.spokenText)
                    }
                    self.addLog("GoldenBrainRouter response: \(result.spokenText)")

                    var payload = self.liveTurnEvidencePayload(
                        turnID: turnID,
                        userPrompt: userPrompt,
                        finalizationReason: finalizationReason,
                        brainLatencyMS: result.totalMilliseconds,
                        firstResponseMS: result.firstResponseMilliseconds,
                        response: result.spokenText,
                        fallbackTriggered: result.fallbackTriggered,
                        fallbackReason: result.fallbackReason,
                        vision: vision,
                        extra: [
                            "raw_output": result.rawOutput,
                            "route": result.route,
                            "confidence": result.confidence,
                            "is_startup": isStartup,
                            "turn_ledger_entries": ledgerSnapshot.count
                        ]
                    )
                    if let metrics = result.liteRTMetrics {
                        payload["litert_metrics"] = metrics.payload
                    }
                    self.emitVoiceBridgeEvent("golden_turn_completed", payload: payload)
                    self.pushDisplayHUD(reason: "golden_turn_completed")
                    self.speakGoldenResponseWithBargeIn(text: result.spokenText)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.brainTurnInFlight = false
                    self.turnTaking.onProcessingComplete()
                    self.failLiveGoldenTurn(
                        reason: error.localizedDescription,
                        userPrompt: userPrompt,
                        finalizationReason: finalizationReason,
                        isStartup: isStartup
                    )
                }
            }
        }
    }

    private func routeCerebrasFastpathTurn(
        userPrompt: String,
        finalizationReason: String,
        isStartup: Bool,
        turnID: String
    ) {
        let started = Date()
        cancelLiveSentinelForBrainTurn()
        brainTurnInFlight = true
        beginLiveGoldenProcessingBackgroundTask(reason: isStartup ? "cerebras_fastpath_startup_turn" : "cerebras_fastpath_user_turn")

        hudState = isStartup ? "thinking_startup" : "thinking"
        hudSTTText = isStartup ? "(startup_state)" : userPrompt
        hudSTTFinalizationReason = finalizationReason
        hudBrainImpl = "CerebrasFastpath"
        hudBrainModel = "gemma-4-31b"
        hudBrainRuntime = "M4 HUD server /fastpath-reply"
        hudBrainText = ""
        hudBrainLatencyMS = 0
        hudFirstResponseMS = 0
        hudEndToEndMS = 0
        hudFallbackTriggered = false
        hudFallbackReason = "none"
        voiceBridgeStatus = "Routing via Cerebras fastpath"
        pushDisplayHUD(reason: "cerebras_fastpath_turn_started")

        if voiceBridgeEnabled {
            turnTaking.onProcessingStart()
        }

        emitVoiceBridgeEvent("cerebras_fastpath_turn_started", payload: [
            "turn_id": turnID,
            "transcript": userPrompt,
            "turn_finalization_reason": finalizationReason,
            "brain_impl": "CerebrasFastpath",
            "brain_model": "gemma-4-31b",
            "brain_runtime": "M4 HUD server /fastpath-reply",
            "is_startup": isStartup,
            "fastpath_base_url": ArtemisFastpathRuntime.baseURL.absoluteString
        ])

        Task { [weak self] in
            do {
                guard let self else { return }
                let reply = try await self.fastpathClient.reply(
                    transcript: userPrompt,
                    context: [
                        "turn_id": turnID,
                        "finalization_reason": finalizationReason,
                        "is_startup": isStartup ? "true" : "false",
                        "surface": "artemis_voice_fastpath",
                        "vision_frame_id": "\(self.liveVisionContext.frameID)",
                        "vision_summary": String(self.liveVisionContext.summary.prefix(240))
                    ]
                )
                await MainActor.run {
                    let text = reply.spokenText
                    self.brainTurnInFlight = false
                    self.turnTaking.onProcessingComplete()
                    self.hudState = text.isEmpty ? "blocked" : "speaking"
                    self.hudBrainText = text
                    self.hudBrainModel = reply.model ?? "gemma-4-31b"
                    self.hudBrainRuntime = "M4 HUD server /fastpath-reply"
                    self.hudBrainLatencyMS = reply.latencyMS ?? 0
                    self.hudFirstResponseMS = reply.latencyMS ?? 0
                    self.hudEndToEndMS = Int(Date().timeIntervalSince(started) * 1000)
                    self.endToEndLatencyMS = self.hudEndToEndMS
                    self.hudFallbackTriggered = text.isEmpty
                    self.hudFallbackReason = text.isEmpty ? (reply.error ?? "empty_fastpath_reply") : "none"
                    self.lastBrainResponse = BrainResponse(
                        text: text.isEmpty ? "Cerebras fastpath blocked: \(self.hudFallbackReason)" : text,
                        shouldSendToDisplay: true,
                        shouldSpeak: !text.isEmpty
                    )
                    if !isStartup, !text.isEmpty {
                        self.appendTurnLedger(role: "user", text: userPrompt)
                        self.appendTurnLedger(role: "assistant", text: text)
                    }
                    self.addLog("Cerebras fastpath response: status=\(reply.status) model=\(reply.model ?? "-") latency_ms=\(reply.latencyMS ?? 0) text=\(text)")
                    self.emitVoiceBridgeEvent("cerebras_fastpath_turn_completed", payload: [
                        "turn_id": turnID,
                        "transcript": userPrompt,
                        "response": text,
                        "status": reply.status,
                        "executed": reply.executed,
                        "provider": reply.provider ?? "cerebras",
                        "brain_impl": "CerebrasFastpath",
                        "brain_model": reply.model ?? "gemma-4-31b",
                        "brain_runtime": "M4 HUD server /fastpath-reply",
                        "brain_latency_ms": reply.latencyMS ?? 0,
                        "first_response_ms": reply.latencyMS ?? 0,
                        "end_to_end_ms": self.hudEndToEndMS,
                        "fallback_triggered": text.isEmpty,
                        "fallback_reason": self.hudFallbackReason,
                        "is_startup": isStartup
                    ])
                    self.pushDisplayHUD(reason: "cerebras_fastpath_turn_completed")
                    if text.isEmpty {
                        self.voiceBridgeStatus = "Cerebras fastpath blocked"
                        self.drainPendingLiveSentinelIfNeeded()
                    } else {
                        self.speakGoldenResponseWithBargeIn(text: text)
                    }
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    let reason = String(describing: error)
                    self.brainTurnInFlight = false
                    self.turnTaking.onProcessingComplete()
                    self.hudState = "blocked"
                    self.hudBrainText = "Blocked: \(reason)"
                    self.hudFallbackTriggered = true
                    self.hudFallbackReason = reason
                    self.voiceBridgeStatus = "Cerebras fastpath failed"
                    self.addLog("Cerebras fastpath failed: \(reason)")
                    self.pushDisplayHUD(reason: "cerebras_fastpath_turn_failed")
                    self.emitVoiceBridgeEvent("cerebras_fastpath_turn_failed", payload: [
                        "turn_id": turnID,
                        "transcript": userPrompt,
                        "brain_impl": "CerebrasFastpath",
                        "brain_model": "gemma-4-31b",
                        "brain_runtime": "M4 HUD server /fastpath-reply",
                        "error": reason,
                        "fallback_triggered": true,
                        "fallback_reason": reason,
                        "is_startup": isStartup
                    ])
                    self.drainPendingLiveSentinelIfNeeded()
                }
            }
        }
    }

    private func resolveValidatedVisualContext(
        transcript: String,
        turnID: UUID,
        decision: JarvisVisualIntentDecision
    ) async throws -> JarvisVisualEvidence? {
        switch decision.action {
        case .none:
            return nil
        case .stopCamera:
            stopWearableCameraPreservingVoice(reason: "explicit_voice_intent")
            return nil
        case .inspectCurrentView, .startContinuousView:
            break
        }

        let powerDecision = updateDeviceTelemetry(cameraRequested: true)
        guard powerDecision.allowsCameraStart else {
            throw JarvisVisualContextError.cameraNotReady(
                "power_policy_\(powerDecision.mode.rawValue)_\(powerDecision.reason)"
            )
        }

        let startedCameraForThisTurn = !isRunning
        if startedCameraForThisTurn {
            emitVoiceBridgeEvent("visual_intent_camera_start_requested", payload: [
                "turn_id": turnID.uuidString,
                "vision_intent": decision.action.rawValue,
                "power_mode": powerDecision.mode.rawValue,
                "power_reason": powerDecision.reason,
                "model_api_calls": false
            ])
            startValidation()
        }
        let shouldStopCameraAfterResolution = startedCameraForThisTurn
            && decision.action == .inspectCurrentView
        defer {
            if shouldStopCameraAfterResolution {
                stopWearableCameraPreservingVoice(reason: "one_shot_visual_intent_complete")
            }
        }
        guard isRunning else {
            throw JarvisVisualContextError.cameraNotReady("dat_start_denied")
        }

        let frame = try await waitForFreshDATFrame(timeoutSeconds: 8)
        guard let imageData = compressedSentinelJPEG(from: frame.image) else {
            throw JarvisVisualContextError.noFreshFrame("jpeg_encoding_failed")
        }

        let variant = LocalLFMBenchmarkVariant.lfm450m
        hudState = "vision"
        hudVisionModel = variant.modelName
        voiceBridgeStatus = "Analyzing current glasses view"
        emitVoiceBridgeEvent("validated_visual_probe_started", payload: [
            "turn_id": turnID.uuidString,
            "vision_intent": decision.action.rawValue,
            "frame_id": frame.id,
            "frame_age_ms": frame.ageMilliseconds,
            "capture_mode": "latest_stream_frame_512px_q034",
            "model": variant.modelName,
            "runtime": "LEAP",
            "quantization": variant.quantization,
            "jpeg_bytes": imageData.count,
            "model_api_calls": false
        ])

        let result: LocalModelBenchmarkResult
        do {
            result = try await lfmBenchmark.runVisionProbe(imageData: imageData, variant: variant)
        } catch {
            throw JarvisVisualContextError.analysisFailed(error.localizedDescription)
        }

        let context = liveVisionContextFromLFMResult(
            result.responseText,
            frameID: frame.id,
            latencyMS: result.totalMilliseconds
        )
        let freshness = VisionFreshnessPolicy.classify(
            frameID: context.frameID,
            timestampMS: context.timestampMS,
            ageMS: frame.ageMilliseconds,
            confidence: context.confidence,
            summary: context.summary,
            visibleText: context.visibleText,
            streamState: connectionState.rawValue
        )
        guard freshness.state != .stale,
              freshness.state != .unavailable,
              freshness.state != .streamStopped else {
            throw JarvisVisualContextError.noFreshFrame(freshness.reason)
        }

        liveVisionContext = context
        hudVisionModel = context.visionModel
        hudVisionFrameID = context.frameID
        hudVisionLatencyMS = context.latencyMS
        hudVisionAgeMS = frame.ageMilliseconds
        hudVisionFreshnessState = freshness.state.rawValue
        hudVisionSummary = context.summary
        framesAnalyzed += 1
        let uncertainty = freshness.supportsDirectVisualClaim
            ? context.uncertainty
            : "\(freshness.reason); \(context.uncertainty)"
        let evidence = JarvisVisualEvidence(
            source: "meta_dat",
            captureMode: "latest_stream_frame_512px_q034",
            evidenceClass: "live_dat_plus_local_vlm",
            model: variant.modelName,
            runtime: "LEAP",
            quantization: variant.quantization,
            frameID: frame.id,
            frameAgeMilliseconds: frame.ageMilliseconds,
            inferenceMilliseconds: result.totalMilliseconds,
            summary: context.summary,
            visibleText: context.visibleText,
            uncertainty: uncertainty,
            confidence: context.confidence,
            directClaimAllowed: freshness.supportsDirectVisualClaim
        )
        emitVoiceBridgeEvent("validated_visual_probe_result", payload: [
            "turn_id": turnID.uuidString,
            "vision_intent": decision.action.rawValue,
            "frame_id": frame.id,
            "frame_age_ms": frame.ageMilliseconds,
            "capture_mode": evidence.captureMode,
            "model": evidence.model,
            "runtime": evidence.runtime,
            "quantization": evidence.quantization,
            "latency_ms": evidence.inferenceMilliseconds,
            "confidence": evidence.confidence,
            "direct_claim_allowed": evidence.directClaimAllowed,
            "freshness_state": freshness.state.rawValue,
            "freshness_reason": freshness.reason,
            "model_api_calls": false
        ])
        pushDisplayHUD(reason: "validated_visual_probe_result")
        return evidence
    }

    private func waitForFreshDATFrame(
        timeoutSeconds: TimeInterval
    ) async throws -> (image: UIImage, id: Int, ageMilliseconds: Int) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let image = latestPreviewImage,
               latestPreviewFrameID > 0,
               let metrics = latestDATFrameMetrics(),
               metrics.isFresh {
                return (image, latestPreviewFrameID, metrics.frameAgeMS)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let diagnostic = wearable.diagnosticSnapshot()
        throw JarvisVisualContextError.noFreshFrame(
            "timeout; stream=\(diagnostic.streamState); error=\(diagnostic.lastError)"
        )
    }

    private func shouldRefreshVisionForTurn(userPrompt: String, isStartup: Bool) -> Bool {
        guard !isStartup else { return false }
        let text = userPrompt.lowercased()
        let visualKeywords = [
            "see", "look", "looking", "visible", "vision", "camera", "glasses",
            "around me", "in front", "what is this", "what's this", "read",
            "screen", "text", "where", "object", "room", "surrounding"
        ]
        guard visualKeywords.contains(where: { text.contains($0) }) else { return false }
        if liveVisionContext.frameID == latestPreviewFrameID,
           liveVisionContext.frameID > 0,
           visionAgeMS(for: liveVisionContext) <= 2_500 {
            return false
        }
        return true
    }

    private func runOnDemandVisionForTurn(
        userPrompt: String,
        finalizationReason: String,
        isStartup: Bool,
        turnID: String,
        imageData: Data,
        visionRefreshReason: String
    ) {
        cancelLiveSentinelForBrainTurn()
        let frameID = latestPreviewFrameID
        let variant = LocalLFMBenchmarkVariant.lfm450m
        hudState = "vision"
        hudVisionModel = variant.modelName
        hudFallbackTriggered = true
        hudFallbackReason = visionRefreshReason
        voiceBridgeStatus = "Refreshing live vision"
        addLog("On-demand vision refresh for turn \(turnID), frame \(frameID), reason=\(visionRefreshReason), bytes=\(imageData.count).")
        pushDisplayHUD(reason: "vision_probe_started")
        emitVoiceBridgeEvent("vision_probe_started", payload: [
            "turn_id": turnID,
            "frame_id": frameID,
            "model": variant.modelName,
            "runtime": "LEAP",
            "quantization": variant.quantization,
            "jpeg_bytes": imageData.count,
            "vision_refresh_reason": visionRefreshReason
        ])

        let benchmark = lfmBenchmark
        Task { [weak self] in
            do {
                let result = try await benchmark.runVisionProbe(imageData: imageData, variant: variant)
                await MainActor.run {
                    guard let self else { return }
                    let visionContext = self.liveVisionContextFromLFMResult(
                        result.responseText,
                        frameID: frameID,
                        latencyMS: result.totalMilliseconds
                    )
                    let visionFreshness = VisionFreshnessPolicy.classify(
                        frameID: visionContext.frameID,
                        timestampMS: visionContext.timestampMS,
                        ageMS: 0,
                        confidence: visionContext.confidence,
                        summary: visionContext.summary,
                        visibleText: visionContext.visibleText,
                        streamState: self.connectionState.rawValue
                    )
                    let visionPolicy = self.hierarchicalVisionDecision(
                        frameID: visionContext.frameID,
                        frameAgeMS: 0,
                        latencyMS: result.totalMilliseconds,
                        confidence: visionContext.confidence,
                        summary: visionContext.summary,
                        visibleText: visionContext.visibleText,
                        userPrompt: userPrompt,
                        detectedFailure: self.isLowInformationVisionResponse(result.responseText),
                        sceneChanged: self.detectEscalation(in: result.responseText),
                        evidenceClass: "live_dat"
                    )
                    self.recordHierarchicalVisionDecisionIfNeeded(visionPolicy)
                    self.framesAnalyzed += 1
                    self.sentinelSamples += 1
                    self.sentinelLastInferenceMS = result.totalMilliseconds
                    self.averageInferenceMS = result.totalMilliseconds
                    self.liveVisionContext = visionContext
                    self.hudVisionModel = visionContext.visionModel
                    self.hudVisionFrameID = visionContext.frameID
                    self.hudVisionLatencyMS = visionContext.latencyMS
                    self.hudVisionAgeMS = 0
                    self.hudVisionFreshnessState = visionFreshness.state.rawValue
                    self.hudVisionSummary = visionContext.summary
                    self.lastObservation = VisionObservation(
                        timestamp: .now,
                        scene: visionContext.summary,
                        peopleCount: 0,
                        objects: self.extractVisionStringArray(key: "objects", from: result.responseText),
                        visibleText: visionContext.visibleText,
                        notableChange: visionContext.uncertainty,
                        confidence: visionContext.confidence
                    )
                    self.addLog("On-demand vision refresh complete for turn \(turnID): \(result.compactSummary)")
                    self.pushDisplayHUD(reason: "vision_probe_result")
                    var payload: [String: Any] = [
                        "turn_id": turnID,
                        "frame_id": frameID,
                        "model": variant.modelName,
                        "runtime": "LEAP",
                        "quantization": variant.quantization,
                        "latency_ms": result.totalMilliseconds,
                        "jpeg_bytes": imageData.count,
                        "response_text": result.responseText,
                        "vision_summary": visionContext.summary,
                        "vision_confidence": visionContext.confidence,
                        "vision_freshness_state": visionFreshness.state.rawValue,
                        "vision_freshness_reason": visionFreshness.reason,
                        "vision_direct_claim_allowed": visionFreshness.supportsDirectVisualClaim,
                        "vision_refresh_reason": visionRefreshReason
                    ]
                    for (key, value) in self.hierarchicalVisionPolicyPayload(visionPolicy) {
                        payload[key] = value
                    }
                    self.emitVoiceBridgeEvent("vision_probe_result", payload: payload)
                    self.pushDisplayHUD(reason: "vision_probe_result")
                    self.routeGoldenTurn(
                        userPrompt: userPrompt,
                        finalizationReason: finalizationReason,
                        isStartup: isStartup,
                        turnID: turnID,
                        allowVisionRefresh: false
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.addLog("On-demand vision refresh failed for turn \(turnID): \(error.localizedDescription)")
                    self.emitVoiceBridgeEvent("vision_probe_failed", payload: [
                        "turn_id": turnID,
                        "frame_id": frameID,
                        "model": variant.modelName,
                        "runtime": "LEAP",
                        "quantization": variant.quantization,
                        "jpeg_bytes": imageData.count,
                        "error": error.localizedDescription,
                        "vision_refresh_reason": visionRefreshReason
                    ])
                    self.routeGoldenTurn(
                        userPrompt: userPrompt,
                        finalizationReason: finalizationReason,
                        isStartup: isStartup,
                        turnID: turnID,
                        allowVisionRefresh: false
                    )
                }
            }
        }
    }

    private func failLiveGoldenTurn(
        reason: String,
        userPrompt: String,
        finalizationReason: String,
        isStartup: Bool
    ) {
        endLiveGoldenProcessingBackgroundTask(reason: "golden_turn_blocked")
        hudState = "blocked"
        hudBrainImpl = "GoldenBrainRouter"
        hudBrainModel = selectedModelName
        hudBrainRuntime = "LiteRT-LM GPU"
        hudBrainText = "Blocked: \(reason)"
        hudFallbackTriggered = true
        hudFallbackReason = reason
        lastBrainResponse = BrainResponse(
            text: "Live golden loop blocked: \(reason)",
            shouldSendToDisplay: true,
            shouldSpeak: false
        )
        voiceBridgeStatus = "Blocked"
        addLog("Live golden turn blocked: \(reason)")
        pushDisplayHUD(reason: "golden_turn_blocked")
        emitVoiceBridgeEvent("golden_turn_blocked", payload: liveTurnEvidencePayload(
            turnID: currentTurnID.isEmpty ? "turn-\(nowMilliseconds())" : currentTurnID,
            userPrompt: userPrompt,
            finalizationReason: finalizationReason,
            brainLatencyMS: 0,
            firstResponseMS: 0,
            response: "",
            fallbackTriggered: true,
            fallbackReason: reason,
            vision: liveVisionContext,
            extra: ["is_startup": isStartup]
        ))
    }

    private func speakGoldenResponseWithBargeIn(
        text: String,
        usePrivateGlassesRoute: Bool = false
    ) {
        selectedSpeechEngine = .kokoroLocal
        guard canUseForegroundAudio() else {
            pendingForegroundKokoroText = text
            audioOutputInFlight = false
            speechOutputStatus = "Deferred"
            hudState = "waiting_foreground"
            addLog("Kokoro speech deferred until active app; chars=\(text.count); audio=\(audioRuntimeStateSummary())")
            pushDisplayHUD(reason: "tts_deferred_lifecycle")
            emitVoiceBridgeEvent("voice_tts_deferred_for_lifecycle", payload: [
                "turn_id": currentTurnID,
                "text_chars": text.count,
                "audio_runtime": audioRuntimeStateSummary()
            ])
            return
        }
        audioOutputInFlight = true
        cancelLiveSentinelForAudioOutput()
        if liveGoldenModeEnabled, usePrivateGlassesRoute {
            speechOutput.enableDuplexBargeInRoute()
            addLog("TTS preparing Kokoro on explicitly requested Bluetooth HFP duplex route. audio=\(audioRuntimeStateSummary())")
        } else {
            speechOutput.useSystemDefaultRoute()
            addLog("TTS preparing Kokoro on iOS default audio route. audio=\(audioRuntimeStateSummary())")
        }
        speechOutput.speak(text, engine: .kokoroLocal)
    }

    private func invalidLiveUserResponseReason(_ response: String, userPrompt: String) -> String? {
        let normalized = response
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "router_empty_response"
        }
        if normalized.contains("what would you like to test")
            || normalized.contains("what do you want to test")
            || normalized == "hello!"
            || normalized == "hello! i am online." {
            return "router_repeated_startup_greeting"
        }
        if normalized == "direct answer"
            || normalized == "concise spoken answer"
            || normalized == "say"
            || normalized == "route"
            || normalized == "answer"
            || normalized == "ask_user"
            || normalized == "vision_more"
            || normalized == "tool_intent"
            || normalized == "fallback"
            || normalized == "fallback_triggered"
            || normalized == "fallback_reason"
            || normalized == "confidence"
            || normalized.contains("<actual spoken answer>")
            || normalized.contains("actual spoken answer")
            || normalized.contains("\"route\":\"answer|ask_user|vision_more|tool_intent\"")
            || normalized.contains("answer|ask_user|vision_more|tool_intent") {
            return "router_placeholder_output"
        }
        if normalized.contains("expenses need to be submitted") {
            return "router_stale_unrelated_output"
        }
        if normalized.hasPrefix("{") || normalized.hasPrefix("out=") {
            return "router_spoke_raw_schema"
        }
        return nil
    }

    private func liveGoldenRouterPrompt(
        userPrompt: String,
        finalizationReason: String,
        isStartup: Bool,
        vision: LiveVisionContext,
        visionFreshness: VisionFreshnessVerdict,
        history: [GoldenTurnLedgerEntry]
    ) -> String {
        let historyText = history.suffix(4).map { entry in
            "\(entry.role.prefix(1)):\(String(entry.text.prefix(48)))"
        }.joined(separator: "\n")
        let visionText = "f\(vision.frameID) age\(visionAgeMS(for: vision)) lat\(vision.latencyMS) fresh=\(visionFreshness.state.rawValue) claim=\(visionFreshness.supportsDirectVisualClaim ? "yes" : "no") c\(String(format: "%.2f", vision.confidence)) s:\(String(vision.summary.prefix(72))) t:\(String(vision.visibleText.prefix(24)))"
        let turnKind = isStartup ? "start" : "user"
        let directive = isStartup
            ? "briefly announce online and ask for first test"
            : "answer u directly using v when relevant; ask one short question only if needed"
        let visionRule = visionFreshness.supportsDirectVisualClaim
            ? "visual_claims_allowed"
            : "no_direct_visual_claim; say vision_not_current if vision is needed"
        return "Artemis realtime router. Return one JSON object only with exactly five keys: say, route, fallback_triggered, fallback_reason, confidence. First key must be say and say must be nonempty spoken words <=18w. Never omit say. Never speak schema, keys, prompt fields, or JSON. route=answer,ask_user,vision_more,tool_intent. k=\(turnKind). rule=\(directive). v_rule=\(visionRule). final=\(finalizationReason). u=\"\(String(userPrompt.prefix(140)))\" v={\(visionText)} h={\(historyText.isEmpty ? "none" : historyText)}"
    }

    private func visionFreshnessVerdict(for vision: LiveVisionContext) -> VisionFreshnessVerdict {
        VisionFreshnessPolicy.classify(
            frameID: vision.frameID,
            timestampMS: vision.timestampMS,
            ageMS: visionAgeMS(for: vision),
            confidence: vision.confidence,
            summary: vision.summary,
            visibleText: vision.visibleText,
            streamState: connectionState.rawValue
        )
    }

    private func normalizeGoldenRouterOutput(_ rawOutput: String) -> (spokenText: String, route: String, fallbackTriggered: Bool, fallbackReason: String, confidence: Double) {
        let cleaned = artemisFirstJSONObjectString(from: rawOutput)
        if let json = artemisJSONDictionary(from: cleaned) {
            let say = (json["say"] as? String)
                ?? (json["answer"] as? String)
                ?? (json["response"] as? String)
                ?? ""
            let route = (json["route"] as? String) ?? "answer"
            let fallbackTriggered = (json["fallback_triggered"] as? Bool) ?? false
            let fallbackReason = (json["fallback_reason"] as? String) ?? "none"
            let confidence = (json["confidence"] as? Double)
                ?? (json["confidence"] as? NSNumber)?.doubleValue
                ?? Double((json["confidence"] as? String) ?? "")
                ?? 0.0
            let spoken = say.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty {
                return (String(spoken.prefix(260)), route, fallbackTriggered, fallbackReason, confidence)
            }
        }
        if let repaired = artemisJSONStringValue(for: "say", in: rawOutput)
            ?? artemisJSONStringValue(for: "answer", in: rawOutput)
            ?? artemisJSONStringValue(for: "response", in: rawOutput) {
            let spoken = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty {
                return (
                    String(spoken.prefix(260)),
                    "repaired_partial_json",
                    true,
                    "router_output_repaired_partial_json",
                    0.45
                )
            }
        }
        return (
            "I did not get a usable local model response.",
            "invalid_json",
            true,
            "router_output_not_valid_json",
            0.0
        )
    }

    private func liveTurnEvidencePayload(
        turnID: String,
        userPrompt: String,
        finalizationReason: String,
        brainLatencyMS: Int,
        firstResponseMS: Int,
        response: String,
        fallbackTriggered: Bool,
        fallbackReason: String,
        vision: LiveVisionContext,
        extra: [String: Any]
    ) -> [String: Any] {
        let visionAgeMS = visionAgeMS(for: vision)
        let visionFreshness = visionFreshnessVerdict(for: vision)
        var payload: [String: Any] = [
            "turn_id": turnID,
            "stt_source": "apple",
            "turn_finalization_reason": finalizationReason,
            "transcript": userPrompt,
            "brain_impl": "GoldenBrainRouter",
            "brain_model": selectedModelName,
            "brain_runtime": "LiteRT-LM GPU",
            "brain_latency_ms": brainLatencyMS,
            "brain_output_contract": "live_router_json_v5_18w_512tok_freshconv",
            "vision_source": vision.source,
            "vision_model": vision.visionModel,
            "vision_prompt_mode": vision.promptMode,
            "vision_frame_id": vision.frameID,
            "vision_timestamp_ms": vision.timestampMS,
            "vision_age_ms_at_turn": visionAgeMS,
            "vision_freshness_state": visionFreshness.state.rawValue,
            "vision_freshness_reason": visionFreshness.reason,
            "vision_direct_claim_allowed": visionFreshness.supportsDirectVisualClaim,
            "vision_stream_state": connectionState.rawValue,
            "vision_latency_ms": vision.latencyMS,
            "vision_summary": vision.summary,
            "vision_visible_text": vision.visibleText,
            "vision_uncertainty": vision.uncertainty,
            "vision_confidence": vision.confidence,
            "latest_preview_frame_id_at_turn": latestPreviewFrameID,
            "frames_received_at_turn": framesReceived,
            "frames_analyzed_at_turn": framesAnalyzed,
            "stream_fps_at_turn": streamFPS,
            "tts_engine": SpeechOutputEngine.kokoroLocal.rawValue,
            "first_response_ms": firstResponseMS,
            "end_to_end_ms": hudEndToEndMS,
            "fallback_triggered": fallbackTriggered,
            "fallback_reason": fallbackReason,
            "response": response,
            "hud_state": hudState
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        return payload
    }

    private func visionAgeMS(for vision: LiveVisionContext) -> Int {
        guard vision.timestampMS > 0 else { return -1 }
        return max(0, nowMilliseconds() - vision.timestampMS)
    }

    private func datLifecycleState(for state: WearableConnectionState) -> DATLifecycleState {
        switch state {
        case .disconnected, .simulated:
            return .disconnected
        case .connecting, .connected:
            return .connecting
        case .streaming:
            return .streaming
        case .degraded, .failed:
            return .degraded
        case .stale:
            return .stale
        }
    }

    private func wearableConnectionState(for state: DATLifecycleState) -> WearableConnectionState {
        switch state {
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .streaming:
            return .streaming
        case .degraded:
            return .degraded
        case .stale:
            return .stale
        }
    }

    private func datLifecyclePayload(
        decision: DATLifecycleDecision,
        metrics: DATFrameMetrics?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "dat_lifecycle_state": decision.state.rawValue,
            "dat_lifecycle_reason": decision.reason,
            "dat_accept_live_visual_context": decision.acceptLiveVisualContext,
            "dat_device_unavailable_reason": decision.deviceUnavailableReason,
            "dat_stream_fps": streamFPS,
            "dat_dropped_frames": datDroppedFrames,
            "thermal_state": thermalLabelForEvent(thermalState),
            "phone_battery": batteryLabel,
            "phone_power_mode": powerModeLabel,
            "wearable_battery": wearableBatteryLabel,
            "wearable_battery_source": "dat_error_only_no_percentage_api",
            "wearable_thermal_level": wearableThermalLabel,
            "wearable_power_mode": wearablePowerModeLabel.lowercased(),
            "wearable_power_reason": wearablePowerReason,
            "app_lifecycle_state": appLifecycleState
        ]
        if let metrics {
            payload["dat_frame_age_ms"] = metrics.frameAgeMS
            payload["dat_ingest_latency_ms"] = metrics.ingestLatencyMS
            payload["dat_frame_fresh"] = metrics.isFresh
        }
        return payload
    }

    private func latestDATFrameMetrics(nowMS: Int? = nil) -> DATFrameMetrics? {
        guard latestPreviewFrameID > 0 else { return nil }
        return DATLifecyclePolicy.frameMetrics(
            frameID: latestPreviewFrameID,
            previousFrameID: latestPreviewFrameID,
            sourceTimestampMS: latestDATFrameSourceTimestampMS,
            ingestTimestampMS: latestDATFrameIngestTimestampMS,
            nowMS: nowMS ?? nowMilliseconds()
        )
    }

    private func appendTurnLedger(role: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turnLedger.append(GoldenTurnLedgerEntry(role: role, text: trimmed, timestampMS: nowMilliseconds()))
        if turnLedger.count > maxTurnLedgerEntries {
            turnLedger.removeFirst(turnLedger.count - maxTurnLedgerEntries)
        }
    }

    private func nowMilliseconds() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    func runExtractionPass() {
        mode = .extraction
        addLog("Extraction pass requested. Current implementation uses schema-shaped mock output.")
        askBrain("Summarize the current scene as a short wearable status.")
    }

    func importModel(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let modelsDirectory = try localModelsDirectory()
            let destination = modelsDirectory.appendingPathComponent(url.lastPathComponent)

            if url.standardizedFileURL == destination.standardizedFileURL,
               FileManager.default.fileExists(atPath: destination.path) {
                selectedModelPath = destination.path
                selectedModelName = destination.lastPathComponent
                modelBenchmarkStatus = "Ready"
                modelBenchmarkOutput = "Selected existing \(selectedModelName); no copy needed."
                addLog("Selected existing local model: \(selectedModelName)")
                return
            }

            let tempDestination = modelsDirectory
                .appendingPathComponent(".import-\(UUID().uuidString)-\(url.lastPathComponent)")
            do {
                try FileManager.default.copyItem(at: url, to: tempDestination)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempDestination, to: destination)
            } catch {
                if FileManager.default.fileExists(atPath: tempDestination.path) {
                    try? FileManager.default.removeItem(at: tempDestination)
                }
                throw error
            }

            selectedModelPath = destination.path
            selectedModelName = destination.lastPathComponent
            modelBenchmarkStatus = "Ready"
            modelBenchmarkOutput = "Selected \(selectedModelName). Run synthetic first, then latest-frame vision."
            addLog("Imported local model: \(selectedModelName)")
        } catch {
            modelBenchmarkStatus = "Import failed"
            modelBenchmarkOutput = error.localizedDescription
            addLog("Model import failed: \(error.localizedDescription)")
        }
    }

    func importBenchmarkVideo(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let videosDirectory = try localBenchmarkVideosDirectory()
            let destination = videosDirectory.appendingPathComponent(url.lastPathComponent)
            let tempDestination = videosDirectory
                .appendingPathComponent(".import-\(UUID().uuidString)-\(url.lastPathComponent)")

            do {
                try FileManager.default.copyItem(at: url, to: tempDestination)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempDestination, to: destination)
            } catch {
                if FileManager.default.fileExists(atPath: tempDestination.path) {
                    try? FileManager.default.removeItem(at: tempDestination)
                }
                throw error
            }

            selectedBenchmarkVideoURL = destination
            selectedBenchmarkVideoName = destination.lastPathComponent
            modelBenchmarkStatus = "Video ready"
            modelBenchmarkOutput = "Selected offline video \(selectedBenchmarkVideoName). Run LiteRT Video Bench to test Gemma on-device without DAT streaming."
            addLog("Imported offline benchmark video: \(selectedBenchmarkVideoName)")
        } catch {
            modelBenchmarkStatus = "Video import failed"
            modelBenchmarkOutput = error.localizedDescription
            addLog("Offline video import failed: \(error.localizedDescription)")
        }
    }

    func refreshBenchmarkVideos() {
        do {
            let videosDirectory = try localBenchmarkVideosDirectory()
            let candidates = try FileManager.default.contentsOfDirectory(
                at: videosDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

            if let video = candidates.first {
                selectedBenchmarkVideoURL = video
                selectedBenchmarkVideoName = video.lastPathComponent
                addLog("Selected existing benchmark video: \(selectedBenchmarkVideoName)")
            }
        } catch {
            addLog("Benchmark video scan failed: \(error.localizedDescription)")
        }
    }

    func autoRunOfflineVideoBenchmarkIfPossible() {
        guard !didAutoRunOfflineVideoBenchmark else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--cleanup-artemis-cache") {
            cleanupArtemisCacheForLowSpace()
        }
        if arguments.contains("--kokoro-tts-smoke-speaker") {
            didAutoRunOfflineVideoBenchmark = true
            selectedSpeechEngine = .kokoroLocal
            speechOutput.forceKokoroBuiltInSpeakerForDiagnostics()
            modelBenchmarkStatus = "Kokoro speaker smoke"
            modelBenchmarkOutput = "Launch argument received. Testing native Kokoro TTS through iPhone speaker only; DAT stream and agent loop remain off."
            addLog("Launch argument --kokoro-tts-smoke-speaker received; forcing built-in speaker for native Kokoro smoke phrase.")
            pendingKokoroSpeakerSmoke = true
            runPendingKokoroSpeakerSmoke(reason: "launch_arg")
            return
        }
        if arguments.contains("--kokoro-tts-smoke") {
            didAutoRunOfflineVideoBenchmark = true
            selectedSpeechEngine = .kokoroLocal
            modelBenchmarkStatus = "Kokoro smoke"
            modelBenchmarkOutput = "Launch argument received. Testing native Kokoro TTS only; DAT stream and agent loop remain off."
            addLog("Launch argument --kokoro-tts-smoke received; speaking native Kokoro smoke phrase.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self?.speechOutput.speak("Kokoro voice online. Artemis voice output is now local.", engine: .kokoroLocal)
                }
            }
            return
        }
        if arguments.contains("--kokoro-generation-probe") {
            didAutoRunOfflineVideoBenchmark = true
            selectedSpeechEngine = .kokoroLocal
            addLog("Launch argument --kokoro-generation-probe received; generating Kokoro samples without playback.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self?.runKokoroGenerationProbe()
                }
            }
            return
        }
        if arguments.contains("--run-stt-calibration-hfp-network") || arguments.contains("--run-stt-calibration-hfp") || arguments.contains("--run-stt-calibration") {
            didAutoRunOfflineVideoBenchmark = true
            pendingSTTCalibrationRoute = (arguments.contains("--run-stt-calibration-hfp") || arguments.contains("--run-stt-calibration-hfp-network")) ? .bluetoothHFP : .measurement
            pendingSTTRequiresOnDeviceRecognition = !arguments.contains("--run-stt-calibration-hfp-network")
            modelBenchmarkStatus = "STT calibration"
            modelBenchmarkOutput = "Launch argument received. Running Apple STT only; no TTS, no DAT, no brain/router. route=\(pendingSTTCalibrationRoute.rawValue) on_device=\(pendingSTTRequiresOnDeviceRecognition)"
            addLog("Launch argument STT calibration received; starting Apple STT-only calibration. route=\(pendingSTTCalibrationRoute.rawValue) on_device=\(pendingSTTRequiresOnDeviceRecognition)")
            pendingSTTCalibration = true
            runPendingSTTCalibration(reason: "launch_arg")
            return
        }
        if arguments.contains("--run-audio-golden-smoke") {
            didAutoRunOfflineVideoBenchmark = true
            liveGoldenModeEnabled = true
            selectedSpeechEngine = .kokoroLocal
            refreshLocalModels()
            modelBenchmarkStatus = "Audio golden smoke"
            modelBenchmarkOutput = "Launch argument received. Running GoldenBrainRouter, Kokoro-only TTS, Voice Bridge, and turn-taking without DAT stream."
            addLog("Launch argument --run-audio-golden-smoke received; DAT disabled for audio+GoldenBrain proof.")
            pendingAudioGoldenSmoke = true
            runPendingAudioGoldenSmoke(reason: "launch_arg")
            return
        }
        if arguments.contains("--run-jarvis-local-gemma-loop"),
           !arguments.contains("--run-display-hud-coexistence"),
           !arguments.contains("--run-live-golden-loop") {
            didAutoRunOfflineVideoBenchmark = true
            liveGoldenModeEnabled = true
            displayHUDModeEnabled = false
            sentinelEnabled = false
            selectedSpeechEngine = .kokoroLocal
            shouldSpeakStartupGreeting = false
            shouldStartVoiceBridgeAfterStartupGreeting = false
            modelBenchmarkStatus = "Jarvis Local Gemma"
            modelBenchmarkOutput = "Starting validated Parakeet/Silero/local Gemma/eSpeak/Kokoro voice path without DAT, Codex, or Cerebras."
            addLog("Launch argument --run-jarvis-local-gemma-loop received; starting voice-only local Gemma validation.")
            emitVoiceBridgeEvent("jarvis_local_gemma_loop_scheduled", payload: [
                "evidence_target": "live_assistant",
                "brain_mode": JarvisBrainMode.localGemma.rawValue,
                "dat_enabled": false,
                "vision_inference_enabled": false,
                "local_gemma_enabled": true,
                "codex_enabled": false,
                "cerebras_enabled": false,
                "model_api_calls": false
            ])
            pendingValidatedStartupProbe = "Say briefly that Jarvis local Gemma is online, then ask what I want to test."
            startVoiceBridge()
            return
        }
        if arguments.contains("--run-jarvis-codex-bridge-loop") {
            didAutoRunOfflineVideoBenchmark = true
            liveGoldenModeEnabled = true
            displayHUDModeEnabled = false
            sentinelEnabled = false
            selectedSpeechEngine = .kokoroLocal
            shouldSpeakStartupGreeting = false
            shouldStartVoiceBridgeAfterStartupGreeting = false
            modelBenchmarkStatus = "Jarvis Codex bridge"
            let launchTTSEngine = arguments.contains("--run-jarvis-nano-bridge")
                ? "Nano Supertonic"
                : "Supertonic Core ML"
            modelBenchmarkOutput = "Starting validated Parakeet/Silero/Codex/\(launchTTSEngine) voice path without DAT, local Gemma, vision, or Cerebras."
            addLog("Launch argument --run-jarvis-codex-bridge-loop received; starting voice-only Codex bridge validation through Meta audio.")
            emitVoiceBridgeEvent("jarvis_codex_bridge_loop_scheduled", payload: [
                "evidence_target": "live_assistant",
                "dat_enabled": false,
                "vision_inference_enabled": false,
                "local_gemma_enabled": false,
                "cerebras_enabled": false,
                "model_api_calls": true
            ])
            pendingValidatedStartupProbe = "Reply with exactly this one sentence: Jarvis glasses voice online. I can hear you."
            startVoiceBridge()
            return
        }
        let fastpathModeRequested = arguments.contains("--run-cerebras-fastpath-loop")
            || ProcessInfo.processInfo.environment["ARTEMIS_FASTPATH_MODE"] == "1"
        if fastpathModeRequested {
            didAutoRunOfflineVideoBenchmark = true
            liveGoldenModeEnabled = true
            cerebrasFastpathModeEnabled = true
            selectedSpeechEngine = .kokoroLocal
            shouldSpeakStartupGreeting = false
            shouldStartVoiceBridgeAfterStartupGreeting = false
            modelBenchmarkStatus = "Cerebras fastpath"
            modelBenchmarkOutput = "Launch argument received. Running Apple STT, M4 HUD server /fastpath-reply, Cerebras Gemma fastpath, Kokoro-only TTS, and continuous STT."
            addLog("Cerebras fastpath launch mode received; routing final STT turns through M4 HUD server fastpath. base_url=\(ArtemisFastpathRuntime.baseURL.absoluteString)")
            startVoiceBridge()
            routeGoldenTurn(
                userPrompt: "Jarvis fastpath online. Say one sentence and I will answer through the M4 server.",
                finalizationReason: "startup_state",
                isStartup: true,
                allowVisionRefresh: false
            )
            return
        }
        if arguments.contains("--run-display-hud-coexistence") {
            didAutoRunOfflineVideoBenchmark = true
            liveGoldenModeEnabled = true
            webAppDisplayModeEnabled = arguments.contains("--use-webapp-display")
            displayHUDModeEnabled = !webAppDisplayModeEnabled
            selectedSpeechEngine = .kokoroLocal
            shouldSpeakStartupGreeting = false
            shouldStartVoiceBridgeAfterStartupGreeting = false
            modelBenchmarkStatus = webAppDisplayModeEnabled
                ? "Web App camera coexistence"
                : "Display HUD coexistence"
            modelBenchmarkOutput = webAppDisplayModeEnabled
                ? "Starting Meta DAT camera and validated voice while leaving the glasses display available to the connected Web App."
                : "Starting Meta DAT camera/display with the validated Parakeet/Silero/\(jarvisBrainMode.displayName)/LFM/eSpeak/Kokoro voice runtime."
            addLog(
                webAppDisplayModeEnabled
                    ? "Launch argument --use-webapp-display received; Meta DAT camera plus validated voice scheduled without native HUD ownership."
                    : "Launch argument --run-display-hud-coexistence received; Meta DAT plus validated voice runtime scheduled."
            )
            pendingValidatedStartupProbe = "Reply with exactly this one sentence: Jarvis glasses voice online. I can hear you."
            pushDisplayHUD(reason: "display_hud_launch_arg")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    if !self.isRunning {
                        self.startValidation()
                    }
                }
            }
            return
        }
        if arguments.contains("--run-dat-display-smoke") {
            didAutoRunOfflineVideoBenchmark = true
            liveGoldenModeEnabled = false
            displayHUDModeEnabled = true
            sentinelEnabled = false
            shouldSpeakStartupGreeting = false
            shouldStartVoiceBridgeAfterStartupGreeting = false
            modelBenchmarkStatus = "DAT display smoke"
            modelBenchmarkOutput = "Starting the real Meta DAT camera/display path only. Voice, local models, vision inference, and Codex are disabled for this isolation run."
            addLog("Launch argument --run-dat-display-smoke received; starting Meta DAT camera/display only at the proven 24 fps setting.")
            emitVoiceBridgeEvent("dat_display_smoke_scheduled", payload: [
                "evidence_target": "live_dat",
                "camera_fps": WearablePowerPolicy.defaultCameraFrameRate,
                "display_hud": true,
                "voice_enabled": false,
                "vision_inference_enabled": false,
                "model_api_calls": false
            ])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self, !self.isRunning else { return }
                    self.startValidation()
                }
            }
            return
        }
        if arguments.contains("--run-live-golden-loop") {
            didAutoRunOfflineVideoBenchmark = true
            liveGoldenModeEnabled = true
            selectedSpeechEngine = .kokoroLocal
            refreshLocalModels()
            shouldSpeakStartupGreeting = false
            shouldStartVoiceBridgeAfterStartupGreeting = false
            modelBenchmarkStatus = "Live loop ready"
            modelBenchmarkOutput = "Arming Meta DAT with Parakeet EOU, Silero VAD, \(jarvisBrainMode.displayName), on-demand LFM vision, eSpeak-NG, Kokoro, and HUD telemetry."
            addLog("Launch argument --run-live-golden-loop received; Meta DAT plus validated voice runtime scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    if !self.sentinelEnabled {
                        self.toggleLiveSentinel()
                    }
                    if !self.isRunning {
                        self.startValidation()
                    }
                }
            }
            return
        }
        if arguments.contains("--clear-benchmark-results") {
            ArtemisBenchmarkEventStore.clearResults()
            addLog("Cleared ArtemisBenchResults before launch-argument benchmark.")
        }
        if arguments.contains("--run-gemma-text-smoke-gpu")
            || arguments.contains("--run-gemma-text-smoke-cpu")
            || arguments.contains("--run-gemma-text-smoke-mtp-gpu") {
            didAutoRunOfflineVideoBenchmark = true
            let backend: Backend = arguments.contains("--run-gemma-text-smoke-cpu") ? .cpu() : .gpu
            let speculativeDecoding = arguments.contains("--run-gemma-text-smoke-mtp-gpu")
            modelBenchmarkStatus = "Gemma text smoke ready"
            modelBenchmarkOutput = "Launch argument received. Starting Gemma E2B text-only smoke with backend=\(backend.rawValue), mtp=\(speculativeDecoding) after startup settles..."
            addLog("Launch argument received; delayed Gemma text-only smoke scheduled with backend=\(backend.rawValue), mtp=\(speculativeDecoding).")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runGemmaTextSmokeBenchmark(
                        backend: backend,
                        speculativeDecoding: speculativeDecoding
                    )
                }
            }
            return
        }
        if arguments.contains("--run-text-only-prompt-smoke") {
            didAutoRunOfflineVideoBenchmark = true
            modelBenchmarkStatus = "Prompt smoke ready"
            modelBenchmarkOutput = "Launch argument received. Starting Gemma prompt-path smoke after startup settles..."
            addLog("Launch argument --run-text-only-prompt-smoke received; delayed text-only prompt smoke scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runTextOnlyPromptSmokeBenchmark()
                }
            }
            return
        }
        if arguments.contains("--run-session-packet-prompt-smoke") {
            didAutoRunOfflineVideoBenchmark = true
            modelBenchmarkStatus = "Packet prompt smoke ready"
            modelBenchmarkOutput = "Launch argument received. Starting exact replay-packet prompt smoke after startup settles..."
            addLog("Launch argument --run-session-packet-prompt-smoke received; delayed packet prompt smoke scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runSessionPacketPromptSmokeBenchmark()
                }
            }
            return
        }
        if arguments.contains("--run-prompt-variant-matrix") {
            didAutoRunOfflineVideoBenchmark = true
            modelBenchmarkStatus = "Prompt matrix ready"
            modelBenchmarkOutput = "Launch argument received. Starting prompt variant matrix after startup settles..."
            addLog("Launch argument --run-prompt-variant-matrix received; delayed prompt variant matrix scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runPromptVariantMatrixBenchmark()
                }
            }
            return
        }
        if arguments.contains("--run-conscious-session-synthesis") {
            didAutoRunOfflineVideoBenchmark = true
            modelBenchmarkStatus = "Session synthesis ready"
            modelBenchmarkOutput = "Launch argument received. Starting Gemma-only conscious session synthesis after startup settles..."
            addLog("Launch argument --run-conscious-session-synthesis received; delayed Gemma-only session synthesis scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runConsciousSessionSynthesisFromLatest()
                }
            }
            return
        }
        guard selectedBenchmarkVideoURL != nil else { return }
        didAutoRunOfflineVideoBenchmark = true
        if arguments.contains("--run-architecture-search-batch") {
            modelBenchmarkStatus = "Architecture search ready"
            modelBenchmarkOutput = "Launch argument received. Starting Artemis architecture-search batch after startup settles..."
            addLog("Launch argument --run-architecture-search-batch received; delayed architecture-search batch scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runArchitectureSearchBatch()
                }
            }
            return
        }
        if arguments.contains("--run-integrated-audio-only-bench") {
            modelBenchmarkStatus = "Audio replay ready"
            modelBenchmarkOutput = "Launch argument received. Starting LFM 450M vision + Gemma E2B audio-only replay after startup settles..."
            addLog("Launch argument --run-integrated-audio-only-bench received; delayed integrated audio-only replay bench scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runIntegratedReplayBenchmark(inputMode: .audioOnly)
                }
            }
            return
        }
        if arguments.contains("--run-integrated-transcript-only-bench") {
            modelBenchmarkStatus = "Transcript replay ready"
            modelBenchmarkOutput = "Launch argument received. Starting LFM 450M vision + Apple STT + Gemma E2B transcript-only replay after startup settles..."
            addLog("Launch argument --run-integrated-transcript-only-bench received; delayed integrated transcript-only replay bench scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runIntegratedReplayBenchmark(inputMode: .transcriptOnly)
                }
            }
            return
        }
        if arguments.contains("--run-integrated-replay-bench") {
            modelBenchmarkStatus = "Replay ready"
            modelBenchmarkOutput = "Launch argument received. Starting LFM 450M vision + Apple STT + Gemma E2B audio/text replay after startup settles..."
            addLog("Launch argument --run-integrated-replay-bench received; delayed integrated replay bench scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runIntegratedReplayBenchmark(inputMode: .audioAndTranscript)
                }
            }
            return
        }
        if arguments.contains("--run-conscious-session-decode") {
            modelBenchmarkStatus = "Session decode ready"
            modelBenchmarkOutput = "Launch argument received. Starting full Artemis conscious session decode after startup settles..."
            addLog("Launch argument --run-conscious-session-decode received; delayed conscious session decode scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runConsciousSessionDecodeBenchmark()
                }
            }
            return
        }
        if arguments.contains("--run-lfm-1-6b-video-bench") {
            modelBenchmarkStatus = "LFM 1.6B ready"
            modelBenchmarkOutput = "Launch argument received. Starting LFM2.5-VL-1.6B/LEAP video bench after startup settles..."
            addLog("Launch argument --run-lfm-1-6b-video-bench received; delayed LFM 1.6B bench scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runOfflineVideoLFMBenchmark(variant: .lfm16b)
                }
            }
            return
        }
        if arguments.contains("--run-lfm-video-bench") {
            modelBenchmarkStatus = "LFM ready"
            modelBenchmarkOutput = "Launch argument received. Starting LFM/LEAP video bench after startup settles..."
            addLog("Launch argument --run-lfm-video-bench received; delayed LFM bench scheduled.")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await MainActor.run {
                    self?.runOfflineVideoLFMBenchmark(variant: .lfm450m)
                }
            }
            return
        }
        guard arguments.contains("--run-litert-video-bench") else {
            modelBenchmarkStatus = "LiteRT ready"
            modelBenchmarkOutput = "Phone video benches are ready. Auto-run is disabled; use LiteRT Video Bench or LFM Video Bench for the controlled run."
            addLog("Auto-run skipped: LiteRT video bench requires explicit launch argument or button.")
            return
        }
        modelBenchmarkStatus = "LiteRT ready"
        modelBenchmarkOutput = "Launch argument received. Starting LiteRT-LM Gemma video bench after startup settles..."
        addLog("Launch argument --run-litert-video-bench received; delayed LiteRT bench scheduled.")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run {
                self?.runOfflineVideoGemmaBenchmark()
            }
        }
    }

    private func cleanupArtemisCacheForLowSpace() {
        let fileManager = FileManager.default
        var removed: [String] = []
        var failures: [String] = []

        func removeIfPresent(_ url: URL, label: String) {
            guard fileManager.fileExists(atPath: url.path) else { return }
            do {
                try fileManager.removeItem(at: url)
                removed.append(label)
            } catch {
                failures.append("\(label): \(error.localizedDescription)")
            }
        }

        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            removeIfPresent(documents.appendingPathComponent("ArtemisBenchResults"), label: "benchmark results")
        }

        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            removeIfPresent(caches.appendingPathComponent("huggingface"), label: "HuggingFace cache")
            removeIfPresent(caches.appendingPathComponent("com.devansh.Artemis/com.apple.metal"), label: "Metal cache")
            removeIfPresent(caches.appendingPathComponent("com.devansh.Artemis/com.apple.metalfe"), label: "Metal frontend cache")
        }

        let temporary = fileManager.temporaryDirectory
        removeIfPresent(temporary.appendingPathComponent("LiteRTBenchCaches"), label: "LiteRT temp caches")

        if let entries = try? fileManager.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix("CFNetworkDownload_") || name.hasSuffix("_mldrift_weight_cache.bin") {
                    removeIfPresent(entry, label: "tmp/\(name)")
                }
            }
        }

        addLog("Artemis cache cleanup removed: \(removed.isEmpty ? "nothing" : removed.joined(separator: ", "))")
        if !failures.isEmpty {
            addLog("Artemis cache cleanup failures: \(failures.joined(separator: " | "))")
        }
    }

    func runGemmaTextSmokeBenchmark(backend: Backend, speculativeDecoding: Bool = false) {
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let benchmark = modelBenchmark
        let batchID = UUID().uuidString
        modelBenchmarkStatus = "Gemma \(backend.rawValue) smoke"
        modelBenchmarkOutput = "Running fresh-process Gemma text-only smoke with backend=\(backend.rawValue), mtp=\(speculativeDecoding)..."
        addLog("Starting Gemma text-only smoke \(batchID): model=\(modelName), backend=\(backend.rawValue), mtp=\(speculativeDecoding)")
        emitAgentCEvent("gemma_text_smoke_started", payload: [
            "batch_id": batchID,
            "model": modelName,
            "backend": backend.rawValue,
            "vision_backend": "none",
            "audio_backend": "none",
            "mtp": speculativeDecoding,
            "max_num_tokens": 512
        ])

        offlineVideoBenchmarkTask = Task { [weak self] in
            let started = Date()
            await benchmark.resetCaches()
            do {
                let result = try await benchmark.runTextSmoke(
                    modelPath: modelPath,
                    backend: backend,
                    maxNumTokens: 512,
                    speculativeDecoding: speculativeDecoding
                )
                var record: [String: Any] = [
                    "batch_id": batchID,
                    "model": modelName,
                    "backend": backend.rawValue,
                    "vision_backend": "none",
                    "audio_backend": "none",
                    "mtp": speculativeDecoding,
                    "latency_ms": result.totalMilliseconds,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "answer": result.responseText,
                    "device": architectureDeviceSnapshot()
                ]
                if let metrics = result.liteRTMetrics {
                    record["litert_metrics"] = metrics.payload
                }
                let mtpSuffix = speculativeDecoding ? "-mtp" : ""
                ArtemisBenchmarkEventStore.writeJSON(record, name: "gemma-text-smoke-\(backend.rawValue)\(mtpSuffix)-latest.json")
                ArtemisBenchmarkEventStore.append(event: "gemma_text_smoke_complete", payload: record)
                await benchmark.resetCaches()
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Gemma \(backend.rawValue) smoke complete"
                    self.modelBenchmarkOutput = result.summary
                    self.addLog("Gemma text-only smoke complete: backend=\(backend.rawValue), mtp=\(speculativeDecoding), \(result.totalMilliseconds)ms")
                }
            } catch {
                let record: [String: Any] = [
                    "batch_id": batchID,
                    "model": modelName,
                    "backend": backend.rawValue,
                    "vision_backend": "none",
                    "audio_backend": "none",
                    "mtp": speculativeDecoding,
                    "error": error.localizedDescription,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "device": architectureDeviceSnapshot()
                ]
                let mtpSuffix = speculativeDecoding ? "-mtp" : ""
                ArtemisBenchmarkEventStore.writeJSON(record, name: "gemma-text-smoke-\(backend.rawValue)\(mtpSuffix)-latest.json")
                ArtemisBenchmarkEventStore.append(event: "gemma_text_smoke_failed", payload: record)
                await benchmark.resetCaches()
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Gemma \(backend.rawValue) smoke failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Gemma text-only smoke failed: backend=\(backend.rawValue), mtp=\(speculativeDecoding), \(error.localizedDescription)")
                }
            }
        }
    }

    func runTextOnlyPromptSmokeBenchmark() {
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let benchmark = modelBenchmark
        let batchID = UUID().uuidString
        modelBenchmarkStatus = "Prompt smoke"
        modelBenchmarkOutput = "Running Gemma through the session-synthesis text prompt path..."
        addLog("Starting text-only prompt smoke \(batchID): model=\(modelName)")

        offlineVideoBenchmarkTask = Task { [weak self] in
            let started = Date()
            await benchmark.resetCaches()
            do {
                let result = try await benchmark.runPromptSmoke(
                    modelPath: modelPath,
                    maxNumTokens: 512
                )
                var record: [String: Any] = [
                    "batch_id": batchID,
                    "status": "complete",
                    "model": modelName,
                    "backend": "gpu",
                    "vision_backend": "none",
                    "audio_backend": "none",
                    "mtp": false,
                    "latency_ms": result.totalMilliseconds,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "answer": result.responseText,
                    "device": architectureDeviceSnapshot()
                ]
                if let metrics = result.liteRTMetrics {
                    record["litert_metrics"] = metrics.payload
                }
                ArtemisBenchmarkEventStore.writeJSON(record, name: "text-only-prompt-smoke-latest.json")
                ArtemisBenchmarkEventStore.append(event: "text_only_prompt_smoke_complete", payload: record)
                await benchmark.resetCaches()
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Prompt smoke complete"
                    self.modelBenchmarkOutput = result.summary
                    self.addLog("Text-only prompt smoke complete: \(result.totalMilliseconds)ms")
                }
            } catch {
                let record: [String: Any] = [
                    "batch_id": batchID,
                    "status": "failed",
                    "model": modelName,
                    "backend": "gpu",
                    "vision_backend": "none",
                    "audio_backend": "none",
                    "mtp": false,
                    "error": error.localizedDescription,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "device": architectureDeviceSnapshot()
                ]
                ArtemisBenchmarkEventStore.writeJSON(record, name: "text-only-prompt-smoke-latest.json")
                ArtemisBenchmarkEventStore.append(event: "text_only_prompt_smoke_failed", payload: record)
                await benchmark.resetCaches()
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Prompt smoke failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Text-only prompt smoke failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func runSessionPacketPromptSmokeBenchmark() {
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let benchmark = modelBenchmark
        let batchID = UUID().uuidString
        modelBenchmarkStatus = "Packet prompt smoke"
        modelBenchmarkOutput = "Running Gemma over a fixed replay-packet prompt..."
        addLog("Starting session packet prompt smoke \(batchID): model=\(modelName)")

        offlineVideoBenchmarkTask = Task { [weak self] in
            let started = Date()
            await benchmark.resetCaches()
            do {
                let result = try await benchmark.runSessionPacketPromptSmoke(
                    modelPath: modelPath,
                    maxNumTokens: 128
                )
                var record: [String: Any] = [
                    "batch_id": batchID,
                    "status": "complete",
                    "model": modelName,
                    "backend": "gpu",
                    "vision_backend": "none",
                    "audio_backend": "none",
                    "mtp": false,
                    "latency_ms": result.totalMilliseconds,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "answer": result.responseText,
                    "device": architectureDeviceSnapshot()
                ]
                if let metrics = result.liteRTMetrics {
                    record["litert_metrics"] = metrics.payload
                }
                ArtemisBenchmarkEventStore.writeJSON(record, name: "session-packet-prompt-smoke-latest.json")
                ArtemisBenchmarkEventStore.append(event: "session_packet_prompt_smoke_complete", payload: record)
                await benchmark.resetCaches()
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Packet prompt smoke complete"
                    self.modelBenchmarkOutput = result.summary
                    self.addLog("Session packet prompt smoke complete: \(result.totalMilliseconds)ms")
                }
            } catch {
                let record: [String: Any] = [
                    "batch_id": batchID,
                    "status": "failed",
                    "model": modelName,
                    "backend": "gpu",
                    "vision_backend": "none",
                    "audio_backend": "none",
                    "mtp": false,
                    "error": error.localizedDescription,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "device": architectureDeviceSnapshot()
                ]
                ArtemisBenchmarkEventStore.writeJSON(record, name: "session-packet-prompt-smoke-latest.json")
                ArtemisBenchmarkEventStore.append(event: "session_packet_prompt_smoke_failed", payload: record)
                await benchmark.resetCaches()
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Packet prompt smoke failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Session packet prompt smoke failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func runPromptVariantMatrixBenchmark() {
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let benchmark = modelBenchmark
        let batchID = UUID().uuidString
        modelBenchmarkStatus = "Prompt matrix"
        modelBenchmarkOutput = "Running Gemma prompt-shape matrix..."
        addLog("Starting prompt variant matrix \(batchID): model=\(modelName)")

        offlineVideoBenchmarkTask = Task { [weak self] in
            let started = Date()
            let variants = promptVariantMatrixPrompts()
            var rows: [[String: Any]] = []

            func writeProgress(status: String) {
                let failed = rows.filter { ($0["status"] as? String) == "failed" }.count
                let record: [String: Any] = [
                    "batch_id": batchID,
                    "status": status,
                    "model": modelName,
                    "backend": "gpu",
                    "variant_count": variants.count,
                    "completed_variants": rows.count,
                    "failed_count": failed,
                    "variants": rows,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "device": architectureDeviceSnapshot()
                ]
                ArtemisBenchmarkEventStore.writeJSON(record, name: "prompt-variant-matrix-latest.json")
                ArtemisBenchmarkEventStore.append(event: "prompt_variant_matrix_progress", payload: record)
            }

            for variant in variants {
                await benchmark.resetCaches()
                let variantStarted = Date()
                do {
                    let result = try await benchmark.runPromptVariant(
                        modelPath: modelPath,
                        prompt: variant.prompt,
                        maxNumTokens: variant.maxTokens
                    )
                    var row: [String: Any] = [
                        "name": variant.name,
                        "status": "complete",
                        "prompt_chars": variant.prompt.count,
                        "max_tokens": variant.maxTokens,
                        "latency_ms": result.totalMilliseconds,
                        "wall_ms": Int(Date().timeIntervalSince(variantStarted) * 1000),
                        "answer": result.responseText
                    ]
                    if let metrics = result.liteRTMetrics {
                        row["litert_metrics"] = metrics.payload
                    }
                    rows.append(row)
                } catch {
                    rows.append([
                        "name": variant.name,
                        "status": "failed",
                        "prompt_chars": variant.prompt.count,
                        "max_tokens": variant.maxTokens,
                        "wall_ms": Int(Date().timeIntervalSince(variantStarted) * 1000),
                        "error": error.localizedDescription
                    ])
                }
                writeProgress(status: rows.count == variants.count ? "complete" : "running")
                await benchmark.resetCaches()
            }

            await MainActor.run {
                guard let self else { return }
                let failed = rows.filter { ($0["status"] as? String) == "failed" }.count
                self.modelBenchmarkStatus = "Prompt matrix complete"
                self.modelBenchmarkOutput = "Prompt variant matrix complete: \(rows.count) variants, \(failed) failed."
                self.addLog("Prompt variant matrix complete: variants=\(rows.count), failed=\(failed)")
            }
        }
    }

    private func promptVariantMatrixPrompts() -> [(name: String, prompt: String, maxTokens: Int)] {
        [
            (
                "simple_json",
                """
                Artemis local prompt-path smoke. Return JSON only:
                {"ok":true,"role":"router","answer":"prompt path alive","tools":[],"confidence":1.0}
                """,
                512
            ),
            (
                "minimal_packet_plain",
                """
                Artemis router. Packet frames 37 useful 21 scenes workspace bedroom objects laptop monitor keyboard. Return JSON only: {"answer":"workspace and laptop visible","confidence":0.7}
                """,
                128
            ),
            (
                "packet_no_schema",
                """
                Artemis router. Use replay packet only. Duration 183 seconds. Transcript Benchmark complete. Frames 37 useful 21 empty 16. Scenes Bedroom workspace Workspace. Objects bed laptop water bottle desk computer monitor keyboard cords Monitor Keyboard Phone. Actions No action taken Open laptop. Reply with compact JSON.
                """,
                128
            ),
            (
                "packet_simple_schema",
                """
                Artemis router. Use replay packet only. Duration: 183.1s. STT: on_device. Transcript: Benchmark complete. Packet: frames=37; useful_frames=21; empty_frames=16; scenes=Bedroom,workspace,Workspace; objects=bed,laptop,water bottle,desk,computer monitor,keyboard,cords,Monitor,Keyboard,Phone; actions=No action taken,Open laptop. Return JSON only: {"answer":"","confidence":0.0}
                """,
                128
            ),
            (
                "packet_full_schema",
                """
                Artemis router. Use this replay packet only.
                Duration: 183.1s
                STT: on_device
                Transcript: Benchmark complete
                Packet: frames=37; useful_frames=21; empty_frames=16; scenes=Bedroom,workspace,Workspace; objects=bed,laptop,water bottle,desk,computer monitor,keyboard,cords,Monitor,Keyboard,Phone; actions=No action taken,Open laptop; transcript_status=on_device; duration=183.1
                Return one-line JSON only:
                {"context":"","intent":"","answer":"","tools":[],"escalate":false,"realtime_verdict":"","confidence":0.0}
                """,
                128
            ),
            (
                "packet_full_schema_512",
                """
                Artemis router. Use this replay packet only.
                Duration: 183.1s
                STT: on_device
                Transcript: Benchmark complete
                Packet: frames=37; useful_frames=21; empty_frames=16; scenes=Bedroom,workspace,Workspace; objects=bed,laptop,water bottle,desk,computer monitor,keyboard,cords,Monitor,Keyboard,Phone; actions=No action taken,Open laptop; transcript_status=on_device; duration=183.1
                Return one-line JSON only:
                {"context":"","intent":"","answer":"","tools":[],"escalate":false,"realtime_verdict":"","confidence":0.0}
                """,
                512
            )
        ]
    }

    func runArchitectureSearchBatch() {
        guard let videoURL = selectedBenchmarkVideoURL else {
            modelBenchmarkStatus = "No video"
            modelBenchmarkOutput = "Import a benchmark video first."
            return
        }
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let batchID = UUID().uuidString
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let lfmBenchmark = lfmBenchmark
        let gemmaBenchmark = modelBenchmark
        let videoName = selectedBenchmarkVideoName
        let arguments = ProcessInfo.processInfo.arguments
        let includeUnsafeGemmaBatch = arguments.contains("--include-unsafe-gemma-batch")
        let includeUnsafeGemmaAudioBatch = arguments.contains("--include-unsafe-gemma-audio-batch")
        let skipDeepVisionLane = arguments.contains("--skip-deep-vision-lane")
        let includeMTPReasoner = arguments.contains("--include-mtp-reasoner")
        modelBenchmarkStatus = "Architecture batch"
        modelBenchmarkOutput = "Running isolated Artemis architecture search batch \(batchID.prefix(8)) on \(videoName)..."
        addLog("Starting architecture-search batch \(batchID): video=\(videoName), reasoner=\(modelName)")
        emitAgentCEvent("architecture_search_batch_started", payload: [
            "batch_id": batchID,
            "video": videoName,
            "reasoner_model": modelName,
            "fixed_eye_candidate": LocalLFMBenchmarkVariant.lfm450m.modelName,
            "include_unsafe_gemma_batch": includeUnsafeGemmaBatch,
            "include_unsafe_gemma_audio_batch": includeUnsafeGemmaAudioBatch,
            "skip_deep_vision_lane": skipDeepVisionLane,
            "include_mtp_reasoner": includeMTPReasoner
        ])

        offlineVideoBenchmarkTask = Task { [weak self] in
            let totalStart = Date()
            var leaderboard: [[String: Any]] = []
            var failureCount = 0
            var lfm450Timeline: [IntegratedVisualObservation] = []
            var transcript = ""
            var transcriptChunks: [[String: Any]] = []
            var transcriptStatus = "not_attempted"
            var audioStatus = "not_attempted"

            func latencyStats(_ values: [Int]) -> (min: Int, mean: Int, max: Int) {
                guard !values.isEmpty else { return (0, 0, 0) }
                return (
                    values.min() ?? 0,
                    Int(Double(values.reduce(0, +)) / Double(values.count)),
                    values.max() ?? 0
                )
            }

            func realtimeTier(meanMS: Int) -> String {
                switch meanMS {
                case 1...200:
                    return "candidate_5fps"
                case 201...500:
                    return "candidate_2fps"
                case 501...1000:
                    return "candidate_1fps"
                case 1001...2500:
                    return "triggered_only"
                default:
                    return "fallback_only"
                }
            }

            func appendLeaderboard(_ record: [String: Any]) {
                leaderboard.append(record)
                ArtemisBenchmarkEventStore.append(event: "architecture_search_lane_complete", payload: record)
            }

            func appendFailure(_ record: [String: Any]) {
                failureCount += 1
                leaderboard.append(record)
                ArtemisBenchmarkEventStore.append(event: "architecture_search_lane_failed", payload: record)
            }

            do {
                let frames3 = try await OfflineVideoFrameSampler.sampleJPEGFrames(
                    from: videoURL,
                    frameCount: 3,
                    maxDimension: 288,
                    compressionQuality: 0.38
                )
                let frames5 = try await OfflineVideoFrameSampler.sampleJPEGFrames(
                    from: videoURL,
                    frameCount: 5,
                    maxDimension: 288,
                    compressionQuality: 0.38
                )
                let frames5Fast = try await OfflineVideoFrameSampler.sampleJPEGFrames(
                    from: videoURL,
                    frameCount: 5,
                    maxDimension: 224,
                    compressionQuality: 0.32
                )

                var visionLanes: [(id: String, variant: LocalLFMBenchmarkVariant, frames: [OfflineVideoFrame], prompt: String)] = [
                    (
                        "eyes_450m_3f_sentinel",
                        .lfm450m,
                        frames3,
                        """
                        You are Artemis' realtime wearable visual sentinel.
                        Return compact JSON only:
                        {"scene":"","objects":[],"visible_text":"","user_intent_hint":"","should_escalate":false,"confidence":0.0}
                        """
                    ),
                    (
                        "eyes_450m_5f_timeline",
                        .lfm450m,
                        frames5,
                        LocalLFMBenchmarkService.integratedReplayPrompt
                    ),
                    (
                        "eyes_450m_5f_forced_caption_224",
                        .lfm450m,
                        frames5Fast,
                        """
                        You are Artemis' realtime wearable camera sentinel.
                        Describe visible evidence even when the image is blurry.
                        Return one compact JSON object only, no markdown fences:
                        {"scene":"","objects":[],"text":"","action_hint":"","escalate":false,"confidence":0.0}
                        Rules: never leave scene or objects empty unless the frame is fully black; use coarse labels when uncertain; set confidence 0.2-0.5 for blurry evidence; escalate=true for readable screens, people, hazards, or user-question context.
                        """
                    ),
                    (
                        "eyes_450m_5f_ultra_short_224",
                        .lfm450m,
                        frames5Fast,
                        """
                        Wearable vision sentinel. Answer one line only, under 18 words.
                        Format: scene | objects | readable_text | escalate yes/no
                        Use coarse visible objects. Never explain.
                        """
                    )
                ]
                if !skipDeepVisionLane {
                    visionLanes.append((
                        "deep_vision_1_6b_3f",
                        .lfm16b,
                        frames3,
                        LocalLFMBenchmarkService.integratedReplayPrompt
                    ))
                }

                for lane in visionLanes {
                    try Task.checkCancellation()
                    await lfmBenchmark.resetCaches()
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    await MainActor.run {
                        self?.modelBenchmarkStatus = lane.id
                        self?.modelBenchmarkOutput = "Running isolated \(lane.variant.modelName) lane with \(lane.frames.count) sampled frames..."
                    }

                    var latencies: [Int] = []
                    var outputs: [String] = []
                    var timeline: [IntegratedVisualObservation] = []
                    let laneStart = Date()
                    do {
                        for frame in lane.frames {
                            try Task.checkCancellation()
                            ArtemisBenchmarkEventStore.writeFrame(frame.jpegData, name: "\(lane.id)-frame-\(frame.index + 1).jpg")
                            let result = try await lfmBenchmark.runVisionProbe(
                                imageData: frame.jpegData,
                                variant: lane.variant,
                                prompt: lane.prompt
                            )
                            latencies.append(result.totalMilliseconds)
                            outputs.append(result.responseText)
                            timeline.append(IntegratedVisualObservation(
                                frameIndex: frame.index,
                                seconds: frame.seconds,
                                latencyMilliseconds: result.totalMilliseconds,
                                responseText: result.responseText
                            ))
                        }
                        if lane.id == "eyes_450m_5f_timeline", lfm450Timeline.isEmpty {
                            lfm450Timeline = timeline
                        }
                        if lane.id == "eyes_450m_5f_forced_caption_224" {
                            lfm450Timeline = timeline
                        }
                        let stats = latencyStats(latencies)
                        let wallMS = Int(Date().timeIntervalSince(laneStart) * 1000)
                        let quality = visionQualityProxy(outputs: outputs, expectedFrames: lane.frames.count)
                        var record: [String: Any] = [
                            "batch_id": batchID,
                            "lane_id": lane.id,
                            "architecture": "vision_only",
                            "model": lane.variant.modelName,
                            "quantization": lane.variant.quantization,
                            "runtime": "LEAP",
                            "frames": latencies.count,
                            "latency_min_ms": stats.min,
                            "latency_mean_ms": stats.mean,
                            "latency_max_ms": stats.max,
                            "estimated_fps": stats.mean > 0 ? Double(1000) / Double(stats.mean) : 0,
                            "realtime_tier": realtimeTier(meanMS: stats.mean),
                            "wall_ms": wallMS,
                            "output_preview": outputs.joined(separator: "\n").prefix(1600).description,
                            "device": architectureDeviceSnapshot()
                        ]
                        record["quality_proxy_version"] = 1
                        record["quality_proxy_score"] = quality.score
                        record["quality_proxy"] = quality.details
                        if lane.variant.modelName == LocalLFMBenchmarkVariant.lfm16b.modelName {
                            let confidenceBefore = quality.details["confidence_mean"] ?? quality.score
                            let fallbackDecision = architectureFallbackDecision(
                                candidateID: "C_deep_vision_fallback",
                                triggerSignal: "deep_vision_comparison_lane",
                                confidenceBefore: confidenceBefore,
                                fallbackReason: "1.6B vision is expected only when 450M eyes have low confidence, visible screen/text uncertainty, or a user/debug question needs higher-fidelity inspection.",
                                expectedCostMS: 56_000,
                                actualCostMS: stats.mean,
                                fallbackResult: "quality_proxy_score=\(String(format: "%.3f", quality.score)); realtime_tier=\(realtimeTier(meanMS: stats.mean)); frames=\(latencies.count)"
                            )
                            record["fallback_decision"] = fallbackDecision
                            record["expected_fallback"] = fallbackDecision["expected_fallback"]
                            record["fallback_reason"] = fallbackDecision["fallback_reason"]
                            record["trigger_signal"] = fallbackDecision["trigger_signal"]
                            record["confidence_before"] = fallbackDecision["confidence_before"]
                            record["expected_cost_ms"] = fallbackDecision["expected_cost_ms"]
                            record["actual_cost_ms"] = fallbackDecision["actual_cost_ms"]
                            record["fallback_result"] = fallbackDecision["fallback_result"]
                            record["fallback_explained_rate"] = 1.0
                            ArtemisBenchmarkEventStore.append(event: "architecture_search_fallback_decision", payload: fallbackDecision)
                        }
                        appendLeaderboard(record)
                        await lfmBenchmark.resetCaches()
                    } catch {
                        appendFailure([
                            "batch_id": batchID,
                            "lane_id": lane.id,
                            "architecture": "vision_only",
                            "model": lane.variant.modelName,
                            "error": error.localizedDescription,
                            "device": architectureDeviceSnapshot()
                        ])
                        await lfmBenchmark.resetCaches()
                    }
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self?.modelBenchmarkStatus = "Audio/STT"
                    self?.modelBenchmarkOutput = "Extracting audio and running Apple on-device STT control..."
                }
                var audioURL: URL?
                do {
                    let extracted = try await OfflineAudioExtractor.extractAudioAssets(from: videoURL)
                    audioURL = extracted.modelURL
                    audioStatus = "ok:speech=\(extracted.speechURL.lastPathComponent),model=\(extracted.modelURL.lastPathComponent)"
                    let speech = try await OfflineSpeechFileTranscriber.transcribe(url: extracted.speechURL)
                    transcript = speech.text
                    transcriptChunks = speech.chunkPayload
                    transcriptStatus = speech.isOnDevice ? "on_device" : "apple_speech"
                    appendLeaderboard([
                        "batch_id": batchID,
                        "lane_id": "ears_apple_stt",
                        "architecture": "audio_transcript_control",
                        "audio_status": audioStatus,
                        "transcript_contract_version": 1,
                        "transcript_status": transcriptStatus,
                        "transcript_chars": transcript.count,
                        "transcript_chunk_count": transcriptChunks.count,
                        "transcript_chunks": transcriptChunks,
                        "transcript": transcript,
                        "device": architectureDeviceSnapshot()
                    ])
                } catch {
                    transcriptStatus = "failed:\(error.localizedDescription)"
                    appendFailure([
                        "batch_id": batchID,
                        "lane_id": "ears_apple_stt",
                        "architecture": "audio_transcript_control",
                        "audio_status": audioStatus,
                        "error": error.localizedDescription,
                        "device": architectureDeviceSnapshot()
                    ])
                }

                var reasoningModes: [(id: String, speculative: Bool)] = [
                    ("brain_gemma_e2b_text_baseline", false)
                ]
                if includeMTPReasoner {
                    reasoningModes.append(("brain_gemma_e2b_text_mtp", true))
                }
                if includeUnsafeGemmaBatch {
                    for mode in reasoningModes {
                        try Task.checkCancellation()
                        await gemmaBenchmark.resetCaches()
                        try? await Task.sleep(nanoseconds: 750_000_000)
                        await MainActor.run {
                            self?.modelBenchmarkStatus = mode.id
                            self?.modelBenchmarkOutput = "Running Gemma E2B text reasoner with mtp=\(mode.speculative)..."
                        }

                        let laneStart = Date()
                        do {
                            let result = try await gemmaBenchmark.runReplayReasoning(
                                modelPath: modelPath,
                                audioFileURL: nil,
                                transcript: transcript,
                                transcriptStatus: transcriptStatus,
                                inputMode: .transcriptOnly,
                                visualTimeline: lfm450Timeline,
                                speculativeDecoding: mode.speculative
                            )
                            var record: [String: Any] = [
                                "batch_id": batchID,
                                "lane_id": mode.id,
                                "architecture": "vision_transcript_reasoner",
                                "vision_model": LocalLFMBenchmarkVariant.lfm450m.modelName,
                                "reasoner_model": modelName,
                                "mtp": mode.speculative,
                                "max_num_tokens": 512,
                                "latency_ms": result.totalMilliseconds,
                                "wall_ms": Int(Date().timeIntervalSince(laneStart) * 1000),
                                "transcript_contract_version": 1,
                                "transcript_status": transcriptStatus,
                                "transcript_chunk_count": transcriptChunks.count,
                                "transcript_chunks": transcriptChunks,
                                "answer": result.responseText,
                                "device": architectureDeviceSnapshot()
                            ]
                            if let metrics = result.liteRTMetrics {
                                record["litert_metrics"] = metrics.payload
                            }
                            appendLeaderboard(record)
                            await gemmaBenchmark.resetCaches()
                        } catch {
                            appendFailure([
                                "batch_id": batchID,
                                "lane_id": mode.id,
                                "architecture": "vision_transcript_reasoner",
                                "reasoner_model": modelName,
                                "mtp": mode.speculative,
                                "error": error.localizedDescription,
                                "device": architectureDeviceSnapshot()
                            ])
                            await gemmaBenchmark.resetCaches()
                        }
                    }
                    if !includeMTPReasoner {
                        appendLeaderboard([
                            "batch_id": batchID,
                            "lane_id": "brain_gemma_e2b_text_mtp",
                            "architecture": "vision_transcript_reasoner",
                            "vision_model": LocalLFMBenchmarkVariant.lfm450m.modelName,
                            "reasoner_model": modelName,
                            "mtp": true,
                            "skipped": true,
                            "skip_reason": "MTP/speculative Gemma is disabled unless --include-mtp-reasoner is passed; an earlier mixed run hit signal 11 after baseline succeeded.",
                            "device": architectureDeviceSnapshot()
                        ])
                    }
                } else {
                    appendLeaderboard([
                        "batch_id": batchID,
                        "lane_id": "brain_gemma_e2b_text_baseline",
                        "architecture": "vision_transcript_reasoner",
                        "vision_model": LocalLFMBenchmarkVariant.lfm450m.modelName,
                        "reasoner_model": modelName,
                        "mtp": false,
                        "skipped": true,
                        "skip_reason": "Gemma LiteRT batch is disabled by default; rerun with --include-unsafe-gemma-batch for isolated Gemma debugging.",
                        "device": architectureDeviceSnapshot()
                    ])
                    appendLeaderboard([
                        "batch_id": batchID,
                        "lane_id": "brain_gemma_e2b_text_mtp",
                        "architecture": "vision_transcript_reasoner",
                        "vision_model": LocalLFMBenchmarkVariant.lfm450m.modelName,
                        "reasoner_model": modelName,
                        "mtp": true,
                        "skipped": true,
                        "skip_reason": "MTP/speculative Gemma is disabled unless --include-unsafe-gemma-batch --include-mtp-reasoner are both passed.",
                        "device": architectureDeviceSnapshot()
                    ])
                }

                try Task.checkCancellation()
                if includeUnsafeGemmaBatch {
                    await gemmaBenchmark.resetCaches()
                }
                if includeUnsafeGemmaAudioBatch, let audioURL {
                    await MainActor.run {
                        self?.modelBenchmarkStatus = "Gemma audio smoke"
                        self?.modelBenchmarkOutput = "Testing Gemma E2B direct audio with file/data/stream smoke lanes..."
                    }
                    let smokeResults = await runGemmaAudioSmokeLanes(
                        gemmaBenchmark: gemmaBenchmark,
                        modelPath: modelPath,
                        modelName: modelName,
                        audioURL: audioURL,
                        batchID: batchID
                    )
                    for record in smokeResults {
                        let ok = (record["ok"] as? Bool) ?? false
                        ok ? appendLeaderboard(record) : appendFailure(record)
                    }
                    await gemmaBenchmark.resetCaches()
                } else if audioURL != nil {
                    appendLeaderboard([
                        "batch_id": batchID,
                        "lane_id": "brain_gemma_audio_smoke",
                        "architecture": "direct_audio_smoke",
                        "reasoner_model": modelName,
                        "skipped": true,
                        "skip_reason": includeUnsafeGemmaBatch
                            ? "Gemma LiteRT direct audio requires --include-unsafe-gemma-audio-batch; text reasoner isolation is running without audio."
                            : "Gemma LiteRT direct audio is disabled in the default overnight batch after signal 11 during initialization.",
                        "device": architectureDeviceSnapshot()
                    ])
                }

                let totalMS = Int(Date().timeIntervalSince(totalStart) * 1000)
                let completed = leaderboard.filter {
                    ($0["error"] as? String) == nil && (($0["skipped"] as? Bool) != true)
                }.count
                let summary: [String: Any] = [
                    "batch_id": batchID,
                    "video": videoURL.lastPathComponent,
                    "reasoner_model": modelName,
                    "total_wall_ms": totalMS,
                    "completed_lanes": completed,
                    "failed_lanes": failureCount,
                    "leaderboard": leaderboard,
                    "verdict": architectureVerdict(from: leaderboard)
                ]
                ArtemisBenchmarkEventStore.writeJSON(summary, name: "architecture-leaderboard-latest.json")
                ArtemisBenchmarkEventStore.append(event: "architecture_search_batch_complete", payload: summary)

                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Architecture complete"
                    self.modelBenchmarkOutput = ArchitectureSummaryFormatter.text(from: summary)
                    self.addLog("Architecture-search batch complete: completed=\(completed), failed=\(failureCount), total=\(totalMS)ms")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.modelBenchmarkStatus = "Architecture cancelled"
                    self?.addLog("Architecture-search batch cancelled.")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Architecture failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Architecture-search batch failed: \(error.localizedDescription)")
                    self.emitAgentCEvent("architecture_search_batch_failed", payload: [
                        "batch_id": batchID,
                        "video": videoURL.lastPathComponent,
                        "reasoner_model": modelName,
                        "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    func runOfflineVideoLFMBenchmark(variant: LocalLFMBenchmarkVariant = .lfm450m) {
        guard let videoURL = selectedBenchmarkVideoURL else {
            modelBenchmarkStatus = "No video"
            modelBenchmarkOutput = "Import a benchmark video first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let benchmark = lfmBenchmark
        modelBenchmarkStatus = "\(variant.shortLabel) sampling"
        modelBenchmarkOutput = "Sampling 3 frames from \(selectedBenchmarkVideoName) on iPhone, then running \(variant.modelName) through LEAP..."
        addLog("Starting offline iPhone \(variant.modelName) video benchmark: video=\(selectedBenchmarkVideoName)")
        emitAgentCEvent("offline_lfm_video_benchmark_started", payload: [
            "video": selectedBenchmarkVideoName,
            "model": variant.modelName,
            "quantization": variant.quantization,
            "sample_count": 3
        ])

        offlineVideoBenchmarkTask = Task { [weak self] in
            do {
                let frames = try await OfflineVideoFrameSampler.sampleJPEGFrames(
                    from: videoURL,
                    frameCount: 3,
                    maxDimension: 288,
                    compressionQuality: 0.38
                )

                var latencies: [Int] = []
                var outputs: [String] = []

                for frame in frames {
                    try Task.checkCancellation()
                    await MainActor.run {
                        self?.modelBenchmarkStatus = "\(variant.shortLabel) \(frame.index + 1)/\(frames.count)"
                        self?.modelBenchmarkOutput = "Running \(variant.modelName) on frame \(frame.index + 1)/\(frames.count) at \(String(format: "%.1f", frame.seconds))s..."
                    }

                    let result = try await benchmark.runVisionProbe(imageData: frame.jpegData, variant: variant)
                    latencies.append(result.totalMilliseconds)
                    outputs.append("\(variant.modelName), frame \(frame.index + 1) @ \(String(format: "%.1f", frame.seconds))s: \(result.totalMilliseconds)ms\n\(result.responseText)")

                    await MainActor.run {
                        guard let self else { return }
                        self.sentinelSamples += 1
                        self.sentinelLastInferenceMS = result.totalMilliseconds
                        self.averageInferenceMS = self.rollingAverage(current: self.averageInferenceMS, next: result.totalMilliseconds, count: max(self.sentinelSamples, 1))
                        self.addLog("Offline video \(variant.shortLabel) frame \(frame.index + 1)/\(frames.count): \(result.compactSummary)")
                        self.emitAgentCEvent("offline_lfm_video_frame_result", payload: [
                            "frame_index": frame.index,
                            "seconds": frame.seconds,
                            "latency_ms": result.totalMilliseconds,
                            "jpeg_bytes": frame.jpegData.count,
                            "model": variant.modelName,
                            "quantization": variant.quantization,
                            "response_text": result.responseText
                        ])
                    }
                }

                let mean = latencies.isEmpty ? 0 : Int(Double(latencies.reduce(0, +)) / Double(latencies.count))
                let minLatency = latencies.min() ?? 0
                let maxLatency = latencies.max() ?? 0
                let summary = """
                iPhone offline LFM video benchmark
                Model: \(variant.modelName)
                Quantization: \(variant.quantization)
                Runtime: Liquid LEAP
                Video: \(videoURL.lastPathComponent)
                Frames: \(latencies.count)
                Latency ms: min \(minLatency), mean \(mean), max \(maxLatency)

                \(outputs.joined(separator: "\n\n"))
                """

                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "\(variant.shortLabel) complete"
                    self.modelBenchmarkOutput = summary
                    self.addLog("Offline iPhone \(variant.modelName) benchmark complete: frames=\(latencies.count), mean=\(mean)ms")
                    self.emitAgentCEvent("offline_lfm_video_benchmark_complete", payload: [
                        "video": videoURL.lastPathComponent,
                        "model": variant.modelName,
                        "quantization": variant.quantization,
                        "runtime": "LEAP",
                        "frames": latencies.count,
                        "latency_min_ms": minLatency,
                        "latency_mean_ms": mean,
                        "latency_max_ms": maxLatency
                    ])
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.modelBenchmarkStatus = "LFM cancelled"
                    self?.addLog("Offline LFM video benchmark cancelled.")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "LFM failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Offline iPhone \(variant.modelName) benchmark failed: \(error.localizedDescription)")
                    self.emitAgentCEvent("offline_lfm_video_benchmark_failed", payload: [
                        "video": videoURL.lastPathComponent,
                        "model": variant.modelName,
                        "quantization": variant.quantization,
                        "runtime": "LEAP",
                        "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    func runOfflineVideoGemmaBenchmark() {
        guard let videoURL = selectedBenchmarkVideoURL else {
            modelBenchmarkStatus = "No video"
            modelBenchmarkOutput = "Import a benchmark video first."
            return
        }
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let benchmark = modelBenchmark
        let variants = LocalVisionBenchmarkVariant.officialGemmaTriage
        modelBenchmarkStatus = "Video sampling"
        modelBenchmarkOutput = "Sampling 1 frame from \(selectedBenchmarkVideoName) on iPhone, then running \(variants.count) LiteRT-LM Gemma variants one at a time..."
        addLog("Starting offline iPhone video benchmark: video=\(selectedBenchmarkVideoName), model=\(modelName)")
        emitAgentCEvent("offline_video_benchmark_started", payload: [
            "video": selectedBenchmarkVideoName,
            "model": modelName,
            "sample_count": 1,
            "variants": variants.map(\.label)
        ])

        offlineVideoBenchmarkTask = Task { [weak self] in
            do {
                let frames = try await OfflineVideoFrameSampler.sampleJPEGFrames(
                    from: videoURL,
                    frameCount: 1,
                    maxDimension: 288,
                    compressionQuality: 0.38
                )

                var latencies: [Int] = []
                var outputs: [String] = []

                for variant in variants {
                    try Task.checkCancellation()
                    await benchmark.resetCaches()

                    for frame in frames {
                        try Task.checkCancellation()
                        await MainActor.run {
                            self?.modelBenchmarkStatus = "\(variant.shortLabel) \(frame.index + 1)/\(frames.count)"
                            self?.modelBenchmarkOutput = "Running \(variant.label) on frame \(frame.index + 1)/\(frames.count) at \(String(format: "%.1f", frame.seconds))s..."
                        }

                        do {
                            let result = try await benchmark.runSentinelProbe(
                                modelPath: modelPath,
                                imageData: frame.jpegData,
                                variant: variant
                            )
                            latencies.append(result.totalMilliseconds)
                            outputs.append("\(variant.label), frame \(frame.index + 1) @ \(String(format: "%.1f", frame.seconds))s: \(result.totalMilliseconds)ms\n\(result.responseText)")

                            await MainActor.run {
                                guard let self else { return }
                                self.sentinelSamples += 1
                                self.sentinelLastInferenceMS = result.totalMilliseconds
                                self.averageInferenceMS = self.rollingAverage(current: self.averageInferenceMS, next: result.totalMilliseconds, count: max(self.sentinelSamples, 1))
                                self.addLog("Offline video \(variant.shortLabel) frame \(frame.index + 1)/\(frames.count): \(result.compactSummary)")
                                self.emitAgentCEvent("offline_video_frame_result", payload: [
                                    "frame_index": frame.index,
                                    "seconds": frame.seconds,
                                    "latency_ms": result.totalMilliseconds,
                                    "jpeg_bytes": frame.jpegData.count,
                                    "model": modelName,
                                    "variant": variant.label,
                                    "vision_backend": variant.visionBackend.rawValue,
                                    "mtp": variant.speculativeDecoding,
                                    "response_text": result.responseText
                                ])
                            }
                        } catch {
                            outputs.append("\(variant.label), frame \(frame.index + 1) @ \(String(format: "%.1f", frame.seconds))s: FAILED\n\(error.localizedDescription)")
                            await MainActor.run {
                                guard let self else { return }
                                self.addLog("Offline video \(variant.shortLabel) failed: \(error.localizedDescription)")
                                self.emitAgentCEvent("offline_video_frame_failed", payload: [
                                    "frame_index": frame.index,
                                    "seconds": frame.seconds,
                                    "jpeg_bytes": frame.jpegData.count,
                                    "model": modelName,
                                    "variant": variant.label,
                                    "vision_backend": variant.visionBackend.rawValue,
                                    "mtp": variant.speculativeDecoding,
                                    "error": error.localizedDescription
                                ])
                            }
                        }
                    }
                }

                let mean = latencies.isEmpty ? 0 : Int(Double(latencies.reduce(0, +)) / Double(latencies.count))
                let minLatency = latencies.min() ?? 0
                let maxLatency = latencies.max() ?? 0
                let summary = """
                iPhone offline video benchmark
                Model: \(modelName)
                Video: \(videoURL.lastPathComponent)
                Variants: \(variants.map(\.label).joined(separator: ", "))
                Frames: \(latencies.count)
                Latency ms: min \(minLatency), mean \(mean), max \(maxLatency)

                \(outputs.joined(separator: "\n\n"))
                """

                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Video complete"
                    self.modelBenchmarkOutput = summary
                    self.addLog("Offline iPhone video benchmark complete: frames=\(latencies.count), mean=\(mean)ms")
                    self.emitAgentCEvent("offline_video_benchmark_complete", payload: [
                        "video": videoURL.lastPathComponent,
                        "model": modelName,
                        "variants": variants.map(\.label),
                        "frames": latencies.count,
                        "latency_min_ms": minLatency,
                        "latency_mean_ms": mean,
                        "latency_max_ms": maxLatency
                    ])
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.modelBenchmarkStatus = "Video cancelled"
                    self?.addLog("Offline iPhone video benchmark cancelled.")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Video failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Offline iPhone video benchmark failed: \(error.localizedDescription)")
                    self.emitAgentCEvent("offline_video_benchmark_failed", payload: [
                        "video": videoURL.lastPathComponent,
                        "model": modelName,
                        "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    func runIntegratedReplayBenchmark(inputMode: IntegratedReplayInputMode = .audioAndTranscript) {
        guard let videoURL = selectedBenchmarkVideoURL else {
            modelBenchmarkStatus = "No video"
            modelBenchmarkOutput = "Import a benchmark video first."
            return
        }
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let lfmBenchmark = lfmBenchmark
        let gemmaBenchmark = modelBenchmark
        let visualVariant = LocalLFMBenchmarkVariant.lfm450m
        modelBenchmarkStatus = "Replay sampling"
        modelBenchmarkOutput = "Sampling 5 frames, extracting audio if needed, then running \(inputMode.displayName)..."
        addLog("Starting integrated iPhone replay benchmark: mode=\(inputMode.rawValue), video=\(selectedBenchmarkVideoName), reasoner=\(modelName), visual=\(visualVariant.modelName)")
        emitAgentCEvent("integrated_replay_benchmark_started", payload: [
            "input_mode": inputMode.rawValue,
            "video": selectedBenchmarkVideoName,
            "reasoner_model": modelName,
            "vision_model": visualVariant.modelName,
            "vision_quantization": visualVariant.quantization,
            "sample_count": 5
        ])

        offlineVideoBenchmarkTask = Task { [weak self] in
            let totalStart = Date()
            do {
                let frames = try await OfflineVideoFrameSampler.sampleJPEGFrames(
                    from: videoURL,
                    frameCount: 5,
                    maxDimension: 288,
                    compressionQuality: 0.38
                )

                var visualLatencies: [Int] = []
                var visualTimeline: [IntegratedVisualObservation] = []

                for frame in frames {
                    try Task.checkCancellation()
                    await MainActor.run {
                        self?.modelBenchmarkStatus = "LFM frame \(frame.index + 1)/\(frames.count)"
                        self?.modelBenchmarkOutput = "Running LFM 450M on replay frame \(frame.index + 1)/\(frames.count) at \(String(format: "%.1f", frame.seconds))s..."
                    }

                    ArtemisBenchmarkEventStore.writeFrame(frame.jpegData, name: "integrated-frame-\(frame.index + 1).jpg")
                    let result = try await lfmBenchmark.runVisionProbe(
                        imageData: frame.jpegData,
                        variant: visualVariant,
                        prompt: LocalLFMBenchmarkService.integratedReplayPrompt
                    )
                    visualLatencies.append(result.totalMilliseconds)
                    visualTimeline.append(IntegratedVisualObservation(
                        frameIndex: frame.index,
                        seconds: frame.seconds,
                        latencyMilliseconds: result.totalMilliseconds,
                        responseText: result.responseText
                    ))

                    await MainActor.run {
                        guard let self else { return }
                        self.sentinelSamples += 1
                        self.sentinelLastInferenceMS = result.totalMilliseconds
                        self.averageInferenceMS = self.rollingAverage(current: self.averageInferenceMS, next: result.totalMilliseconds, count: max(self.sentinelSamples, 1))
                        self.addLog("Integrated replay LFM frame \(frame.index + 1)/\(frames.count): \(result.compactSummary)")
                        self.emitAgentCEvent("integrated_replay_visual_frame_result", payload: [
                            "frame_index": frame.index,
                            "seconds": frame.seconds,
                            "latency_ms": result.totalMilliseconds,
                            "jpeg_bytes": frame.jpegData.count,
                            "model": visualVariant.modelName,
                            "quantization": visualVariant.quantization,
                            "response_text": result.responseText
                        ])
                    }
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self?.modelBenchmarkStatus = "Audio extract"
                    self?.modelBenchmarkOutput = "Extracting audio from \(videoURL.lastPathComponent) for Apple STT and Gemma E2B audio/text reasoning..."
                }

                var audioURL: URL?
                var transcript = ""
                var transcriptChunks: [[String: Any]] = []
                var transcriptStatus = inputMode.usesTranscript ? "not_attempted" : "skipped"
                var audioStatus = "not_attempted"

                if inputMode.usesAudio || inputMode.usesTranscript {
                    do {
                    let extracted = try await OfflineAudioExtractor.extractAudioAssets(from: videoURL)
                    audioURL = inputMode.usesAudio ? extracted.modelURL : nil
                    audioStatus = "ok:speech=\(extracted.speechURL.lastPathComponent),model=\(extracted.modelURL.lastPathComponent)"
                    await MainActor.run {
                        self?.addLog("Integrated replay audio extracted: speech=\(extracted.speechURL.lastPathComponent), model=\(extracted.modelURL.lastPathComponent)")
                    }
                    if inputMode.usesTranscript {
                        do {
                            let speech = try await OfflineSpeechFileTranscriber.transcribe(url: extracted.speechURL)
                            transcript = speech.text
                            transcriptChunks = speech.chunkPayload
                            transcriptStatus = speech.isOnDevice ? "on_device" : "apple_speech"
                            await MainActor.run {
                                self?.addLog("Integrated replay STT complete: chars=\(speech.text.count), chunks=\(transcriptChunks.count), mode=\(transcriptStatus)")
                            }
                        } catch {
                            transcriptStatus = "failed:\(error.localizedDescription)"
                            await MainActor.run {
                                self?.addLog("Integrated replay STT failed; continuing with Gemma replay: \(error.localizedDescription)")
                            }
                        }
                    }
                    } catch {
                        audioStatus = "failed:\(error.localizedDescription)"
                        await MainActor.run {
                            self?.addLog("Integrated replay audio extraction failed; continuing without audio: \(error.localizedDescription)")
                        }
                    }
                } else {
                    audioStatus = "skipped"
                }

                if inputMode.usesAudio, audioURL == nil {
                    throw NSError(
                        domain: "ArtemisIntegratedReplay",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio replay requires an extracted model audio file."]
                    )
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self?.modelBenchmarkStatus = "Gemma reasoning"
                    self?.modelBenchmarkOutput = "Running Gemma E2B \(inputMode.rawValue) replay over LFM visual timeline\(audioURL == nil ? "" : " + audio file")..."
                }

                let reasoningResult: LocalModelBenchmarkResult
                let reasoningMode: String
                var audioReasoningError = ""
                do {
                    reasoningResult = try await gemmaBenchmark.runReplayReasoning(
                        modelPath: modelPath,
                        audioFileURL: audioURL,
                        transcript: transcript,
                        transcriptStatus: transcriptStatus,
                        inputMode: inputMode,
                        visualTimeline: visualTimeline
                    )
                    reasoningMode = inputMode.rawValue
                } catch {
                    guard inputMode.allowsTextFallback, audioURL != nil else { throw error }
                    audioReasoningError = error.localizedDescription
                    await MainActor.run {
                        guard let self else { return }
                        self.addLog("Gemma audio/text replay failed; retrying without audio file: \(error.localizedDescription)")
                        self.emitAgentCEvent("integrated_replay_audio_reasoning_failed", payload: [
                            "video": videoURL.lastPathComponent,
                            "reasoner_model": modelName,
                            "audio_status": audioStatus,
                            "audio_file": audioURL?.lastPathComponent ?? "",
                            "error": error.localizedDescription
                        ])
                    }
                    reasoningResult = try await gemmaBenchmark.runReplayReasoning(
                        modelPath: modelPath,
                        audioFileURL: nil,
                        transcript: transcript,
                        transcriptStatus: "\(transcriptStatus); audio_file_retry_failed=\(error.localizedDescription)",
                        inputMode: .transcriptOnly,
                        visualTimeline: visualTimeline
                    )
                    reasoningMode = "text_visual_timeline_after_audio_failure"
                }

                let totalMS = Int(Date().timeIntervalSince(totalStart) * 1000)
                let visualMean = visualLatencies.isEmpty ? 0 : Int(Double(visualLatencies.reduce(0, +)) / Double(visualLatencies.count))
                let visualMin = visualLatencies.min() ?? 0
                let visualMax = visualLatencies.max() ?? 0
                let realtimeMultiplier = videoURL.durationSecondsForDisplay.map { duration in
                    duration > 0 ? Double(totalMS) / 1000.0 / duration : 0
                } ?? 0
                let timelineText = visualTimeline.map { observation in
                    "Frame \(observation.frameIndex + 1) @ \(String(format: "%.1f", observation.seconds))s, \(observation.latencyMilliseconds)ms: \(observation.responseText)"
                }.joined(separator: "\n\n")
                let summary = """
                Integrated Artemis replay benchmark
                Video: \(videoURL.lastPathComponent)
                Vision: \(visualVariant.modelName) \(visualVariant.quantization) via Liquid LEAP
                Reasoner: \(modelName) via LiteRT-LM
                Reasoning mode: \(reasoningMode)
                Audio extraction: \(audioStatus)
                STT: \(transcriptStatus)
                Frames: \(visualLatencies.count)
                LFM visual latency ms: min \(visualMin), mean \(visualMean), max \(visualMax)
                Gemma reasoning latency: \(reasoningResult.totalMilliseconds)ms
                Total replay wall time: \(totalMS)ms
                Replay realtime factor: \(String(format: "%.2fx", realtimeMultiplier))

                Transcript:
                \(transcript.isEmpty ? "(empty or unavailable)" : transcript)

                LFM visual timeline:
                \(timelineText)

                Gemma integrated answer:
                \(reasoningResult.responseText)
                """

                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Replay complete"
                    self.modelBenchmarkOutput = summary
                    self.addLog("Integrated replay complete: frames=\(visualLatencies.count), lfm_mean=\(visualMean)ms, gemma=\(reasoningResult.totalMilliseconds)ms, total=\(totalMS)ms")
                    self.emitAgentCEvent("integrated_replay_benchmark_complete", payload: [
                        "video": videoURL.lastPathComponent,
                        "input_mode": inputMode.rawValue,
                        "vision_model": visualVariant.modelName,
                        "vision_quantization": visualVariant.quantization,
                        "reasoner_model": modelName,
                        "reasoning_mode": reasoningMode,
                        "audio_status": audioStatus,
                        "audio_reasoning_error": audioReasoningError,
                        "transcript_contract_version": 1,
                        "transcript_status": transcriptStatus,
                        "transcript": transcript,
                        "transcript_chunk_count": transcriptChunks.count,
                        "transcript_chunks": transcriptChunks,
                        "frames": visualLatencies.count,
                        "lfm_latency_min_ms": visualMin,
                        "lfm_latency_mean_ms": visualMean,
                        "lfm_latency_max_ms": visualMax,
                        "gemma_latency_ms": reasoningResult.totalMilliseconds,
                        "total_latency_ms": totalMS,
                        "realtime_factor": realtimeMultiplier,
                        "answer": reasoningResult.responseText
                    ])
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.modelBenchmarkStatus = "Replay cancelled"
                    self?.addLog("Integrated replay benchmark cancelled.")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Replay failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Integrated replay benchmark failed: \(error.localizedDescription)")
                    self.emitAgentCEvent("integrated_replay_benchmark_failed", payload: [
                        "video": videoURL.lastPathComponent,
                        "input_mode": inputMode.rawValue,
                        "reasoner_model": modelName,
                        "vision_model": visualVariant.modelName,
                        "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    func runConsciousSessionDecodeBenchmark() {
        guard let videoURL = selectedBenchmarkVideoURL else {
            modelBenchmarkStatus = "No video"
            modelBenchmarkOutput = "Import a benchmark video first."
            return
        }
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let batchID = UUID().uuidString
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let videoName = selectedBenchmarkVideoName
        let lfmBenchmark = lfmBenchmark
        let gemmaBenchmark = modelBenchmark
        let visualVariant = LocalLFMBenchmarkVariant.lfm450m
        let durationSeconds = videoURL.durationSecondsForDisplay ?? 180.0
        let requestedFrames = min(48, max(12, Int((durationSeconds / 5.0).rounded(.toNearestOrAwayFromZero))))
        let frameMaxDimension: CGFloat = 224
        let compressionQuality: CGFloat = 0.32

        modelBenchmarkStatus = "Session decode"
        modelBenchmarkOutput = "Decoding \(videoName): \(requestedFrames) sampled frames + full audio transcript + Gemma synthesis..."
        addLog("Starting conscious session decode \(batchID): video=\(videoName), frames=\(requestedFrames), reasoner=\(modelName)")
        emitAgentCEvent("conscious_session_decode_started", payload: [
            "batch_id": batchID,
            "video": videoName,
            "duration_s": durationSeconds,
            "requested_frames": requestedFrames,
            "vision_model": visualVariant.modelName,
            "reasoner_model": modelName
        ])

        offlineVideoBenchmarkTask = Task { [weak self] in
            let totalStart = Date()
            var visualLatencies: [Int] = []
            var visualTimeline: [IntegratedVisualObservation] = []
            var visualTimelinePayload: [[String: Any]] = []
            var transcript = ""
            var transcriptChunks: [[String: Any]] = []
            var transcriptStatus = "not_attempted"
            var audioStatus = "not_attempted"
            let startingDevice = architectureDeviceSnapshot()

            func latencyStats(_ values: [Int]) -> (min: Int, mean: Int, max: Int) {
                guard !values.isEmpty else { return (0, 0, 0) }
                return (
                    values.min() ?? 0,
                    Int(Double(values.reduce(0, +)) / Double(values.count)),
                    values.max() ?? 0
                )
            }

            do {
                try Task.checkCancellation()
                let frames = try await OfflineVideoFrameSampler.sampleJPEGFrames(
                    from: videoURL,
                    frameCount: requestedFrames,
                    maxDimension: frameMaxDimension,
                    compressionQuality: compressionQuality
                )

                for (position, frame) in frames.enumerated() {
                    try Task.checkCancellation()
                    await MainActor.run {
                        self?.modelBenchmarkStatus = "Decode frame \(position + 1)/\(frames.count)"
                        self?.modelBenchmarkOutput = "LFM 450M decoding \(videoName) @ \(String(format: "%.1f", frame.seconds))s..."
                    }
                    ArtemisBenchmarkEventStore.writeFrame(frame.jpegData, name: "conscious-session-frame-\(String(format: "%03d", position + 1)).jpg")
                    let result = try await lfmBenchmark.runVisionProbe(
                        imageData: frame.jpegData,
                        variant: visualVariant,
                        prompt: LocalLFMBenchmarkService.sessionDecodeFramePrompt
                    )
                    visualLatencies.append(result.totalMilliseconds)
                    let observation = IntegratedVisualObservation(
                        frameIndex: position,
                        seconds: frame.seconds,
                        latencyMilliseconds: result.totalMilliseconds,
                        responseText: result.responseText
                    )
                    visualTimeline.append(observation)
                    visualTimelinePayload.append([
                        "index": position,
                        "seconds": frame.seconds,
                        "latency_ms": result.totalMilliseconds,
                        "jpeg_bytes": frame.jpegData.count,
                        "observation": result.responseText
                    ])
                    ArtemisBenchmarkEventStore.append(event: "conscious_session_frame_decoded", payload: [
                        "batch_id": batchID,
                        "index": position,
                        "seconds": frame.seconds,
                        "latency_ms": result.totalMilliseconds,
                        "jpeg_bytes": frame.jpegData.count,
                        "observation": result.responseText
                    ])
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self?.modelBenchmarkStatus = "Session STT"
                    self?.modelBenchmarkOutput = "Extracting and transcribing full audio for \(videoName)..."
                }
                do {
                    let extracted = try await OfflineAudioExtractor.extractAudioAssets(from: videoURL)
                    audioStatus = "ok:speech=\(extracted.speechURL.lastPathComponent),model=\(extracted.modelURL.lastPathComponent)"
                    let speech = try await OfflineSpeechFileTranscriber.transcribe(url: extracted.speechURL)
                    transcript = speech.text
                    transcriptChunks = speech.chunkPayload
                    transcriptStatus = speech.isOnDevice ? "on_device" : "apple_speech"
                } catch {
                    audioStatus = "failed:\(error.localizedDescription)"
                    transcriptStatus = "failed:\(error.localizedDescription)"
                }

                let preReasoningSnapshot: [String: Any] = [
                    "batch_id": batchID,
                    "status": "vision_transcript_ready",
                    "architecture": "conscious_session_decode_v1",
                    "video": videoName,
                    "duration_s": durationSeconds,
                    "requested_frames": requestedFrames,
                    "decoded_frames": visualTimeline.count,
                    "vision_model": visualVariant.modelName,
                    "vision_quantization": visualVariant.quantization,
                    "audio_status": audioStatus,
                    "transcript_contract_version": 1,
                    "transcript_status": transcriptStatus,
                    "transcript_chars": transcript.count,
                    "transcript_chunk_count": transcriptChunks.count,
                    "transcript_chunks": transcriptChunks,
                    "transcript": transcript,
                    "visual_timeline": visualTimelinePayload,
                    "device_start": startingDevice,
                    "device_mid": architectureDeviceSnapshot()
                ]
                ArtemisBenchmarkEventStore.writeJSON(preReasoningSnapshot, name: "conscious-session-vision-timeline-latest.json")
                ArtemisBenchmarkEventStore.writeJSON(preReasoningSnapshot, name: "conscious-session-decode-latest.json")

                let totalMS = Int(Date().timeIntervalSince(totalStart) * 1000)
                let stats = latencyStats(visualLatencies)
                let realtimeFactor = durationSeconds > 0
                    ? Double(totalMS) / 1000.0 / durationSeconds
                    : 0.0
                let observedVisionFPS = stats.mean > 0 ? Double(1000) / Double(stats.mean) : 0.0
                let quality = visionQualityProxy(
                    outputs: visualTimeline.map(\.responseText),
                    expectedFrames: requestedFrames
                )
                var summary: [String: Any] = [
                    "batch_id": batchID,
                    "status": "complete",
                    "architecture": "conscious_session_decode_v1",
                    "reasoning_strategy": "chunked_visual_summaries_then_final_answer",
                    "video": videoName,
                    "duration_s": durationSeconds,
                    "requested_frames": requestedFrames,
                    "decoded_frames": visualTimeline.count,
                    "frame_interval_s_estimate": durationSeconds / Double(max(requestedFrames + 1, 1)),
                    "frame_max_dimension": Int(frameMaxDimension),
                    "compression_quality": Double(compressionQuality),
                    "vision_model": visualVariant.modelName,
                    "vision_quantization": visualVariant.quantization,
                    "vision_runtime": "LEAP",
                    "vision_latency_min_ms": stats.min,
                    "vision_latency_mean_ms": stats.mean,
                    "vision_latency_max_ms": stats.max,
                    "vision_observed_fps": observedVisionFPS,
                    "vision_quality_proxy_score": quality.score,
                    "vision_quality_proxy": quality.details,
                    "audio_status": audioStatus,
                    "transcript_contract_version": 1,
                    "transcript_status": transcriptStatus,
                    "transcript_chars": transcript.count,
                    "transcript_chunk_count": transcriptChunks.count,
                    "transcript_chunks": transcriptChunks,
                    "transcript": transcript,
                    "reasoner_model": modelName,
                    "reasoner_runtime": "LiteRT-LM",
                    "reasoner_latency_ms": NSNull(),
                    "total_wall_ms": totalMS,
                    "realtime_factor": realtimeFactor,
                    "answer": "",
                    "visual_timeline": visualTimelinePayload,
                    "device_start": startingDevice,
                    "device_end": architectureDeviceSnapshot()
                ]
                ArtemisBenchmarkEventStore.writeJSON(summary, name: "conscious-session-decode-latest.json")
                ArtemisBenchmarkEventStore.append(event: "conscious_session_vision_transcript_complete", payload: summary)

                let transcriptPreview = transcript.isEmpty ? "(empty or unavailable)" : transcript
                let output = """
                Artemis conscious session vision/transcript decode
                Video: \(videoName)
                Duration: \(String(format: "%.1f", durationSeconds))s
                Frames: \(visualTimeline.count)/\(requestedFrames)
                Vision latency ms: min \(stats.min), mean \(stats.mean), max \(stats.max)
                Vision observed FPS: \(String(format: "%.2f", observedVisionFPS))
                Vision quality proxy: \(String(format: "%.2f", quality.score))
                STT: \(transcriptStatus), chars \(transcript.count)
                Gemma latency: pending fresh-process synthesis
                Total wall: \(totalMS)ms
                Realtime factor: \(String(format: "%.2fx", realtimeFactor))

                Transcript:
                \(transcriptPreview)

                Next:
                Relaunch with --run-conscious-session-synthesis for fresh-process Gemma synthesis.
                """
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Vision transcript ready"
                    self.modelBenchmarkOutput = output
                    self.addLog("Conscious session vision/transcript complete: frames=\(visualTimeline.count), transcript_chars=\(transcript.count), transcript_chunks=\(transcriptChunks.count), total=\(totalMS)ms")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.modelBenchmarkStatus = "Session decode cancelled"
                    self?.addLog("Conscious session decode cancelled.")
                }
            } catch {
                let partialStatus = visualTimeline.isEmpty ? "failed" : "partial_success"
                let record: [String: Any] = [
                    "batch_id": batchID,
                    "status": partialStatus,
                    "architecture": "conscious_session_decode_v1",
                    "video": videoName,
                    "error": error.localizedDescription,
                    "decoded_frames": visualTimeline.count,
                    "audio_status": audioStatus,
                    "transcript_contract_version": 1,
                    "transcript_status": transcriptStatus,
                    "transcript_chars": transcript.count,
                    "transcript_chunk_count": transcriptChunks.count,
                    "transcript_chunks": transcriptChunks,
                    "transcript": transcript,
                    "visual_timeline": visualTimelinePayload,
                    "device": architectureDeviceSnapshot()
                ]
                ArtemisBenchmarkEventStore.writeJSON(record, name: "conscious-session-decode-latest.json")
                ArtemisBenchmarkEventStore.append(event: "conscious_session_decode_failed", payload: record)
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Session decode failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Conscious session decode failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func runConsciousSessionSynthesisFromLatest() {
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Copy an official Gemma .litertlm model into Documents/Models first."
            return
        }

        offlineVideoBenchmarkTask?.cancel()
        let modelPath = selectedModelPath
        let modelName = selectedModelName
        let gemmaBenchmark = modelBenchmark
        let batchID = UUID().uuidString
        modelBenchmarkStatus = "Session synthesis"
        modelBenchmarkOutput = "Loading latest vision/transcript timeline and running fresh-process Gemma synthesis..."
        addLog("Starting conscious session synthesis \(batchID): reasoner=\(modelName)")

        offlineVideoBenchmarkTask = Task { [weak self] in
            let started = Date()
            var synthesisStrategy = "not_started"
            do {
                let source = try ArtemisBenchmarkEventStore.readJSON(name: "conscious-session-vision-timeline-latest.json")
                let videoName = source["video"] as? String ?? "unknown"
                let durationSeconds = source["duration_s"] as? Double ?? 0.0
                let transcript = source["transcript"] as? String ?? ""
                let transcriptStatus = source["transcript_status"] as? String ?? "unknown"
                let visualPayload = source["visual_timeline"] as? [[String: Any]] ?? []
                let visualTimeline = visualPayload.compactMap { row -> IntegratedVisualObservation? in
                    guard let observation = row["observation"] as? String else { return nil }
                    let index = row["index"] as? Int ?? 0
                    let seconds = row["seconds"] as? Double ?? 0.0
                    let latency = row["latency_ms"] as? Int ?? 0
                    return IntegratedVisualObservation(
                        frameIndex: index,
                        seconds: seconds,
                        latencyMilliseconds: latency,
                        responseText: observation
                    )
                }
                guard !visualTimeline.isEmpty else {
                    throw NSError(
                        domain: "ArtemisConsciousSynthesis",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "No visual timeline found in conscious-session-vision-timeline-latest.json."]
                    )
                }

                let promptPreview = await gemmaBenchmark.sessionQuickReasoningPromptPreview(
                    transcript: transcript,
                    transcriptStatus: transcriptStatus,
                    visualTimeline: visualTimeline,
                    videoDurationSeconds: durationSeconds
                )
                var debugRecord: [String: Any] = [
                    "batch_id": batchID,
                    "status": "prompt_prepared",
                    "architecture": "conscious_session_decode_v1",
                    "reasoner_model": modelName,
                    "visual_frames": visualTimeline.count,
                    "transcript_chars": transcript.count,
                    "device": architectureDeviceSnapshot()
                ]
                promptPreview.forEach { key, value in
                    debugRecord[key] = value
                }
                ArtemisBenchmarkEventStore.writeJSON(debugRecord, name: "conscious-session-synthesis-debug-latest.json")
                ArtemisBenchmarkEventStore.append(event: "conscious_session_synthesis_prompt_prepared", payload: debugRecord)

                var fallbackError: String?
                synthesisStrategy = "single_call_compacted_timeline"
                let result: LocalModelBenchmarkResult
                if ProcessInfo.processInfo.arguments.contains("--try-chunked-synthesis") {
                    synthesisStrategy = "fresh_process_chunked_gemma_synthesis"
                    do {
                        result = try await gemmaBenchmark.runSessionDecodeChunkedReasoning(
                            modelPath: modelPath,
                            transcript: transcript,
                            transcriptStatus: transcriptStatus,
                            visualTimeline: visualTimeline,
                            videoDurationSeconds: durationSeconds
                        )
                    } catch {
                        fallbackError = error.localizedDescription
                        await gemmaBenchmark.resetCaches()
                        synthesisStrategy = "single_call_compacted_timeline_fallback"
                        result = try await gemmaBenchmark.runSessionQuickReasoning(
                            modelPath: modelPath,
                            transcript: transcript,
                            transcriptStatus: transcriptStatus,
                            visualTimeline: visualTimeline,
                            videoDurationSeconds: durationSeconds
                        )
                    }
                } else {
                    synthesisStrategy = "single_call_sanitized_replay_packet"
                    result = try await gemmaBenchmark.runSessionQuickReasoning(
                        modelPath: modelPath,
                        transcript: transcript,
                        transcriptStatus: transcriptStatus,
                        visualTimeline: visualTimeline,
                        videoDurationSeconds: durationSeconds
                    )
                }
                await gemmaBenchmark.resetCaches()

                let totalMS = Int(Date().timeIntervalSince(started) * 1000)
                var output = source
                output["batch_id"] = batchID
                output["status"] = fallbackError == nil ? "complete" : "complete_with_fallback"
                output["architecture"] = "conscious_session_decode_v1"
                output["reasoning_strategy"] = synthesisStrategy
                output["reasoner_model"] = modelName
                output["reasoner_runtime"] = "LiteRT-LM"
                output["reasoner_latency_ms"] = result.totalMilliseconds
                output["synthesis_wall_ms"] = totalMS
                output["answer"] = result.responseText
                output["device_synthesis_end"] = architectureDeviceSnapshot()
                if let fallbackError {
                    output["fallback_from_error"] = fallbackError
                }
                if let metrics = result.liteRTMetrics {
                    output["litert_metrics"] = metrics.payload
                }
                ArtemisBenchmarkEventStore.writeJSON(output, name: "conscious-session-decode-latest.json")
                ArtemisBenchmarkEventStore.writeJSON(output, name: "conscious-session-synthesis-latest.json")
                ArtemisBenchmarkEventStore.append(event: "conscious_session_synthesis_complete", payload: output)

                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Session synthesis complete"
                    self.modelBenchmarkOutput = """
                    Artemis conscious session synthesis
                    Video: \(videoName)
                    Frames: \(visualTimeline.count)
                    Transcript chars: \(transcript.count)
                    Gemma total chunked latency: \(result.totalMilliseconds)ms

                    Answer:
                    \(result.responseText)
                    """
                    self.addLog("Conscious session synthesis complete: strategy=\(synthesisStrategy), frames=\(visualTimeline.count), transcript_chars=\(transcript.count), gemma_total=\(result.totalMilliseconds)ms")
                }
            } catch {
                let record: [String: Any] = [
                    "batch_id": batchID,
                    "status": "partial_success",
                    "architecture": "conscious_session_decode_v1",
                    "reasoning_strategy": synthesisStrategy,
                    "reasoner_model": modelName,
                    "error": error.localizedDescription,
                    "device": architectureDeviceSnapshot()
                ]
                ArtemisBenchmarkEventStore.writeJSON(record, name: "conscious-session-decode-latest.json")
                ArtemisBenchmarkEventStore.writeJSON(record, name: "conscious-session-synthesis-latest.json")
                ArtemisBenchmarkEventStore.append(event: "conscious_session_synthesis_failed", payload: record)
                await gemmaBenchmark.resetCaches()
                await MainActor.run {
                    guard let self else { return }
                    self.modelBenchmarkStatus = "Session synthesis failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Conscious session synthesis failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelOfflineVideoBenchmark() {
        offlineVideoBenchmarkTask?.cancel()
        offlineVideoBenchmarkTask = nil
        modelBenchmarkStatus = "Video cancelled"
        addLog("Offline video benchmark cancellation requested.")
    }

    func refreshLocalModels() {
        do {
            let modelsDirectory = try localModelsDirectory()
            let candidates = try FileManager.default.contentsOfDirectory(
                at: modelsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            .filter { ["litertlm", "task"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

            if let model = candidates.first {
                let modelSize = formattedFileSize(for: model)
                selectedModelPath = model.path
                selectedModelName = model.lastPathComponent
                modelBenchmarkStatus = "Ready"
                modelStorageSummary = "Documents/Models: \(candidates.count) model\(candidates.count == 1 ? "" : "s")"
                modelBenchmarkOutput = "Selected existing model \(selectedModelName) (\(modelSize))."
                addLog("Model scan found \(selectedModelName) (\(modelSize)).")
            } else {
                selectedModelPath = ""
                selectedModelName = "No model selected"
                modelBenchmarkStatus = "No model"
                modelStorageSummary = "Documents/Models: empty"
                modelBenchmarkOutput = "Import Gemma E4B .litertlm through Files, then run benchmark."
                addLog("Model scan found no .litertlm or .task files.")
            }
        } catch {
            modelBenchmarkStatus = "Model scan failed"
            modelStorageSummary = "Model scan failed"
            modelBenchmarkOutput = error.localizedDescription
            addLog("Model scan failed: \(error.localizedDescription)")
        }
    }

    func runGemmaSyntheticBenchmark() {
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Import a .litertlm model first."
            return
        }

        modelBenchmarkStatus = "Running synthetic"
        modelBenchmarkOutput = "Loading \(selectedModelName) with GPU backend..."
        addLog("Starting Gemma synthetic benchmark: \(selectedModelName)")

        Task {
            do {
                let result = try await modelBenchmark.runSyntheticBenchmark(modelPath: selectedModelPath)
                await MainActor.run {
                    self.averageInferenceMS = result.totalMilliseconds
                    self.modelBenchmarkStatus = "Synthetic complete"
                    self.modelBenchmarkOutput = result.summary
                    self.addLog("Gemma synthetic benchmark complete: \(result.compactSummary)")
                }
            } catch {
                await MainActor.run {
                    self.modelBenchmarkStatus = "Synthetic failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Gemma synthetic benchmark failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func runGemmaLatestFrameVisionProbe() {
        if selectedModelPath.isEmpty {
            refreshLocalModels()
        }
        guard !selectedModelPath.isEmpty else {
            modelBenchmarkStatus = "No model"
            modelBenchmarkOutput = "Import a .litertlm model first."
            return
        }

        guard let imageData = latestPreviewImage?.jpegData(compressionQuality: 0.62) else {
            modelBenchmarkStatus = "No frame"
            modelBenchmarkOutput = "Start the glasses stream and wait for Live Preview first."
            return
        }

        modelBenchmarkStatus = "Running vision"
        modelBenchmarkOutput = "Sending latest glasses frame to \(selectedModelName)..."
        addLog("Starting Gemma latest-frame vision probe with \(imageData.count) bytes.")

        Task {
            do {
                let result = try await modelBenchmark.runVisionProbe(modelPath: selectedModelPath, imageData: imageData)
                await MainActor.run {
                    self.averageInferenceMS = result.totalMilliseconds
                    self.modelBenchmarkStatus = "Vision complete"
                    self.modelBenchmarkOutput = result.summary
                    self.lastBrainResponse = BrainResponse(
                        text: result.responseText,
                        shouldSendToDisplay: true,
                        shouldSpeak: false
                    )
                    self.addLog("Gemma vision probe complete: \(result.compactSummary)")
                }
            } catch {
                await MainActor.run {
                    self.modelBenchmarkStatus = "Vision failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Gemma vision probe failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func maybeRunLiveSentinel(image: UIImage?, frameID: Int) {
        guard sentinelEnabled else { return }
        guard frameID - lastSentinelFrameID >= sentinelFrameStride else { return }
        guard !brainTurnInFlight else {
            sentinelStatus = "Paused for brain"
            return
        }
        guard !audioOutputInFlight else {
            sentinelStatus = "Paused for audio"
            return
        }
        guard ProcessInfo.processInfo.thermalState != .critical else {
            sentinelEnabled = false
            sentinelStatus = "Thermal stop"
            sentinelDecision = "Realtime LFM vision sentinel stopped because iPhone thermal state is critical."
            addLog("LFM realtime sentinel stopped: thermal state critical.")
            emitAgentCEvent("lfm_realtime_stopped", payload: [
                "reason": "thermal_critical",
                "frame_id": frameID
            ])
            return
        }
        guard let image else {
            sentinelStatus = "No image"
            return
        }

        guard let imageData = compressedSentinelJPEG(from: image) else {
            sentinelStatus = "Encode failed"
            addLog("Live sentinel skipped: failed to encode preview image.")
            return
        }

        if sentinelInFlight {
            pendingSentinelFrame = (frameID: frameID, imageData: imageData)
            sentinelStatus = "Pending \(frameID)"
            return
        }

        startLiveSentinel(frameID: frameID, imageData: imageData)
    }

    private func startLiveSentinel(frameID: Int, imageData: Data) {
        let variant = LocalLFMBenchmarkVariant.lfm450m
        let benchmark = lfmBenchmark
        sentinelInFlight = true
        lastSentinelFrameID = frameID
        sentinelStatus = "Running"
        sentinelDecision = "Analyzing frame \(frameID) locally with \(variant.modelName)."
        addLog("Live sentinel frame \(frameID) started with \(imageData.count) bytes.")
        emitAgentCEvent("vision_probe_started", payload: [
            "frame_id": frameID,
            "model": variant.modelName,
            "runtime": "LEAP",
            "quantization": variant.quantization,
            "jpeg_bytes": imageData.count,
            "stride_frames": sentinelFrameStride
        ])

        sentinelTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await benchmark.runVisionProbe(imageData: imageData, variant: variant)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.sentinelTask = nil
                    let shouldEscalate = self.detectEscalation(in: result.responseText)
                    let visionContext = self.liveVisionContextFromLFMResult(
                        result.responseText,
                        frameID: frameID,
                        latencyMS: result.totalMilliseconds
                    )
                    let visionFreshness = VisionFreshnessPolicy.classify(
                        frameID: visionContext.frameID,
                        timestampMS: visionContext.timestampMS,
                        ageMS: 0,
                        confidence: visionContext.confidence,
                        summary: visionContext.summary,
                        visibleText: visionContext.visibleText,
                        streamState: self.connectionState.rawValue
                    )
                    let visionPolicy = self.hierarchicalVisionDecision(
                        frameID: visionContext.frameID,
                        frameAgeMS: 0,
                        latencyMS: result.totalMilliseconds,
                        confidence: visionContext.confidence,
                        summary: visionContext.summary,
                        visibleText: visionContext.visibleText,
                        userPrompt: "",
                        detectedFailure: self.isLowInformationVisionResponse(result.responseText),
                        sceneChanged: shouldEscalate,
                        evidenceClass: "live_dat"
                    )
                    self.recordHierarchicalVisionDecisionIfNeeded(visionPolicy)
                    self.sentinelInFlight = false
                    self.sentinelSamples += 1
                    self.sentinelLastInferenceMS = result.totalMilliseconds
                    self.averageInferenceMS = result.totalMilliseconds
                    self.framesAnalyzed += 1
                    self.sentinelStatus = "\(result.totalMilliseconds)ms"
                    self.sentinelEscalationLabel = shouldEscalate ? "Yes" : "No"
                    self.sentinelDecision = result.responseText
                    self.liveVisionContext = visionContext
                    self.hudVisionModel = visionContext.visionModel
                    self.hudVisionFrameID = visionContext.frameID
                    self.hudVisionLatencyMS = visionContext.latencyMS
                    self.hudVisionAgeMS = 0
                    self.hudVisionFreshnessState = visionFreshness.state.rawValue
                    self.hudVisionSummary = visionContext.summary
                    self.lastObservation = VisionObservation(
                        timestamp: .now,
                        scene: visionContext.summary,
                        peopleCount: 0,
                        objects: self.extractVisionStringArray(key: "objects", from: result.responseText),
                        visibleText: visionContext.visibleText,
                        notableChange: visionContext.uncertainty,
                        confidence: visionContext.confidence
                    )
                    self.modelBenchmarkStatus = "Sentinel live"
                    self.modelBenchmarkOutput = result.summary
                    self.addLog("Live sentinel frame \(frameID) complete: escalate=\(shouldEscalate ? "yes" : "no"), \(result.compactSummary)")
                    var payload: [String: Any] = [
                        "frame_id": frameID,
                        "model": variant.modelName,
                        "runtime": "LEAP",
                        "quantization": variant.quantization,
                        "latency_ms": result.totalMilliseconds,
                        "jpeg_bytes": imageData.count,
                        "should_escalate": shouldEscalate,
                        "response_text": result.responseText,
                        "vision_summary": visionContext.summary,
                        "vision_confidence": visionContext.confidence,
                        "vision_freshness_state": visionFreshness.state.rawValue,
                        "vision_freshness_reason": visionFreshness.reason,
                        "vision_direct_claim_allowed": visionFreshness.supportsDirectVisualClaim
                    ]
                    for (key, value) in self.hierarchicalVisionPolicyPayload(visionPolicy) {
                        payload[key] = value
                    }
                    self.emitAgentCEvent("vision_probe_result", payload: payload)
                    self.drainPendingLiveSentinelIfNeeded()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self else { return }
                    self.sentinelTask = nil
                    self.sentinelInFlight = false
                    self.pendingSentinelFrame = nil
                    self.sentinelStatus = self.brainTurnInFlight ? "Paused for brain" : "Cancelled"
                    self.addLog("Live sentinel frame \(frameID) cancelled before result handling.")
                    self.emitAgentCEvent("vision_probe_cancelled", payload: [
                        "frame_id": frameID,
                        "model": variant.modelName,
                        "runtime": "LEAP",
                        "reason": self.brainTurnInFlight ? "brain_turn" : "task_cancelled"
                    ])
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.sentinelTask = nil
                    self.sentinelInFlight = false
                    self.sentinelEnabled = false
                    self.sentinelStatus = "Disabled"
                    self.sentinelDecision = error.localizedDescription
                    self.modelBenchmarkStatus = "Sentinel failed"
                    self.modelBenchmarkOutput = error.localizedDescription
                    self.addLog("Live sentinel frame \(frameID) failed and sentinel was disabled: \(error.localizedDescription)")
                    self.emitAgentCEvent("vision_probe_failed", payload: [
                        "frame_id": frameID,
                        "model": variant.modelName,
                        "runtime": "LEAP",
                        "quantization": variant.quantization,
                        "error": error.localizedDescription
                    ])
                    self.drainPendingLiveSentinelIfNeeded()
                }
            }
        }
    }

    private func drainPendingLiveSentinelIfNeeded() {
        guard !brainTurnInFlight else { return }
        guard !audioOutputInFlight else { return }
        guard !sentinelInFlight, let pending = pendingSentinelFrame else { return }
        pendingSentinelFrame = nil
        startLiveSentinel(frameID: pending.frameID, imageData: pending.imageData)
    }

    private func cancelLiveSentinelForBrainTurn() {
        guard sentinelInFlight else { return }
        let cancelledFrameID = lastSentinelFrameID
        sentinelTask?.cancel()
        sentinelTask = nil
        sentinelInFlight = false
        pendingSentinelFrame = nil
        sentinelStatus = "Paused for brain"
        addLog("Live sentinel frame \(cancelledFrameID) cancelled for brain turn.")
        emitAgentCEvent("vision_probe_cancelled", payload: [
            "frame_id": cancelledFrameID,
            "model": LocalLFMBenchmarkVariant.lfm450m.modelName,
            "runtime": "LEAP",
            "reason": "brain_turn"
        ])
    }

    private func cancelLiveSentinelForAudioOutput() {
        guard sentinelInFlight else { return }
        let cancelledFrameID = lastSentinelFrameID
        sentinelTask?.cancel()
        sentinelTask = nil
        sentinelInFlight = false
        pendingSentinelFrame = nil
        sentinelStatus = "Paused for audio"
        addLog("Live sentinel frame \(cancelledFrameID) cancelled for Kokoro audio output.")
        emitAgentCEvent("vision_probe_cancelled", payload: [
            "frame_id": cancelledFrameID,
            "model": LocalLFMBenchmarkVariant.lfm450m.modelName,
            "runtime": "LEAP",
            "reason": "audio_output"
        ])
    }

    private func compressedSentinelJPEG(from image: UIImage) -> Data? {
        let maxDimension: CGFloat = 512
        let size = image.size
        let largestSide = max(size.width, size.height)
        let scale = largestSide > maxDimension ? maxDimension / largestSide : 1
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.34)
    }

    private func detectEscalation(in responseText: String) -> Bool {
        let normalized = responseText
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return normalized.contains("\"should_escalate\":true")
            || normalized.contains("should_escalate:true")
            || normalized.contains("\"escalate\":true")
            || normalized.contains("escalate:true")
    }

    private func hierarchicalVisionDecision(
        frameID: Int,
        frameAgeMS: Int,
        latencyMS: Int,
        confidence: Double,
        summary: String,
        visibleText: String,
        userPrompt: String,
        detectedFailure: Bool,
        sceneChanged: Bool,
        evidenceClass: String
    ) -> HierarchicalVisionPolicyDecision {
        HierarchicalVisionPolicy.decide(
            frameID: frameID,
            frameAgeMS: frameAgeMS,
            sceneChanged: sceneChanged,
            confidence: confidence,
            summary: summary,
            visibleText: visibleText,
            userPrompt: userPrompt,
            detectedFailure: detectedFailure,
            lastExpensiveVisionAtMS: lastExpensiveVisionRequestAtMS,
            nowMS: nowMilliseconds(),
            sentinelModel: LocalLFMBenchmarkVariant.lfm450m.modelName,
            sentinelLatencyMS: latencyMS,
            evidenceClass: evidenceClass
        )
    }

    private func recordHierarchicalVisionDecisionIfNeeded(_ decision: HierarchicalVisionPolicyDecision) {
        guard decision.escalationAllowed,
              decision.lane == .ocrSelectedCrop || decision.lane == .deepInspector else {
            return
        }
        lastExpensiveVisionRequestAtMS = nowMilliseconds()
    }

    private func hierarchicalVisionPolicyPayload(_ decision: HierarchicalVisionPolicyDecision) -> [String: Any] {
        [
            "vision_policy_lane": decision.lane.rawValue,
            "vision_policy_reason": decision.reason,
            "vision_policy_frame_id": decision.frameID,
            "vision_policy_model": decision.model,
            "vision_policy_latency_ms": decision.latencyMS,
            "vision_policy_evidence_class": decision.evidenceClass,
            "vision_policy_escalation_allowed": decision.escalationAllowed,
            "vision_policy_rate_limited": decision.rateLimited,
            "vision_policy_stale_rejected": decision.staleRejected
        ]
    }

    private func liveVisionContextFromLFMResult(
        _ responseText: String,
        frameID: Int,
        latencyMS: Int
    ) -> LiveVisionContext {
        let cleaned = artemisFirstJSONObjectString(from: responseText)
        var scene = ""
        var visibleText = ""
        var uncertainty = ""
        var confidence = 0.35

        if let json = artemisJSONDictionary(from: cleaned) {
            scene = (json["scene"] as? String)
                ?? (json["summary"] as? String)
                ?? ""
            visibleText = (json["text"] as? String)
                ?? (json["visible_text"] as? String)
                ?? (json["screen_or_text"] as? String)
                ?? ""
            uncertainty = (json["reason"] as? String)
                ?? (json["uncertainty"] as? String)
                ?? ""
            confidence = (json["confidence"] as? Double)
                ?? (json["confidence"] as? NSNumber)?.doubleValue
                ?? Double((json["confidence"] as? String) ?? "")
                ?? confidence
            let objects = extractVisionStringArray(key: "objects", from: cleaned)
            if scene.isEmpty, !objects.isEmpty {
                scene = "Visible objects: \(objects.prefix(5).joined(separator: ", "))"
            }
        }

        if scene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scene = String(cleaned.prefix(260))
        }
        if scene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scene = "LFM returned no usable scene summary."
            uncertainty = "empty_lfm_response"
            confidence = 0.0
        }

        return LiveVisionContext(
            source: "meta_dat",
            visionModel: LocalLFMBenchmarkVariant.lfm450m.modelName,
            promptMode: "live_json_1fps",
            frameID: frameID,
            timestampMS: nowMilliseconds(),
            latencyMS: latencyMS,
            summary: scene,
            visibleText: visibleText,
            uncertainty: uncertainty.isEmpty ? "none_reported" : uncertainty,
            confidence: max(0.0, min(confidence, 1.0))
        )
    }

    private func extractVisionStringArray(key: String, from responseText: String) -> [String] {
        guard let json = artemisJSONDictionary(from: responseText),
              let raw = json[key] else {
            return []
        }
        if let values = raw as? [String] {
            return values
        }
        if let values = raw as? [Any] {
            return values.compactMap { $0 as? String }
        }
        if let value = raw as? String, !value.isEmpty {
            return [value]
        }
        return []
    }

    private func isLowInformationVisionResponse(_ responseText: String) -> Bool {
        let normalized = responseText
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return normalized.contains("\"scene\":\"\"")
            && normalized.contains("\"objects\":[]")
            && normalized.contains("\"confidence\":0.0")
    }

    private func emitAgentCEvent(_ event: String, payload: [String: Any]) {
        ArtemisBenchmarkEventStore.append(event: event, payload: payload)
        ArtemisRemoteLogSink.sendEvent(event, payload: payload)
        if !isNoisyAgentCEvent(event) {
            addLog("agent_c_event \(event)")
        }
    }

    private func isNoisyAgentCEvent(_ event: String) -> Bool {
        switch event {
        case "voice_stt_audio_level",
             "display_hud_snapshot",
             "display_hud_coexistence_sample",
             "startup_greeting_skipped_inflight":
            return true
        default:
            return false
        }
    }

    private func emitVoiceBridgeEvent(_ event: String, payload: [String: Any]) {
        voiceEventSequence += 1
        var body = payload
        let visionFreshness = visionFreshnessVerdict(for: liveVisionContext)
        let datMetrics = latestDATFrameMetrics()
        func defaultValue(_ key: String, _ value: Any) {
            if body[key] == nil {
                body[key] = value
            }
        }
        defaultValue("turn_id", currentTurnID)
        defaultValue("seq", voiceEventSequence)
        defaultValue("voice_bridge_enabled", voiceBridgeEnabled)
        defaultValue("voice_bridge_status", voiceBridgeStatus)
        defaultValue("speech_input_status", speechInputStatus)
        defaultValue("speech_output_status", speechOutputStatus)
        defaultValue("turn_state", turnTaking.currentState.rawValue)
        defaultValue("is_listening", isListening)
        defaultValue("stt_source", "apple")
        defaultValue("turn_finalization_reason", hudSTTFinalizationReason)
        defaultValue("brain_impl", hudBrainImpl)
        defaultValue("brain_model", hudBrainModel)
        defaultValue("brain_runtime", hudBrainRuntime)
        defaultValue("vision_source", liveVisionContext.source)
        defaultValue("vision_model", liveVisionContext.visionModel)
        defaultValue("vision_prompt_mode", liveVisionContext.promptMode)
        defaultValue("vision_frame_id", liveVisionContext.frameID)
        defaultValue("vision_timestamp_ms", liveVisionContext.timestampMS)
        defaultValue("vision_age_ms", visionAgeMS(for: liveVisionContext))
        defaultValue("vision_freshness_state", visionFreshness.state.rawValue)
        defaultValue("vision_freshness_reason", visionFreshness.reason)
        defaultValue("vision_direct_claim_allowed", visionFreshness.supportsDirectVisualClaim)
        defaultValue("vision_stream_state", connectionState.rawValue)
        defaultValue("vision_latency_ms", liveVisionContext.latencyMS)
        defaultValue("dat_lifecycle_state", datLifecycleState(for: connectionState).rawValue)
        defaultValue("dat_stream_fps", streamFPS)
        defaultValue("dat_dropped_frames", datDroppedFrames)
        defaultValue("dat_device_unavailable_reason", datDeviceUnavailableReason)
        defaultValue("dat_frame_age_ms", datMetrics?.frameAgeMS ?? datFrameAgeMS)
        defaultValue("dat_ingest_latency_ms", datMetrics?.ingestLatencyMS ?? datIngestLatencyMS)
        defaultValue("dat_frame_fresh", datMetrics?.isFresh ?? false)
        defaultValue("tts_engine", SpeechOutputEngine.kokoroLocal.rawValue)
        defaultValue("first_response_ms", hudFirstResponseMS)
        defaultValue("end_to_end_ms", hudEndToEndMS)
        defaultValue("fallback_triggered", hudFallbackTriggered)
        defaultValue("fallback_reason", hudFallbackReason)
        defaultValue("thermal_state", thermalLabelForEvent(thermalState))
        defaultValue("battery", batteryLabel)
        defaultValue("phone_battery", batteryLabel)
        defaultValue("phone_power_mode", powerModeLabel)
        defaultValue("wearable_battery", wearableBatteryLabel)
        defaultValue("wearable_battery_source", "dat_error_only_no_percentage_api")
        defaultValue("wearable_thermal_level", wearableThermalLabel)
        defaultValue("wearable_power_mode", wearablePowerModeLabel.lowercased())
        defaultValue("wearable_power_reason", wearablePowerReason)
        defaultValue("wearable_camera_frame_rate_label", wearablePowerCameraFPS)
        defaultValue("wearable_hud_min_interval", wearablePowerHUDInterval)
        emitAgentCEvent(event, payload: body)
    }

    private func maybeQueueStartupGreeting(reason: String, previewImageAvailable: Bool, frameID: Int?) {
        guard !brainTurnInFlight, !audioOutputInFlight else {
            let skipKey = "\(reason)|\(currentTurnID)|\(brainTurnInFlight)|\(audioOutputInFlight)"
            let shouldReportSkip = skipKey != lastStartupGreetingSkipKey
                || lastStartupGreetingSkipLogAt.map { Date().timeIntervalSince($0) >= 2.0 } ?? true
            if shouldReportSkip {
                lastStartupGreetingSkipKey = skipKey
                lastStartupGreetingSkipLogAt = Date()
                addLog("Startup greeting queue skipped; live golden turn already active. reason=\(reason); turn_id=\(currentTurnID)")
                emitVoiceBridgeEvent("startup_greeting_skipped_inflight", payload: [
                    "startup_reason": reason,
                    "active_turn_id": currentTurnID,
                    "brain_turn_in_flight": brainTurnInFlight,
                    "audio_output_in_flight": audioOutputInFlight
                ])
            }
            return
        }
        let trigger = LiveStartupDecision.trigger(
            shouldSpeakStartupGreeting: shouldSpeakStartupGreeting,
            didSpeakStartupGreeting: didSpeakStartupGreeting,
            liveGoldenModeEnabled: liveGoldenModeEnabled,
            appLifecycleState: appLifecycleState,
            previewImageAvailable: previewImageAvailable
        )
        guard trigger != .wait else { return }
        guard prepareLiveGoldenDefaultAudioRoute(reason: reason) else { return }
        didSpeakStartupGreeting = true
        let fpsText = streamFPS > 0 ? String(format: "%.1f", streamFPS) : "live"
        if shouldStartVoiceBridgeAfterStartupGreeting, !voiceBridgeEnabled {
            didStartVoiceBridgeAfterStartupGreeting = true
            startVoiceBridge(armListeningImmediately: false)
        }
        voiceBridgeStatus = "Startup routing"
        let startupPrompt: String
        let startupFrameID: Int
        let visionState: String
        switch trigger {
        case .queueWithPreview:
            startupFrameID = frameID ?? latestPreviewFrameID
            visionState = sentinelEnabled ? "on" : "off"
            startupPrompt = "Start live session. frame=\(startupFrameID), fps=\(fpsText), vision=\(visionState). Greet and ask for first request."
            addLog("Startup state turn queued after frame \(startupFrameID); reason=\(reason).")
        case .queueWithoutVision:
            startupFrameID = latestPreviewFrameID
            visionState = "warming_up"
            startupPrompt = "Start live session. Vision is warming up and the first live frame is not ready yet. Greet me, say you are online, and ask what I want to test first."
            addLog("Startup state turn queued before first frame; reason=\(reason).")
        case .wait:
            return
        }
        emitVoiceBridgeEvent("startup_greeting_queued", payload: [
            "frame_id": startupFrameID,
            "stream_fps": streamFPS,
            "decoded_frame_images": decodedFrameImages,
            "latest_preview_frame_id": latestPreviewFrameID,
            "startup_prompt": startupPrompt,
            "startup_reason": reason,
            "startup_vision_state": visionState
        ])
        routeGoldenTurn(
            userPrompt: startupPrompt,
            finalizationReason: "startup_state",
            isStartup: true,
            allowVisionRefresh: trigger == .queueWithPreview
        )
    }

    private func maybeSpeakStartupGreeting(frame: WearableFrame) {
        maybeQueueStartupGreeting(
            reason: "first_preview_frame",
            previewImageAvailable: frame.previewImageAvailable,
            frameID: frame.id
        )
    }

    private func ensurePendingVoiceTurnID() -> String {
        if pendingVoiceTurnID.isEmpty {
            pendingVoiceTurnID = "turn-\(nowMilliseconds())"
        }
        return pendingVoiceTurnID
    }

    private func sttTurnFinalizationDecision(
        for text: String,
        metadata: SpeechTranscriptMetadata,
        isFinal: Bool,
        stablePartialCount: Int,
        silenceDurationMS: Int
    ) -> STTTurnFinalizationDecision {
        STTTurnFinalizationPolicy.decision(
            transcript: text,
            isFinal: isFinal,
            metadata: metadata.turnFinalizationMetadata,
            stablePartialCount: stablePartialCount,
            silenceDurationMS: silenceDurationMS,
            commandDelayNanoseconds: voiceAutoRouteCommandDelayNanoseconds,
            shortUtteranceDelayNanoseconds: voiceAutoRouteShortUtteranceDelayNanoseconds,
            readyUtteranceDelayNanoseconds: voiceAutoRouteReadyUtteranceDelayNanoseconds
        )
    }

    private func scheduleVoiceAutoRoute(for text: String, metadata: SpeechTranscriptMetadata) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard voiceBridgeEnabled, !trimmed.isEmpty else { return }
        guard trimmed != lastRoutedVoiceText else { return }
        guard turnTaking.currentState == .userSpeaking || turnTaking.currentState == .listening else { return }
        let turnID = ensurePendingVoiceTurnID()

        if trimmed == lastVoiceAutoRouteCandidateText {
            voiceAutoRouteStablePartialCount += 1
        } else {
            lastVoiceAutoRouteCandidateText = trimmed
            voiceAutoRouteStablePartialCount = 1
        }
        let stablePartialCount = voiceAutoRouteStablePartialCount
        voiceAutoRouteTask?.cancel()
        let wordCount = trimmed.split { $0.isWhitespace || $0.isNewline }.count
        let decision = sttTurnFinalizationDecision(
            for: trimmed,
            metadata: metadata,
            isFinal: false,
            stablePartialCount: stablePartialCount,
            silenceDurationMS: 0
        )
        guard decision.shouldRoute else {
            emitVoiceBridgeEvent("voice_turn_auto_finalize_blocked", payload: [
                "turn_id": turnID,
                "transcript": trimmed,
                "word_count": wordCount,
                "block_reason": decision.reason,
                "stt_stable_partial_count": stablePartialCount,
                "stt_silence_ms": 0,
                "stt_segment_count": metadata.segmentCount,
                "stt_confidence_mean": metadata.confidenceMean,
                "stt_confidence_min": metadata.confidenceMin,
                "stt_duration_s": metadata.durationSeconds,
                "stt_last_segment": metadata.lastSegmentText
            ])
            return
        }
        let delay = decision.delayNanoseconds
        voiceAutoRouteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                let current = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == trimmed, current != self.lastRoutedVoiceText else { return }
                let silenceDurationMS = Int(Date().timeIntervalSince(self.lastSTTTranscriptAt ?? Date()) * 1000)
                let finalStablePartialCount = max(self.voiceAutoRouteStablePartialCount, stablePartialCount)
                let finalDecision = self.sttTurnFinalizationDecision(
                    for: current,
                    metadata: self.lastSpeechTranscriptMetadata,
                    isFinal: false,
                    stablePartialCount: finalStablePartialCount,
                    silenceDurationMS: silenceDurationMS
                )
                guard finalDecision.shouldRoute else {
                    self.emitVoiceBridgeEvent("voice_turn_auto_finalize_blocked", payload: [
                        "turn_id": turnID,
                        "transcript": current,
                        "word_count": wordCount,
                        "block_reason": finalDecision.reason,
                        "stt_stable_partial_count": finalStablePartialCount,
                        "stt_silence_ms": silenceDurationMS,
                        "stt_segment_count": self.lastSpeechTranscriptMetadata.segmentCount,
                        "stt_confidence_mean": self.lastSpeechTranscriptMetadata.confidenceMean,
                        "stt_confidence_min": self.lastSpeechTranscriptMetadata.confidenceMin,
                        "stt_duration_s": self.lastSpeechTranscriptMetadata.durationSeconds,
                        "stt_last_segment": self.lastSpeechTranscriptMetadata.lastSegmentText
                    ])
                    return
                }
                self.emitVoiceBridgeEvent("voice_turn_auto_finalized", payload: [
                    "turn_id": turnID,
                    "transcript": current,
                    "delay_ms": Int(delay / 1_000_000),
                    "word_count": wordCount,
                    "gate_reason": finalDecision.reason,
                    "schedule_gate_reason": decision.reason,
                    "stt_stable_partial_count": finalStablePartialCount,
                    "stt_silence_ms": silenceDurationMS,
                    "stt_segment_count": self.lastSpeechTranscriptMetadata.segmentCount,
                    "stt_confidence_mean": self.lastSpeechTranscriptMetadata.confidenceMean,
                    "stt_confidence_min": self.lastSpeechTranscriptMetadata.confidenceMin,
                    "stt_duration_s": self.lastSpeechTranscriptMetadata.durationSeconds,
                    "stt_last_segment": self.lastSpeechTranscriptMetadata.lastSegmentText
                ])
                self.pendingTurnFinalizationReason = finalDecision.reason
                self.hudSTTFinalizationReason = finalDecision.reason
                self.turnTaking.onTranscript(current, isFinal: true)
            }
        }
    }

    private func cancelVoiceAutoRoute() {
        voiceAutoRouteTask?.cancel()
        voiceAutoRouteTask = nil
        lastVoiceAutoRouteCandidateText = ""
        voiceAutoRouteStablePartialCount = 0
    }

    private func thermalLabelForEvent(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    func recordWearablePowerCheckpoint() {
        let trimmed = wearableBatteryPercentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percent = Int(trimmed), (0...100).contains(percent) else {
            wearablePowerSampleStatus = "Enter the glasses battery as a whole number from 0 to 100."
            return
        }

        let decision = updateDeviceTelemetry(cameraRequested: isRunning)
        let runtime = wearable.powerRuntimeSnapshot()
        let sample = WearablePowerSample(
            id: UUID(),
            recordedAt: Date(),
            phase: wearablePowerTestPhase,
            batteryPercent: percent,
            batterySource: "meta_ai_manual_checkpoint",
            jarvisValidationRunning: isRunning,
            wearableConnectionState: connectionState.rawValue,
            wearableThermalLevel: wearableThermalLabel,
            wearablePowerMode: decision.mode.rawValue,
            phoneBattery: batteryLabel,
            phoneThermalState: thermalLabelForEvent(thermalState),
            runtime: runtime
        )
        wearablePowerSamples.append(sample)
        wearableBatteryLabel = "\(percent)% manual"
        wearableBatteryPercentInput = ""

        if let summary = WearablePowerTestMath.latestDrainSummary(samples: wearablePowerSamples) {
            wearablePowerDrainLabel = summary.label
        } else {
            wearablePowerDrainLabel = "Need another \(wearablePowerTestPhase.label) checkpoint after 1+ min"
        }

        do {
            let fileURL = try WearablePowerSampleLog.append(sample)
            wearablePowerSampleStatus = "Saved \(wearablePowerTestPhase.label) at \(percent)% (sample \(wearablePowerSamples.count))."
            addLog("Wearable power checkpoint saved: \(fileURL.lastPathComponent), phase=\(sample.phase.rawValue), battery=\(percent)%, session=\(runtime.sessionActive), camera=\(runtime.cameraActive), display=\(runtime.displayActive).")
        } catch {
            wearablePowerSampleStatus = "Checkpoint captured in memory; file write failed: \(error.localizedDescription)"
            addLog("Wearable power checkpoint file write failed: \(error.localizedDescription)")
        }

        emitVoiceBridgeEvent("wearable_power_checkpoint", payload: [
            "wearable_battery": "\(percent)%",
            "wearable_battery_percent": percent,
            "wearable_battery_source": sample.batterySource,
            "power_test_phase": sample.phase.rawValue,
            "power_test_sample_count": wearablePowerSamples.count,
            "dat_session_active": runtime.sessionActive,
            "camera_active": runtime.cameraActive,
            "display_active": runtime.displayActive,
            "display_state": runtime.displayState,
            "wearable_thermal_level": sample.wearableThermalLevel,
            "wearable_power_mode": sample.wearablePowerMode
        ])
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func rollingAverage(current: Int, next: Int, count: Int) -> Int {
        guard count > 1 else { return next }
        return Int((Double(current) * Double(count - 1) + Double(next)) / Double(count))
    }

    @discardableResult
    private func updateDeviceTelemetry(cameraRequested: Bool = false) -> WearablePowerDecision {
        thermalState = ProcessInfo.processInfo.thermalState
        powerModeLabel = ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power" : "Normal"

        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            batteryLabel = "\(Int(level * 100))%"
        } else {
            batteryLabel = "Unknown"
        }

        return applyWearablePowerPolicy(cameraRequested: cameraRequested)
    }

    @discardableResult
    private func applyWearablePowerPolicy(cameraRequested: Bool) -> WearablePowerDecision {
        let decision = WearablePowerPolicy.decision(
            phoneLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            phoneThermalState: thermalLabelForEvent(thermalState),
            wearableThermalLevel: wearableThermalLabel,
            latestPowerFault: latestWearablePowerFault,
            cameraRequested: cameraRequested
        )
        wearablePowerModeLabel = decision.mode.label
        wearablePowerReason = decision.reason
        wearablePowerCameraFPS = decision.cameraFrameRate > 0 ? "\(decision.cameraFrameRate) fps" : "off"
        wearablePowerHUDInterval = String(format: "%.0fs", decision.minimumHUDIntervalSeconds)
        wearable.configurePowerPolicy(
            cameraFrameRate: max(1, decision.cameraFrameRate),
            minimumDisplayHUDInterval: decision.minimumHUDIntervalSeconds
        )

        let fingerprint = [
            decision.mode.rawValue,
            decision.reason,
            wearableThermalLabel,
            latestWearablePowerFault,
            batteryLabel,
            powerModeLabel,
            wearablePowerCameraFPS,
            wearablePowerHUDInterval
        ].joined(separator: "|")
        if fingerprint != lastWearablePowerLogFingerprint {
            lastWearablePowerLogFingerprint = fingerprint
            addLog("Wearable power policy: mode=\(decision.mode.rawValue), reason=\(decision.reason), camera=\(wearablePowerCameraFPS), hud_interval=\(wearablePowerHUDInterval), wearable_thermal=\(wearableThermalLabel), wearable_battery=\(wearableBatteryLabel), phone_battery=\(batteryLabel), phone_power=\(powerModeLabel).")
            emitVoiceBridgeEvent("wearable_power_policy_changed", payload: wearablePowerPayload(decision: decision))
        }
        return decision
    }

    private func wearablePowerPayload(decision: WearablePowerDecision) -> [String: Any] {
        [
            "wearable_power_mode": decision.mode.rawValue,
            "wearable_power_reason": decision.reason,
            "wearable_camera_frame_rate": decision.cameraFrameRate,
            "wearable_hud_min_interval_s": decision.minimumHUDIntervalSeconds,
            "wearable_allows_camera_start": decision.allowsCameraStart,
            "wearable_thermal_level": wearableThermalLabel,
            "wearable_battery": wearableBatteryLabel,
            "wearable_battery_source": "dat_error_only_no_percentage_api",
            "wearable_latest_power_fault": latestWearablePowerFault,
            "phone_battery": batteryLabel,
            "phone_power_mode": powerModeLabel,
            "phone_thermal_state": thermalLabelForEvent(thermalState)
        ]
    }

    private func wearablePowerHUDLine() -> String {
        "Power \(wearablePowerModeLabel) / wear \(wearableThermalLabel) / phone \(batteryLabel)"
    }

    private func recordWearablePowerFault(_ event: WearablePowerRuntimeEvent) {
        latestWearablePowerFault = event.kind
        if event.kind == "battery_critical" {
            wearableBatteryLabel = "Critical"
        }
        let decision = applyWearablePowerPolicy(cameraRequested: isRunning)
        addLog("Wearable power event: kind=\(event.kind), source=\(event.source), mode=\(decision.mode.rawValue), description=\(event.description).")
        var payload = wearablePowerPayload(decision: decision)
        payload["wearable_power_fault_source"] = event.source
        payload["wearable_power_fault_description"] = event.description
        emitVoiceBridgeEvent("wearable_power_fault", payload: payload)

        guard decision.mode == .critical, isRunning else { return }
        addLog("Stopping DAT validation to protect glasses after critical wearable power event: \(event.kind).")
        emitVoiceBridgeEvent("wearable_power_auto_stop", payload: wearablePowerPayload(decision: decision))
        stopValidation()
    }

    private func updateWearableThermalSnapshot() {
        let labels = Array(wearableThermalLevels.values)
        wearableThermalLabel = highestWearableThermalLabel(labels)
        _ = applyWearablePowerPolicy(cameraRequested: isRunning)
    }

    private func highestWearableThermalLabel(_ labels: [String]) -> String {
        guard !labels.isEmpty else { return "unknown" }
        let order = [
            "unknown": 0,
            "none": 1,
            "light": 2,
            "moderate": 3,
            "severe": 4,
            "critical": 5,
            "emergency": 6,
            "shutdown": 7
        ]
        return labels.max { (left, right) in
            (order[left] ?? 0) < (order[right] ?? 0)
        } ?? "unknown"
    }

    private func wearableThermalLabelForEvent(_ level: ThermalLevel) -> String {
        switch level {
        case .unknown:
            return "unknown"
        case .none:
            return "none"
        case .light:
            return "light"
        case .moderate:
            return "moderate"
        case .severe:
            return "severe"
        case .critical:
            return "critical"
        case .emergency:
            return "emergency"
        case .shutdown:
            return "shutdown"
        @unknown default:
            return "unknown"
        }
    }

    private func localModelsDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let models = documents.appendingPathComponent("Models", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: models.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try FileManager.default.removeItem(at: models)
        }
        if !FileManager.default.fileExists(atPath: models.path, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        }
        return models
    }

    private func localBenchmarkVideosDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let videos = documents.appendingPathComponent("BenchmarkVideos", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: videos.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try FileManager.default.removeItem(at: videos)
        }
        if !FileManager.default.fileExists(atPath: videos.path, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        }
        return videos
    }

    private func formattedFileSize(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func observeWearablesRegistration() {
        registrationTask?.cancel()
        let initialState = Wearables.shared.registrationState
        registrationStateLabel = String(describing: initialState)
        isDATRegistered = initialState == .registered
        registrationTask = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                await MainActor.run {
                    self?.registrationStateLabel = String(describing: state)
                    self?.isDATRegistered = state == .registered
                    self?.addLog("DAT registration state: \(String(describing: state))")
                }
            }
        }
    }

    private func observeWearablesDevices() {
        deviceTask?.cancel()
        deviceTask = Task { [weak self] in
            for await deviceIds in Wearables.shared.devicesStream() {
                await MainActor.run {
                    self?.updateDeviceDiagnostics(deviceIds: deviceIds)
                }
            }
        }
        updateDeviceDiagnostics(deviceIds: Wearables.shared.devices)
    }

    private func updateDeviceDiagnostics(deviceIds: [DeviceIdentifier]) {
        let deviceSet = Set(deviceIds)
        compatibilityTokens = compatibilityTokens.filter { deviceSet.contains($0.key) }
        linkStateTokens = linkStateTokens.filter { deviceSet.contains($0.key) }
        let removedDeviceStateTasks = deviceStateTasks.keys.filter { !deviceSet.contains($0) }
        for deviceId in removedDeviceStateTasks {
            deviceStateTasks[deviceId]?.cancel()
            deviceStateTasks[deviceId] = nil
            wearableThermalLevels[deviceId] = nil
        }
        updateWearableThermalSnapshot()

        deviceDiagnostics = deviceIds.map { deviceId in
            guard let device = Wearables.shared.deviceForIdentifier(deviceId) else {
                return "\(String(describing: deviceId)): missing metadata"
            }

            if compatibilityTokens[deviceId] == nil {
                compatibilityTokens[deviceId] = device.addCompatibilityListener { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateDeviceDiagnostics(deviceIds: Wearables.shared.devices)
                    }
                }
            }

            if linkStateTokens[deviceId] == nil {
                linkStateTokens[deviceId] = device.addLinkStateListener { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateDeviceDiagnostics(deviceIds: Wearables.shared.devices)
                    }
                }
            }

            if deviceStateTasks[deviceId] == nil {
                deviceStateTasks[deviceId] = Task { [weak self] in
                    for await state in Wearables.shared.deviceStateStream(for: deviceId) {
                        await MainActor.run {
                            guard let self else { return }
                            let thermal = self.wearableThermalLabelForEvent(state.thermalLevel)
                            self.wearableThermalLevels[deviceId] = thermal
                            self.updateWearableThermalSnapshot()
                            self.addLog("DAT device state: \(device.nameOrId()) | wearable_thermal=\(thermal)")
                        }
                    }
                }
            }

            let compatibility = device.compatibility()
            let linkState = device.linkState
            let supportsDisplay = device.supportsDisplay()
            let deviceType = device.deviceType()
            let eligible = linkState == .connected && compatibility == .compatible
            let action: String
            switch compatibility {
            case .deviceUpdateRequired:
                action = "action=Firmware update"
            case .sdkUpdateRequired:
                action = "action=Update DAT SDK"
            case .undefined:
                action = linkState == .connected ? "action=Wait/reopen Meta AI; compat undefined" : "action=Open Meta AI until link connected"
            case .compatible:
                action = eligible ? "action=Eligible" : "action=Wait for link connected"
            @unknown default:
                action = "action=Unknown compatibility"
            }

            return [
                device.nameOrId(),
                deviceType.rawValue,
                "link=\(String(describing: linkState))",
                "compat=\(String(describing: compatibility))",
                "display=\(supportsDisplay)",
                "typeDisplay=\(deviceType.supportsDisplay)",
                "wearable_thermal=\(wearableThermalLevels[deviceId] ?? "unknown")",
                "wearable_battery=unavailable",
                "eligible=\(eligible)",
                action
            ].joined(separator: " | ")
        }

        if deviceDiagnostics.isEmpty {
            deviceDiagnostics = ["No DAT devices visible to Artemis yet."]
            datDeviceActionHint = "Open Meta AI, confirm glasses are paired/connected, then return to Artemis."
            wearableThermalLabel = "unknown"
        } else if deviceDiagnostics.contains(where: { $0.contains("eligible=true") }) {
            datDeviceActionHint = "DAT device eligible. Start should reach session/camera/display attach."
        } else if deviceDiagnostics.contains(where: { $0.contains("Firmware update") }) {
            datDeviceActionHint = "Firmware update required. Tap Firmware before retrying."
        } else if deviceDiagnostics.contains(where: { $0.contains("Update DAT SDK") }) {
            datDeviceActionHint = "SDK update required. Update meta-wearables-dat-ios before retrying."
        } else if deviceDiagnostics.contains(where: { $0.contains("link=connecting") || $0.contains("compat=undefined") }) {
            datDeviceActionHint = "Meta AI sees the glasses but DAT is not eligible yet. Keep Meta AI open until connected/compatible, then retry."
        } else {
            datDeviceActionHint = "DAT device visible but not eligible. Check Meta AI connection, registration, and update buttons."
        }

        let fingerprint = "\(datDeviceActionHint) || \(deviceDiagnostics.joined(separator: " || "))"
        if fingerprint != lastDeviceDiagnosticsFingerprint {
            lastDeviceDiagnosticsFingerprint = fingerprint
            addLog("DAT eligibility: \(datDeviceActionHint)")
            addLog("DAT devices: \(deviceDiagnostics.joined(separator: " || "))")
        }
    }

    private func addLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        let line = "[\(formatter.string(from: .now))] \(message)"
        NSLog("[Artemis] %@", line)
        ArtemisRemoteLogSink.send(line)
        ArtemisBenchmarkEventStore.append(event: "app_log", payload: [
            "message": line
        ])
        logs.insert(line, at: 0)
        if logs.count > 80 {
            logs.removeLast(logs.count - 80)
        }
    }
}

extension ArtemisSessionModel: AppleSpeechInputDelegate {
    func speechInputDidUpdateTranscript(_ transcript: String, isFinal: Bool, metadata: SpeechTranscriptMetadata) {
        self.transcript = transcript
        self.lastSpeechTranscriptMetadata = metadata
        self.speechInputStatus = isFinal ? "Final transcript" : "Listening"
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lastSTTTranscriptAt = Date()
            didReportQuietInputForCurrentListen = false
            didReportNoTranscriptForCurrentListen = false
        }
        hudSTTText = trimmed
        hudSTTFinalizationReason = isFinal ? "final" : "partial"
        pushDisplayHUD(reason: isFinal ? "stt_final" : "stt_partial")
        if voiceBridgeEnabled {
            let turnID = ensurePendingVoiceTurnID()
            if isFinal {
                pendingTurnFinalizationReason = "final"
            }
            turnTaking.onTranscript(transcript, isFinal: isFinal)
            emitVoiceBridgeEvent(isFinal ? "voice_stt_final" : "voice_stt_partial", payload: [
                "turn_id": turnID,
                "transcript": trimmed,
                "char_count": trimmed.count,
                "stt_segment_count": metadata.segmentCount,
                "stt_confidence_mean": metadata.confidenceMean,
                "stt_confidence_min": metadata.confidenceMin,
                "stt_duration_s": metadata.durationSeconds,
                "stt_last_segment": metadata.lastSegmentText
            ])
            if isFinal {
                cancelVoiceAutoRoute()
            } else {
                scheduleVoiceAutoRoute(for: trimmed, metadata: metadata)
            }
        }
        if isFinal {
            addLog("Final transcript: \(transcript)")
        }
    }

    func speechInputDidObserveAudioLevel(rms: Float, peak: Float) {
        guard voiceBridgeEnabled else { return }
        currentListenMaxPeak = max(currentListenMaxPeak, peak)
        updateTurnTakingVADFromAudioLevel(peak: peak)
        let shouldEmitLevelEvent = lastVoiceAudioLevelEventAt.map { Date().timeIntervalSince($0) >= 1.5 } ?? true
        let shouldEmitPeakEvent = peak >= 0.12
        if shouldEmitLevelEvent || shouldEmitPeakEvent {
            lastVoiceAudioLevelEventAt = Date()
            emitVoiceBridgeEvent("voice_stt_audio_level", payload: [
                "turn_id": pendingVoiceTurnID,
                "rms": Double(rms),
                "peak": Double(peak),
                "window_max_peak": Double(currentListenMaxPeak),
                "audio_runtime": audioRuntimeStateSummary()
            ])
        }

        guard (liveGoldenModeEnabled || sttCalibrationModeEnabled),
              isListening,
              !didReportQuietInputForCurrentListen,
              let startedAt = currentListenStartedAt else {
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let hasTranscriptThisListen = lastSTTTranscriptAt.map { $0 >= startedAt } ?? false
        guard elapsed >= liveGoldenQuietInputWindowSeconds,
              !hasTranscriptThisListen,
              currentListenMaxPeak < liveGoldenQuietInputPeakThreshold else {
            if elapsed >= liveGoldenNoTranscriptWindowSeconds,
               !hasTranscriptThisListen,
               !didReportNoTranscriptForCurrentListen {
                didReportNoTranscriptForCurrentListen = true
                speechInputStatus = "No transcript"
                hudState = "listening_no_transcript"
                pushDisplayHUD(reason: "stt_no_transcript_timeout")
                let reason = "Mic tap has audio but SFSpeech produced no partial after \(String(format: "%.1f", elapsed))s."
                addLog("STT no transcript timeout: \(reason) max_peak=\(String(format: "%.4f", currentListenMaxPeak)) audio=\(audioRuntimeStateSummary())")
                emitVoiceBridgeEvent("voice_stt_no_transcript_timeout", payload: [
                    "turn_id": pendingVoiceTurnID,
                    "elapsed_s": elapsed,
                    "max_peak": Double(currentListenMaxPeak),
                    "quiet_threshold_peak": Double(liveGoldenQuietInputPeakThreshold),
                    "audio_runtime": audioRuntimeStateSummary(),
                    "reason": reason
                ])
            }
            return
        }

        didReportQuietInputForCurrentListen = true
        speechInputStatus = "Input too quiet"
        hudState = "listening_quiet_input"
        pushDisplayHUD(reason: "stt_input_too_quiet")
        let reason = "Mic tap is alive but peak stayed below \(String(format: "%.3f", liveGoldenQuietInputPeakThreshold)) for \(String(format: "%.1f", elapsed))s; active route may be wrong or too far."
        addLog("STT input too quiet: \(reason) audio=\(audioRuntimeStateSummary())")
        emitVoiceBridgeEvent("voice_stt_input_too_quiet", payload: [
            "turn_id": pendingVoiceTurnID,
            "elapsed_s": elapsed,
            "max_peak": Double(currentListenMaxPeak),
            "threshold_peak": Double(liveGoldenQuietInputPeakThreshold),
            "audio_runtime": audioRuntimeStateSummary(),
            "reason": reason
        ])
    }

    private func updateTurnTakingVADFromAudioLevel(peak: Float) {
        guard isListening else { return }
        let now = Date()
        if peak >= liveGoldenVADSpeechPeakThreshold {
            lastVADSpeechAt = now
            guard !vadSpeechActive else { return }
            vadSpeechActive = true
            turnTaking.onSpeechStart()
            emitVoiceBridgeEvent("voice_vad_speech_start", payload: [
                "turn_id": pendingVoiceTurnID,
                "peak": Double(peak),
                "threshold_peak": Double(liveGoldenVADSpeechPeakThreshold),
                "audio_runtime": audioRuntimeStateSummary()
            ])
            return
        }

        guard vadSpeechActive,
              let lastVADSpeechAt,
              now.timeIntervalSince(lastVADSpeechAt) >= liveGoldenVADReleaseSeconds else {
            return
        }
        vadSpeechActive = false
        turnTaking.onSpeechEnd()
        emitVoiceBridgeEvent("voice_vad_speech_end", payload: [
            "turn_id": pendingVoiceTurnID,
            "peak": Double(peak),
            "threshold_peak": Double(liveGoldenVADSpeechPeakThreshold),
            "release_s": liveGoldenVADReleaseSeconds,
            "audio_runtime": audioRuntimeStateSummary()
        ])
    }

    func speechInputDidFail(_ error: Error) {
        if isStoppingSpeechInput || isBenignStoppedSpeechError(error) {
            addLog("Ignored stopped STT callback: \(error.localizedDescription)")
            return
        }
        isListening = false
        speechInputStatus = "Failed"
        cancelVoiceAutoRoute()
        if voiceBridgeEnabled {
            emitVoiceBridgeEvent("voice_stt_failed", payload: [
                "turn_id": pendingVoiceTurnID,
                "error": describeSpeechRuntimeError(error),
                "audio_runtime": audioRuntimeStateSummary()
            ])
        }
        addLog("STT error: \(describeSpeechRuntimeError(error)); audio=\(audioRuntimeStateSummary())")
    }

    private func isBenignStoppedSpeechError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return !isListening && (
            message.contains("no speech detected")
            || message.contains("canceled")
            || message.contains("cancelled")
        )
    }
}

@MainActor
protocol AppleSpeechInputDelegate: AnyObject {
    func speechInputDidUpdateTranscript(_ transcript: String, isFinal: Bool, metadata: SpeechTranscriptMetadata)
    func speechInputDidObserveAudioLevel(rms: Float, peak: Float)
    func speechInputDidFail(_ error: Error)
}

extension ArtemisSessionModel: SpeechOutputServiceDelegate {
    func speechOutputDidStart(text: String, engine: SpeechOutputEngine) {
        endLiveGoldenProcessingBackgroundTask(reason: "tts_started")
        audioOutputInFlight = true
        if engine == .kokoroLocal {
            pendingPrivateAudioRetryText = ""
        }
        speechOutputStatus = "Speaking (\(engine.rawValue))"
        hudState = "speaking"
        hudTTSText = text
        addLog("TTS started (\(engine.rawValue)): \(text)")
        pushDisplayHUD(reason: "tts_started")
        emitVoiceBridgeEvent("voice_tts_started", payload: [
            "turn_id": currentTurnID,
            "text": text,
            "engine": engine.rawValue,
            "barge_in_mode": "valid_non_echo_speech_interrupts"
        ])
        if voiceBridgeEnabled {
            turnTaking.onTTSStart(text: text)
            emitVoiceBridgeEvent("voice_barge_in_armed_for_tts", payload: [
                "action": "start_stt_after_tts_route_preflight",
                "barge_in_mode": "valid_non_echo_speech_interrupts",
                "tts_chars": text.count,
                "audio_runtime": audioRuntimeStateSummary()
            ])
            if !isListening, !isSpeechInputStartInFlight {
                startListening()
            }
        }
    }

    func speechOutputDidGenerate(text: String, engine: SpeechOutputEngine, stats: KokoroSpeechPlaybackStats) {
        hudTTSVoice = stats.voiceName
        hudTTSGenerationMS = stats.generationMilliseconds
        pushDisplayHUD(reason: "tts_generated")
        emitVoiceBridgeEvent("voice_tts_generated", payload: [
            "turn_id": currentTurnID,
            "text": text,
            "engine": engine.rawValue,
            "voice": stats.voiceName,
            "generation_ms": stats.generationMilliseconds,
            "audio_s": stats.audioDurationSeconds,
            "rtf": stats.realTimeFactor,
            "raw_peak_sample": stats.rawPeakSample,
            "normalization_gain": stats.normalizationGain,
            "peak_sample": stats.peakSample,
            "clipped_samples": stats.clippedSampleCount,
            "audio_route": stats.audioRoute,
            "session_sample_rate": stats.sessionSampleRate,
            "output_latency_s": stats.outputLatencySeconds,
            "sample_mode": stats.sampleMode,
            "diagnostic_wav": stats.diagnosticWavPath ?? ""
        ])
    }

    func speechOutputDidFinish(text: String, engine: SpeechOutputEngine) {
        audioOutputInFlight = false
        speechOutputStatus = "Idle"
        hudState = voiceBridgeEnabled ? "listening" : "idle"
        addLog("TTS finished (\(engine.rawValue)): \(text)")
        pushDisplayHUD(reason: "tts_finished")
        emitVoiceBridgeEvent("voice_tts_finished", payload: [
            "turn_id": currentTurnID,
            "text": text,
            "engine": engine.rawValue
        ])
        if shouldStartVoiceBridgeAfterStartupGreeting,
           didSpeakStartupGreeting,
           !didStartVoiceBridgeAfterStartupGreeting,
           !voiceBridgeEnabled {
            didStartVoiceBridgeAfterStartupGreeting = true
            addLog("Starting Voice Bridge after startup greeting.")
            emitVoiceBridgeEvent("startup_voice_bridge_starting", payload: [:])
            startVoiceBridge()
        }
        if voiceBridgeEnabled {
            turnTaking.onTTSEnd()
            if liveGoldenModeEnabled {
                restartListeningAfterSpeechOutput(reason: "tts_finished")
            } else {
                startListening()
            }
        }
        drainPendingLiveSentinelIfNeeded()
    }

    func speechOutputDidFail(text: String, engine: SpeechOutputEngine, error: Error) {
        endLiveGoldenProcessingBackgroundTask(reason: "tts_failed")
        audioOutputInFlight = false
        speechOutputStatus = "Failed (\(engine.rawValue))"
        hudState = "blocked"
        hudFallbackTriggered = true
        hudFallbackReason = error.localizedDescription
        let detailedError = describeSpeechRuntimeError(error)
        addLog("TTS failed (\(engine.rawValue)): \(detailedError); audio=\(audioRuntimeStateSummary())")
        pushDisplayHUD(reason: "tts_failed")
        emitVoiceBridgeEvent("voice_tts_failed", payload: [
            "turn_id": currentTurnID,
            "text": text,
            "engine": engine.rawValue,
            "error": detailedError,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        if voiceBridgeEnabled {
            turnTaking.onTTSEnd()
            voiceBridgeStatus = "TTS failed"
            if shouldResumeListeningAfterSpeechOutputFailure(error) {
                startListening()
            } else {
                pendingPrivateAudioRetryText = text
                emitVoiceBridgeEvent("voice_stt_blocked_after_tts_failure", payload: [
                    "turn_id": currentTurnID,
                    "reason": detailedError,
                    "audio_runtime": audioRuntimeStateSummary()
                ])
            }
        }
        drainPendingLiveSentinelIfNeeded()
    }

    private func shouldResumeListeningAfterSpeechOutputFailure(_ error: Error) -> Bool {
        if case KokoroSpeechOutputError.audioRouteNotAllowed = error {
            return false
        }
        return true
    }
}

extension ArtemisSessionModel: TurnTakingDelegate {
    func turnTakingDidChangeState(from: TurnState, to: TurnState) {
        turnTakingStateLabel = to.rawValue
        voiceBridgeStatus = to.rawValue
        hudState = to.rawValue.lowercased()
        pushDisplayHUD(reason: "turn_state_changed")
        emitVoiceBridgeEvent("voice_turn_state_changed", payload: [
            "from": from.rawValue,
            "to": to.rawValue
        ])
    }

    func turnTakingDidDetectBargeIn(transcribedText: String) {
        cancelVoiceAutoRoute()
        transcript = transcribedText
        voiceDraft = transcribedText
        voiceBridgeStatus = "Barge-in detected"
        hudState = "interrupted"
        hudSTTText = transcribedText
        pushDisplayHUD(reason: "barge_in_detected")
        emitVoiceBridgeEvent("voice_barge_in_detected", payload: [
            "turn_id": ensurePendingVoiceTurnID(),
            "transcript": transcribedText
        ])
        addLog("Turn-taking barge-in detected: \(transcribedText)")
    }

    func turnTakingDidCompleteTurn(userText: String) {
        cancelVoiceAutoRoute()
        lastRoutedVoiceText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnID = ensurePendingVoiceTurnID()
        if sttCalibrationModeEnabled {
            stopListening()
            sttCalibrationModeEnabled = false
            voiceBridgeStatus = "STT calibration captured"
            hudState = "stt_calibration_done"
            pushDisplayHUD(reason: "stt_calibration_completed")
            emitVoiceBridgeEvent("stt_calibration_turn_completed", payload: [
                "turn_id": turnID,
                "transcript": lastRoutedVoiceText,
                "audio_runtime": audioRuntimeStateSummary()
            ])
            addLog("STT calibration captured transcript: \(lastRoutedVoiceText)")
            turnTaking.endConversation()
            pendingVoiceTurnID = ""
            return
        }
        emitVoiceBridgeEvent("voice_turn_completed_stt_continues", payload: [
            "turn_id": turnID,
            "was_listening": isListening,
            "was_starting": isSpeechInputStartInFlight,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        if !isListening, !isSpeechInputStartInFlight {
            startListening()
        }
        voiceBridgeStatus = "Routing transcript"
        hudState = "thinking"
        pushDisplayHUD(reason: "turn_completed")
        emitVoiceBridgeEvent("voice_turn_completed", payload: [
            "turn_id": turnID,
            "transcript": lastRoutedVoiceText
        ])
        askBrain(userText, turnID: turnID)
        pendingVoiceTurnID = ""
    }

    func turnTakingDidTimeoutProcessing(afterMilliseconds milliseconds: Double) {
        voiceBridgeStatus = "Brain slow"
        hudState = "thinking_slow"
        pushDisplayHUD(reason: "brain_processing_slow")
        emitVoiceBridgeEvent("voice_processing_slow", payload: [
            "turn_id": currentTurnID,
            "threshold_ms": Int(milliseconds),
            "brain_turn_in_flight": brainTurnInFlight,
            "audio_output_in_flight": audioOutputInFlight,
            "audio_runtime": audioRuntimeStateSummary()
        ])
        addLog("Turn-taking brain processing slow after \(Int(milliseconds))ms; preserving processing state.")
    }

    func turnTakingShouldStartListening() {
        startListening()
    }

    func turnTakingShouldStopTTS() {
        speechOutput.stop()
        speechOutputStatus = "Interrupted"
        hudState = "interrupted"
        EchoDetector.shared.ttsDidEnd()
        emitVoiceBridgeEvent("voice_tts_interrupted", payload: [
            "turn_id": currentTurnID,
            "transcript": transcript
        ])
    }
}

enum SpeechInputRouteMode: String {
    case measurement
    case duplexA2DP = "duplex_a2dp"
    case bluetoothHFP = "bluetooth_hfp"
}

final class AppleSpeechInput {
    weak var delegate: AppleSpeechInputDelegate?
    var requiredAudioRoutePolicy: ArtemisAudioRoutePolicy?
    var useDuplexVoiceRoute = false
    var forcedRouteMode: SpeechInputRouteMode?
    var requiresOnDeviceRecognition: Bool?

    private var audioEngine: AVAudioEngine?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var isStarting = false
    private var lastAudioLevelReport = Date.distantPast

    func start() async throws {
        guard !isStarting else {
            throw SpeechInputError.alreadyStarting
        }
        isStarting = true
        defer { isStarting = false }

        let status = await requestSpeechAuthorization()
        guard status == .authorized else {
            throw SpeechInputError.notAuthorized
        }

        guard let recognizer else {
            throw SpeechInputError.recognizerUnavailable
        }

        stop()

        let session = AVAudioSession.sharedInstance()
        if requiredAudioRoutePolicy == .metaGlassesOnly {
            do {
                _ = try ArtemisAudioRoutePolicy.activateMetaGlassesDuplexSession(resetActiveSession: true)
            } catch let error as ArtemisAudioRouteActivationError {
                throw SpeechInputError.privateAudioRouteNotAllowed(error.localizedDescription)
            }
        } else if (forcedRouteMode ?? (useDuplexVoiceRoute ? .duplexA2DP : .measurement)) == .bluetoothHFP {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .mixWithOthers])
            try session.setActive(true)
            if let bluetoothInput = session.availableInputs?.first(where: { input in
                input.portType == .bluetoothHFP || input.portType == .bluetoothLE
            }) {
                try? session.setPreferredInput(bluetoothInput)
            }
        } else if (forcedRouteMode ?? (useDuplexVoiceRoute ? .duplexA2DP : .measurement)) == .duplexA2DP {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)
            if !Self.currentRouteHasBluetoothOutput(session) {
                try? session.overrideOutputAudioPort(.speaker)
            }
        } else {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition ?? recognizer.supportsOnDeviceRecognition
        recognitionRequest = request

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechInputError.invalidInputFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.reportAudioLevelIfNeeded(buffer)
            self?.recognitionRequest?.append(buffer)
        }
        tapInstalled = true
        audioEngine = engine

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let metadata = SpeechTranscriptMetadata(transcription: result.bestTranscription)
                Task { @MainActor in
                    self?.delegate?.speechInputDidUpdateTranscript(
                        result.bestTranscription.formattedString,
                        isFinal: result.isFinal,
                        metadata: metadata
                    )
                }
            }

            if let error {
                Task { @MainActor in
                    self?.delegate?.speechInputDidFail(error)
                }
            }
        }
    }

    func stop() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.reset()
        }
        audioEngine = nil
    }

    private func reportAudioLevelIfNeeded(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastAudioLevelReport) >= 0.75 else { return }
        lastAudioLevelReport = now
        guard let channelData = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sumSquares: Float = 0
        var peak: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        Task { @MainActor [weak self] in
            self?.delegate?.speechInputDidObserveAudioLevel(rms: rms, peak: peak)
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func currentRouteHasBluetoothOutput(_ session: AVAudioSession) -> Bool {
        session.currentRoute.outputs.contains { output in
            output.portType == .bluetoothA2DP
                || output.portType == .bluetoothHFP
                || output.portType == .bluetoothLE
        }
    }
}

enum SpeechInputError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case alreadyStarting
    case invalidInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount)
    case privateAudioRouteNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Speech recognition is not authorized."
        case .recognizerUnavailable:
            "Speech recognizer is unavailable for this locale."
        case .alreadyStarting:
            "Speech recognizer is already starting."
        case let .invalidInputFormat(sampleRate, channelCount):
            "Speech input format unavailable: sampleRate=\(sampleRate), channelCount=\(channelCount)."
        case let .privateAudioRouteNotAllowed(reason):
            reason
        }
    }
}

@MainActor
final class SpeechOutputService: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    weak var delegate: SpeechOutputServiceDelegate?
    private let synthesizer = AVSpeechSynthesizer()
    private var kokoro: KokoroSpeechOutput?
    private var activeEngine: SpeechOutputEngine = .kokoroLocal
    private var activeText = ""
    private var activeSpeechID = UUID()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func forceKokoroBuiltInSpeakerForDiagnostics() {
        kokoroOutput().setRouteMode(.builtInSpeakerDiagnostic)
    }

    func useSystemDefaultRoute() {
        kokoroOutput().setRouteMode(.systemDefault)
    }

    func enableDuplexBargeInRoute() {
        kokoroOutput().setRouteMode(.duplexBargeIn)
    }

    func enablePrivateGlassesDuplexRoute() {
        kokoroOutput().setRouteMode(.privateGlassesDuplex)
    }

    func speak(_ text: String, engine: SpeechOutputEngine) {
        let speechID = UUID()
        activeSpeechID = speechID
        activeEngine = engine
        activeText = text

        switch engine {
        case .kokoroLocal:
            let kokoro = kokoroOutput()
            #if os(iOS)
            do {
                let route = try kokoro.prepareAudioSessionForPlayback()
                print("[SpeechOutputService] Kokoro route preflight OK: \(route)")
            } catch {
                print("[SpeechOutputService] Kokoro route preflight failed: \(error.localizedDescription)")
                delegate?.speechOutputDidFail(text: text, engine: engine, error: error)
                return
            }
            #endif
            guard kokoro.isAvailable else {
                delegate?.speechOutputDidFail(
                    text: text,
                    engine: engine,
                    error: KokoroSpeechOutputError.missingModel
                )
                return
            }
            let chunks = ArtemisTTSChunker.chunks(for: text)
            guard !chunks.isEmpty else {
                delegate?.speechOutputDidFail(
                    text: text,
                    engine: engine,
                    error: KokoroSpeechOutputError.emptyAudio
                )
                return
            }
            delegate?.speechOutputDidStart(text: text, engine: engine)
            print(
                "[SpeechOutputService] Kokoro BYOB-style chunk queue: chunks=\(chunks.count) text_chars=\(text.count)"
            )
            kokoro.speakQueued(
                chunks,
                onChunkGenerated: { [weak self] index, total, chunk, stats in
                    guard let self, self.activeSpeechID == speechID else { return }
                    print(
                        "[KokoroSpeechOutput] chunk=\(index + 1)/\(total) voice=\(stats.voiceName) generation_ms=\(stats.generationMilliseconds) audio_s=\(String(format: "%.2f", stats.audioDurationSeconds)) rtf=\(String(format: "%.2f", stats.realTimeFactor)) raw_peak=\(String(format: "%.3f", stats.rawPeakSample)) gain=\(String(format: "%.3f", stats.normalizationGain)) peak=\(String(format: "%.3f", stats.peakSample)) clipped=\(stats.clippedSampleCount) mode=\(stats.sampleMode) wav=\(stats.diagnosticWavPath ?? "") route=\(stats.audioRoute) session_hz=\(String(format: "%.0f", stats.sessionSampleRate)) latency=\(String(format: "%.3f", stats.outputLatencySeconds))"
                    )
                    self.delegate?.speechOutputDidGenerate(text: chunk, engine: engine, stats: stats)
                },
                completion: { [weak self] result in
                    guard let self, self.activeSpeechID == speechID else { return }
                    switch result {
                    case .success:
                        self.delegate?.speechOutputDidFinish(text: text, engine: engine)
                    case let .failure(error):
                        self.delegate?.speechOutputDidFail(text: text, engine: engine, error: error)
                    }
                }
            )
        case .apple:
            speakWithApple(text)
        case .supertonicLocal:
            delegate?.speechOutputDidFail(
                text: text,
                engine: engine,
                error: KokoroSpeechOutputError.missingVoice("Supertonic is not wired")
            )
        }
    }

    func stop() {
        activeSpeechID = UUID()
        kokoro?.stop()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func kokoroOutput() -> KokoroSpeechOutput {
        if let kokoro {
            return kokoro
        }
        let output = KokoroSpeechOutput()
        kokoro = output
        return output
    }

    func probeKokoroGeneration(
        _ text: String,
        completion: @escaping @MainActor (Result<KokoroSpeechPlaybackStats, Error>) -> Void
    ) {
        let kokoro = kokoroOutput()
        guard kokoro.isAvailable else {
            completion(.failure(KokoroSpeechOutputError.missingModel))
            return
        }
        kokoro.generateOnly(text, completion: completion)
    }

    private func speakWithApple(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        activeText = utterance.speechString
        delegate?.speechOutputDidStart(text: utterance.speechString, engine: activeEngine)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        delegate?.speechOutputDidFinish(text: utterance.speechString, engine: activeEngine)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        delegate?.speechOutputDidFinish(text: utterance.speechString, engine: activeEngine)
    }
}

struct WearableFrame: Sendable {
    let id: Int
    let timestamp: Date
    let previewImageAvailable: Bool
}

struct WearablePowerRuntimeEvent: Sendable {
    let kind: String
    let source: String
    let description: String
}

struct DisplayHUDSnapshot: Sendable {
    let mode: String
    let streamState: String
    let framesReceived: Int
    let decodedFrameImages: Int
    let streamFPS: Double
    let sttText: String
    let sttFinalizationReason: String
    let assistantText: String
    let ttsText: String
    let ttsVoice: String
    let visionModel: String
    let visionFrameID: Int
    let visionLatencyMS: Int
    let visionSummary: String
    let latencyText: String
    let powerLine: String
    let stateText: String
    let updateReason: String
    let updatedAtMS: Int

    var streamLine: String {
        String(
            format: "%@ | %d/%d frames | %.1f fps",
            streamState,
            decodedFrameImages,
            framesReceived,
            streamFPS
        )
    }

    var visionLine: String {
        "Vision \(visionModel) f\(visionFrameID) \(visionLatencyMS)ms"
    }

    var elementContract: [String] {
        [
            "root:FlexBox(column,spacing:10,crossAlignment:stretch,padding:18,background:card)",
            "header:Icon(starCircleTriangleAi)+Text(Jarvis,heading)+Text(mode/state,meta,secondary)",
            "meta:Text(updateReason)+Text(streamLine)+Text(powerLine)",
            "card:YOU+sttFinalizationReason+sttText",
            "card:JARVIS+visionFrame/thinking+assistantText",
            "card:VOICE+ttsVoice+ttsText",
            "footer:visionLine+visionSummary+latencyText"
        ]
    }

    var eventPayload: [String: Any] {
        [
            "mode": mode,
            "stream_state": streamState,
            "frames_received": framesReceived,
            "decoded_frame_images": decodedFrameImages,
            "stream_fps": streamFPS,
            "stream_line": streamLine,
            "stt_text": sttText,
            "stt_finalization_reason": sttFinalizationReason,
            "assistant_text": assistantText,
            "tts_text": ttsText,
            "tts_voice": ttsVoice,
            "vision_model": visionModel,
            "vision_frame_id": visionFrameID,
            "vision_latency_ms": visionLatencyMS,
            "vision_summary": visionSummary,
            "vision_line": visionLine,
            "latency_text": latencyText,
            "power_line": powerLine,
            "state_text": stateText,
            "update_reason": updateReason,
            "updated_at_ms": updatedAtMS,
            "display_tree_contract": elementContract
        ]
    }
}

@MainActor
final class MetaDATWearableSession {
    private let defaultMaxAttempts = 5
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var display: MWDATDisplay.Display?
    private var frameToken: AnyListenerToken?
    private var stateToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var displayStateToken: AnyListenerToken?
    private var sessionErrorTask: Task<Void, Never>?
    private var diagnostics: ((String) -> Void)?
    private var frameID = 0
    private var displayHUDEnabled = false
    private var pendingDisplayHUDSnapshot: DisplayHUDSnapshot?
    private var displayHUDSending = false
    private var lastDisplayHUDSendAt: Date?
    private var minimumDisplayHUDInterval: TimeInterval = WearablePowerPolicy.normalHUDIntervalSeconds
    private var cameraFrameRate = WearablePowerPolicy.defaultCameraFrameRate
    private var persistentEligibilityRetryEnabled = false
    private var lastPermissionState = "not_checked"
    private var lastEligibleDevice = false
    private var lastEligibilitySummary = "not_checked"
    private var lastSessionState = "absent"
    private var lastStreamState = "absent"
    private var lastDisplayState = "absent"
    private var lastErrorDescription = "none"

    func diagnosticSnapshot() -> DATWearableDiagnosticSnapshot {
        DATWearableDiagnosticSnapshot(
            permissionState: lastPermissionState,
            eligibleDevice: lastEligibleDevice,
            eligibilitySummary: lastEligibilitySummary,
            sessionState: lastSessionState,
            streamState: lastStreamState,
            displayState: lastDisplayState,
            lastError: lastErrorDescription
        )
    }

    func configurePowerPolicy(cameraFrameRate: Int, minimumDisplayHUDInterval: TimeInterval) {
        let clampedFrameRate = min(max(cameraFrameRate, 1), 24)
        let clampedHUDInterval = max(minimumDisplayHUDInterval, 0.75)
        guard self.cameraFrameRate != clampedFrameRate
            || abs(self.minimumDisplayHUDInterval - clampedHUDInterval) > 0.01 else {
            return
        }
        self.cameraFrameRate = clampedFrameRate
        self.minimumDisplayHUDInterval = clampedHUDInterval
        emit("dat_power_policy camera_fps=\(clampedFrameRate) display_hud_min_interval_s=\(String(format: "%.2f", clampedHUDInterval))")
    }

    func configurePersistentEligibilityRetry(enabled: Bool) {
        persistentEligibilityRetryEnabled = enabled
        emit("dat_persistent_eligibility_retry enabled=\(enabled)")
    }

    func configureDisplayHUD(enabled: Bool) {
        displayHUDEnabled = enabled
        emit("display_hud_configured enabled=\(enabled)")
        if enabled, display?.state == .started, pendingDisplayHUDSnapshot != nil {
            scheduleDisplayHUDSend()
        }
    }

    func powerRuntimeSnapshot() -> WearablePowerRuntimeSnapshot {
        let displayState = display.map { String(describing: $0.state) } ?? "absent"
        return WearablePowerRuntimeSnapshot(
            sessionActive: deviceSession != nil,
            cameraActive: stream?.state == .streaming,
            displayActive: display?.state == .started,
            displayState: displayState
        )
    }

    func updateDisplayHUD(_ snapshot: DisplayHUDSnapshot) {
        pendingDisplayHUDSnapshot = snapshot
        guard displayHUDEnabled else { return }
        scheduleDisplayHUDSend()
    }

    func frames(
        onDiagnostic: @escaping (String) -> Void = { _ in },
        onPowerEvent: @escaping @MainActor (WearablePowerRuntimeEvent) -> Void = { _ in },
        onPreviewImage: @escaping @MainActor (UIImage?, Int) -> Void = { _, _ in }
    ) -> AsyncStream<WearableFrame> {
        AsyncStream { continuation in
            diagnostics = onDiagnostic
            let task = Task { @MainActor in
                await self.start(
                    continuation: continuation,
                    onPreviewImage: onPreviewImage,
                    onPowerEvent: onPowerEvent
                )
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in
                    self.stop()
                }
            }
        }
    }

    func stop() {
        let activeStream = stream
        let activeDisplay = display
        clearListeners()
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        stream = nil
        display = nil
        deviceSession?.stop()
        deviceSession = nil

        if let activeDisplay {
            activeDisplay.stop()
        }

        if let activeStream {
            activeStream.stop()
        }
    }

    private func start(
        continuation: AsyncStream<WearableFrame>.Continuation,
        onPreviewImage: @escaping @MainActor (UIImage?, Int) -> Void,
        onPowerEvent: @escaping @MainActor (WearablePowerRuntimeEvent) -> Void
    ) async {
        let maxAttempts = defaultMaxAttempts
        var attempt = 1
        lastPermissionState = "not_checked"
        lastEligibleDevice = false
        lastEligibilitySummary = "not_checked"
        lastSessionState = "absent"
        lastStreamState = "absent"
        lastDisplayState = "absent"
        lastErrorDescription = "none"

        while true {
            if Task.isCancelled {
                continuation.finish()
                return
            }

            do {
                if attempt > 1 {
                    emit("Retrying Meta DAT camera stream start, attempt \(attempt)/\(maxAttempts).")
                }

                let permission = Permission.camera
                await waitForConnectedCompatibleDevice(timeoutSeconds: attempt == 1 ? 18 : 6)
                emit("Checking Meta DAT camera permission.")
                var permissionStatus = try await Wearables.shared.checkPermissionStatus(permission)
                lastPermissionState = String(describing: permissionStatus)
                emit("Camera permission status: \(String(describing: permissionStatus))")
                if permissionStatus != .granted {
                    emit("Requesting Meta DAT camera permission.")
                    permissionStatus = try await Wearables.shared.requestPermission(permission)
                    lastPermissionState = String(describing: permissionStatus)
                    emit("Camera permission request result: \(String(describing: permissionStatus))")
                }
                guard permissionStatus == .granted else {
                    emit("Camera stream blocked because permission is not granted.")
                    continuation.finish()
                    return
                }

                let selector = try makeDeviceSelector()
                emit("Creating Meta DAT device session.")
                let session = try Wearables.shared.createSession(deviceSelector: selector)
                deviceSession = session

                let stateStream = session.stateStream()
                let errorStream = session.errorStream()
                emit("Starting Meta DAT device session.")
                try session.start()
                try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
                lastSessionState = String(describing: session.state)
                emit("Meta DAT device session started.")
                sessionErrorTask = observeSessionErrors(session, onPowerEvent: onPowerEvent)
                await attachDisplayHUDIfNeeded(to: session)

                let config = StreamConfiguration(
                    videoCodec: VideoCodec.raw,
                    resolution: StreamingResolution.low,
                    frameRate: UInt(cameraFrameRate)
                )

                emit("Adding low-resolution raw camera stream at \(cameraFrameRate)fps.")
                guard let newStream = try session.addStream(config: config) else {
                    emit("Meta DAT returned no camera stream.")
                    continuation.finish()
                    return
                }

                stream = newStream
                setupListeners(
                    for: newStream,
                    continuation: continuation,
                    onPreviewImage: onPreviewImage,
                    onPowerEvent: onPowerEvent
                )
                emit("Starting Meta DAT camera stream.")
                newStream.start()
                emit("Meta DAT camera stream start requested.")
                return
            } catch {
                if let event = wearablePowerRuntimeEvent(from: error, source: "camera_start") {
                    onPowerEvent(event)
                }
                clearListeners()
                sessionErrorTask?.cancel()
                sessionErrorTask = nil
                stream = nil
                deviceSession?.stop()
                deviceSession = nil
                display = nil

                let errorDescription = describeDATRuntimeError(error)
                lastErrorDescription = errorDescription
                switch retryDecisionForCameraStart(
                    errorDescription: errorDescription,
                    attempt: attempt,
                    maxAttempts: maxAttempts
                ) {
                case .retry(let afterSeconds):
                    emit("Camera stream start attempt \(attempt) failed, will retry: \(errorDescription)")
                    let clamped = max(afterSeconds, 0.25)
                    try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                    attempt += 1
                    continue
                case .fail:
                    emit("Camera stream start failed: \(errorDescription)")
                    continuation.finish()
                    return
                }
            }
        }
    }

    private func retryDecisionForCameraStart(
        errorDescription: String,
        attempt: Int,
        maxAttempts: Int
    ) -> DATStartRetryDecision {
        DATStartRetryPolicy.decision(
            errorDescription: errorDescription,
            isPersistentEligibilityRetryEnabled: persistentEligibilityRetryEnabled,
            attempt: attempt,
            maxAttempts: maxAttempts
        )
    }

    private func observeSessionErrors(
        _ session: DeviceSession,
        onPowerEvent: @escaping @MainActor (WearablePowerRuntimeEvent) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await error in session.errorStream() {
                await MainActor.run {
                    self?.lastErrorDescription = describeDATRuntimeError(error)
                    self?.emit("Meta DAT device session error: \(describeDATRuntimeError(error))")
                    if let event = self?.wearablePowerRuntimeEvent(from: error, source: "device_session") {
                        onPowerEvent(event)
                    }
                }
            }
        }
    }

    private func setupListeners(
        for stream: MWDATCamera.Stream,
        continuation: AsyncStream<WearableFrame>.Continuation,
        onPreviewImage: @escaping @MainActor (UIImage?, Int) -> Void,
        onPowerEvent: @escaping @MainActor (WearablePowerRuntimeEvent) -> Void
    ) {
        stateToken = stream.statePublisher.listen { state in
            Task { @MainActor [weak self] in
                self?.lastStreamState = String(describing: state)
                self?.emit("Camera stream state: \(String(describing: state))")
            }
            if state == .stopped {
                continuation.finish()
            }
        }

        frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.frameID += 1
                let image = frame.makeUIImage()
                onPreviewImage(image, self.frameID)
                continuation.yield(
                    WearableFrame(
                        id: self.frameID,
                        timestamp: .now,
                        previewImageAvailable: image != nil
                    )
                )
            }
        }

        errorToken = stream.errorPublisher.listen { error in
            Task { @MainActor [weak self] in
                self?.lastErrorDescription = "\(error.localizedDescription) (\(String(describing: error)))"
                self?.emit("Camera stream error: \(error.localizedDescription) (\(String(describing: error)))")
                if let event = self?.wearablePowerRuntimeEvent(from: error, source: "camera_stream") {
                    onPowerEvent(event)
                }
            }
            continuation.finish()
        }
    }

    private func wearablePowerRuntimeEvent(from error: Error, source: String) -> WearablePowerRuntimeEvent? {
        if let sessionError = error as? DeviceSessionError {
            switch sessionError {
            case .batteryCritical:
                return WearablePowerRuntimeEvent(kind: "battery_critical", source: source, description: describeDATRuntimeError(sessionError))
            case .peakPowerShutdown:
                return WearablePowerRuntimeEvent(kind: "peak_power_shutdown", source: source, description: describeDATRuntimeError(sessionError))
            case .thermalCritical:
                return WearablePowerRuntimeEvent(kind: "thermal_critical", source: source, description: describeDATRuntimeError(sessionError))
            case .thermalEmergency:
                return WearablePowerRuntimeEvent(kind: "thermal_emergency", source: source, description: describeDATRuntimeError(sessionError))
            default:
                break
            }
        }

        if let streamError = error as? MWDATCamera.StreamError {
            switch streamError {
            case .batteryCritical:
                return WearablePowerRuntimeEvent(kind: "battery_critical", source: source, description: streamError.localizedDescription)
            case .peakPowerShutdown:
                return WearablePowerRuntimeEvent(kind: "peak_power_shutdown", source: source, description: streamError.localizedDescription)
            case .thermalCritical:
                return WearablePowerRuntimeEvent(kind: "thermal_critical", source: source, description: streamError.localizedDescription)
            case .thermalEmergency:
                return WearablePowerRuntimeEvent(kind: "thermal_emergency", source: source, description: streamError.localizedDescription)
            default:
                break
            }
        }

        return nil
    }

    private func clearListeners() {
        frameToken = nil
        stateToken = nil
        errorToken = nil
        displayStateToken = nil
    }

    private func waitForConnectedCompatibleDevice(timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastSummary = ""

        while Date() < deadline {
            let snapshot = currentDATDeviceEligibilitySnapshot()
            if snapshot.eligible {
                emit("DAT device eligible before permission: \(snapshot.summary)")
                return
            }
            if snapshot.summary != lastSummary {
                emit("Waiting for DAT eligible device before permission: \(snapshot.summary)")
                lastSummary = snapshot.summary
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let snapshot = currentDATDeviceEligibilitySnapshot()
        emit("DAT device eligibility wait timed out before permission: \(snapshot.summary)")
    }

    private func currentDATDeviceEligibilitySnapshot() -> (eligible: Bool, summary: String) {
        let devices = Wearables.shared.devices.compactMap { deviceID -> (Bool, String)? in
            guard let device = Wearables.shared.deviceForIdentifier(deviceID) else { return nil }
            let isEligible = device.linkState == .connected && device.compatibility() == .compatible
            return (
                isEligible,
                "\(String(describing: deviceID)) | \(device.nameOrId()) | link=\(String(describing: device.linkState)) | compat=\(String(describing: device.compatibility())) | display=\(device.supportsDisplay())"
            )
        }

        guard !devices.isEmpty else {
            lastEligibleDevice = false
            lastEligibilitySummary = "No DAT devices visible."
            return (false, lastEligibilitySummary)
        }
        let snapshot = (
            devices.contains { $0.0 },
            devices.map(\.1).joined(separator: " || ")
        )
        lastEligibleDevice = snapshot.0
        lastEligibilitySummary = snapshot.1
        return snapshot
    }

    private func attachDisplayHUDIfNeeded(to session: DeviceSession) async {
        guard displayHUDEnabled else { return }
        do {
            emit("display_hud_attach_started")
            let newDisplay = try session.addDisplay()
            display = newDisplay
            displayStateToken = newDisplay.statePublisher.listen { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastDisplayState = String(describing: state)
                    self.emit("display_hud_state \(String(describing: state))")
                    if state == .started {
                        self.emit("display_hud_started")
                        self.scheduleDisplayHUDSend()
                    }
                }
            }
            newDisplay.start()
            emit("display_hud_start_requested")
        } catch {
            emit("display_hud_attach_failed: \(error.localizedDescription) (\(String(describing: error)))")
        }
    }

    private func scheduleDisplayHUDSend() {
        guard displayHUDEnabled, !displayHUDSending else { return }
        guard display?.state == .started else { return }

        let delay: TimeInterval
        if let lastDisplayHUDSendAt {
            delay = max(0, minimumDisplayHUDInterval - Date().timeIntervalSince(lastDisplayHUDSendAt))
        } else {
            delay = 0
        }

        displayHUDSending = true
        Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.sendDisplayHUDSnapshot()
        }
    }

    private func sendDisplayHUDSnapshot() async {
        guard let snapshot = pendingDisplayHUDSnapshot else {
            displayHUDSending = false
            return
        }
        pendingDisplayHUDSnapshot = nil

        guard displayHUDEnabled, let display, display.state == .started else {
            displayHUDSending = false
            return
        }

        emit("display_hud_send_started")
        emit("display_hud_send_detail reason=\(snapshot.updateReason) frame=\(snapshot.visionFrameID) frames=\(snapshot.framesReceived)")
        var snapshotPayload = snapshot.eventPayload
        snapshotPayload["send_phase"] = "before_send"
        ArtemisBenchmarkEventStore.append(event: "display_hud_snapshot", payload: snapshotPayload)
        ArtemisRemoteLogSink.sendEvent("display_hud_snapshot", payload: snapshotPayload)
        lastDisplayHUDSendAt = Date()
        do {
            try await display.send(makeDisplayHUDView(snapshot))
            var sentPayload = snapshot.eventPayload
            sentPayload["send_phase"] = "sent"
            ArtemisBenchmarkEventStore.append(event: "display_hud_snapshot", payload: sentPayload)
            ArtemisRemoteLogSink.sendEvent("display_hud_snapshot", payload: sentPayload)
            emit("display_hud_send_completed")
            emit("display_hud_send_detail_completed reason=\(snapshot.updateReason) frame=\(snapshot.visionFrameID) frames=\(snapshot.framesReceived)")
        } catch {
            var failedPayload = snapshot.eventPayload
            failedPayload["send_phase"] = "failed"
            failedPayload["error"] = error.localizedDescription
            ArtemisBenchmarkEventStore.append(event: "display_hud_snapshot", payload: failedPayload)
            ArtemisRemoteLogSink.sendEvent("display_hud_snapshot", payload: failedPayload)
            emit("display_hud_send_failed reason=\(snapshot.updateReason): \(error.localizedDescription) (\(String(describing: error)))")
        }

        displayHUDSending = false
        if pendingDisplayHUDSnapshot != nil {
            scheduleDisplayHUDSend()
        }
    }

    private func makeDisplayHUDView(_ snapshot: DisplayHUDSnapshot) -> MWDATDisplay.FlexBox {
        let streamLine = snapshot.streamLine
        let visionLine = snapshot.visionLine
        return MWDATDisplay.FlexBox(direction: .column, spacing: 10, crossAlignment: .stretch) {
            MWDATDisplay.FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center) {
                MWDATDisplay.Icon(name: .starCircleTriangleAi)
                MWDATDisplay.FlexBox(direction: .column, spacing: 2) {
                    MWDATDisplay.Text("Jarvis", style: .heading)
                    MWDATDisplay.Text(trimDisplayHUDText("\(snapshot.mode) / \(snapshot.stateText)", limit: 56), style: .meta, color: .secondary)
                }
            }

            MWDATDisplay.FlexBox(direction: .column, spacing: 4, crossAlignment: .stretch) {
                MWDATDisplay.Text(trimDisplayHUDText(snapshot.updateReason, limit: 44), style: .meta, color: .secondary)
                MWDATDisplay.Text(trimDisplayHUDText(streamLine, limit: 58), style: .meta, color: .secondary)
                MWDATDisplay.Text(trimDisplayHUDText(snapshot.powerLine, limit: 58), style: .meta, color: .secondary)
            }

            makeDisplayHUDRoleCard(
                label: "YOU",
                detail: snapshot.sttFinalizationReason,
                text: snapshot.sttText,
                labelColor: .secondary,
                textColor: .primary
            )

            makeDisplayHUDRoleCard(
                label: "JARVIS",
                detail: "\(snapshot.visionFrameID > 0 ? "vision f\(snapshot.visionFrameID)" : "thinking")",
                text: snapshot.assistantText,
                labelColor: .primary,
                textColor: .primary
            )

            makeDisplayHUDRoleCard(
                label: "VOICE",
                detail: snapshot.ttsVoice,
                text: snapshot.ttsText,
                labelColor: .secondary,
                textColor: .secondary
            )

            MWDATDisplay.FlexBox(direction: .column, spacing: 4, crossAlignment: .stretch) {
                MWDATDisplay.Text(trimDisplayHUDText(visionLine, limit: 62), style: .meta, color: .secondary)
                MWDATDisplay.Text(trimDisplayHUDText(snapshot.visionSummary, limit: 84), style: .body, color: .secondary)
                MWDATDisplay.Text(trimDisplayHUDText(snapshot.latencyText, limit: 88), style: .meta, color: .secondary)
            }
        }
        .padding(18)
        .background(.card)
    }

    private func makeDisplayHUDRoleCard(
        label: String,
        detail: String,
        text: String,
        labelColor: MWDATDisplay.TextColor,
        textColor: MWDATDisplay.TextColor
    ) -> MWDATDisplay.FlexBox {
        let cleanText = trimDisplayHUDText(text, limit: 88)
        let cleanDetail = trimDisplayHUDText(detail, limit: 32)
        return MWDATDisplay.FlexBox(direction: .column, spacing: 3, crossAlignment: .stretch) {
            MWDATDisplay.FlexBox(direction: .row, spacing: 6, alignment: .center, crossAlignment: .center) {
                MWDATDisplay.Text(label, style: .meta, color: labelColor)
                MWDATDisplay.Text(cleanDetail, style: .meta, color: .secondary)
            }
            MWDATDisplay.Text(cleanText, style: .body, color: textColor)
        }
        .padding(MWDATDisplay.EdgeInsets(top: 8, bottom: 8, leading: 10, trailing: 10))
        .background(.card)
    }

    private func trimDisplayHUDText(_ text: String, limit: Int = 96) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed.isEmpty ? "-" : collapsed }
        return String(collapsed.prefix(limit - 3)) + "..."
    }

    private func makeDeviceSelector() throws -> any DeviceSelector {
        if let deviceId = Wearables.shared.devices.first(where: { deviceId in
            guard let device = Wearables.shared.deviceForIdentifier(deviceId) else { return false }
            return device.linkState == .connected && device.compatibility() == .compatible
        }) {
            emit("Using specific DAT device selector: \(String(describing: deviceId))")
            return SpecificDeviceSelector(device: deviceId)
        }

        let visibleDevices = Wearables.shared.devices
            .map { String(describing: $0) }
            .joined(separator: ", ")
        emit("No connected compatible device found for specific selector. Visible devices: \(visibleDevices)")
        return AutoDeviceSelector(wearables: Wearables.shared)
    }

    private func waitForSessionStart(
        stateStream: AsyncStream<DeviceSessionState>,
        errorStream: AsyncStream<DeviceSessionError>
    ) async throws {
        if deviceSession?.state == .started { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in stateStream {
                    if state == .started { return }
                    if state == .stopped {
                        throw DeviceSessionError.unexpectedError(description: "The session stopped before starting.")
                    }
                }
            }

            group.addTask {
                for await error in errorStream {
                    throw error
                }
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func emit(_ message: String) {
        diagnostics?(message)
    }
}

struct LocalModelBenchmarkResult: Sendable {
    let totalMilliseconds: Int
    let responseText: String
    let summary: String
    let compactSummary: String
    let liteRTMetrics: LiteRTBenchmarkMetrics?

    init(
        totalMilliseconds: Int,
        responseText: String,
        summary: String,
        compactSummary: String,
        liteRTMetrics: LiteRTBenchmarkMetrics? = nil
    ) {
        self.totalMilliseconds = totalMilliseconds
        self.responseText = responseText
        self.summary = summary
        self.compactSummary = compactSummary
        self.liteRTMetrics = liteRTMetrics
    }
}

struct LiteRTBenchmarkMetrics: Sendable {
    let initTimeSeconds: Double
    let timeToFirstTokenSeconds: Double
    let prefillTokenCount: Int
    let decodeTokenCount: Int
    let prefillTokensPerSecond: Double
    let decodeTokensPerSecond: Double
    let observedDecodeTokensPerSecond: Double

    init(info: BenchmarkInfo, totalMilliseconds: Int) {
        initTimeSeconds = info.initTimeInSecond
        timeToFirstTokenSeconds = info.timeToFirstTokenInSecond
        prefillTokenCount = info.lastPrefillTokenCount
        decodeTokenCount = info.lastDecodeTokenCount
        prefillTokensPerSecond = info.lastPrefillTokensPerSecond
        decodeTokensPerSecond = info.lastDecodeTokensPerSecond
        observedDecodeTokensPerSecond = totalMilliseconds > 0
            ? Double(info.lastDecodeTokenCount) / (Double(totalMilliseconds) / 1000.0)
            : 0.0
    }

    var payload: [String: Any] {
        [
            "init_time_s": initTimeSeconds,
            "ttft_s": timeToFirstTokenSeconds,
            "prefill_token_count": prefillTokenCount,
            "decode_token_count": decodeTokenCount,
            "prefill_tps": prefillTokensPerSecond,
            "decode_tps": decodeTokensPerSecond,
            "observed_decode_tps_whole_call": observedDecodeTokensPerSecond
        ]
    }

    var summaryLine: String {
        "\nInit: \(String(format: "%.2f", initTimeSeconds))s, TTFT: \(String(format: "%.2f", timeToFirstTokenSeconds))s, prefill: \(String(format: "%.1f", prefillTokensPerSecond)) tok/s (\(prefillTokenCount)), decode: \(String(format: "%.1f", decodeTokensPerSecond)) tok/s (\(decodeTokenCount)), observed whole-call decode: \(String(format: "%.1f", observedDecodeTokensPerSecond)) tok/s"
    }
}

enum ArchitectureDeviceSnapshot {
    static func current() -> [String: Any] {
        [
            "thermal_state": ProcessInfo.processInfo.thermalState.readableName,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "timestamp": ISO8601DateFormatter().string(from: .now)
        ]
    }
}

enum ArchitectureSummaryFormatter {
    static func text(from summary: [String: Any]) -> String {
        let batchID = summary["batch_id"] as? String ?? "unknown"
        let totalMS = summary["total_wall_ms"] as? Int ?? 0
        let completed = summary["completed_lanes"] as? Int ?? 0
        let failed = summary["failed_lanes"] as? Int ?? 0
        let verdict = summary["verdict"] as? String ?? "No verdict."
        let rows = (summary["leaderboard"] as? [[String: Any]] ?? [])
            .map { row -> String in
                let lane = row["lane_id"] as? String ?? "unknown_lane"
                let architecture = row["architecture"] as? String ?? "unknown_arch"
                if let error = row["error"] as? String {
                    return "- \(lane) [\(architecture)] FAILED: \(error)"
                }
                if (row["skipped"] as? Bool) == true {
                    let reason = row["skip_reason"] as? String ?? "skipped"
                    return "- \(lane) [\(architecture)] SKIPPED: \(reason)"
                }
                let latency = row["latency_mean_ms"] as? Int
                    ?? row["latency_ms"] as? Int
                    ?? row["wall_ms"] as? Int
                    ?? 0
                let metrics = row["litert_metrics"] as? [String: Any]
                let decodeTPS = metrics?["decode_tps"] as? Double
                let ttft = metrics?["ttft_s"] as? Double
                let metricText: String
                if let decodeTPS, let ttft {
                    metricText = ", decode \(String(format: "%.1f", decodeTPS)) tok/s, TTFT \(String(format: "%.2f", ttft))s"
                } else {
                    metricText = ""
                }
                return "- \(lane) [\(architecture)] \(latency)ms\(metricText)"
            }
            .joined(separator: "\n")
        return """
        Artemis architecture-search batch
        Batch: \(batchID)
        Total wall time: \(totalMS)ms
        Lanes: \(completed) complete, \(failed) failed

        Verdict:
        \(verdict)

        Leaderboard:
        \(rows)
        """
    }
}

func architectureDeviceSnapshot() -> [String: Any] {
    ArchitectureDeviceSnapshot.current()
}

func visionQualityProxy(outputs: [String], expectedFrames: Int) -> (score: Double, details: [String: Double]) {
    let frameCount = max(expectedFrames, outputs.count, 1)
    let boilerplateTerms: Set<String> = [
        "wearable", "vision", "sentinel", "camera", "realtime", "real", "time",
        "scene", "objects", "object", "readable", "text", "escalate", "confidence",
        "action", "hint", "visible", "people", "important", "detail"
    ]
    var nonEmptyFrames = 0
    var emptyDefaults = 0
    var usableFormats = 0
    var confidenceValues: [Double] = []
    var escalationSignals = 0
    var densityTotal = 0.0

    for rawOutput in outputs {
        let output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = output.lowercased()
        let emptyDefault = lower.contains("\"scene\":\"\"")
            || lower.contains("\"scene\": \"\"")
            || lower.contains("\"objects\":[]")
            || lower.contains("\"objects\": []")
            || lower.contains("\"visible_objects\":[]")
            || lower.contains("\"visible_objects\": []")
        if emptyDefault {
            emptyDefaults += 1
        }

        let cleaned = output
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) != nil
            || cleaned.split(separator: "|").count >= 3 {
            usableFormats += 1
        }

        if lower.contains("escalate\":true")
            || lower.contains("escalate\": true")
            || lower.contains("should_escalate\":true")
            || lower.contains("should_escalate\": true")
            || lower.contains("escalate: yes")
            || lower.contains("escalate yes") {
            escalationSignals += 1
        }

        if let confidence = firstNumber(after: "confidence", in: lower) {
            confidenceValues.append(min(max(confidence, 0.0), 1.0))
        }

        let evidenceWords = lower
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { word in
                word.count > 2
                    && !boilerplateTerms.contains(word)
                    && Double(word) == nil
                    && word != "false"
                    && word != "true"
                    && word != "null"
            }
        let uniqueEvidence = Set(evidenceWords)
        let density = min(1.0, Double(uniqueEvidence.count) / 12.0)
        densityTotal += density
        if !emptyDefault && density >= 0.18 {
            nonEmptyFrames += 1
        }
    }

    let nonEmptyFrameRatio = Double(nonEmptyFrames) / Double(frameCount)
    let evidenceDensity = densityTotal / Double(frameCount)
    let emptyDefaultRatio = Double(emptyDefaults) / Double(frameCount)
    let formatUsableRatio = Double(usableFormats) / Double(frameCount)
    let confidenceMean = confidenceValues.isEmpty
        ? 0.0
        : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
    let escalationSignalRatio = Double(escalationSignals) / Double(frameCount)
    let rawScore =
        0.40 * nonEmptyFrameRatio
        + 0.25 * evidenceDensity
        + 0.15 * formatUsableRatio
        + 0.10 * confidenceMean
        + 0.10 * escalationSignalRatio
        - 0.35 * emptyDefaultRatio
    let score = min(max(rawScore, 0.0), 1.0)

    return (
        score,
        [
            "non_empty_frame_ratio": nonEmptyFrameRatio,
            "evidence_density": evidenceDensity,
            "empty_default_ratio": emptyDefaultRatio,
            "format_usable_ratio": formatUsableRatio,
            "confidence_mean": confidenceMean,
            "escalation_signal_ratio": escalationSignalRatio
        ]
    )
}

private func firstNumber(after key: String, in text: String) -> Double? {
    guard let keyRange = text.range(of: key) else { return nil }
    let suffix = text[keyRange.upperBound...]
    let allowed = Set("0123456789.-")
    var started = false
    var number = ""
    for character in suffix {
        if allowed.contains(character) {
            started = true
            number.append(character)
        } else if started {
            break
        }
    }
    return Double(number)
}

func architectureVerdict(from leaderboard: [[String: Any]]) -> String {
    let successes = leaderboard.filter {
        ($0["error"] as? String) == nil && (($0["skipped"] as? Bool) != true)
    }
    let failures = leaderboard.filter { ($0["error"] as? String) != nil }.count
    let skipped = leaderboard.filter { ($0["skipped"] as? Bool) == true }.count
    let visionSuccesses = successes.filter { ($0["architecture"] as? String) == "vision_only" }
    let bestQualityVision = visionSuccesses.max {
        let leftQuality = ($0["quality_proxy_score"] as? Double) ?? 0.0
        let rightQuality = ($1["quality_proxy_score"] as? Double) ?? 0.0
        if leftQuality != rightQuality {
            return leftQuality < rightQuality
        }
        return (($0["latency_mean_ms"] as? Int) ?? Int.max) > (($1["latency_mean_ms"] as? Int) ?? Int.max)
    }
    let fastestUsefulVision = (visionSuccesses.filter {
        let quality = ($0["quality_proxy_score"] as? Double) ?? 0.0
        let fps = ($0["estimated_fps"] as? Double) ?? 0.0
        return quality >= 0.1 && fps >= 1.0
    }.min {
        (($0["latency_mean_ms"] as? Int) ?? Int.max) < (($1["latency_mean_ms"] as? Int) ?? Int.max)
    }) ?? visionSuccesses.min {
        (($0["latency_mean_ms"] as? Int) ?? Int.max) < (($1["latency_mean_ms"] as? Int) ?? Int.max)
    }
    let fastestReasoner = successes
        .filter { ($0["architecture"] as? String) == "vision_transcript_reasoner" }
        .min {
            (($0["latency_ms"] as? Int) ?? Int.max) < (($1["latency_ms"] as? Int) ?? Int.max)
        }
    let audioWorked = successes.contains {
        ($0["architecture"] as? String) == "direct_audio_smoke" && (($0["ok"] as? Bool) ?? false)
    }

    let qualityEyes = bestQualityVision?["lane_id"] as? String ?? "no successful vision lane"
    let fastEyes = fastestUsefulVision?["lane_id"] as? String ?? "no successful vision lane"
    let brain = fastestReasoner?["lane_id"] as? String ?? "no successful reasoner lane"
    let ears = audioWorked ? "Gemma direct audio passed a smoke lane; compare quality before using it." : "Use Apple STT as V1 ears; Gemma direct audio remains experimental/blocked."
    return "Best quality eye: \(qualityEyes). Fastest useful eye: \(fastEyes). Best current brain: \(brain). \(ears) Failures: \(failures). Skipped: \(skipped)."
}

func architectureFallbackDecision(
    candidateID: String,
    triggerSignal: String,
    confidenceBefore: Double,
    fallbackReason: String,
    expectedCostMS: Int,
    actualCostMS: Int?,
    fallbackResult: String
) -> [String: Any] {
    [
        "candidate_id": candidateID,
        "expected_fallback": true,
        "fallback_reason": fallbackReason,
        "trigger_signal": triggerSignal,
        "confidence_before": min(max(confidenceBefore, 0.0), 1.0),
        "expected_cost_ms": expectedCostMS,
        "actual_cost_ms": actualCostMS.map { $0 as Any } ?? NSNull(),
        "fallback_result": fallbackResult,
        "timestamp": ISO8601DateFormatter().string(from: .now)
    ]
}

private extension ProcessInfo.ThermalState {
    var readableName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

enum IntegratedReplayInputMode: String, Sendable {
    case audioOnly = "audio_only"
    case transcriptOnly = "transcript_only"
    case audioAndTranscript = "audio_and_transcript"

    var displayName: String {
        switch self {
        case .audioOnly:
            "LFM 450M vision + Gemma E2B audio-only reasoning"
        case .transcriptOnly:
            "LFM 450M vision + Apple STT + Gemma E2B transcript-only reasoning"
        case .audioAndTranscript:
            "LFM 450M vision + Apple STT + Gemma E2B audio/text reasoning"
        }
    }

    var usesAudio: Bool {
        self == .audioOnly || self == .audioAndTranscript
    }

    var usesTranscript: Bool {
        self == .transcriptOnly || self == .audioAndTranscript
    }

    var allowsTextFallback: Bool {
        self == .audioAndTranscript
    }
}

enum GemmaAudioSmokeInput: Sendable {
    case data(Data)
    case file(String)
}

struct LocalVisionBenchmarkVariant: Sendable {
    let label: String
    let shortLabel: String
    let visionBackend: Backend
    let speculativeDecoding: Bool

    static let officialGemmaTriage: [LocalVisionBenchmarkVariant] = [
        LocalVisionBenchmarkVariant(
            label: "LiteRT Gemma compressed/QAT artifact, text GPU, vision CPU",
            shortLabel: "Gemma CPU-vision",
            visionBackend: .cpu(),
            speculativeDecoding: false
        ),
        LocalVisionBenchmarkVariant(
            label: "LiteRT Gemma MTP, text GPU, vision CPU",
            shortLabel: "Gemma MTP CPU-vision",
            visionBackend: .cpu(),
            speculativeDecoding: true
        )
    ]
}

actor LocalModelBenchmarkService {
    private var cachedModelPath = ""
    private var cachedModelKey = ""
    private var cachedEngine: LiteRTLM.Engine?
    private var cachedConversation: LiteRTLM.Conversation?

    func resetCaches() {
        cachedModelPath = ""
        cachedModelKey = ""
        cachedEngine = nil
        cachedConversation = nil
    }

    func runSyntheticBenchmark(modelPath: String) async throws -> LocalModelBenchmarkResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = false
        let start = Date()
        let info = try await benchmark(
            modelPath: modelPath,
            backend: .gpu,
            prefillTokens: 128,
            decodeTokens: 128,
            cacheDir: NSTemporaryDirectory()
        )
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = LiteRTBenchmarkMetrics(info: info, totalMilliseconds: totalMS)
        let summary = """
        Synthetic GPU benchmark
        Total wall time: \(totalMS)ms
        Init: \(String(format: "%.2f", info.initTimeInSecond))s
        TTFT: \(String(format: "%.2f", info.timeToFirstTokenInSecond))s
        Prefill: \(String(format: "%.1f", info.lastPrefillTokensPerSecond)) tok/s (\(info.lastPrefillTokenCount) tokens)
        Decode: \(String(format: "%.1f", info.lastDecodeTokensPerSecond)) tok/s (\(info.lastDecodeTokenCount) tokens)
        """
        let compact = "decode \(String(format: "%.1f", info.lastDecodeTokensPerSecond)) tok/s, ttft \(String(format: "%.2f", info.timeToFirstTokenInSecond))s"
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: compact,
            summary: summary,
            compactSummary: compact,
            liteRTMetrics: metrics
        )
    }

    func runVisionProbe(modelPath: String, imageData: Data) async throws -> LocalModelBenchmarkResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.visualTokenBudget = 140
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = false
        let conversation = try await conversation(for: modelPath, visionBackend: .cpu(), speculativeDecoding: false)
        let start = Date()
        let prompt = """
        You are Artemis running on smart glasses. Analyze this live POV frame.
        Return compact JSON with: scene, objects, text, people_count, action_suggestion, confidence.
        """
        let message = Message(contents: [
            .text(prompt),
            .imageData(imageData)
        ])
        let response = try await conversation.sendMessage(message)
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = benchmarkMetrics(for: conversation, totalMilliseconds: totalMS)
        let benchmarkSummary = metrics?.summaryLine ?? ""
        let text = response.toString
        let summary = """
        Latest-frame vision probe
        Total wall time: \(totalMS)ms
        JPEG input: \(imageData.count) bytes\(benchmarkSummary)

        \(text)
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: text,
            summary: summary,
            compactSummary: "\(totalMS)ms, \(imageData.count) bytes",
            liteRTMetrics: metrics
        )
    }

    func runSentinelProbe(modelPath: String, imageData: Data) async throws -> LocalModelBenchmarkResult {
        try await runSentinelProbe(
            modelPath: modelPath,
            imageData: imageData,
            variant: LocalVisionBenchmarkVariant(
                label: "LiteRT Gemma live sentinel, text GPU, vision CPU",
                shortLabel: "Live Sentinel",
                visionBackend: .cpu(),
                speculativeDecoding: false
            )
        )
    }

    func runSentinelProbe(
        modelPath: String,
        imageData: Data,
        variant: LocalVisionBenchmarkVariant
    ) async throws -> LocalModelBenchmarkResult {
        try await runSentinelProbe(
            modelPath: modelPath,
            imageData: imageData,
            visionBackend: variant.visionBackend,
            speculativeDecoding: variant.speculativeDecoding,
            label: variant.label
        )
    }

    private func runSentinelProbe(
        modelPath: String,
        imageData: Data,
        visionBackend: Backend,
        speculativeDecoding: Bool,
        label: String
    ) async throws -> LocalModelBenchmarkResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.visualTokenBudget = 70
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = speculativeDecoding
        try validateSpeculativeSupport(modelPath: modelPath, speculativeDecoding: speculativeDecoding)
        let conversation = try await conversation(
            for: modelPath,
            visionBackend: visionBackend,
            speculativeDecoding: speculativeDecoding
        )
        let start = Date()
        let prompt = """
        You are Artemis' live local sentinel running on smart glasses POV frames.
        Decide whether this frame can be handled locally or should escalate to a bigger model.
        Escalate only for: explicit user question, safety hazard, navigation/action uncertainty, visible document/screen text that matters, unknown object/person needing identity, or low confidence.
        Return compact JSON only:
        {"scene":"","objects":[],"text":"","local_action":"","should_escalate":false,"reason":"","confidence":0.0}
        """
        let message = Message(contents: [
            .text(prompt),
            .imageData(imageData)
        ])
        let response = try await conversation.sendMessage(message)
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = benchmarkMetrics(for: conversation, totalMilliseconds: totalMS)
        let benchmarkSummary = metrics?.summaryLine ?? ""
        let text = response.toString
        let summary = """
        Live sentinel probe
        Variant: \(label)
        Vision backend: \(visionBackend.rawValue)
        MTP/speculative decoding: \(speculativeDecoding ? "enabled" : "disabled")
        Total wall time: \(totalMS)ms
        JPEG input: \(imageData.count) bytes\(benchmarkSummary)

        \(text)
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: text,
            summary: summary,
            compactSummary: "\(visionBackend.rawValue), mtp=\(speculativeDecoding), \(totalMS)ms, \(imageData.count) bytes",
            liteRTMetrics: metrics
        )
    }

    func runReplayReasoning(
        modelPath: String,
        audioFileURL: URL?,
        transcript: String,
        transcriptStatus: String,
        inputMode: IntegratedReplayInputMode,
        visualTimeline: [IntegratedVisualObservation],
        speculativeDecoding: Bool = false
    ) async throws -> LocalModelBenchmarkResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = speculativeDecoding
        try validateSpeculativeSupport(modelPath: modelPath, speculativeDecoding: speculativeDecoding)
        let conversation = try await conversation(
            for: modelPath,
            visionBackend: nil,
            audioBackend: audioFileURL == nil ? nil : .cpu(),
            speculativeDecoding: speculativeDecoding,
            maxNumTokens: 512
        )
        let start = Date()
        let usableTimeline = visualTimeline
            .filter { !$0.responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(4)
        let visualText = usableTimeline.map { observation in
            let response = observation.responseText
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .prefix(220)
            return "f\(observation.frameIndex + 1)@\(String(format: "%.0f", observation.seconds))s \(observation.latencyMilliseconds)ms: \(response)"
        }.joined(separator: "\n")
        let compactTranscript = transcript.isEmpty
            ? "(none)"
            : String(transcript.replacingOccurrences(of: "\n", with: " ").prefix(180))
        let prompt = """
        Local Artemis router replay.
        mode=\(inputMode.rawValue)
        stt=\(transcriptStatus): \(compactTranscript)
        vision=LFM2.5-VL-450M:
        \(visualText.isEmpty ? "(no usable frames)" : visualText)

        Return compact JSON only, no markdown:
        {"intent":"","visual":"","answer":"","action":"","escalate":false,"confidence":0.0,"note":""}
        Keep values short. Escalate only for unreadable screen text, people, hazards, or unclear user intent.
        """
        var contents: [Content] = []
        if let audioFileURL {
            contents.append(.audioFile(audioFileURL.path))
        }
        contents.append(.text(prompt))
        let response = try await conversation.sendMessage(Message(contents: contents))
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = benchmarkMetrics(for: conversation, totalMilliseconds: totalMS)
        let benchmarkSummary = metrics?.summaryLine ?? ""
        let text = response.toString
        let summary = """
        Integrated replay reasoning
        Audio file included: \(audioFileURL == nil ? "false" : "true")
        MTP/speculative decoding: \(speculativeDecoding ? "enabled" : "disabled")
        Total wall time: \(totalMS)ms\(benchmarkSummary)

        \(text)
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: text,
            summary: summary,
            compactSummary: "audio=\(audioFileURL == nil ? "false" : "true"), \(totalMS)ms",
            liteRTMetrics: metrics
        )
    }

    func runSessionDecodeReasoning(
        modelPath: String,
        transcript: String,
        transcriptStatus: String,
        visualTimeline: [IntegratedVisualObservation],
        videoDurationSeconds: Double
    ) async throws -> LocalModelBenchmarkResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = false
        let conversation = try await conversation(
            for: modelPath,
            visionBackend: nil,
            audioBackend: nil,
            speculativeDecoding: false,
            maxNumTokens: 1024
        )
        let timelineText = visualTimeline.map { observation in
            let cleaned = observation.responseText
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "t=\(String(format: "%.1f", observation.seconds))s latency=\(observation.latencyMilliseconds)ms obs=\(String(cleaned.prefix(260)))"
        }.joined(separator: "\n")
        let transcriptText = transcript.isEmpty
            ? "(none)"
            : String(transcript.replacingOccurrences(of: "\n", with: " ").prefix(6000))
        let prompt = """
        You are Artemis evaluating a recorded Meta glasses work-session replay.
        Goal: judge what Artemis would understand in realtime and answer the user's spoken/session intent.

        Video duration: \(String(format: "%.1f", videoDurationSeconds)) seconds
        STT status: \(transcriptStatus)
        Transcript:
        \(transcriptText)

        Visual observations sampled across the entire video:
        \(timelineText.isEmpty ? "(no usable visual observations)" : timelineText)

        Return JSON only, no markdown:
        {
          "session_summary": "",
          "user_intent": "",
          "direct_answer": "",
          "visual_evidence": [],
          "misses_or_uncertainty": [],
          "tool_or_agent_actions": [],
          "realtime_assessment": {
            "would_feel_realtime": false,
            "why": "",
            "minimum_next_architecture": ""
          },
          "confidence": 0.0
        }
        Be blunt. If transcript is weak or visuals are generic, say so. Keep the answer compact but useful.
        """
        let start = Date()
        let response = try await conversation.sendMessage(Message(prompt))
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = benchmarkMetrics(for: conversation, totalMilliseconds: totalMS)
        let benchmarkSummary = metrics?.summaryLine ?? ""
        let text = response.toString
        let summary = """
        Conscious session reasoning
        Total wall time: \(totalMS)ms\(benchmarkSummary)

        \(text)
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: text,
            summary: summary,
            compactSummary: "session_decode, \(totalMS)ms",
            liteRTMetrics: metrics
        )
    }

    func runSessionDecodeChunkedReasoning(
        modelPath: String,
        transcript: String,
        transcriptStatus: String,
        visualTimeline: [IntegratedVisualObservation],
        videoDurationSeconds: Double
    ) async throws -> LocalModelBenchmarkResult {
        let started = Date()
        let chunkSize = 8
        let chunks = stride(from: 0, to: visualTimeline.count, by: chunkSize).map {
            Array(visualTimeline[$0..<min($0 + chunkSize, visualTimeline.count)])
        }
        var chunkSummaries: [String] = []

        for (chunkIndex, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            resetCaches()
            let observations = chunk.map { observation in
                let cleaned = observation.responseText
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "t=\(String(format: "%.1f", observation.seconds))s latency=\(observation.latencyMilliseconds)ms obs=\(String(cleaned.prefix(220)))"
            }.joined(separator: "\n")
            let prompt = """
            You are compressing a short segment of a Meta glasses POV work-session replay.
            Return JSON only, no markdown:
            {"segment_index":\(chunkIndex),"summary":"","objects":[],"screen_or_text":"","user_action":"","debug_relevance":"","uncertainty":"","confidence":0.0}

            Segment observations:
            \(observations)
            """
            let result = try await runTextOnlyPrompt(
                modelPath: modelPath,
                prompt: prompt,
                maxNumTokens: 384
            )
            chunkSummaries.append("chunk \(chunkIndex): \(result.responseText)")
        }

        try Task.checkCancellation()
        resetCaches()
        let transcriptText = transcript.isEmpty
            ? "(none)"
            : String(transcript.replacingOccurrences(of: "\n", with: " ").prefix(5000))
        let finalPrompt = """
        You are Artemis evaluating a recorded Meta glasses work-session replay.
        Goal: judge what Artemis would understand in realtime and answer the user's spoken/session intent.

        Video duration: \(String(format: "%.1f", videoDurationSeconds)) seconds
        STT status: \(transcriptStatus)
        Transcript:
        \(transcriptText)

        Compressed visual segment summaries:
        \(chunkSummaries.joined(separator: "\n"))

        Return JSON only, no markdown:
        {
          "session_summary": "",
          "user_intent": "",
          "direct_answer": "",
          "visual_evidence": [],
          "misses_or_uncertainty": [],
          "tool_or_agent_actions": [],
          "realtime_assessment": {
            "would_feel_realtime": false,
            "why": "",
            "minimum_next_architecture": ""
          },
          "confidence": 0.0
        }
        Be blunt. If transcript is weak or visuals are generic, say so.
        """
        var final = try await runTextOnlyPrompt(
            modelPath: modelPath,
            prompt: finalPrompt,
            maxNumTokens: 768
        )
        let totalMS = Int(Date().timeIntervalSince(started) * 1000)
        let summary = """
        Conscious session chunked reasoning
        Chunks: \(chunkSummaries.count)
        Total chunked wall time: \(totalMS)ms
        Final synthesis latency: \(final.totalMilliseconds)ms

        Chunk summaries:
        \(chunkSummaries.joined(separator: "\n\n"))

        Final:
        \(final.responseText)
        """
        final = LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: final.responseText,
            summary: summary,
            compactSummary: "session_decode_chunked, chunks=\(chunkSummaries.count), \(totalMS)ms",
            liteRTMetrics: final.liteRTMetrics
        )
        return final
    }

    func runSessionQuickReasoning(
        modelPath: String,
        transcript: String,
        transcriptStatus: String,
        visualTimeline: [IntegratedVisualObservation],
        videoDurationSeconds: Double
    ) async throws -> LocalModelBenchmarkResult {
        let started = Date()
        resetCaches()
        let promptPayload = sessionQuickReasoningPrompt(
            transcript: transcript,
            transcriptStatus: transcriptStatus,
            visualTimeline: visualTimeline,
            videoDurationSeconds: videoDurationSeconds
        )
        let prompt = promptPayload.prompt
        let result = try await runTextOnlyPrompt(
            modelPath: modelPath,
            prompt: prompt,
            maxNumTokens: 64
        )
        let totalMS = Int(Date().timeIntervalSince(started) * 1000)
        let summary = """
        \(result.responseText)

        Prompt chars: \(prompt.count)
        Packet:
        \(promptPayload.packet.joined(separator: "\n"))
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: result.responseText,
            summary: summary,
            compactSummary: "session_quick_reasoning_sanitized, packet=\(promptPayload.packet.count), prompt_chars=\(prompt.count), \(totalMS)ms",
            liteRTMetrics: result.liteRTMetrics
        )
    }

    func sessionQuickReasoningPromptPreview(
        transcript: String,
        transcriptStatus: String,
        visualTimeline: [IntegratedVisualObservation],
        videoDurationSeconds: Double
    ) -> [String: Any] {
        let payload = sessionQuickReasoningPrompt(
            transcript: transcript,
            transcriptStatus: transcriptStatus,
            visualTimeline: visualTimeline,
            videoDurationSeconds: videoDurationSeconds
        )
        return [
            "prompt_chars": payload.prompt.count,
            "prompt_preview": String(payload.prompt.prefix(1200)),
            "packet": payload.packet,
            "packet_count": payload.packet.count,
            "max_num_tokens": 64
        ]
    }

    private func sessionQuickReasoningPrompt(
        transcript: String,
        transcriptStatus: String,
        visualTimeline: [IntegratedVisualObservation],
        videoDurationSeconds: Double
    ) -> (prompt: String, packet: [String]) {
        let packet = sanitizedSessionPacket(
            transcript: transcript,
            transcriptStatus: transcriptStatus,
            visualTimeline: visualTimeline,
            videoDurationSeconds: videoDurationSeconds
        )
        let transcriptText = transcript.isEmpty
            ? "(none)"
            : String(transcript.replacingOccurrences(of: "\n", with: " ").prefix(120))
        let prompt = """
        Vision summary: \(packet.joined(separator: "; ")). User said: \(transcriptText).
        Reply one line: NEXT helpful action; ROUTE none vision_more mac_codex ask_user; CONF 0 to 1.
        """
        return (prompt, packet)
    }

    private func sanitizedSessionPacket(
        transcript: String,
        transcriptStatus: String,
        visualTimeline: [IntegratedVisualObservation],
        videoDurationSeconds: Double
    ) -> [String] {
        let nonEmpty = visualTimeline.filter { !isEmptyObservation($0.responseText) }
        let top = nonEmpty.isEmpty ? Array(visualTimeline.prefix(4)) : Array(nonEmpty.prefix(6))
        var scenes: [String] = []
        var objects: [String] = []
        var actions: [String] = []

        for observation in top {
            let cleaned = cleanObservationText(observation.responseText)
            scenes.append(contentsOf: extractedValues(for: "scene", in: cleaned).prefix(1))
            objects.append(contentsOf: extractedValues(for: "objects", in: cleaned).prefix(4))
            objects.append(contentsOf: extractedValues(for: "visible_objects", in: cleaned).prefix(4))
            actions.append(contentsOf: extractedValues(for: "user_action", in: cleaned).prefix(1))
        }

        let uniqueScenes = Array(NSOrderedSet(array: scenes.map(sanitizePacketValue)).compactMap { $0 as? String })
            .filter { !$0.isEmpty }
            .prefix(3)
        let uniqueObjects = Array(NSOrderedSet(array: objects.map(sanitizePacketValue)).compactMap { $0 as? String })
            .filter { !$0.isEmpty }
            .prefix(6)
        let uniqueActions = Array(NSOrderedSet(array: actions.map(sanitizePacketValue)).compactMap { $0 as? String })
            .filter { !$0.isEmpty && $0.lowercased() != "none" }
            .prefix(2)

        return [
            "frames=\(visualTimeline.count)",
            "useful_frames=\(nonEmpty.count)",
            "scenes=\(uniqueScenes.isEmpty ? "unknown" : uniqueScenes.joined(separator: ","))",
            "objects=\(uniqueObjects.isEmpty ? "unknown" : uniqueObjects.joined(separator: ","))",
            "actions=\(uniqueActions.isEmpty ? "unknown" : uniqueActions.joined(separator: ","))"
        ]
    }

    private func isEmptyObservation(_ text: String) -> Bool {
        let cleaned = cleanObservationText(text)
        return cleaned.contains("\"scene\":\"\"")
            && cleaned.contains("\"objects\":[]")
            && cleaned.contains("\"screen_or_text\":\"\"")
    }

    private func cleanObservationText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractedValues(for key: String, in text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json[key] else {
            return []
        }
        if let value = raw as? String {
            return value.isEmpty ? [] : [value]
        }
        if let values = raw as? [String] {
            return values
        }
        if let values = raw as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private func sanitizePacketValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: ";", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(36)
            .description
    }

    func runPromptSmoke(
        modelPath: String,
        maxNumTokens: Int
    ) async throws -> LocalModelBenchmarkResult {
        let prompt = """
        Artemis local prompt-path smoke. Return JSON only:
        {"ok":true,"role":"router","answer":"prompt path alive","tools":[],"confidence":1.0}
        """
        let result = try await runTextOnlyPrompt(
            modelPath: modelPath,
            prompt: prompt,
            maxNumTokens: maxNumTokens
        )
        return LocalModelBenchmarkResult(
            totalMilliseconds: result.totalMilliseconds,
            responseText: result.responseText,
            summary: result.responseText,
            compactSummary: "prompt_smoke, \(result.totalMilliseconds)ms",
            liteRTMetrics: result.liteRTMetrics
        )
    }

    func runSessionPacketPromptSmoke(
        modelPath: String,
        maxNumTokens: Int
    ) async throws -> LocalModelBenchmarkResult {
        let prompt = """
        Vision summary: frames=37; useful_frames=21; scenes=Bedroom,workspace,Workspace; objects=bed,laptop,water bottle,desk,computer monitor,keyboard; actions=No action detected,Open laptop. User said: Benchmark complete.
        Reply one line: NEXT helpful action; ROUTE none vision_more mac_codex ask_user; CONF 0 to 1.
        """
        let result = try await runTextOnlyPrompt(
            modelPath: modelPath,
            prompt: prompt,
            maxNumTokens: maxNumTokens
        )
        let summary = """
        \(result.responseText)

        Prompt chars: \(prompt.count)
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: result.totalMilliseconds,
            responseText: result.responseText,
            summary: summary,
            compactSummary: "session_packet_prompt_smoke, prompt_chars=\(prompt.count), \(result.totalMilliseconds)ms",
            liteRTMetrics: result.liteRTMetrics
        )
    }

    func runPromptVariant(
        modelPath: String,
        prompt: String,
        maxNumTokens: Int
    ) async throws -> LocalModelBenchmarkResult {
        try await runTextOnlyPrompt(
            modelPath: modelPath,
            prompt: prompt,
            maxNumTokens: maxNumTokens
        )
    }

    func runLiveGoldenTurn(
        modelPath: String,
        modelName: String,
        prompt: String,
        maxNumTokens: Int,
        onPartial: @escaping (String, Int) async -> Void
    ) async throws -> GoldenBrainTurnResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = false
        let conversation = try await conversation(
            for: modelPath,
            backend: .gpu,
            visionBackend: nil,
            audioBackend: nil,
            speculativeDecoding: false,
            maxNumTokens: maxNumTokens,
            reuseConversation: false
        )
        let start = Date()
        var streamed = ""
        var firstResponseMS = 0
        for try await chunk in conversation.sendMessageStream(Message(prompt)) {
            let text = chunk.toString
            guard !text.isEmpty else { continue }
            streamed.append(text)
            if firstResponseMS == 0 {
                firstResponseMS = Int(Date().timeIntervalSince(start) * 1000)
            }
            await onPartial(streamed, firstResponseMS)
        }
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = benchmarkMetrics(for: conversation, totalMilliseconds: totalMS)
        let normalized = normalizeLiveRouterOutput(streamed)
        return GoldenBrainTurnResult(
            rawOutput: streamed,
            streamedOutput: streamed,
            spokenText: normalized.spokenText,
            route: normalized.route,
            fallbackTriggered: normalized.fallbackTriggered,
            fallbackReason: normalized.fallbackReason,
            confidence: normalized.confidence,
            firstResponseMilliseconds: firstResponseMS,
            totalMilliseconds: totalMS,
            liteRTMetrics: metrics
        )
    }

    func runPromptVariantMatrix(modelPath: String) async -> [String: Any] {
        let variants: [(String, String, Int)] = [
            (
                "simple_json",
                """
                Artemis local prompt-path smoke. Return JSON only:
                {"ok":true,"role":"router","answer":"prompt path alive","tools":[],"confidence":1.0}
                """,
                512
            ),
            (
                "minimal_packet_plain",
                """
                Artemis router. Packet frames 37 useful 21 scenes workspace bedroom objects laptop monitor keyboard. Return JSON only: {"answer":"workspace and laptop visible","confidence":0.7}
                """,
                128
            ),
            (
                "packet_no_schema",
                """
                Artemis router. Use replay packet only. Duration 183 seconds. Transcript Benchmark complete. Frames 37 useful 21 empty 16. Scenes Bedroom workspace Workspace. Objects bed laptop water bottle desk computer monitor keyboard cords Monitor Keyboard Phone. Actions No action taken Open laptop. Reply with compact JSON.
                """,
                128
            ),
            (
                "packet_simple_schema",
                """
                Artemis router. Use replay packet only. Duration: 183.1s. STT: on_device. Transcript: Benchmark complete. Packet: frames=37; useful_frames=21; empty_frames=16; scenes=Bedroom,workspace,Workspace; objects=bed,laptop,water bottle,desk,computer monitor,keyboard,cords,Monitor,Keyboard,Phone; actions=No action taken,Open laptop. Return JSON only: {"answer":"","confidence":0.0}
                """,
                128
            ),
            (
                "packet_full_schema",
                """
                Artemis router. Use this replay packet only.
                Duration: 183.1s
                STT: on_device
                Transcript: Benchmark complete
                Packet: frames=37; useful_frames=21; empty_frames=16; scenes=Bedroom,workspace,Workspace; objects=bed,laptop,water bottle,desk,computer monitor,keyboard,cords,Monitor,Keyboard,Phone; actions=No action taken,Open laptop; transcript_status=on_device; duration=183.1
                Return one-line JSON only:
                {"context":"","intent":"","answer":"","tools":[],"escalate":false,"realtime_verdict":"","confidence":0.0}
                """,
                128
            ),
            (
                "packet_full_schema_512",
                """
                Artemis router. Use this replay packet only.
                Duration: 183.1s
                STT: on_device
                Transcript: Benchmark complete
                Packet: frames=37; useful_frames=21; empty_frames=16; scenes=Bedroom,workspace,Workspace; objects=bed,laptop,water bottle,desk,computer monitor,keyboard,cords,Monitor,Keyboard,Phone; actions=No action taken,Open laptop; transcript_status=on_device; duration=183.1
                Return one-line JSON only:
                {"context":"","intent":"","answer":"","tools":[],"escalate":false,"realtime_verdict":"","confidence":0.0}
                """,
                512
            )
        ]

        var rows: [[String: Any]] = []
        for (name, prompt, maxTokens) in variants {
            await resetCaches()
            let started = Date()
            do {
                let result = try await runTextOnlyPrompt(
                    modelPath: modelPath,
                    prompt: prompt,
                    maxNumTokens: maxTokens
                )
                var row: [String: Any] = [
                    "name": name,
                    "status": "complete",
                    "prompt_chars": prompt.count,
                    "max_tokens": maxTokens,
                    "latency_ms": result.totalMilliseconds,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "answer": result.responseText
                ]
                if let metrics = result.liteRTMetrics {
                    row["litert_metrics"] = metrics.payload
                }
                rows.append(row)
            } catch {
                rows.append([
                    "name": name,
                    "status": "failed",
                    "prompt_chars": prompt.count,
                    "max_tokens": maxTokens,
                    "wall_ms": Int(Date().timeIntervalSince(started) * 1000),
                    "error": error.localizedDescription
                ])
            }
            await resetCaches()
        }
        return ["variants": rows]
    }

    private func compactVisualTimeline(
        _ visualTimeline: [IntegratedVisualObservation],
        maxLines: Int
    ) -> [String] {
        let scored = visualTimeline.compactMap { observation -> (Int, String)? in
            let cleaned = observation.responseText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let isEmptyDefault = cleaned.contains("\"objects\":[]")
                && cleaned.contains("\"scene\":\"\"")
                && cleaned.contains("\"screen_or_text\":\"\"")
            var score = isEmptyDefault ? 0 : 1
            if cleaned.localizedCaseInsensitiveContains("screen")
                || cleaned.localizedCaseInsensitiveContains("code")
                || cleaned.localizedCaseInsensitiveContains("text")
                || cleaned.localizedCaseInsensitiveContains("laptop") {
                score += 2
            }
            if cleaned.localizedCaseInsensitiveContains("monitor")
                || cleaned.localizedCaseInsensitiveContains("keyboard")
                || cleaned.localizedCaseInsensitiveContains("workspace") {
                score += 1
            }
            let line = "t=\(String(format: "%.1f", observation.seconds))s \(String(cleaned.prefix(90)))"
            return (score, line)
        }

        let prioritized = scored
            .filter { $0.0 > 0 }
            .sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0 }
            .prefix(maxLines)
            .map(\.1)
        if !prioritized.isEmpty {
            return Array(prioritized)
        }
        return visualTimeline.prefix(maxLines).map { observation in
            let cleaned = observation.responseText
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "t=\(String(format: "%.1f", observation.seconds))s \(String(cleaned.prefix(90)))"
        }
    }

    private func runTextOnlyPrompt(
        modelPath: String,
        prompt: String,
        maxNumTokens: Int
    ) async throws -> LocalModelBenchmarkResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = false
        let conversation = try await conversation(
            for: modelPath,
            visionBackend: nil,
            audioBackend: nil,
            speculativeDecoding: false,
            maxNumTokens: maxNumTokens
        )
        let start = Date()
        let response = try await conversation.sendMessage(Message(prompt))
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = benchmarkMetrics(for: conversation, totalMilliseconds: totalMS)
        let text = response.toString
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: text,
            summary: text,
            compactSummary: "text_only_prompt, \(totalMS)ms",
            liteRTMetrics: metrics
        )
    }

    private func normalizeLiveRouterOutput(_ rawOutput: String) -> (spokenText: String, route: String, fallbackTriggered: Bool, fallbackReason: String, confidence: Double) {
        let cleaned = artemisFirstJSONObjectString(from: rawOutput)
        if let json = artemisJSONDictionary(from: cleaned) {
            let say = (json["say"] as? String)
                ?? (json["answer"] as? String)
                ?? (json["response"] as? String)
                ?? ""
            let route = (json["route"] as? String) ?? "answer"
            let fallbackTriggered = (json["fallback_triggered"] as? Bool) ?? false
            let fallbackReason = (json["fallback_reason"] as? String) ?? "none"
            let confidence = (json["confidence"] as? Double)
                ?? (json["confidence"] as? NSNumber)?.doubleValue
                ?? Double((json["confidence"] as? String) ?? "")
                ?? 0.0
            let spoken = say.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty {
                return (String(spoken.prefix(260)), route, fallbackTriggered, fallbackReason, confidence)
            }
        }
        if let repaired = artemisJSONStringValue(for: "say", in: rawOutput)
            ?? artemisJSONStringValue(for: "answer", in: rawOutput)
            ?? artemisJSONStringValue(for: "response", in: rawOutput) {
            let spoken = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty {
                return (
                    String(spoken.prefix(260)),
                    "repaired_partial_json",
                    true,
                    "router_output_repaired_partial_json",
                    0.45
                )
            }
        }
        return (
            cleaned.isEmpty ? "I did not get a usable local model response." : String(cleaned.prefix(260)),
            "raw_text",
            true,
            "router_output_not_valid_json",
            cleaned.isEmpty ? 0.0 : 0.35
        )
    }

    func runTextSmoke(
        modelPath: String,
        backend: Backend,
        maxNumTokens: Int,
        speculativeDecoding: Bool = false
    ) async throws -> LocalModelBenchmarkResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = speculativeDecoding
        try validateSpeculativeSupport(modelPath: modelPath, speculativeDecoding: speculativeDecoding)
        let conversation = try await conversation(
            for: modelPath,
            backend: backend,
            visionBackend: nil,
            audioBackend: nil,
            speculativeDecoding: speculativeDecoding,
            maxNumTokens: maxNumTokens
        )
        let start = Date()
        let prompt = """
        You are Artemis running a local Gemma text-only smoke test on iPhone.
        Return compact JSON only:
        {"ok":true,"role":"router_reasoner","summary":"","next_test":""}
        Keep every value short.
        """
        let response = try await conversation.sendMessage(Message(prompt))
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = benchmarkMetrics(for: conversation, totalMilliseconds: totalMS)
        let benchmarkSummary = metrics?.summaryLine ?? ""
        let text = response.toString
        let summary = """
        Gemma text-only smoke
        Backend: \(backend.rawValue)
        MTP/speculative decoding: \(speculativeDecoding ? "enabled" : "disabled")
        Max tokens: \(maxNumTokens)
        Total wall time: \(totalMS)ms\(benchmarkSummary)

        \(text)
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: text,
            summary: summary,
            compactSummary: "backend=\(backend.rawValue), mtp=\(speculativeDecoding), max=\(maxNumTokens), \(totalMS)ms",
            liteRTMetrics: metrics
        )
    }

    func runAudioSmoke(
        modelPath: String,
        input: GemmaAudioSmokeInput,
        label: String,
        streaming: Bool
    ) async throws -> LocalModelBenchmarkResult {
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = false
        let conversation = try await conversation(
            for: modelPath,
            visionBackend: nil,
            audioBackend: .cpu(),
            speculativeDecoding: false
        )
        let content: Content
        let inputDescription: String
        switch input {
        case .data(let data):
            content = .audioData(data)
            inputDescription = "audioData bytes=\(data.count)"
        case .file(let path):
            content = .audioFile(path)
            inputDescription = "audioFile path=\(URL(fileURLWithPath: path).lastPathComponent)"
        }

        let prompt = """
        This is an Artemis audio smoke test for the local Gemma E2B LiteRT audio path.
        If the audio input is accepted, reply with compact JSON only:
        {"audio_path_ok":true,"heard":"","notes":""}
        If you cannot infer audio content, still return valid JSON and explain that in notes.
        """
        let message = Message(contents: [content, .text(prompt)])
        let start = Date()
        let text: String
        if streaming {
            var streamed = ""
            for try await chunk in conversation.sendMessageStream(message) {
                streamed += chunk.toString
            }
            text = streamed
        } else {
            let response = try await conversation.sendMessage(message)
            text = response.toString
        }
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let metrics = benchmarkMetrics(for: conversation, totalMilliseconds: totalMS)
        let benchmarkSummary = metrics?.summaryLine ?? ""
        let summary = """
        Gemma direct audio smoke
        Label: \(label)
        Input: \(inputDescription)
        Streaming: \(streaming)
        Total wall time: \(totalMS)ms\(benchmarkSummary)

        \(text)
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: text,
            summary: summary,
            compactSummary: "\(label), streaming=\(streaming), \(totalMS)ms",
            liteRTMetrics: metrics
        )
    }

    private func conversation(
        for modelPath: String,
        backend: Backend = .gpu,
        visionBackend: Backend? = .cpu(),
        audioBackend: Backend? = nil,
        speculativeDecoding: Bool = false,
        maxNumTokens: Int = 1536,
        reuseConversation: Bool = true
    ) async throws -> LiteRTLM.Conversation {
        let visionKey = visionBackend?.rawValue ?? "none"
        let audioKey = audioBackend?.rawValue ?? "none"
        let modelKey = "\(modelPath)|backend=\(backend.rawValue)|vision=\(visionKey)|audio=\(audioKey)|mtp=\(speculativeDecoding)|max=\(maxNumTokens)"
        if modelKey == cachedModelKey, let cachedEngine {
            if reuseConversation, let cachedConversation {
                return cachedConversation
            }
            let conversation = try await makeConversation(for: cachedEngine)
            if reuseConversation {
                cachedConversation = conversation
            }
            return conversation
        }

        resetCaches()

        let config = try LiteRTLM.EngineConfig(
            modelPath: modelPath,
            backend: backend,
            visionBackend: visionBackend,
            audioBackend: audioBackend,
            maxNumTokens: maxNumTokens,
            cacheDir: freshLiteRTCacheDirectory(
                modelPath: modelPath,
                backend: backend,
                visionBackend: visionBackend,
                audioBackend: audioBackend,
                speculativeDecoding: speculativeDecoding
            )
        )
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()
        let conversation = try await makeConversation(for: engine)
        cachedModelPath = modelPath
        cachedModelKey = modelKey
        cachedEngine = engine
        cachedConversation = reuseConversation ? conversation : nil
        return conversation
    }

    private func makeConversation(for engine: LiteRTLM.Engine) async throws -> LiteRTLM.Conversation {
        let sampler = try SamplerConfig(topK: 40, topP: 0.9, temperature: 0.2)
        return try await engine.createConversation(
            with: LiteRTLM.ConversationConfig(
                systemMessage: Message("Artemis."),
                samplerConfig: sampler
            )
        )
    }

    private func benchmarkMetrics(
        for conversation: LiteRTLM.Conversation,
        totalMilliseconds: Int
    ) -> LiteRTBenchmarkMetrics? {
        guard let info = try? conversation.getBenchmarkInfo() else {
            return nil
        }
        return LiteRTBenchmarkMetrics(info: info, totalMilliseconds: totalMilliseconds)
    }

    private func validateSpeculativeSupport(
        modelPath: String,
        speculativeDecoding: Bool
    ) throws {
        guard speculativeDecoding else { return }
        guard let capabilities = Capabilities(modelPath: modelPath) else {
            throw NSError(
                domain: "ArtemisLiteRT",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Could not read LiteRT model capabilities before enabling MTP."]
            )
        }
        guard capabilities.hasSpeculativeDecodingSupport() else {
            throw NSError(
                domain: "ArtemisLiteRT",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Selected LiteRT model does not advertise MTP/speculative decoding support."]
            )
        }
    }

    private func freshLiteRTCacheDirectory(
        modelPath: String,
        backend: Backend,
        visionBackend: Backend?,
        audioBackend: Backend? = nil,
        speculativeDecoding: Bool
    ) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LiteRTBenchCaches", isDirectory: true)
        let modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        let runName = [
            modelName,
            "backend-\(backend.rawValue)",
            "vision-\(visionBackend?.rawValue ?? "none")",
            "audio-\(audioBackend?.rawValue ?? "none")",
            "mtp-\(speculativeDecoding)",
            UUID().uuidString
        ].joined(separator: "-")
        let directory = root.appendingPathComponent(runName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }
}

enum SyntheticWAVAudio {
    static func oneSecondTone() throws -> (url: URL, data: Data) {
        let sampleRate = 16_000
        let durationSeconds = 1
        let sampleCount = sampleRate * durationSeconds
        var pcm = Data()
        pcm.reserveCapacity(sampleCount * 2)
        for index in 0..<sampleCount {
            let seconds = Double(index) / Double(sampleRate)
            let envelope = min(1.0, Double(index) / 1600.0) * min(1.0, Double(sampleCount - index) / 1600.0)
            let sample = Int16(sin(2.0 * .pi * 440.0 * seconds) * 0.18 * envelope * Double(Int16.max))
            appendLE(sample, to: &pcm)
        }

        var wav = Data()
        wav.append(Data("RIFF".utf8))
        appendLE(UInt32(36 + pcm.count), to: &wav)
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        appendLE(UInt32(16), to: &wav)
        appendLE(UInt16(1), to: &wav)
        appendLE(UInt16(1), to: &wav)
        appendLE(UInt32(sampleRate), to: &wav)
        appendLE(UInt32(sampleRate * 2), to: &wav)
        appendLE(UInt16(2), to: &wav)
        appendLE(UInt16(16), to: &wav)
        wav.append(Data("data".utf8))
        appendLE(UInt32(pcm.count), to: &wav)
        wav.append(pcm)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("artemis-audio-smoke-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try wav.write(to: url, options: .atomic)
        return (url, wav)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer in
            data.append(buffer.bindMemory(to: UInt8.self))
        }
    }
}

func runGemmaAudioSmokeLanes(
    gemmaBenchmark: LocalModelBenchmarkService,
    modelPath: String,
    modelName: String,
    audioURL: URL,
    batchID: String
) async -> [[String: Any]] {
    var records: [[String: Any]] = []
    let synthetic: (url: URL, data: Data)
    do {
        synthetic = try SyntheticWAVAudio.oneSecondTone()
    } catch {
        return [[
            "batch_id": batchID,
            "lane_id": "audio_fixture_generation",
            "architecture": "direct_audio_smoke",
            "reasoner_model": modelName,
            "ok": false,
            "error": error.localizedDescription,
            "device": architectureDeviceSnapshot()
        ]]
    }

    let lanes: [(id: String, input: GemmaAudioSmokeInput, streaming: Bool)] = [
        ("audio_generated_wav_file_send", .file(synthetic.url.path), false),
        ("audio_generated_wav_data_send", .data(synthetic.data), false),
        ("audio_generated_wav_file_stream", .file(synthetic.url.path), true),
        ("audio_video_file_send", .file(audioURL.path), false)
    ]

    for lane in lanes {
        await gemmaBenchmark.resetCaches()
        try? await Task.sleep(nanoseconds: 500_000_000)
        let start = Date()
        do {
            let result = try await gemmaBenchmark.runAudioSmoke(
                modelPath: modelPath,
                input: lane.input,
                label: lane.id,
                streaming: lane.streaming
            )
            var record: [String: Any] = [
                "batch_id": batchID,
                "lane_id": lane.id,
                "architecture": "direct_audio_smoke",
                "reasoner_model": modelName,
                "ok": true,
                "streaming": lane.streaming,
                "latency_ms": result.totalMilliseconds,
                "wall_ms": Int(Date().timeIntervalSince(start) * 1000),
                "answer": result.responseText,
                "device": architectureDeviceSnapshot()
            ]
            if let metrics = result.liteRTMetrics {
                record["litert_metrics"] = metrics.payload
            }
            records.append(record)
        } catch {
            records.append([
                "batch_id": batchID,
                "lane_id": lane.id,
                "architecture": "direct_audio_smoke",
                "reasoner_model": modelName,
                "ok": false,
                "streaming": lane.streaming,
                "wall_ms": Int(Date().timeIntervalSince(start) * 1000),
                "error": error.localizedDescription,
                "device": architectureDeviceSnapshot()
            ])
        }
        await gemmaBenchmark.resetCaches()
    }
    return records
}

struct LocalLFMBenchmarkVariant: Sendable {
    let modelName: String
    let shortLabel: String
    let quantization: String

    static let lfm450m = LocalLFMBenchmarkVariant(
        modelName: "LFM2.5-VL-450M",
        shortLabel: "LFM 450M",
        quantization: "Q4_0"
    )

    static let lfm16b = LocalLFMBenchmarkVariant(
        modelName: "LFM2.5-VL-1.6B",
        shortLabel: "LFM 1.6B",
        quantization: "Q4_0"
    )
}

actor LocalLFMBenchmarkService {
    static let integratedReplayPrompt = """
    You are Artemis reviewing one sampled frame from a Meta glasses POV video.
    Describe concrete evidence in this frame for a later reasoning model.
    Return compact JSON only:
    {"scene":"","visible_objects":[],"visible_text":"","people":[],"user_action_or_question_hint":"","important_detail":"","confidence":0.0}
    Do not leave fields empty unless the frame is genuinely blank, dark, or unreadable.
    """

    static let sessionDecodeFramePrompt = """
    You are Artemis decoding one frame from a Meta glasses POV work-session video.
    Return one compact JSON object only, no markdown:
    {"scene":"","objects":[],"screen_or_text":"","user_action":"","debug_relevance":"","confidence":0.0}
    Use coarse labels if blurry. Do not leave scene or objects empty unless the frame is genuinely blank.
    """

    private var cachedModelKey = ""
    private var modelRunner: (any ModelRunner)?

    func resetCaches() {
        cachedModelKey = ""
        modelRunner = nil
    }

    func runVisionProbe(
        imageData: Data,
        variant: LocalLFMBenchmarkVariant,
        prompt: String? = nil
    ) async throws -> LocalModelBenchmarkResult {
        let runner = try await runner(for: variant)
        let start = Date()
        let prompt = prompt ?? """
        Artemis live eyes. Describe only visible evidence from this glasses POV frame.
        Keep fields short. Use coarse labels if blurry. Do not identify people.
        Escalate only for readable text, safety, user action uncertainty, or low confidence.
        JSON only:
        {"scene":"","objects":[],"text":"","action_hint":"","should_escalate":false,"reason":"none","confidence":0.0}
        """
        let imageContent = try ChatMessageContent.Image.fromJPEGData(imageData)
        let message = ChatMessage(
            role: .user,
            content: [imageContent as ChatMessageContent, ChatMessageContent.text(prompt)],
            reasoningContent: nil,
            functionCalls: nil
        )
        let conversation = runner.createConversation(systemPrompt: "You are a concise local wearable vision assistant.")
        var text = ""
        for try await response in conversation.generateResponse(message: message) {
            switch onEnum(of: response) {
            case .chunk(let chunk):
                text.append(chunk.text)
            case .complete:
                break
            default:
                break
            }
        }
        let totalMS = Int(Date().timeIntervalSince(start) * 1000)
        let summary = """
        LFM vision probe
        Runtime: Liquid LEAP
        Model: \(variant.modelName) \(variant.quantization)
        Total wall time: \(totalMS)ms
        JPEG input: \(imageData.count) bytes

        \(text)
        """
        return LocalModelBenchmarkResult(
            totalMilliseconds: totalMS,
            responseText: text,
            summary: summary,
            compactSummary: "\(variant.modelName), \(totalMS)ms, \(imageData.count) bytes"
        )
    }

    private func runner(for variant: LocalLFMBenchmarkVariant) async throws -> any ModelRunner {
        let modelKey = "\(variant.modelName)|\(variant.quantization)"
        if modelKey == cachedModelKey, let modelRunner {
            return modelRunner
        }
        modelRunner = nil
        let runner = try await Leap.shared.load(
            model: variant.modelName,
            quantization: variant.quantization,
            progress: { _, _ in }
        )
        cachedModelKey = modelKey
        modelRunner = runner
        return runner
    }
}

struct OfflineVideoFrame: Sendable {
    let index: Int
    let seconds: Double
    let jpegData: Data
}

struct IntegratedVisualObservation: Sendable {
    let frameIndex: Int
    let seconds: Double
    let latencyMilliseconds: Int
    let responseText: String
}

struct OfflineSpeechChunk: Sendable {
    let startMilliseconds: Int
    let endMilliseconds: Int
    let text: String
    let confidence: Double
    let source: String

    var payload: [String: Any] {
        [
            "start_ms": startMilliseconds,
            "end_ms": endMilliseconds,
            "text": text,
            "confidence": confidence,
            "source": source
        ]
    }
}

struct OfflineSpeechTranscription: Sendable {
    let text: String
    let isOnDevice: Bool
    let chunks: [OfflineSpeechChunk]

    var chunkPayload: [[String: Any]] {
        chunks.map(\.payload)
    }
}

struct OfflineExtractedAudio: Sendable {
    let speechURL: URL
    let modelURL: URL
}

struct OfflineAudioChunk: Sendable {
    let url: URL
    let startMilliseconds: Int
    let endMilliseconds: Int
}

enum OfflineAudioExtractor {
    static func extractAudioAssets(from videoURL: URL) async throws -> OfflineExtractedAudio {
        let speechURL = try await extractM4A(from: videoURL)
        let modelURL: URL
        do {
            modelURL = try await extractWAV(from: videoURL)
        } catch {
            NSLog("[Artemis] WAV extraction failed; falling back to M4A for model audio: \(error)")
            modelURL = speechURL
        }
        return OfflineExtractedAudio(speechURL: speechURL, modelURL: modelURL)
    }

    static func extractM4A(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw NSError(
                domain: "ArtemisOfflineAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Benchmark video has no audio track."]
            )
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "ArtemisOfflineAudio",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create M4A export session."]
            )
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("artemis-replay-audio-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .m4a

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    let error = export.error ?? NSError(
                        domain: "ArtemisOfflineAudio",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Audio export \(export.status.readableName)."]
                    )
                    continuation.resume(throwing: error)
                default:
                    continuation.resume(throwing: NSError(
                        domain: "ArtemisOfflineAudio",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Audio export ended in unexpected state: \(export.status.readableName)."]
                    ))
                }
            }
        }
        return output
    }

    static func durationSeconds(for audioURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        return max(0, CMTimeGetSeconds(duration))
    }

    static func extractM4AChunks(from audioURL: URL, chunkDurationSeconds: Double) async throws -> [OfflineAudioChunk] {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = max(0, CMTimeGetSeconds(duration))
        guard totalSeconds > 0 else { return [] }

        var chunks: [OfflineAudioChunk] = []
        var startSeconds = 0.0
        while startSeconds < totalSeconds {
            let remaining = totalSeconds - startSeconds
            let length = min(chunkDurationSeconds, remaining)
            if length < 0.5 {
                break
            }

            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw NSError(
                    domain: "ArtemisOfflineAudio",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create M4A chunk export session."]
                )
            }

            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("artemis-replay-audio-chunk-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            try? FileManager.default.removeItem(at: output)

            let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
            let durationTime = CMTime(seconds: length, preferredTimescale: 600)
            export.outputURL = output
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(start: startTime, duration: durationTime)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                export.exportAsynchronously {
                    switch export.status {
                    case .completed:
                        continuation.resume()
                    case .failed, .cancelled:
                        let error = export.error ?? NSError(
                            domain: "ArtemisOfflineAudio",
                            code: 14,
                            userInfo: [NSLocalizedDescriptionKey: "Audio chunk export \(export.status.readableName)."]
                        )
                        continuation.resume(throwing: error)
                    default:
                        continuation.resume(throwing: NSError(
                            domain: "ArtemisOfflineAudio",
                            code: 15,
                            userInfo: [NSLocalizedDescriptionKey: "Audio chunk export ended in unexpected state: \(export.status.readableName)."]
                        ))
                    }
                }
            }

            chunks.append(OfflineAudioChunk(
                url: output,
                startMilliseconds: Int((startSeconds * 1000).rounded()),
                endMilliseconds: Int(((startSeconds + length) * 1000).rounded())
            ))
            startSeconds += chunkDurationSeconds
        }
        return chunks
    }

    static func extractWAV(from videoURL: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: videoURL)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = audioTracks.first else {
                throw NSError(
                    domain: "ArtemisOfflineAudio",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Benchmark video has no audio track for WAV export."]
                )
            }

            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("artemis-replay-audio-\(UUID().uuidString)")
                .appendingPathExtension("wav")
            try? FileManager.default.removeItem(at: output)

            let reader = try AVAssetReader(asset: asset)
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else {
                throw NSError(
                    domain: "ArtemisOfflineAudio",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Could not add WAV reader output."]
                )
            }
            reader.add(readerOutput)

            let writer = try AVAssetWriter(outputURL: output, fileType: .wav)
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
            writerInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerInput) else {
                throw NSError(
                    domain: "ArtemisOfflineAudio",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Could not add WAV writer input."]
                )
            }
            writer.add(writerInput)

            guard reader.startReading() else {
                throw reader.error ?? NSError(
                    domain: "ArtemisOfflineAudio",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Could not start WAV reader."]
                )
            }
            guard writer.startWriting() else {
                throw writer.error ?? NSError(
                    domain: "ArtemisOfflineAudio",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Could not start WAV writer."]
                )
            }
            writer.startSession(atSourceTime: .zero)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "artemis.offline.wav.writer")
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                            if !writerInput.append(sampleBuffer) {
                                reader.cancelReading()
                                writerInput.markAsFinished()
                                writer.cancelWriting()
                                continuation.resume(throwing: writer.error ?? NSError(
                                    domain: "ArtemisOfflineAudio",
                                    code: 10,
                                    userInfo: [NSLocalizedDescriptionKey: "WAV writer input append failed."]
                                ))
                                return
                            }
                        } else {
                            writerInput.markAsFinished()
                            writer.finishWriting {
                                if reader.status == .failed {
                                    continuation.resume(throwing: reader.error ?? NSError(
                                        domain: "ArtemisOfflineAudio",
                                        code: 11,
                                        userInfo: [NSLocalizedDescriptionKey: "WAV reader failed."]
                                    ))
                                } else if writer.status == .failed {
                                    continuation.resume(throwing: writer.error ?? NSError(
                                        domain: "ArtemisOfflineAudio",
                                        code: 12,
                                        userInfo: [NSLocalizedDescriptionKey: "WAV writer failed."]
                                    ))
                                } else {
                                    continuation.resume()
                                }
                            }
                            return
                        }
                    }
                }
            }

            return output
        }.value
    }
}

enum OfflineSpeechFileTranscriber {
    private static let chunkThresholdSeconds = 45.0
    private static let chunkDurationSeconds = 25.0

    static func transcribe(url: URL) async throws -> OfflineSpeechTranscription {
        let authorizationStatus = await requestSpeechAuthorization()
        guard authorizationStatus == .authorized else {
            throw NSError(
                domain: "ArtemisOfflineSpeech",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition authorization is \(authorizationStatus.readableName)."]
            )
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw NSError(
                domain: "ArtemisOfflineSpeech",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create en-US speech recognizer."]
            )
        }
        guard recognizer.isAvailable else {
            throw NSError(
                domain: "ArtemisOfflineSpeech",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not currently available."]
            )
        }

        let requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let durationSeconds = (try? await OfflineAudioExtractor.durationSeconds(for: url)) ?? 0
        if durationSeconds > chunkThresholdSeconds {
            let audioChunks = try await OfflineAudioExtractor.extractM4AChunks(
                from: url,
                chunkDurationSeconds: chunkDurationSeconds
            )
            guard !audioChunks.isEmpty else {
                throw NSError(
                    domain: "ArtemisOfflineSpeech",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Could not split long audio into speech chunks."]
                )
            }

            var chunks: [OfflineSpeechChunk] = []
            var textParts: [String] = []
            for audioChunk in audioChunks {
                let chunkTranscription = try await transcribeSingleFile(
                    url: audioChunk.url,
                    recognizer: recognizer,
                    requiresOnDeviceRecognition: requiresOnDeviceRecognition,
                    offsetMilliseconds: audioChunk.startMilliseconds,
                    source: "apple_speech_file_chunk"
                )
                if !chunkTranscription.text.isEmpty {
                    textParts.append(chunkTranscription.text)
                }
                chunks.append(contentsOf: chunkTranscription.chunks)
            }

            let text = textParts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return OfflineSpeechTranscription(
                text: text,
                isOnDevice: requiresOnDeviceRecognition,
                chunks: chunks
            )
        }

        return try await transcribeSingleFile(
            url: url,
            recognizer: recognizer,
            requiresOnDeviceRecognition: requiresOnDeviceRecognition,
            offsetMilliseconds: 0,
            source: "apple_speech_segment"
        )
    }

    private static func transcribeSingleFile(
        url: URL,
        recognizer: SFSpeechRecognizer,
        requiresOnDeviceRecognition: Bool,
        offsetMilliseconds: Int,
        source: String
    ) async throws -> OfflineSpeechTranscription {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if requiresOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let isOnDevice = request.requiresOnDeviceRecognition

        let transcription = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OfflineSpeechTranscription, Error>) in
            var didResume = false
            var latestText = ""
            var latestChunks: [OfflineSpeechChunk] = []
            var task: SFSpeechRecognitionTask?

            func makeTranscription(text: String, chunks: [OfflineSpeechChunk]) -> OfflineSpeechTranscription {
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalChunks: [OfflineSpeechChunk]
                if chunks.isEmpty, !trimmedText.isEmpty {
                    finalChunks = [
                        OfflineSpeechChunk(
                            startMilliseconds: offsetMilliseconds,
                            endMilliseconds: offsetMilliseconds,
                            text: trimmedText,
                            confidence: 0.0,
                            source: "apple_speech_full_text_fallback"
                        )
                    ]
                } else {
                    finalChunks = chunks
                }
                return OfflineSpeechTranscription(text: trimmedText, isOnDevice: isOnDevice, chunks: finalChunks)
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    latestText = result.bestTranscription.formattedString
                    latestChunks = result.bestTranscription.segments.compactMap { segment in
                        let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        let startMS = offsetMilliseconds + max(0, Int((segment.timestamp * 1000).rounded()))
                        let endMS = max(startMS, offsetMilliseconds + Int(((segment.timestamp + segment.duration) * 1000).rounded()))
                        return OfflineSpeechChunk(
                            startMilliseconds: startMS,
                            endMilliseconds: endMS,
                            text: text,
                            confidence: Double(segment.confidence),
                            source: source
                        )
                    }
                    if result.isFinal, !didResume {
                        didResume = true
                        task?.cancel()
                        continuation.resume(returning: makeTranscription(text: latestText, chunks: latestChunks))
                    }
                }
                if let error, !didResume {
                    didResume = true
                    task?.cancel()
                    if latestText.isEmpty {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: makeTranscription(text: latestText, chunks: latestChunks))
                    }
                }
            }
        }

        return transcription
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private extension AVAssetExportSession.Status {
    var readableName: String {
        switch self {
        case .unknown: "unknown"
        case .waiting: "waiting"
        case .exporting: "exporting"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        @unknown default: "unknown_future"
        }
    }
}

private extension SFSpeechRecognizerAuthorizationStatus {
    var readableName: String {
        switch self {
        case .notDetermined: "not_determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown_future"
        }
    }
}

private extension URL {
    var durationSecondsForDisplay: Double? {
        let asset = AVURLAsset(url: self)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

struct BenchmarkVideoTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            BenchmarkVideoTransfer(url: received.file)
        }
    }
}

enum OfflineVideoFrameSampler {
    static func sampleJPEGFrames(
        from url: URL,
        frameCount: Int,
        maxDimension: CGFloat,
        compressionQuality: CGFloat
    ) async throws -> [OfflineVideoFrame] {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let durationSeconds = max(CMTimeGetSeconds(duration), 1)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let count = max(frameCount, 1)
            let step = durationSeconds / Double(count + 1)
            var frames: [OfflineVideoFrame] = []
            frames.reserveCapacity(count)

            for index in 0..<count {
                try Task.checkCancellation()
                let seconds = min(step * Double(index + 1), durationSeconds)
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                let image = UIImage(cgImage: cgImage)
                let size = image.size
                let largestSide = max(size.width, size.height)
                let scale = largestSide > maxDimension ? maxDimension / largestSide : 1
                let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: targetSize)
                let resized = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: targetSize))
                }
                guard let jpegData = resized.jpegData(compressionQuality: compressionQuality) else {
                    throw NSError(
                        domain: "ArtemisOfflineVideo",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to encode sampled frame \(index + 1)."]
                    )
                }
                frames.append(OfflineVideoFrame(index: index, seconds: seconds, jpegData: jpegData))
            }

            return frames
        }.value
    }
}

struct ArtemisDashboard: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = ArtemisSessionModel()
    @State private var showingModelImporter = false
    @State private var showingVideoImporter = false
    @State private var selectedPhotosVideo: PhotosPickerItem?
    @State private var showingLogs = false
    @State private var showingSetup = false
    @State private var showingDiagnostics = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        compactModePicker
                        compactRuntimeStatus

                        if session.latestPreviewImage != nil || session.isRunning {
                            compactPreview
                        }

                        compactConversation
                        compactPrimaryControls
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Jarvis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingLogs = true
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .accessibilityLabel("Logs")

                    Menu {
                        Button {
                            showingSetup = true
                        } label: {
                            Label("Setup", systemImage: "gearshape")
                        }

                        Button {
                            showingDiagnostics = true
                        } label: {
                            Label("Diagnostics", systemImage: "waveform.path.ecg")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .fileImporter(
                isPresented: $showingModelImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        session.importModel(from: url)
                    }
                case .failure(let error):
                    session.modelBenchmarkStatus = "Import failed"
                    session.modelBenchmarkOutput = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $showingVideoImporter,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        session.importBenchmarkVideo(from: url)
                    }
                case .failure(let error):
                    session.modelBenchmarkStatus = "Video import failed"
                    session.modelBenchmarkOutput = error.localizedDescription
                }
            }
            .onAppear {
                session.recordScenePhase(scenePhase)
                session.refreshLocalModels()
                session.refreshBenchmarkVideos()
                session.autoRunOfflineVideoBenchmarkIfPossible()
            }
            .onChange(of: scenePhase) { _, phase in
                session.recordScenePhase(phase)
                if phase == .active {
                    session.refreshLocalModels()
                    session.refreshBenchmarkVideos()
                    session.autoRunOfflineVideoBenchmarkIfPossible()
                }
            }
            .onChange(of: selectedPhotosVideo) { _, item in
                guard let item else { return }
                Task {
                    do {
                        if let transfer = try await item.loadTransferable(type: BenchmarkVideoTransfer.self) {
                            await MainActor.run {
                                session.importBenchmarkVideo(from: transfer.url)
                            }
                        }
                    } catch {
                        await MainActor.run {
                            session.modelBenchmarkStatus = "Video import failed"
                            session.modelBenchmarkOutput = error.localizedDescription
                        }
                    }
                }
            }
            .sheet(isPresented: $showingLogs) {
                logsSheet
            }
            .sheet(isPresented: $showingSetup) {
                setupSheet
            }
            .sheet(isPresented: $showingDiagnostics) {
                diagnosticsSheet
            }
        }
    }

    private var compactModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Brain", selection: Binding(
                get: { session.jarvisBrainMode },
                set: { session.selectJarvisBrainMode($0) }
            )) {
                Text("OFFLINE").tag(JarvisBrainMode.localGemma)
                Text("ONLINE").tag(JarvisBrainMode.codexBridge)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Image(systemName: session.jarvisBrainMode == .localGemma ? "iphone" : "network")
                    .foregroundStyle(session.jarvisBrainMode == .localGemma ? .green : .blue)
                Text(modeDetail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var compactRuntimeStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(runtimeTint.opacity(0.14))
                    Image(systemName: runtimeSystemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(runtimeTint)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(runtimeStateTitle)
                        .font(.title3.weight(.semibold))
                    Text(session.voiceBridgeStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 8)

                if session.hudFirstResponseMS > 0 {
                    Text("\(session.hudFirstResponseMS) ms")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 16) {
                compactStatusItem(
                    title: "Glasses",
                    value: session.connectionState.rawValue,
                    systemImage: "eyeglasses"
                )
                compactStatusItem(
                    title: "Audio",
                    value: compactAudioRoute,
                    systemImage: "headphones"
                )
                compactStatusItem(
                    title: "Battery",
                    value: session.wearableBatteryLabel,
                    systemImage: "battery.50percent"
                )
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var compactConversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label("You", systemImage: "mic")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(session.transcript.isEmpty ? "Waiting for speech" : session.transcript)
                    .foregroundStyle(session.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Label("Jarvis", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(compactResponseText)
                    .foregroundStyle(compactResponseText == "Ready" ? .secondary : .primary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var compactPreview: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(.black)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

            if let image = session.latestPreviewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipped()
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 6) {
                Image(systemName: session.isRunning ? "camera.fill" : "camera")
                Text(session.isRunning ? "LIVE" : "LAST FRAME")
                Spacer()
                Text("f\(session.latestPreviewFrameID)")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.58))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var compactPrimaryControls: some View {
        HStack(spacing: 12) {
            Button {
                session.toggleVoiceBridge()
            } label: {
                Label(
                    session.voiceBridgeEnabled ? "Stop Jarvis" : "Start Jarvis",
                    systemImage: session.voiceBridgeEnabled ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(session.voiceBridgeEnabled ? .red : .green)

            Button {
                session.stopSpeechOutput()
            } label: {
                Image(systemName: "speaker.slash.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("Stop speech")
        }
    }

    private var logsSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.logs.isEmpty {
                        ContentUnavailableView(
                            "No Logs",
                            systemImage: "doc.text",
                            description: Text("Runtime events will appear here.")
                        )
                    } else {
                        ForEach(session.logs, id: \.self) { line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        showingLogs = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        session.clearLogs()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Clear logs")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var setupSheet: some View {
        NavigationStack {
            Form {
                Section("Meta Glasses") {
                    LabeledContent("Registration", value: session.registrationStateLabel)
                    LabeledContent("Connection", value: session.connectionState.rawValue)

                    Button {
                        session.registerWearables()
                    } label: {
                        Label("Register", systemImage: "link.badge.plus")
                    }
                    .disabled(session.isDATRegistered)

                    Button {
                        session.requestCameraPermission()
                    } label: {
                        Label("Camera Permission", systemImage: "camera.badge.ellipsis")
                    }

                    Button {
                        session.isRunning ? session.stopValidation() : session.startValidation()
                    } label: {
                        Label(
                            session.isRunning ? "Stop Camera + HUD" : "Start Camera + HUD",
                            systemImage: session.isRunning ? "stop.circle" : "camera"
                        )
                    }
                    .foregroundStyle(session.isRunning ? .red : .primary)
                }

                Section("Audio") {
                    LabeledContent("Route", value: compactAudioRoute)
                    HStack {
                        Text("Choose output")
                        Spacer()
                        PrivateAudioRoutePicker()
                            .frame(width: 46, height: 36)
                            .accessibilityLabel("Choose audio route")
                    }
                    Button {
                        session.refreshAudioRouteDiagnostics()
                    } label: {
                        Label("Refresh Route", systemImage: "arrow.clockwise")
                    }
                }

                Section("Device Support") {
                    Button {
                        session.openDATGlassesAppUpdate()
                    } label: {
                        Label("Open DAT App", systemImage: "apps.iphone")
                    }
                    Button {
                        session.openFirmwareUpdate()
                    } label: {
                        Label("Check Firmware", systemImage: "gear.badge")
                    }
                    Button(role: .destructive) {
                        session.unregisterWearables()
                    } label: {
                        Label("Unregister", systemImage: "link.badge.minus")
                    }
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showingSetup = false
                    }
                }
            }
        }
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusGrid
                    powerTestPanel
                    previewPanel
                    controls
                    observationPanel
                    brainPanel
                    speechPanel
                    modelBenchmarkPanel
                }
                .padding()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showingDiagnostics = false
                    }
                }
            }
        }
    }

    private var modeDetail: String {
        switch session.jarvisBrainMode {
        case .localGemma:
            "Gemma E2B + on-demand LFM vision"
        case .codexBridge:
            "Codex bridge + on-demand LFM vision"
        }
    }

    private var compactResponseText: String {
        if !session.hudBrainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.hudBrainText
        }
        let response = session.lastBrainResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return response.isEmpty ? "Ready" : response
    }

    private var compactAudioRoute: String {
        let summary = session.audioRouteSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return "Unknown" }
        if summary.localizedCaseInsensitiveContains("bose") { return "Bose" }
        if summary.localizedCaseInsensitiveContains("meta")
            || summary.localizedCaseInsensitiveContains("ray-ban") { return "Glasses" }
        if summary.localizedCaseInsensitiveContains("speaker") { return "iPhone" }
        return "Connected"
    }

    private var runtimeStateTitle: String {
        if session.speechOutputStatus.localizedCaseInsensitiveContains("speaking") {
            return "Speaking"
        }
        if session.hudState.localizedCaseInsensitiveContains("thinking")
            || session.hudState.localizedCaseInsensitiveContains("processing") {
            return "Thinking"
        }
        if session.isListening {
            return "Listening"
        }
        return session.voiceBridgeEnabled ? "Ready" : "Stopped"
    }

    private var runtimeSystemImage: String {
        switch runtimeStateTitle {
        case "Speaking": "speaker.wave.2.fill"
        case "Thinking": "brain.head.profile"
        case "Listening": "waveform"
        case "Ready": "checkmark.circle.fill"
        default: "power"
        }
    }

    private var runtimeTint: Color {
        switch runtimeStateTitle {
        case "Speaking": .orange
        case "Thinking": .blue
        case "Listening": .green
        case "Ready": .mint
        default: .secondary
        }
    }

    private func compactStatusItem(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                MetricTile(label: "Mode", value: session.mode.rawValue)
                MetricTile(label: "Wearable", value: session.connectionState.rawValue)
            }
            GridRow {
                MetricTile(label: "Frames", value: "\(session.framesAnalyzed)/\(session.framesReceived)")
                MetricTile(label: "Latency", value: "\(session.endToEndLatencyMS)ms")
            }
            GridRow {
                MetricTile(label: "Inference", value: "\(session.averageInferenceMS)ms")
                MetricTile(label: "Thermal", value: thermalLabel(session.thermalState))
            }
            GridRow {
                MetricTile(label: "DAT", value: session.registrationStateLabel)
                MetricTile(label: "Devices", value: "\(session.deviceDiagnostics.count)")
            }
            GridRow {
                MetricTile(label: "FPS", value: String(format: "%.1f", session.streamFPS))
                MetricTile(label: "Decoded", value: "\(session.decodedFrameImages)")
            }
            GridRow {
                MetricTile(label: "Phone Batt", value: session.batteryLabel)
                MetricTile(label: "Phone Power", value: session.powerModeLabel)
            }
            GridRow {
                MetricTile(label: "Wear Pwr", value: session.wearablePowerModeLabel)
                MetricTile(label: "Wear Therm", value: session.wearableThermalLabel)
            }
            GridRow {
                MetricTile(label: "Wear Batt", value: session.wearableBatteryLabel)
                MetricTile(label: "HUD Pace", value: session.wearablePowerHUDInterval)
            }
            GridRow {
                MetricTile(label: "Power Samples", value: "\(session.wearablePowerSamples.count)")
                MetricTile(label: "Drain", value: session.wearablePowerDrainLabel)
            }
            GridRow {
                MetricTile(label: "Sentinel", value: session.sentinelStatus)
                MetricTile(label: "Escalate", value: session.sentinelEscalationLabel)
            }
            GridRow {
                MetricTile(label: "Brain", value: session.hudBrainLatencyMS > 0 ? "\(session.hudBrainLatencyMS)ms" : session.hudBrainImpl)
                MetricTile(label: "TTS Gen", value: session.hudTTSGenerationMS > 0 ? "\(session.hudTTSGenerationMS)ms" : session.hudTTSVoice)
            }
            GridRow {
                MetricTile(label: "First", value: session.hudFirstResponseMS > 0 ? "\(session.hudFirstResponseMS)ms" : "-")
                MetricTile(label: "Vision", value: session.hudVisionLatencyMS > 0 ? "\(session.hudVisionLatencyMS)ms" : "waiting")
            }
        }
    }

    private var powerTestPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Glasses Power Baseline", systemImage: "battery.50percent")
                    .font(.headline)
                Spacer()
                Text("\(session.wearablePowerSamples.count) samples")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("Test phase", selection: $session.wearablePowerTestPhase) {
                ForEach(WearablePowerTestPhase.allCases) { phase in
                    Text(phase.label).tag(phase)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 10) {
                TextField("Meta battery %", text: $session.wearableBatteryPercentInput)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button("Record") {
                    session.recordWearablePowerCheckpoint()
                }
                .buttonStyle(.borderedProminent)
            }

            Text(session.wearablePowerDrainLabel)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(session.wearablePowerSampleStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live Preview")
                    .font(.headline)
                Spacer()
                Text(session.latestPreviewFrameID == 0 ? "No image" : "Frame \(session.latestPreviewFrameID)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)

                if let image = session.latestPreviewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.title)
                        Text(session.isRunning ? "Waiting for decoded frame" : "Start stream to preview")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        HudChip(
                            title: session.connectionState.rawValue,
                            systemImage: session.connectionState == .streaming ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                            tint: session.connectionState == .streaming ? .green : .orange
                        )
                        HudChip(
                            title: String(format: "%.1f FPS", session.streamFPS),
                            systemImage: "speedometer",
                            tint: .blue
                        )
                        Spacer()
                        HudChip(
                            title: "\(session.decodedFrameImages) decoded",
                            systemImage: "photo.on.rectangle",
                            tint: .purple
                        )
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            HudChip(
                                title: session.mode.rawValue,
                                systemImage: "waveform.path.ecg",
                                tint: .cyan
                            )
                            HudChip(
                                title: session.modelBenchmarkStatus,
                                systemImage: session.selectedModelPath.isEmpty ? "cpu" : "cpu.fill",
                                tint: session.selectedModelPath.isEmpty ? .orange : .green
                            )
                            HudChip(
                                title: session.sentinelEnabled ? "Sentinel \(session.sentinelStatus)" : "Sentinel off",
                                systemImage: session.sentinelEnabled ? "scope" : "scope",
                                tint: session.sentinelEnabled ? .mint : .gray
                            )
                            Spacer()
                        }

                        liveVoiceHud

                        HStack {
                            Button("Ask") {
                                session.askBrain()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Frame") {
                                session.runGemmaLatestFrameVisionProbe()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(session.selectedModelPath.isEmpty || session.latestPreviewImage == nil)

                            Spacer()

                            Text("Frame \(session.latestPreviewFrameID)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.86))
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Validation Controls")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button(session.isDATRegistered ? "Registered" : "Register") {
                        session.registerWearables()
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.isDATRegistered)

                    Button("Unregister") {
                        session.unregisterWearables()
                    }
                    .buttonStyle(.bordered)

                    Button("DAT App") {
                        session.openDATGlassesAppUpdate()
                    }
                    .buttonStyle(.bordered)

                    Button("Firmware") {
                        session.openFirmwareUpdate()
                    }
                    .buttonStyle(.bordered)

                    Button("Camera Perm") {
                        session.requestCameraPermission()
                    }
                    .buttonStyle(.bordered)

                    Button(session.isListening ? "Stop STT" : "Start STT") {
                        session.toggleListening()
                    }
                    .buttonStyle(.bordered)

                    Button("Ask Brain") {
                        session.askBrain()
                    }
                    .buttonStyle(.bordered)

                    Button("Extract") {
                        session.runExtractionPass()
                    }
                    .buttonStyle(.bordered)

                    Button(session.sentinelEnabled ? "Sentinel Off" : "Sentinel On") {
                        session.toggleLiveSentinel()
                    }
                    .buttonStyle(.bordered)
                }
            }

            deviceDiagnosticsPanel
        }
    }

    private var modelBenchmarkPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local Model Bench")
                    .font(.headline)
                Spacer()
                Text(session.modelBenchmarkStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(session.selectedModelName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Text(session.modelStorageSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text("Offline video: \(session.selectedBenchmarkVideoName)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("Import Model") {
                        showingModelImporter = true
                    }
                    .buttonStyle(.bordered)

                    Button("Import Video") {
                        showingVideoImporter = true
                    }
                    .buttonStyle(.bordered)

                    PhotosPicker(selection: $selectedPhotosVideo, matching: .videos) {
                        Text("Pick Phone Video")
                    }
                    .buttonStyle(.bordered)

                    Button("Find Local") {
                        session.refreshLocalModels()
                    }
                    .buttonStyle(.bordered)

                    Button("Gemma Synthetic") {
                        session.runGemmaSyntheticBenchmark()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedModelPath.isEmpty)

                    Button("Gemma Frame") {
                        session.runGemmaLatestFrameVisionProbe()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedModelPath.isEmpty || session.latestPreviewImage == nil)

                    Button("LiteRT Video Bench") {
                        session.runOfflineVideoGemmaBenchmark()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedBenchmarkVideoName == "No video selected")

                    Button("LFM 450M Bench") {
                        session.runOfflineVideoLFMBenchmark(variant: .lfm450m)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedBenchmarkVideoName == "No video selected")

                    Button("LFM 1.6B Bench") {
                        session.runOfflineVideoLFMBenchmark(variant: .lfm16b)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedBenchmarkVideoName == "No video selected")

                    Button("Integrated Replay") {
                        session.runIntegratedReplayBenchmark()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedBenchmarkVideoName == "No video selected" || session.selectedModelPath.isEmpty)

                    Button("Session Decode") {
                        session.runConsciousSessionDecodeBenchmark()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedBenchmarkVideoName == "No video selected" || session.selectedModelPath.isEmpty)

                    Button("Architecture Batch") {
                        session.runArchitectureSearchBatch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedBenchmarkVideoName == "No video selected" || session.selectedModelPath.isEmpty)

                    Button("Stop Video Bench") {
                        session.cancelOfflineVideoBenchmark()
                    }
                    .buttonStyle(.bordered)

                    Button(session.sentinelEnabled ? "Stop Sentinel" : "Live Sentinel") {
                        session.toggleLiveSentinel()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Live Sentinel")
                    .font(.subheadline.weight(.semibold))
                Text("Samples: \(session.sentinelSamples), last: \(session.sentinelLastInferenceMS)ms, escalate: \(session.sentinelEscalationLabel)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(session.sentinelDecision)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(session.modelBenchmarkOutput)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var liveVoiceHud: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HudChip(
                    title: session.liveGoldenModeEnabled ? "live_golden" : session.mode.rawValue,
                    systemImage: "circle.hexagongrid.fill",
                    tint: session.liveGoldenModeEnabled ? .green : .cyan
                )
                HudChip(
                    title: session.isListening ? "STT \(session.speechInputStatus)" : "STT off",
                    systemImage: session.isListening ? "mic.fill" : "mic.slash",
                    tint: session.isListening ? .green : .gray
                )
                HudChip(
                    title: session.speechOutputStatus,
                    systemImage: session.speechOutputStatus.hasPrefix("Speaking") ? "speaker.wave.2.fill" : "speaker",
                    tint: session.speechOutputStatus.hasPrefix("Speaking") ? .orange : .gray
                )
                Spacer()
                Text(session.turnTakingStateLabel)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(session.hudSTTText.isEmpty ? "STT: waiting (\(session.hudSTTFinalizationReason))" : "STT: \(session.hudSTTText) (\(session.hudSTTFinalizationReason))")
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                } icon: {
                    Image(systemName: "quote.bubble")
                }

                Label {
                    Text("Brain: \(session.hudBrainModel) \(session.hudBrainRuntime), \(session.hudBrainLatencyMS)ms")
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                } icon: {
                    Image(systemName: "cpu")
                }

                Label {
                    Text("Generated: \(session.hudBrainText.isEmpty ? session.lastBrainResponse.text : session.hudBrainText)")
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                } icon: {
                    Image(systemName: "sparkles")
                }

                Label {
                    Text("Vision: f\(session.hudVisionFrameID) \(session.hudVisionLatencyMS)ms age \(session.hudVisionAgeMS)ms, \(session.hudVisionSummary)")
                        .lineLimit(2)
                        .minimumScaleFactor(0.68)
                } icon: {
                    Image(systemName: "eye")
                }

                Label {
                    Text("TTS: \(session.hudTTSVoice), gen \(session.hudTTSGenerationMS)ms, \(session.hudTTSText)")
                        .lineLimit(2)
                        .minimumScaleFactor(0.68)
                } icon: {
                    Image(systemName: "speaker.wave.2")
                }

                Label {
                    Text("Latency: first \(session.hudFirstResponseMS)ms, e2e \(session.hudEndToEndMS)ms, state \(session.hudState)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                } icon: {
                    Image(systemName: "timer")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
    }

    private var deviceDiagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DAT Devices")
                .font(.subheadline.weight(.semibold))
            Text(session.datDeviceActionHint)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            ForEach(Array(session.deviceDiagnostics.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var observationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("World State")
                .font(.headline)
            Text(session.lastObservation.scene)
                .font(.title3.weight(.semibold))
            Text("Objects: \(session.lastObservation.objects.joined(separator: ", "))")
            Text("People: \(session.lastObservation.peopleCount)")
            Text("Visible text: \(session.lastObservation.visibleText.isEmpty ? "none" : session.lastObservation.visibleText)")
            Text("Change: \(session.lastObservation.notableChange)")
            ProgressView(value: session.lastObservation.confidence, total: 1) {
                Text("Confidence")
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var brainPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Brain")
                .font(.headline)
            Text(session.lastBrainResponse.text)
            Text(session.lastBrainResponse.shouldSendToDisplay ? "Display payload queued" : "No display payload")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var speechPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voice")
                    .font(.headline)
                Spacer()
                Text(session.voiceBridgeStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Picker("Brain", selection: Binding(
                get: { session.jarvisBrainMode },
                set: { session.selectJarvisBrainMode($0) }
            )) {
                ForEach(JarvisBrainMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Output", selection: $session.selectedSpeechEngine) {
                ForEach([SpeechOutputEngine.kokoroLocal]) { engine in
                    Text(engine.rawValue).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Input")
                        .foregroundStyle(.secondary)
                    Text(session.speechInputStatus)
                        .font(.caption.monospaced())
                }
                GridRow {
                    Text("Output")
                        .foregroundStyle(.secondary)
                    Text(session.speechOutputStatus)
                        .font(.caption.monospaced())
                }
                GridRow {
                    Text("Turn")
                        .foregroundStyle(.secondary)
                    Text(session.turnTakingStateLabel)
                        .font(.caption.monospaced())
                }
                GridRow {
                    Text("Incident")
                        .foregroundStyle(.secondary)
                    Text(session.lastVoiceIncidentID)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Private Route")
                        .font(.caption.weight(.semibold))
                    PrivateAudioRoutePicker()
                        .frame(width: 46, height: 36)
                        .accessibilityLabel("Choose Artemis audio route")
                    Button("Refresh Route") {
                        session.refreshAudioRouteDiagnostics()
                    }
                    .buttonStyle(.bordered)
                }
                Text(session.audioRouteSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.62)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button(session.voiceBridgeEnabled ? "Stop Bridge" : "Voice Bridge") {
                        session.toggleVoiceBridge()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(session.isListening ? "Stop STT" : "Start STT") {
                        session.toggleListening()
                    }
                    .buttonStyle(.bordered)

                    Button("Speak Last") {
                        session.speakLastBrainResponse()
                    }
                    .buttonStyle(.bordered)

                    Button("Retry Private Audio") {
                        session.retryPrivateAudioRouteSpeech()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Stop TTS") {
                        session.stopSpeechOutput()
                    }
                    .buttonStyle(.bordered)

                    Button("Mark Bug") {
                        session.markVoiceIncident(label: "manual_bug")
                    }
                    .buttonStyle(.bordered)

                    Button("False Pause") {
                        session.markVoiceIncident(label: "false_pause")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack {
                TextField("Type fallback prompt", text: $session.voiceDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    session.sendVoiceDraft()
                }
                .buttonStyle(.bordered)
            }

            Text(session.transcript.isEmpty ? "No transcript yet" : session.transcript)
                .foregroundStyle(session.transcript.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    session.clearLogs()
                }
            }

            ForEach(session.logs, id: \.self) { line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }
}

struct HudChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.82), in: Capsule())
    }
}

struct PrivateAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = false
        view.showsRouteButton = true
        view.tintColor = UIColor.systemBlue
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.showsVolumeSlider = false
        uiView.showsRouteButton = true
    }
}

struct MetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
