@preconcurrency import AVFoundation
import CoreML
import CryptoKit
import Darwin
import FluidAudio
import Foundation

private struct SupertonicGeneratedAudio: Sendable {
    let samples: [Float]
    let generationMilliseconds: Int
    let modelLoadMilliseconds: Int
    let normalizedText: String
    let seed: UInt64
    let peakResidentMemoryBytes: UInt64
    let thermalState: String
}

private actor SupertonicVoiceRuntime {
    private let contract = VoiceContractV1.canonical
    private var manager: Supertonic3Manager?
    private var style: Supertonic3VoiceStyle?
    func synthesize(text: String, seed: UInt64) async throws -> SupertonicGeneratedAudio {
        let normalizedText = try contract.normalize(text)
        let prepared = try await prepare()
        let started = ContinuousClock.now
        let result = try await prepared.manager.synthesize(
            text: normalizedText,
            language: contract.language,
            style: prepared.style,
            totalSteps: contract.denoisingSteps,
            speed: contract.speed,
            silenceDuration: contract.chunking.interChunkSilenceSeconds,
            seed: seed
        )
        let elapsed = ContinuousClock.now - started
        return SupertonicGeneratedAudio(
            samples: result.samples,
            generationMilliseconds: Self.milliseconds(elapsed),
            modelLoadMilliseconds: prepared.modelLoadMilliseconds,
            normalizedText: normalizedText,
            seed: seed,
            peakResidentMemoryBytes: Self.peakResidentMemoryBytes(),
            thermalState: Self.thermalStateDescription()
        )
    }

    private func prepare() async throws -> (
        manager: Supertonic3Manager,
        style: Supertonic3VoiceStyle,
        modelLoadMilliseconds: Int
    ) {
        if let manager, let style {
            return (manager, style, 0)
        }

        let started = ContinuousClock.now
        let cacheDirectory = try Self.cacheDirectory()
        let repositoryDirectory: URL
        let styleURL: URL
        do {
            repositoryDirectory = try await Supertonic3ResourceDownloader.ensureModels(
                directory: cacheDirectory,
                veVariant: "ane-int4"
            )
            styleURL = try await Supertonic3ResourceDownloader.downloadVoiceStyle(
                .f1,
                directory: cacheDirectory
            )
        } catch {
            throw VoiceContractErrorV1(
                code: .modelAssetsMissing,
                detail: error.localizedDescription
            )
        }

        try Self.verifySHA256(
            repositoryDirectory.appendingPathComponent("manifest.json"),
            expected: contract.runtime.modelManifestSHA256,
            code: .modelProvenanceMismatch
        )
        try Self.verifySHA256(
            styleURL,
            expected: contract.runtime.voiceStyleSHA256,
            code: .voiceStyleMismatch
        )

        let loadedStyle: Supertonic3VoiceStyle
        do {
            loadedStyle = try Supertonic3VoiceStyle.load(from: styleURL)
        } catch {
            throw VoiceContractErrorV1(
                code: .voiceStyleMismatch,
                detail: error.localizedDescription
            )
        }

        let loadedManager = Supertonic3Manager(
            directory: cacheDirectory,
            computeUnits: .cpuAndNeuralEngine,
            vectorEstimator: .aneBucketed(.int4)
        )
        do {
            try await loadedManager.initialize()
        } catch {
            throw VoiceContractErrorV1(
                code: .runtimeUnavailable,
                detail: error.localizedDescription
            )
        }

        let loadMilliseconds = Self.milliseconds(ContinuousClock.now - started)
        manager = loadedManager
        style = loadedStyle
        return (loadedManager, loadedStyle, loadMilliseconds)
    }

    private static func cacheDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appendingPathComponent("ArtemisVoice", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func verifySHA256(
        _ url: URL,
        expected: String,
        code: VoiceFailureCodeV1
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceContractErrorV1(code: code, detail: "Missing \(url.lastPathComponent).")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expected else {
            throw VoiceContractErrorV1(
                code: code,
                detail: "\(url.lastPathComponent) expected \(expected), found \(digest)."
            )
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    private static func peakResidentMemoryBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss))
    }

    private static func thermalStateDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
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
}

