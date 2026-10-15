import AVFoundation
import Foundation
import OnnxRuntimeBindings

struct JarvisVoiceKokoroSpeechPlaybackStats: Sendable {
    let voiceName: String
    let generationMilliseconds: Int
    let audioDurationSeconds: Double
    let peakSample: Float
    let clippedSampleCount: Int
    let rawPeakSample: Float
    let normalizationGain: Float
    let audioRoute: String
    let sessionSampleRate: Double
    let outputLatencySeconds: Double
    let sampleMode: String
    let diagnosticWavPath: String?
    let playbackState: String
    let audioEngineRunning: Bool
    let playerNodePlaying: Bool
    let scheduledBufferFrames: Int
    let lifecycleEpoch: Int
    let lifecycleGeneration: Int
    let g2pFrontendID: String
    let normalizedText: String
    let phonemes: String
    let phonemeTokenCount: Int

    var realTimeFactor: Double {
        guard generationMilliseconds > 0 else { return 0 }
        return audioDurationSeconds / (Double(generationMilliseconds) / 1000.0)
    }

    var routeProof: String {
        JarvisVoiceTTSRouteProof(
            routeDescription: audioRoute,
            playbackState: playbackState,
            audioEngineRunning: audioEngineRunning,
            playerNodePlaying: playerNodePlaying,
            scheduledBufferFrames: scheduledBufferFrames
        ).audibilityProof
    }

    func withPlaybackState(
        _ playbackState: String,
        audioEngineRunning: Bool,
        playerNodePlaying: Bool,
        scheduledBufferFrames: Int
    ) -> JarvisVoiceKokoroSpeechPlaybackStats {
        JarvisVoiceKokoroSpeechPlaybackStats(
            voiceName: voiceName,
            generationMilliseconds: generationMilliseconds,
            audioDurationSeconds: audioDurationSeconds,
            peakSample: peakSample,
            clippedSampleCount: clippedSampleCount,
            rawPeakSample: rawPeakSample,
            normalizationGain: normalizationGain,
            audioRoute: audioRoute,
            sessionSampleRate: sessionSampleRate,
            outputLatencySeconds: outputLatencySeconds,
            sampleMode: sampleMode,
            diagnosticWavPath: diagnosticWavPath,
            playbackState: playbackState,
            audioEngineRunning: audioEngineRunning,
            playerNodePlaying: playerNodePlaying,
            scheduledBufferFrames: scheduledBufferFrames,
            lifecycleEpoch: lifecycleEpoch,
            lifecycleGeneration: lifecycleGeneration,
            g2pFrontendID: g2pFrontendID,
            normalizedText: normalizedText,
            phonemes: phonemes,
            phonemeTokenCount: phonemeTokenCount
        )
    }
}

struct JarvisVoiceKokoroStreamingPipelineSnapshot: Equatable, Sendable {
    let event: String
    let acceptedTextChunks: Int
    let nextGenerationIndex: Int
    let generatedReadyCount: Int
    let scheduledOutstandingCount: Int
    let completedClipCount: Int
    let generationInFlight: Bool
    let inputFinished: Bool
    let maxOutstandingClips: Int
}

enum JarvisVoiceKokoroAudioRouteMode: Sendable {
    case phoneDuplex
}

enum JarvisVoiceKokoroAudioSampleMode: Sendable {
    case officialRawCopy
    case normalized
}

enum JarvisVoiceKokoroSpeechOutputError: LocalizedError {
    case missingModel
    case missingConfig
    case missingVoice(String)
    case runtimeUnavailable(String)
    case phonemeTokenizationFailed
    case emptyAudio
    case bufferCreationFailed
    case channelDataUnavailable
    case audioRouteNotAllowed(String)
    case streamingChunkFailed(index: Int, text: String, message: String)

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Kokoro ONNX model asset kokoro.onnx is missing from the app bundle."
        case .missingConfig:
            return "Kokoro ONNX config asset kokoro-config.json is missing from the app bundle."
        case let .missingVoice(voice):
            return "Kokoro ONNX voice style \(voice).bin is missing from the app bundle."
        case let .runtimeUnavailable(message):
            return "Kokoro ONNX runtime is unavailable: \(message)"
        case .phonemeTokenizationFailed:
            return "Kokoro ONNX could not phonemize/tokenize the requested text."
        case .emptyAudio:
            return "Kokoro ONNX generated no audio samples."
        case .bufferCreationFailed:
            return "Could not allocate an audio buffer for Kokoro output."
        case .channelDataUnavailable:
            return "Could not access the Kokoro audio buffer channel data."
        case let .audioRouteNotAllowed(reason):
            return reason
        case let .streamingChunkFailed(index, text, message):
            return "Kokoro streaming chunk \(index) failed for \(String(text.prefix(240))): \(message)"
        }
    }
}

