@preconcurrency import AVFoundation
import Foundation

struct FullDuplexAudioState: Sendable {
    let routeDescription: String
    let sampleRate: Double
    let outputLatency: Double
    let engineRunning: Bool
    let playerPlaying: Bool
    let voiceProcessingEnabled: Bool

    init(
        routeDescription: String,
        sampleRate: Double,
        outputLatency: Double,
        engineRunning: Bool,
        playerPlaying: Bool,
        voiceProcessingEnabled: Bool = false
    ) {
        self.routeDescription = routeDescription
        self.sampleRate = sampleRate
        self.outputLatency = outputLatency
        self.engineRunning = engineRunning
        self.playerPlaying = playerPlaying
        self.voiceProcessingEnabled = voiceProcessingEnabled
    }
}

enum FullDuplexAudioRouteMode: String, Sendable {
    case builtInSpeaker
    case callFreeJarvis
    case adaptiveJarvis
    case metaGlasses
    case phoneMicGlassesOutput
}

enum FullDuplexAudioError: LocalizedError {
    case microphoneNotAuthorized
    case invalidInputFormat
    case bufferCopyFailed
    case playbackConversionFailed(String)
    case speechActivityMonitorUnavailable
    case routeNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneNotAuthorized:
            "Microphone access is not authorized."
        case .invalidInputFormat:
            "The full-duplex microphone format is unavailable."
        case .bufferCopyFailed:
            "The microphone buffer could not be copied for local processing."
        case let .playbackConversionFailed(reason):
            "The TTS audio could not be converted for playback: \(reason)"
        case .speechActivityMonitorUnavailable:
            "Apple voice-processing speech activity monitoring is unavailable."
        case let .routeNotAllowed(reason):
            reason
        }
    }
}