@MainActor
final class SupertonicSpeechOutput: VoiceSpeechOutput {
    private final class StreamingPlaybackSession {
        let id: UUID
        let playbackID: UUID
        let lifecycleToken: ArtemisTTSLifecycleToken
        let audioSessionState: FullDuplexAudioState
        let onChunkGenerated: @MainActor (Int, Int, String, VoiceSpeechPlaybackStats) -> Void
        let onPipelineState: @MainActor (VoiceStreamingPipelineSnapshot) -> Void
        let completion: @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
        let lookaheadPolicy: ArtemisTTSLookaheadPolicy
        var chunks: [String] = []
        var generated: [Int: Result<SupertonicGeneratedAudio, Error>] = [:]
        var nextGenerationIndex = 0
        var nextScheduleIndex = 0
        var completedClipCount = 0
        var generationInFlight = false
        var inputFinished = false
        var didComplete = false
        var lastCompletedStats: VoiceSpeechPlaybackStats?
        var lastPipelineSnapshot: VoiceStreamingPipelineSnapshot?

        init(
            id: UUID,
            playbackID: UUID,
            lifecycleToken: ArtemisTTSLifecycleToken,
            audioSessionState: FullDuplexAudioState,
            contract: VoiceContractV1,
            onChunkGenerated: @escaping @MainActor (
                Int, Int, String, VoiceSpeechPlaybackStats
            ) -> Void,
            onPipelineState: @escaping @MainActor (VoiceStreamingPipelineSnapshot) -> Void,
            completion: @escaping @MainActor (
                Result<VoiceSpeechPlaybackStats, Error>
            ) -> Void
        ) {
            self.id = id
            self.playbackID = playbackID
            self.lifecycleToken = lifecycleToken
            self.audioSessionState = audioSessionState
            self.lookaheadPolicy = ArtemisTTSLookaheadPolicy(
                maxOutstandingClips: contract.chunking.maximumOutstandingClips
            )
            self.onChunkGenerated = onChunkGenerated
            self.onPipelineState = onPipelineState
            self.completion = completion
        }
    }