@MainActor
final class JarvisVoiceKokoroSpeechOutput {
    private final class StreamingPlaybackSession {
        let id: UUID
        let playbackID: UUID
        let lifecycleToken: JarvisVoiceTTSLifecycleToken
        let audioSessionState: FullDuplexAudioState
        let onChunkGenerated: @MainActor (Int, Int, String, JarvisVoiceKokoroSpeechPlaybackStats) -> Void
        let onPipelineState: @MainActor (JarvisVoiceKokoroStreamingPipelineSnapshot) -> Void
        let completion: @MainActor (Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>) -> Void
        let lookaheadPolicy = JarvisVoiceTTSLookaheadPolicy(maxOutstandingClips: 3)
        var chunks: [String] = []
        var generated: [Int: Result<KokoroGeneratedAudio, Error>] = [:]
        var nextGenerationIndex = 0
        var nextScheduleIndex = 0
        var completedClipCount = 0
        var generationInFlight = false
        var inputFinished = false
        var didComplete = false
        var lastCompletedStats: JarvisVoiceKokoroSpeechPlaybackStats?
        var lastPipelineSnapshot: JarvisVoiceKokoroStreamingPipelineSnapshot?

        init(
            id: UUID,
            playbackID: UUID,
            lifecycleToken: JarvisVoiceTTSLifecycleToken,
            audioSessionState: FullDuplexAudioState,
            onChunkGenerated: @escaping @MainActor (Int, Int, String, JarvisVoiceKokoroSpeechPlaybackStats) -> Void,
            onPipelineState: @escaping @MainActor (JarvisVoiceKokoroStreamingPipelineSnapshot) -> Void,
            completion: @escaping @MainActor (Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>) -> Void
        ) {
            self.id = id
            self.playbackID = playbackID
            self.lifecycleToken = lifecycleToken
            self.audioSessionState = audioSessionState
            self.onChunkGenerated = onChunkGenerated
            self.onPipelineState = onPipelineState
            self.completion = completion
        }
    }