/// Owns the only AVAudioSession and AVAudioEngine in the live voice path.
/// Capture and product TTS playback share Apple's voice-processing graph so the
/// microphone remains armed while acoustic echo cancellation is active.
@MainActor
final class FullDuplexAudioCoordinator {
    typealias CaptureHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: 1
    )!
    private var captureHandler: CaptureHandler?
    private var tapInstalled = false
    private var playbackPausedForSpeechActivity = false
    private let routeMode: FullDuplexAudioRouteMode

    init(routeMode: FullDuplexAudioRouteMode = .builtInSpeaker) {
        self.routeMode = routeMode
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        playerNode.volume = 1
    }

    var isRunning: Bool { engine.isRunning }

    func start(capture: @escaping CaptureHandler) async throws -> FullDuplexAudioState {
        guard await requestMicrophoneAuthorization() else {
            throw FullDuplexAudioError.microphoneNotAuthorized
        }

        captureHandler = capture
        if engine.isRunning {
            return state()
        }

        let session = AVAudioSession.sharedInstance()
        switch routeMode {
        case .builtInSpeaker:
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker]
            )
        case .callFreeJarvis:
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true)
            guard let builtInMic = session.availableInputs?.first(where: {
                $0.portType == .builtInMic
            }) else {
                throw FullDuplexAudioError.routeNotAllowed(
                    "The iPhone microphone is unavailable for call-free Jarvis audio."
                )
            }
            try session.setPreferredInput(builtInMic)
            try session.setActive(true)
            if !session.currentRoute.outputs.contains(where: {
                $0.portType == .bluetoothA2DP
            }) {
                try session.overrideOutputAudioPort(.speaker)
            }
        case .adaptiveJarvis:
            do {
                _ = try ArtemisAudioRoutePolicy.activateAdaptiveJarvisDuplexSession(
                    resetActiveSession: true
                )
            } catch {
                throw FullDuplexAudioError.routeNotAllowed(error.localizedDescription)
            }
        case .metaGlasses:
            do {
                _ = try ArtemisAudioRoutePolicy.activateMetaGlassesDuplexSession(
                    resetActiveSession: true
                )
            } catch {
                throw FullDuplexAudioError.routeNotAllowed(error.localizedDescription)
            }
        case .phoneMicGlassesOutput:
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true)
            guard let builtInMic = session.availableInputs?.first(where: {
                $0.portType == .builtInMic
            }) else {
                throw FullDuplexAudioError.routeNotAllowed(
                    "The iPhone microphone is unavailable for HUD coexistence."
                )
            }
            try session.setPreferredInput(builtInMic)
        }
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.01)
        if routeMode == .builtInSpeaker {
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }
            try session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
        }

        let inputNode = engine.inputNode
        if routeMode != .phoneMicGlassesOutput,
           routeMode != .callFreeJarvis,
           !inputNode.isVoiceProcessingEnabled {
            try inputNode.setVoiceProcessingEnabled(true)
        }
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw FullDuplexAudioError.invalidInputFormat
        }

        if !tapInstalled {
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                guard let copy = Self.copy(buffer) else { return }
                self?.captureHandler?(copy)
            }
            tapInstalled = true
        }

        engine.prepare()
        try engine.start()
        if routeMode == .callFreeJarvis {
            try await Task.sleep(nanoseconds: 200_000_000)
            let hasBuiltInInput = session.currentRoute.inputs.contains {
                $0.portType == .builtInMic
            }
            let hasHFPRoute = session.currentRoute.inputs.contains {
                $0.portType == .bluetoothHFP
            } || session.currentRoute.outputs.contains {
                $0.portType == .bluetoothHFP
            }
            let hasAllowedOutput = session.currentRoute.outputs.contains {
                $0.portType == .bluetoothA2DP
                    || $0.portType == .builtInSpeaker
                    || $0.portType == .builtInReceiver
            }
            guard hasBuiltInInput, !hasHFPRoute, hasAllowedOutput else {
                let route = state().routeDescription
                stop()
                throw FullDuplexAudioError.routeNotAllowed(
                    "Call-free Jarvis requires iPhone mic and forbids Bluetooth HFP. Current route: \(route)"
                )
            }
        }
        if routeMode == .phoneMicGlassesOutput {
            try await Task.sleep(nanoseconds: 200_000_000)
            let hasBuiltInInput = session.currentRoute.inputs.contains {
                $0.portType == .builtInMic
            }
            let hasA2DPOutput = session.currentRoute.outputs.contains {
                $0.portType == .bluetoothA2DP
            }
            guard hasBuiltInInput, hasA2DPOutput else {
                let route = state().routeDescription
                stop()
                throw FullDuplexAudioError.routeNotAllowed(
                    "HUD coexistence requires iPhone mic plus Meta A2DP output. Current route: \(route)"
                )
            }
        }
        if routeMode == .metaGlasses {
            let outputEndpoints = session.currentRoute.outputs.map {
                ArtemisAudioRouteEndpoint(
                    portType: $0.portType.rawValue,
                    portName: $0.portName
                )
            }
            let decision = ArtemisAudioRoutePolicy.metaGlassesOnly.decision(for: outputEndpoints)
            guard decision.isAllowed else {
                let route = state().routeDescription
                stop()
                throw FullDuplexAudioError.routeNotAllowed(
                    "\(decision.reason) Full-duplex route after engine start: \(route)"
                )
            }
        }
        if routeMode == .adaptiveJarvis {
            let evaluation = adaptiveRouteEvaluation()
            guard evaluation.currentOutputTarget == evaluation.desired.target else {
                let route = state().routeDescription
                stop()
                throw FullDuplexAudioError.routeNotAllowed(
                    "Adaptive Jarvis route changed during engine startup. Desired \(evaluation.desired.target.rawValue), active \(evaluation.currentOutputTarget.rawValue). Current route: \(route)"
                )
            }
        }
        return state()
    }

    var usesAdaptiveRouting: Bool { routeMode == .adaptiveJarvis }

    func adaptiveRouteEvaluation() -> ArtemisAdaptiveAudioEvaluation {
        let session = AVAudioSession.sharedInstance()
        return ArtemisAdaptiveAudioRoutePolicy.jarvis.evaluation(
            outputs: session.currentRoute.outputs.map {
                ArtemisAudioRouteEndpoint(
                    portType: $0.portType.rawValue,
                    portName: $0.portName
                )
            },
            availableInputs: (session.availableInputs ?? []).map {
                ArtemisAudioRouteEndpoint(
                    portType: $0.portType.rawValue,
                    portName: $0.portName
                )
            }
        )
    }

    func stop() {
        endPlaybackSpeechActivityDetection()
        stopPlayback()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        engine.reset()
        captureHandler = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func schedule(
        _ buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void
    ) throws -> FullDuplexAudioState {
        let scheduledBuffer = try playbackBuffer(from: buffer)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        playerNode.scheduleBuffer(
            scheduledBuffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { _ in completion() }
        if !playerNode.isPlaying, !playbackPausedForSpeechActivity { playerNode.play() }
        return state()
    }

    private func playbackBuffer(from source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard source.format != playbackFormat else { return source }
        guard source.frameLength > 0 else {
            throw FullDuplexAudioError.playbackConversionFailed("the source buffer is empty")
        }
        guard let converter = AVAudioConverter(from: source.format, to: playbackFormat) else {
            throw FullDuplexAudioError.playbackConversionFailed(
                "unsupported \(Int(source.format.sampleRate)) Hz to 44100 Hz conversion"
            )
        }

        let ratio = playbackFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 32
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: capacity
        ) else {
            throw FullDuplexAudioError.playbackConversionFailed(
                "the destination buffer could not be allocated"
            )
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error || converted.frameLength == 0 {
            throw FullDuplexAudioError.playbackConversionFailed(
                conversionError?.localizedDescription ?? "the converter produced no audio"
            )
        }
        return converted
    }

    func stopPlayback() {
        playbackPausedForSpeechActivity = false
        playerNode.stop()
        playerNode.reset()
    }

    func pausePlayback() {
        guard playerNode.isPlaying else { return }
        playbackPausedForSpeechActivity = true
        playerNode.pause()
    }

    func resumePlayback() {
        guard playbackPausedForSpeechActivity else { return }
        playbackPausedForSpeechActivity = false
        guard engine.isRunning, !playerNode.isPlaying else { return }
        playerNode.play()
    }

    /// During assistant playback, mute the processed uplink while Apple's voice
    /// processing unit continues listening for local speech. This prevents the
    /// speaker reference from reaching ASR while preserving fast barge-in.
    func beginPlaybackSpeechActivityDetection(
        onSpeechStarted: @escaping @Sendable () -> Void
    ) throws {
        let inputNode = engine.inputNode
        guard inputNode.isVoiceProcessingEnabled else {
            throw FullDuplexAudioError.speechActivityMonitorUnavailable
        }
        endPlaybackSpeechActivityDetection()
        let installed = inputNode.setMutedSpeechActivityEventListener { [weak self] event in
            guard event.rawValue == 0 else { return }
            Task { @MainActor in
                guard let self else { return }
                self.endPlaybackSpeechActivityDetection()
                onSpeechStarted()
            }
        }
        guard installed else {
            throw FullDuplexAudioError.speechActivityMonitorUnavailable
        }
        inputNode.isVoiceProcessingInputMuted = true
    }

    func endPlaybackSpeechActivityDetection() {
        let inputNode = engine.inputNode
        if inputNode.isVoiceProcessingEnabled {
            inputNode.isVoiceProcessingInputMuted = false
            _ = inputNode.setMutedSpeechActivityEventListener(nil)
        }
    }

    func state() -> FullDuplexAudioState {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        return FullDuplexAudioState(
            routeDescription: "inputs=[\(inputs.joined(separator: ","))] outputs=[\(outputs.joined(separator: ","))]",
            sampleRate: session.sampleRate,
            outputLatency: session.outputLatency,
            engineRunning: engine.isRunning,
            playerPlaying: playerNode.isPlaying,
            voiceProcessingEnabled: engine.inputNode.isVoiceProcessingEnabled
        )
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else { return nil }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }
}