    private let contract = VoiceContractV1.canonical
    private let runtime = SupertonicVoiceRuntime()
    private let audio: FullDuplexAudioCoordinator
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: 1
    )!
    private let diagnosticAudioCaptureEnabled: Bool
    private var playbackID = UUID()
    private var ttsLifecycle = ArtemisTTSLifecycle()
    private var streamingSession: StreamingPlaybackSession?

    init(audio: FullDuplexAudioCoordinator) {
        self.audio = audio
        diagnosticAudioCaptureEnabled =
            ProcessInfo.processInfo.arguments.contains("--capture-tts-audio")
            || UserDefaults.standard.bool(forKey: "artemis.captureTTSAudio")
    }

    var selectedVoiceName: String {
        contract.runtime.voiceID
    }

    func speak(
        _ text: String,
        onGenerated: @escaping @MainActor (VoiceSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
    ) {
        speakQueued(
            [text],
            onChunkGenerated: { _, _, _, stats in onGenerated(stats) },
            completion: completion
        )
    }

    func speakQueued(
        _ chunks: [String],
        onChunkGenerated: @escaping @MainActor (
            Int, Int, String, VoiceSpeechPlaybackStats
        ) -> Void,
        completion: @escaping @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
    ) {
        let sessionID = beginStreaming(
            onChunkGenerated: onChunkGenerated,
            onPipelineState: { _ in },
            completion: completion
        )
        appendStreaming(chunks, sessionID: sessionID)
        finishStreaming(sessionID: sessionID)
    }

    func beginStreaming(
        onChunkGenerated: @escaping @MainActor (
            Int, Int, String, VoiceSpeechPlaybackStats
        ) -> Void,
        onPipelineState: @escaping @MainActor (VoiceStreamingPipelineSnapshot) -> Void,
        completion: @escaping @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
    ) -> UUID {
        stop()
        let lifecycleToken = ttsLifecycle.beginPlayback(reason: "voice_contract_stream")
        let currentPlaybackID = UUID()
        playbackID = currentPlaybackID
        let session = StreamingPlaybackSession(
            id: UUID(),
            playbackID: currentPlaybackID,
            lifecycleToken: lifecycleToken,
            audioSessionState: audio.state(),
            contract: contract,
            onChunkGenerated: onChunkGenerated,
            onPipelineState: onPipelineState,
            completion: completion
        )
        streamingSession = session
        reportStreamingPipeline(session, event: VoiceLifecycleEventV1.requestAccepted.rawValue)
        return session.id
    }

    func appendStreaming(_ chunks: [String], sessionID: UUID) {
        guard let session = streamingSession,
              session.id == sessionID,
              !session.inputFinished,
              !session.didComplete else { return }
        do {
            for chunk in chunks {
                session.chunks.append(contentsOf: try contract.chunks(for: chunk))
            }
        } catch {
            finishStreamingSession(session, result: .failure(error))
            return
        }
        reportStreamingPipeline(session, event: VoiceLifecycleEventV1.chunkQueued.rawValue)
        pumpStreamingGeneration(session)
    }

    func finishStreaming(sessionID: UUID) {
        guard let session = streamingSession,
              session.id == sessionID,
              !session.didComplete else { return }
        session.inputFinished = true
        reportStreamingPipeline(session, event: "input_finished")
        pumpStreamingGeneration(session)
        completeStreamingIfReady(session)
        if session.chunks.isEmpty {
            finishStreamingSession(
                session,
                result: .failure(
                    VoiceContractErrorV1(
                        code: .emptyText,
                        detail: "Streaming input produced no speakable chunks."
                    )
                )
            )
        }
    }

    func generateOnly(
        _ text: String,
        completion: @escaping @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
    ) {
        Task {
            do {
                let normalized = try contract.normalize(text)
                let generated = try await runtime.synthesize(
                    text: normalized,
                    seed: contract.seed(forChunkIndex: 0)
                )
                completion(.success(stats(
                    for: generated,
                    audioSessionState: FullDuplexAudioState(
                        routeDescription: "generation-only",
                        sampleRate: Double(contract.sampleFormat.sampleRate),
                        outputLatency: 0,
                        engineRunning: false,
                        playerPlaying: false
                    ),
                    lifecycleToken: ArtemisTTSLifecycleToken(
                        epoch: 0,
                        generation: 0,
                        reason: "generation_only"
                    ),
                    diagnosticWavPath: nil
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop() {
        if let session = streamingSession, !session.didComplete {
            reportStreamingPipeline(
                session,
                event: VoiceLifecycleEventV1.cancelled.rawValue
            )
        }
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
            return
        }

        let index = session.nextGenerationIndex
        let chunk = session.chunks[index]
        let seed = contract.seed(forChunkIndex: index)
        session.nextGenerationIndex += 1
        session.generationInFlight = true
        reportStreamingPipeline(session, event: VoiceLifecycleEventV1.synthesisStarted.rawValue)

        Task { [weak self] in
            guard let self else { return }
            let result: Result<SupertonicGeneratedAudio, Error>
            do {
                result = .success(try await runtime.synthesize(text: chunk, seed: seed))
            } catch {
                result = .failure(error)
            }
            guard self.streamingSession === session,
                  self.playbackID == session.playbackID,
                  self.ttsLifecycle.acceptGenerated(session.lifecycleToken) == .accept else {
                self.reportStreamingPipeline(
                    session,
                    event: VoiceLifecycleEventV1.staleAudioRejected.rawValue
                )
                return
            }
            session.generationInFlight = false
            session.generated[index] = result
            self.reportStreamingPipeline(session, event: "synthesis_completed")
            self.scheduleReadyStreamingClips(session)
            self.pumpStreamingGeneration(session)
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
                schedule(
                    generated,
                    session: session,
                    index: index
                )
                reportStreamingPipeline(session, event: "clip_scheduled")
            case let .failure(error):
                finishStreamingSession(session, result: .failure(error))
                return
            }
        }
    }

    private func schedule(
        _ generated: SupertonicGeneratedAudio,
        session: StreamingPlaybackSession,
        index: Int
    ) {
        let prepared: (AVAudioPCMBuffer, VoiceSpeechPlaybackStats)
        do {
            prepared = try makePlaybackBuffer(
                from: generated,
                audioSessionState: session.audioSessionState,
                lifecycleToken: session.lifecycleToken
            )
        } catch {
            finishStreamingSession(session, result: .failure(error))
            return
        }
        let (buffer, initialStats) = prepared
        var playbackStats: VoiceSpeechPlaybackStats?
        do {
            let state = try audio.schedule(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.streamingSession === session,
                          self.playbackID == session.playbackID,
                          self.ttsLifecycle.acceptGenerated(session.lifecycleToken) == .accept else {
                        self.reportStreamingPipeline(
                            session,
                            event: VoiceLifecycleEventV1.staleAudioRejected.rawValue
                        )
                        return
                    }
                    session.completedClipCount += 1
                    session.lastCompletedStats = playbackStats ?? initialStats
                    self.reportStreamingPipeline(
                        session,
                        event: VoiceLifecycleEventV1.chunkFinished.rawValue
                    )
                    self.scheduleReadyStreamingClips(session)
                    self.pumpStreamingGeneration(session)
                    self.completeStreamingIfReady(session)
                }
            }
            let scheduled = initialStats.withPlaybackState(
                "scheduled_after_player_play",
                audioEngineRunning: state.engineRunning,
                playerNodePlaying: state.playerPlaying,
                scheduledBufferFrames: Int(buffer.frameLength)
            )
            playbackStats = scheduled
            if index == 0 {
                reportStreamingPipeline(
                    session,
                    event: VoiceLifecycleEventV1.firstAudioScheduled.rawValue
                )
                reportStreamingPipeline(
                    session,
                    event: VoiceLifecycleEventV1.playbackStarted.rawValue
                )
            }
            session.onChunkGenerated(index, session.chunks.count, session.chunks[index], scheduled)
        } catch {
            finishStreamingSession(session, result: .failure(error))
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
        result: Result<VoiceSpeechPlaybackStats, Error>
    ) {
        guard streamingSession === session, !session.didComplete else { return }
        session.didComplete = true
        reportStreamingPipeline(
            session,
            event: result.isSuccess
                ? VoiceLifecycleEventV1.playbackFinished.rawValue
                : VoiceLifecycleEventV1.failed.rawValue
        )
        if !result.isSuccess {
            ttsLifecycle.cancelThroughCurrent(reason: "stream_failed")
            audio.stopPlayback()
        }
        streamingSession = nil
        session.completion(result)
    }

    private func reportStreamingPipeline(
        _ session: StreamingPlaybackSession,
        event: String
    ) {
        let snapshot = VoiceStreamingPipelineSnapshot(
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

    private func makePlaybackBuffer(
        from generated: SupertonicGeneratedAudio,
        audioSessionState: FullDuplexAudioState,
        lifecycleToken: ArtemisTTSLifecycleToken
    ) throws -> (AVAudioPCMBuffer, VoiceSpeechPlaybackStats) {
        guard !generated.samples.isEmpty else {
            throw VoiceContractErrorV1(code: .emptyAudio, detail: "Supertonic generated no samples.")
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(generated.samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw VoiceContractErrorV1(
                code: .playbackBufferFailed,
                detail: "Could not allocate a mono Float32 playback buffer."
            )
        }
        buffer.frameLength = buffer.frameCapacity

        let rawPeak = generated.samples.reduce(Float(0)) { max($0, abs($1)) }
        let gain = rawPeak > 0
            ? min(1, contract.sampleFormat.playbackHeadroomPeak / rawPeak)
            : 1
        let fadeCount = min(
            generated.samples.count / 2,
            contract.sampleFormat.sampleRate
                * contract.sampleFormat.edgeFadeMilliseconds / 1_000
        )
        var peak: Float = 0
        var clipped = 0
        for index in generated.samples.indices {
            let fadeIn = fadeCount > 0 && index < fadeCount
                ? Float(index) / Float(fadeCount)
                : 1
            let fromEnd = generated.samples.count - index - 1
            let fadeOut = fadeCount > 0 && fromEnd < fadeCount
                ? Float(fromEnd) / Float(fadeCount)
                : 1
            let scaled = generated.samples[index] * gain * min(fadeIn, fadeOut)
            if abs(scaled) > 1 { clipped += 1 }
            let sample = max(-1, min(1, scaled))
            channel[index] = sample
            peak = max(peak, abs(sample))
        }

        let diagnosticWavPath = writeDiagnosticWAV(buffer: buffer)
        return (
            buffer,
            VoiceSpeechPlaybackStats(
                engineID: contract.runtime.engine,
                voiceName: contract.runtime.voiceID,
                generationMilliseconds: generated.generationMilliseconds,
                modelLoadMilliseconds: generated.modelLoadMilliseconds,
                audioDurationSeconds: Double(generated.samples.count)
                    / Double(contract.sampleFormat.sampleRate),
                peakSample: peak,
                clippedSampleCount: clipped,
                rawPeakSample: rawPeak,
                normalizationGain: gain,
                audioRoute: audioSessionState.routeDescription,
                sessionSampleRate: audioSessionState.sampleRate,
                outputLatencySeconds: audioSessionState.outputLatency,
                sampleMode: "supertonic3_coreml_float32_normalized",
                diagnosticWavPath: diagnosticWavPath,
                playbackState: "buffer_prepared",
                audioEngineRunning: false,
                playerNodePlaying: false,
                scheduledBufferFrames: Int(buffer.frameLength),
                lifecycleEpoch: lifecycleToken.epoch,
                lifecycleGeneration: lifecycleToken.generation,
                normalizedText: generated.normalizedText,
                seed: generated.seed,
                seedPolicy: contract.seed.policyID,
                runtimeRevision: contract.runtime.adapterRevision,
                modelManifestSHA256: contract.runtime.modelManifestSHA256,
                voiceStyleSHA256: contract.runtime.voiceStyleSHA256,
                peakResidentMemoryBytes: generated.peakResidentMemoryBytes,
                thermalState: generated.thermalState
            )
        )
    }

    private func stats(
        for generated: SupertonicGeneratedAudio,
        audioSessionState: FullDuplexAudioState,
        lifecycleToken: ArtemisTTSLifecycleToken,
        diagnosticWavPath: String?
    ) -> VoiceSpeechPlaybackStats {
        let rawPeak = generated.samples.reduce(Float(0)) { max($0, abs($1)) }
        let gain = rawPeak > 0
            ? min(1, contract.sampleFormat.playbackHeadroomPeak / rawPeak)
            : 1
        return VoiceSpeechPlaybackStats(
            engineID: contract.runtime.engine,
            voiceName: contract.runtime.voiceID,
            generationMilliseconds: generated.generationMilliseconds,
            modelLoadMilliseconds: generated.modelLoadMilliseconds,
            audioDurationSeconds: Double(generated.samples.count)
                / Double(contract.sampleFormat.sampleRate),
            peakSample: rawPeak * gain,
            clippedSampleCount: 0,
            rawPeakSample: rawPeak,
            normalizationGain: gain,
            audioRoute: audioSessionState.routeDescription,
            sessionSampleRate: audioSessionState.sampleRate,
            outputLatencySeconds: audioSessionState.outputLatency,
            sampleMode: "supertonic3_coreml_generation_only",
            diagnosticWavPath: diagnosticWavPath,
            playbackState: "generation_only",
            audioEngineRunning: false,
            playerNodePlaying: false,
            scheduledBufferFrames: 0,
            lifecycleEpoch: lifecycleToken.epoch,
            lifecycleGeneration: lifecycleToken.generation,
            normalizedText: generated.normalizedText,
            seed: generated.seed,
            seedPolicy: contract.seed.policyID,
            runtimeRevision: contract.runtime.adapterRevision,
            modelManifestSHA256: contract.runtime.modelManifestSHA256,
            voiceStyleSHA256: contract.runtime.voiceStyleSHA256,
            peakResidentMemoryBytes: generated.peakResidentMemoryBytes,
            thermalState: generated.thermalState
        )
    }

    private func writeDiagnosticWAV(buffer: AVAudioPCMBuffer) -> String? {
        guard diagnosticAudioCaptureEnabled else { return nil }
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = documents
                .appendingPathComponent("ArtemisEvidence", isDirectory: true)
                .appendingPathComponent("audio", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(
                "supertonic-\(UUID().uuidString).wav"
            )
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
            return url.path
        } catch {
            return nil
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