    private let preferredVoiceName = "af_bella"
    private let audio: FullDuplexAudioCoordinator
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(JarvisVoiceKokoroONNXEngine.sampleRate),
        channels: 1
    )!
    private let generationQueue = DispatchQueue(label: "artemis.kokoro.onnx.generation", qos: .userInitiated)
    private var playbackID = UUID()
    private var ttsLifecycle = JarvisVoiceTTSLifecycle()
    private var sampleMode: JarvisVoiceKokoroAudioSampleMode = .normalized
    private var engineResult: Result<JarvisVoiceKokoroONNXEngine, Error>?
    private var streamingSession: StreamingPlaybackSession?

    init(audio: FullDuplexAudioCoordinator) {
        self.audio = audio
    }

    var isAvailable: Bool {
        switch loadEngine() {
        case .success:
            return true
        case let .failure(error):
            print("[JarvisVoiceKokoroSpeechOutput] ONNX unavailable: \(error.localizedDescription)")
            return false
        }
    }

    var selectedVoiceName: String {
        preferredVoiceName
    }

    func setSampleMode(_ sampleMode: JarvisVoiceKokoroAudioSampleMode) {
        self.sampleMode = sampleMode
    }

    #if os(iOS)
    @discardableResult
    func prepareAudioSessionForPlayback() throws -> String {
        audio.state().routeDescription
    }
    #endif

    func speak(
        _ text: String,
        onGenerated: @escaping @MainActor (JarvisVoiceKokoroSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>) -> Void
    ) {
        speakQueued(
            [text],
            onChunkGenerated: { _, _, _, stats in
                onGenerated(stats)
            },
            completion: completion
        )
    }

    func speakQueued(
        _ chunks: [String],
        onChunkGenerated: @escaping @MainActor (Int, Int, String, JarvisVoiceKokoroSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>) -> Void
    ) {
        stop()
        let lifecycleToken = ttsLifecycle.beginPlayback(reason: "speak_queued")
        let currentPlaybackID = UUID()
        playbackID = currentPlaybackID

        guard !chunks.isEmpty else {
            completion(.failure(JarvisVoiceKokoroSpeechOutputError.emptyAudio))
            return
        }

        let engineResult = loadEngine()
        guard case let .success(engine) = engineResult else {
            if case let .failure(error) = engineResult {
                completion(.failure(error))
            }
            return
        }

        let audioSessionState = audio.state()

        var generatedClips: [Int: Result<KokoroGeneratedAudio, Error>] = [:]
        var clipWaiters: [Int: [(Result<KokoroGeneratedAudio, Error>) -> Void]] = [:]
        var requestedClipIndices = Set<Int>()

        func requestClip(at index: Int) {
            guard chunks.indices.contains(index),
                  !requestedClipIndices.contains(index),
                  playbackID == currentPlaybackID else {
                return
            }
            requestedClipIndices.insert(index)
            let chunk = chunks[index]

            generationQueue.async { [weak self] in
                let result: Result<KokoroGeneratedAudio, Error>
                do {
                    result = .success(try engine.generate(text: chunk))
                } catch {
                    result = .failure(error)
                }

                Task { @MainActor [weak self] in
                    guard let self,
                          self.playbackID == currentPlaybackID,
                          self.ttsLifecycle.acceptGenerated(lifecycleToken) == .accept else {
                        return
                    }
                    if let waiters = clipWaiters.removeValue(forKey: index) {
                        waiters.forEach { $0(result) }
                    } else {
                        generatedClips[index] = result
                    }
                }
            }
        }

        func receiveClip(
            at index: Int,
            _ receive: @escaping (Result<KokoroGeneratedAudio, Error>) -> Void
        ) {
            guard playbackID == currentPlaybackID,
                  ttsLifecycle.acceptGenerated(lifecycleToken) == .accept else { return }
            if let result = generatedClips.removeValue(forKey: index) {
                receive(result)
                return
            }

            clipWaiters[index, default: []].append(receive)
            requestClip(at: index)
        }

        var completedClipCount = 0
        var lastCompletedStats: JarvisVoiceKokoroSpeechPlaybackStats?
        var didComplete = false

        func finish(_ result: Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>) {
            guard !didComplete else { return }
            didComplete = true
            completion(result)
        }

        func scheduleIndex(_ index: Int) {
            guard playbackID == currentPlaybackID,
                  ttsLifecycle.acceptGenerated(lifecycleToken) == .accept else { return }
            guard chunks.indices.contains(index) else {
                return
            }

            requestClip(at: index + 1)
            receiveClip(at: index) { [weak self] result in
                guard let self,
                      self.playbackID == currentPlaybackID,
                      self.ttsLifecycle.acceptGenerated(lifecycleToken) == .accept else {
                    return
                }
                switch result {
                case let .success(generated):
                    self.scheduleQueuedClip(
                        generated,
                        audioSessionState: audioSessionState,
                        playbackID: currentPlaybackID,
                        lifecycleToken: lifecycleToken,
                        onGenerated: { stats in
                            onChunkGenerated(index, chunks.count, chunks[index], stats)
                        },
                        completion: { result in
                            guard self.playbackID == currentPlaybackID,
                                  self.ttsLifecycle.acceptGenerated(lifecycleToken) == .accept else {
                                return
                            }
                            switch result {
                            case let .success(stats):
                                completedClipCount += 1
                                lastCompletedStats = stats
                                if completedClipCount == chunks.count {
                                    finish(.success(stats))
                                }
                            case let .failure(error):
                                finish(.failure(error))
                            }
                        }
                    )
                    scheduleIndex(index + 1)
                case let .failure(error):
                    finish(.failure(error))
                }
            }
        }

        requestClip(at: 0)
        scheduleIndex(0)

        if chunks.isEmpty, let lastCompletedStats {
            finish(.success(lastCompletedStats))
        }
    }

    /// Starts an appendable synthesis session. New text may be appended while
    /// earlier audio is playing, allowing one-chunk lookahead across streamed
    /// model sentences without restarting the audio player or lifecycle epoch.
    @discardableResult
    func beginStreaming(
        onChunkGenerated: @escaping @MainActor (Int, Int, String, JarvisVoiceKokoroSpeechPlaybackStats) -> Void,
        onPipelineState: @escaping @MainActor (JarvisVoiceKokoroStreamingPipelineSnapshot) -> Void = { _ in },
        completion: @escaping @MainActor (Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>) -> Void
    ) -> UUID {
        stop()
        let lifecycleToken = ttsLifecycle.beginPlayback(reason: "streaming_speech")
        let sessionID = UUID()
        let currentPlaybackID = UUID()
        playbackID = currentPlaybackID
        let session = StreamingPlaybackSession(
            id: sessionID,
            playbackID: currentPlaybackID,
            lifecycleToken: lifecycleToken,
            audioSessionState: audio.state(),
            onChunkGenerated: onChunkGenerated,
            onPipelineState: onPipelineState,
            completion: completion
        )
        streamingSession = session
        reportStreamingPipeline(session, event: "session_started")
        return sessionID
    }

    func appendStreaming(_ chunks: [String], sessionID: UUID) {
        guard let session = streamingSession,
              session.id == sessionID,
              !session.inputFinished,
              !session.didComplete else { return }
        let speakable = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { JarvisVoiceTTSChunker.containsSpeakableContent($0) }
        guard !speakable.isEmpty else { return }
        session.chunks.append(contentsOf: speakable)
        reportStreamingPipeline(session, event: "text_appended")
        pumpStreamingGeneration(session)
    }

    func finishStreaming(sessionID: UUID) {
        guard let session = streamingSession,
              session.id == sessionID,
              !session.didComplete else { return }
        session.inputFinished = true
        reportStreamingPipeline(session, event: "input_finished")
        if session.chunks.isEmpty {
            finishStreamingSession(session, result: .failure(JarvisVoiceKokoroSpeechOutputError.emptyAudio))
            return
        }
        pumpStreamingGeneration(session)
        completeStreamingIfReady(session)
    }

    func generateOnly(
        _ text: String,
        completion: @escaping @MainActor (Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>) -> Void
    ) {
        let engineResult = loadEngine()
        guard case let .success(engine) = engineResult else {
            if case let .failure(error) = engineResult {
                completion(.failure(error))
            }
            return
        }

        generationQueue.async {
            let result: Result<KokoroGeneratedAudio, Error>
            do {
                result = .success(try engine.generate(text: text))
            } catch {
                result = .failure(error)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case let .success(generated):
                    completion(
                        .success(
                            self.stats(
                                for: generated,
                                audioSessionState: FullDuplexAudioState(
                                    routeDescription: "generation-only",
                                    sampleRate: Double(JarvisVoiceKokoroONNXEngine.sampleRate),
                                    outputLatency: 0,
                                    engineRunning: false,
                                    playerPlaying: false,
                                    voiceProcessingEnabled: false
                                ),
                                diagnosticWavPath: nil
                            )
                        )
                    )
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    func stop() {
        ttsLifecycle.cancelThroughCurrent(reason: "stop")
        playbackID = UUID()
        streamingSession = nil
        audio.stopPlayback()
    }

    private func pumpStreamingGeneration(_ session: StreamingPlaybackSession) {
        guard streamingSession === session,
              playbackID == session.playbackID,
              ttsLifecycle.acceptGenerated(session.lifecycleToken) == .accept,
              !session.didComplete,
              !session.generationInFlight,
              session.nextGenerationIndex < session.chunks.count else {
            completeStreamingIfReady(session)
            return
        }

        guard session.lookaheadPolicy.canGenerate(
            scheduledClipCount: session.nextScheduleIndex,
            completedClipCount: session.completedClipCount,
            generatedReadyCount: session.generated.count,
            generationInFlight: session.generationInFlight
        ) else {
            reportStreamingPipeline(session, event: "lookahead_backpressure")
            completeStreamingIfReady(session)
            return
        }

        let engineResult = loadEngine()
        guard case let .success(engine) = engineResult else {
            if case let .failure(error) = engineResult {
                finishStreamingSession(session, result: .failure(error))
            }
            return
        }

        let index = session.nextGenerationIndex
        let chunk = session.chunks[index]
        session.nextGenerationIndex += 1
        session.generationInFlight = true
        reportStreamingPipeline(session, event: "generation_started")

        generationQueue.async { [weak self] in
            let result: Result<KokoroGeneratedAudio, Error>
            do {
                result = .success(try engine.generate(text: chunk))
            } catch {
                result = .failure(JarvisVoiceKokoroSpeechOutputError.streamingChunkFailed(
                    index: index,
                    text: chunk,
                    message: error.localizedDescription
                ))
            }

            Task { @MainActor [weak self] in
                guard let self,
                      self.streamingSession === session,
                      self.playbackID == session.playbackID,
                      self.ttsLifecycle.acceptGenerated(session.lifecycleToken) == .accept else {
                    return
                }
                session.generationInFlight = false
                session.generated[index] = result
                self.reportStreamingPipeline(session, event: "generation_completed")
                self.scheduleReadyStreamingClips(session)
                self.pumpStreamingGeneration(session)
            }
        }
    }

    private func scheduleReadyStreamingClips(_ session: StreamingPlaybackSession) {
        guard streamingSession === session,
              playbackID == session.playbackID,
              ttsLifecycle.acceptGenerated(session.lifecycleToken) == .accept else { return }

        while session.lookaheadPolicy.canSchedule(
            scheduledClipCount: session.nextScheduleIndex,
            completedClipCount: session.completedClipCount
        ), let result = session.generated.removeValue(forKey: session.nextScheduleIndex) {
            let index = session.nextScheduleIndex
            session.nextScheduleIndex += 1
            switch result {
            case let .success(generated):
                scheduleQueuedClip(
                    generated,
                    audioSessionState: session.audioSessionState,
                    playbackID: session.playbackID,
                    lifecycleToken: session.lifecycleToken,
                    onGenerated: { stats in
                        session.onChunkGenerated(index, session.chunks.count, session.chunks[index], stats)
                    },
                    completion: { [weak self] result in
                        guard let self,
                              self.streamingSession === session,
                              self.playbackID == session.playbackID,
                              self.ttsLifecycle.acceptGenerated(session.lifecycleToken) == .accept else { return }
                        switch result {
                        case let .success(stats):
                            session.completedClipCount += 1
                            session.lastCompletedStats = stats
                            self.reportStreamingPipeline(session, event: "playback_completed")
                            self.scheduleReadyStreamingClips(session)
                            self.pumpStreamingGeneration(session)
                            self.completeStreamingIfReady(session)
                        case let .failure(error):
                            self.finishStreamingSession(session, result: .failure(error))
                        }
                    }
                )
                reportStreamingPipeline(session, event: "clip_scheduled")
            case let .failure(error):
                finishStreamingSession(session, result: .failure(error))
                return
            }
        }
    }

    private func completeStreamingIfReady(_ session: StreamingPlaybackSession) {
        guard streamingSession === session,
              session.inputFinished,
              !session.generationInFlight,
              session.nextGenerationIndex == session.chunks.count,
              session.nextScheduleIndex == session.chunks.count,
              session.completedClipCount == session.chunks.count,
              let stats = session.lastCompletedStats else { return }
        finishStreamingSession(session, result: .success(stats))
    }

    private func finishStreamingSession(
        _ session: StreamingPlaybackSession,
        result: Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>
    ) {
        guard streamingSession === session, !session.didComplete else { return }
        session.didComplete = true
        reportStreamingPipeline(session, event: "session_completed")
        streamingSession = nil
        session.completion(result)
    }

    private func reportStreamingPipeline(
        _ session: StreamingPlaybackSession,
        event: String
    ) {
        let snapshot = JarvisVoiceKokoroStreamingPipelineSnapshot(
            event: event,
            acceptedTextChunks: session.chunks.count,
            nextGenerationIndex: session.nextGenerationIndex,
            generatedReadyCount: session.generated.count,
            scheduledOutstandingCount: max(
                0,
                session.nextScheduleIndex - session.completedClipCount
            ),
            completedClipCount: session.completedClipCount,
            generationInFlight: session.generationInFlight,
            inputFinished: session.inputFinished,
            maxOutstandingClips: session.lookaheadPolicy.maxOutstandingClips
        )
        guard snapshot != session.lastPipelineSnapshot else { return }
        session.lastPipelineSnapshot = snapshot
        session.onPipelineState(snapshot)
    }

    private func loadEngine() -> Result<JarvisVoiceKokoroONNXEngine, Error> {
        if let engineResult {
            return engineResult
        }

        let loaded: Result<JarvisVoiceKokoroONNXEngine, Error>
        do {
            loaded = .success(try JarvisVoiceKokoroONNXEngine(voiceName: preferredVoiceName))
        } catch {
            loaded = .failure(error)
        }
        engineResult = loaded
        return loaded
    }

    private func scheduleQueuedClip(
        _ generated: KokoroGeneratedAudio,
        audioSessionState: FullDuplexAudioState,
        playbackID currentPlaybackID: UUID,
        lifecycleToken: JarvisVoiceTTSLifecycleToken,
        onGenerated: @escaping @MainActor (JarvisVoiceKokoroSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<JarvisVoiceKokoroSpeechPlaybackStats, Error>) -> Void
    ) {
        guard ttsLifecycle.acceptGenerated(lifecycleToken) == .accept else { return }
        let bufferAndStats: (AVAudioPCMBuffer, JarvisVoiceKokoroSpeechPlaybackStats)
        do {
            bufferAndStats = try makePlaybackBuffer(
                from: generated,
                audioSessionState: audioSessionState,
                lifecycleToken: lifecycleToken
            )
        } catch {
            completion(.failure(error))
            return
        }

        let (buffer, stats) = bufferAndStats
        var playbackStats: JarvisVoiceKokoroSpeechPlaybackStats?

        do {
            let scheduledState = try audio.schedule(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.playbackID == currentPlaybackID,
                          self.ttsLifecycle.acceptGenerated(lifecycleToken) == .accept else { return }
                    completion(.success(playbackStats ?? stats))
                }
            }
            let scheduledStats = stats.withPlaybackState(
                "scheduled_after_player_play",
                audioEngineRunning: scheduledState.engineRunning,
                playerNodePlaying: scheduledState.playerPlaying,
                scheduledBufferFrames: Int(buffer.frameLength)
            )
            playbackStats = scheduledStats
            onGenerated(scheduledStats)
        } catch {
            completion(.failure(error))
        }
    }

    private func makePlaybackBuffer(
        from generated: KokoroGeneratedAudio,
        audioSessionState: FullDuplexAudioState,
        lifecycleToken: JarvisVoiceTTSLifecycleToken
    ) throws -> (AVAudioPCMBuffer, JarvisVoiceKokoroSpeechPlaybackStats) {
        let audio = generated.samples
        guard !audio.isEmpty else {
            throw JarvisVoiceKokoroSpeechOutputError.emptyAudio
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(audio.count)
        ) else {
            throw JarvisVoiceKokoroSpeechOutputError.bufferCreationFailed
        }
        buffer.frameLength = buffer.frameCapacity
        guard let channel = buffer.floatChannelData?[0] else {
            throw JarvisVoiceKokoroSpeechOutputError.channelDataUnavailable
        }

        let rawPeakSample = audio.reduce(Float(0)) { max($0, abs($1)) }
        let normalizationGain = sampleMode == .normalized && rawPeakSample > 0 ? min(1, 0.85 / rawPeakSample) : 1
        var peakSample: Float = 0
        var clippedSampleCount = 0
        switch sampleMode {
        case .officialRawCopy:
            audio.withUnsafeBufferPointer { sourceBuffer in
                if let baseAddress = sourceBuffer.baseAddress {
                    UnsafeMutableRawPointer(channel)
                        .copyMemory(
                            from: UnsafeRawPointer(baseAddress),
                            byteCount: sourceBuffer.count * MemoryLayout<Float>.stride
                        )
                }
            }
            for sample in audio {
                peakSample = max(peakSample, abs(sample))
                if sample > 1 || sample < -1 {
                    clippedSampleCount += 1
                }
            }
        case .normalized:
            let fadeSampleCount = min(audio.count / 2, Int(JarvisVoiceKokoroONNXEngine.sampleRate / 200))
            for index in audio.indices {
                let fadeIn = fadeSampleCount > 0 && index < fadeSampleCount
                    ? Float(index) / Float(fadeSampleCount)
                    : 1
                let samplesFromEnd = audio.count - index - 1
                let fadeOut = fadeSampleCount > 0 && samplesFromEnd < fadeSampleCount
                    ? Float(samplesFromEnd) / Float(fadeSampleCount)
                    : 1
                let sample = audio[index] * normalizationGain * min(fadeIn, fadeOut)
                let clampedSample = max(-1, min(1, sample))
                peakSample = max(peakSample, abs(clampedSample))
                if sample > 1 || sample < -1 {
                    clippedSampleCount += 1
                }
                channel[index] = clampedSample
            }
        }

        let diagnosticWavPath = writeDiagnosticWAV(buffer: buffer)
        let stats = JarvisVoiceKokoroSpeechPlaybackStats(
            voiceName: preferredVoiceName,
            generationMilliseconds: generated.generationMilliseconds,
            audioDurationSeconds: Double(audio.count) / Double(JarvisVoiceKokoroONNXEngine.sampleRate),
            peakSample: peakSample,
            clippedSampleCount: clippedSampleCount,
            rawPeakSample: rawPeakSample,
            normalizationGain: normalizationGain,
            audioRoute: audioSessionState.routeDescription,
            sessionSampleRate: audioSessionState.sampleRate,
            outputLatencySeconds: audioSessionState.outputLatency,
            sampleMode: "onnxruntime_\(sampleMode.description)",
            diagnosticWavPath: diagnosticWavPath,
            playbackState: "buffer_prepared",
            audioEngineRunning: false,
            playerNodePlaying: false,
            scheduledBufferFrames: Int(buffer.frameLength),
            lifecycleEpoch: lifecycleToken.epoch,
            lifecycleGeneration: lifecycleToken.generation,
            g2pFrontendID: generated.g2pFrontendID,
            normalizedText: generated.normalizedText,
            phonemes: generated.phonemes,
            phonemeTokenCount: generated.tokenCount
        )
        return (buffer, stats)
    }

    private func stats(
        for generated: KokoroGeneratedAudio,
        audioSessionState: FullDuplexAudioState,
        diagnosticWavPath: String?
    ) -> JarvisVoiceKokoroSpeechPlaybackStats {
        let audio = generated.samples
        let rawPeakSample = audio.reduce(Float(0)) { max($0, abs($1)) }
        let normalizationGain = rawPeakSample > 0 ? min(1, 0.85 / rawPeakSample) : 1
        var peakSample: Float = 0
        var clippedSampleCount = 0
        for sample in audio {
            let normalizedSample = sample * normalizationGain
            peakSample = max(peakSample, abs(normalizedSample))
            if normalizedSample > 1 || normalizedSample < -1 {
                clippedSampleCount += 1
            }
        }

        return JarvisVoiceKokoroSpeechPlaybackStats(
            voiceName: preferredVoiceName,
            generationMilliseconds: generated.generationMilliseconds,
            audioDurationSeconds: Double(audio.count) / Double(JarvisVoiceKokoroONNXEngine.sampleRate),
            peakSample: peakSample,
            clippedSampleCount: clippedSampleCount,
            rawPeakSample: rawPeakSample,
            normalizationGain: normalizationGain,
            audioRoute: audioSessionState.routeDescription,
            sessionSampleRate: audioSessionState.sampleRate,
            outputLatencySeconds: audioSessionState.outputLatency,
            sampleMode: "onnxruntime_generation_only",
            diagnosticWavPath: diagnosticWavPath,
            playbackState: "generation_only",
            audioEngineRunning: false,
            playerNodePlaying: false,
            scheduledBufferFrames: 0,
            lifecycleEpoch: 0,
            lifecycleGeneration: 0,
            g2pFrontendID: generated.g2pFrontendID,
            normalizedText: generated.normalizedText,
            phonemes: generated.phonemes,
            phonemeTokenCount: generated.tokenCount
        )
    }

    private func writeDiagnosticWAV(buffer: AVAudioPCMBuffer) -> String? {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let url = documents.appendingPathComponent("kokoro-last.wav")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try file.write(from: buffer)
            return "Documents/kokoro-last.wav"
        } catch {
            print("[JarvisVoiceKokoroSpeechOutput] failed to write diagnostic wav: \(error.localizedDescription)")
            return nil
        }
    }

}

private final class JarvisVoiceKokoroONNXEngine {
    static let sampleRate = 24_000

    private let voiceName: String
    private let tokenizer: JarvisVoiceKokoroONNXTokenizer
    private let voiceStyle: JarvisVoiceKokoroONNXVoiceStyle
    private let g2pFrontend: any JarvisVoiceKokoroG2PFrontend
    private let env: ORTEnv
    private let session: ORTSession

    init(
        voiceName: String,
        g2pFrontend: (any JarvisVoiceKokoroG2PFrontend)? = nil
    ) throws {
        self.voiceName = voiceName
        self.g2pFrontend = try g2pFrontend ?? EspeakNGG2PFrontend()
        guard let modelURL = Bundle.main.url(forResource: "kokoro", withExtension: "onnx") else {
            throw JarvisVoiceKokoroSpeechOutputError.missingModel
        }
        guard let configURL = Bundle.main.url(forResource: "kokoro-config", withExtension: "json") else {
            throw JarvisVoiceKokoroSpeechOutputError.missingConfig
        }
        guard let voiceURL = Bundle.main.url(forResource: voiceName, withExtension: "bin") else {
            throw JarvisVoiceKokoroSpeechOutputError.missingVoice(voiceName)
        }

        let config = try JarvisVoiceKokoroONNXConfig.load(from: configURL)
        self.tokenizer = JarvisVoiceKokoroONNXTokenizer(vocab: config.vocab)
        self.voiceStyle = try JarvisVoiceKokoroONNXVoiceStyle(data: Data(contentsOf: voiceURL))
        self.env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)

        let options = try ORTSessionOptions()
        try options.setLogSeverityLevel(ORTLoggingLevel.warning)
        try options.setIntraOpNumThreads(1)
        try? options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        try options.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
        do {
            let xnnpackOptions = ORTXnnpackExecutionProviderOptions()
            xnnpackOptions.intra_op_num_threads = 2
            try options.appendXnnpackExecutionProvider(with: xnnpackOptions)
        } catch {
            print("[JarvisVoiceKokoroONNXEngine] XNNPACK unavailable; continuing with default ORT provider: \(error.localizedDescription)")
        }

        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        let inputNames = (try? session.inputNames()) ?? []
        let outputNames = (try? session.outputNames()) ?? []
        print("[JarvisVoiceKokoroONNXEngine] loaded voice=\(voiceName) inputs=\(inputNames) outputs=\(outputNames)")
    }

    func generate(text: String) throws -> KokoroGeneratedAudio {
        let started = Date()
        let g2p = try g2pFrontend.phonemize(text: text)
        let tokenized = try tokenizer.tokenize(phonemes: g2p.phonemes)
        let style = voiceStyle.vector(forPaddedTokenCount: tokenized.paddedTokenIDs.count)

        let inputIDsValue = try Self.makeInt64Tensor(
            tokenized.paddedTokenIDs,
            shape: [1, NSNumber(value: tokenized.paddedTokenIDs.count)]
        )
        let styleValue = try Self.makeFloatTensor(style, shape: [1, 256])
        let speedValue = try Self.makeFloatTensor([1.0], shape: [1])

        let outputs = try session.run(
            withInputs: [
                "input_ids": inputIDsValue,
                "ref_s": styleValue,
                "speed": speedValue,
            ],
            outputNames: Set(["waveform"]),
            runOptions: nil
        )
        guard let waveform = outputs["waveform"] else {
            throw JarvisVoiceKokoroSpeechOutputError.runtimeUnavailable("waveform output was missing")
        }
        let data = try waveform.tensorData()
        let samples = Self.floatArray(from: data)
        guard !samples.isEmpty else {
            throw JarvisVoiceKokoroSpeechOutputError.emptyAudio
        }

        return KokoroGeneratedAudio(
            samples: samples,
            generationMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            normalizedText: g2p.normalizedText,
            g2pFrontendID: g2p.frontendID,
            phonemes: g2p.phonemes,
            tokenCount: tokenized.tokenIDs.count
        )
    }

    private static func makeInt64Tensor(_ values: [Int64], shape: [NSNumber]) throws -> ORTValue {
        let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Int64>.stride)
        return try ORTValue(
            tensorData: data,
            elementType: ORTTensorElementDataType.int64,
            shape: shape
        )
    }

    private static func makeFloatTensor(_ values: [Float], shape: [NSNumber]) throws -> ORTValue {
        let data = NSMutableData(bytes: values, length: values.count * MemoryLayout<Float>.stride)
        return try ORTValue(
            tensorData: data,
            elementType: ORTTensorElementDataType.float,
            shape: shape
        )
    }

    private static func floatArray(from data: NSMutableData) -> [Float] {
        let count = data.length / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        let pointer = data.bytes.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

private struct KokoroGeneratedAudio: Sendable {
    let samples: [Float]
    let generationMilliseconds: Int
    let normalizedText: String
    let g2pFrontendID: String
    let phonemes: String
    let tokenCount: Int
}

private extension JarvisVoiceKokoroAudioSampleMode {
    var description: String {
        switch self {
        case .officialRawCopy:
            return "official_raw_copy"
        case .normalized:
            return "normalized"
        }
    }
}
