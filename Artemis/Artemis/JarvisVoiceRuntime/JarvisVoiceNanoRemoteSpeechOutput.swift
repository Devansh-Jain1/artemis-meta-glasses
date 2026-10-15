import AVFoundation
import Foundation

struct JarvisVoiceNanoRemotePlaybackStats: Sendable {
    let metadata: NanoRemoteTTSMetadata
    let requestMilliseconds: Int
    let audioRoute: String
    let playbackState: String
    let audioEngineRunning: Bool
    let playerNodePlaying: Bool
    let scheduledBufferFrames: Int
    let lifecycleEpoch: Int
    let lifecycleGeneration: Int

    var telemetryFields: [String: String] {
        NanoRemoteTTSTelemetry.chunkFields(
            metadata: metadata,
            requestMilliseconds: requestMilliseconds,
            playbackFrames: scheduledBufferFrames,
            route: audioRoute,
            lifecycleEpoch: lifecycleEpoch
        ).merging([
            "playback_state": playbackState,
            "audio_engine_running": String(audioEngineRunning),
            "player_node_playing": String(playerNodePlaying),
            "lifecycle_generation": String(lifecycleGeneration)
        ]) { _, new in new }
    }
}

enum JarvisVoiceNanoRemoteSpeechOutputError: LocalizedError {
    case invalidConfiguration(String)
    case emptyAudio
    case bufferCreationFailed
    case channelDataUnavailable
    case chunkFailed(index: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason):
            "Nano remote TTS is unavailable: \(reason)."
        case .emptyAudio:
            "Nano remote TTS produced no speakable chunks."
        case .bufferCreationFailed:
            "Nano remote TTS could not allocate a 24 kHz playback buffer."
        case .channelDataUnavailable:
            "Nano remote TTS could not access the playback buffer channel."
        case let .chunkFailed(index, message):
            "Nano remote TTS chunk \(index) failed: \(message)"
        }
    }
}

@MainActor
final class JarvisVoiceNanoRemoteSpeechOutput {
    private final class StreamingSession {
        let id: UUID
        let lifecycleToken: JarvisVoiceTTSLifecycleToken
        let onChunkGenerated: @MainActor (Int, Int, JarvisVoiceNanoRemotePlaybackStats) -> Void
        let onPipelineState: @MainActor (VoiceStreamingPipelineSnapshot) -> Void
        let completion: @MainActor (Result<JarvisVoiceNanoRemotePlaybackStats, Error>) -> Void
        var chunks: [String] = []
        var nextChunkIndex = 0
        var completedClipCount = 0
        var generationInFlight = false
        var scheduledOutstandingCount = 0
        var inputFinished = false
        var didComplete = false
        var lastStats: JarvisVoiceNanoRemotePlaybackStats?
        var lastSnapshot: VoiceStreamingPipelineSnapshot?

        init(
            id: UUID,
            lifecycleToken: JarvisVoiceTTSLifecycleToken,
            onChunkGenerated: @escaping @MainActor (Int, Int, JarvisVoiceNanoRemotePlaybackStats) -> Void,
            onPipelineState: @escaping @MainActor (VoiceStreamingPipelineSnapshot) -> Void,
            completion: @escaping @MainActor (Result<JarvisVoiceNanoRemotePlaybackStats, Error>) -> Void
        ) {
            self.id = id
            self.lifecycleToken = lifecycleToken
            self.onChunkGenerated = onChunkGenerated
            self.onPipelineState = onPipelineState
            self.completion = completion
        }
    }

    private let audio: FullDuplexAudioCoordinator
    private let client: NanoRemoteTTSClient
    private var lifecycle = JarvisVoiceTTSLifecycle()
    private var streamingSession: StreamingSession?
    private var requestTask: Task<Void, Never>?
    private let lookaheadPolicy = NanoRemoteTTSLookaheadPolicy(maxScheduledOutstandingClips: 2)

    init(audio: FullDuplexAudioCoordinator, configuration: NanoRemoteTTSConfiguration) {
        self.audio = audio
        client = NanoRemoteTTSClient(configuration: configuration)
    }

    func speakQueued(
        _ chunks: [String],
        onChunkGenerated: @escaping @MainActor (Int, Int, JarvisVoiceNanoRemotePlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<JarvisVoiceNanoRemotePlaybackStats, Error>) -> Void
    ) {
        let sessionID = beginStreaming(
            onChunkGenerated: onChunkGenerated,
            completion: completion
        )
        appendStreaming(chunks, sessionID: sessionID)
        finishStreaming(sessionID: sessionID)
    }

    @discardableResult
    func beginStreaming(
        onChunkGenerated: @escaping @MainActor (Int, Int, JarvisVoiceNanoRemotePlaybackStats) -> Void,
        onPipelineState: @escaping @MainActor (VoiceStreamingPipelineSnapshot) -> Void = { _ in },
        completion: @escaping @MainActor (Result<JarvisVoiceNanoRemotePlaybackStats, Error>) -> Void
    ) -> UUID {
        stop()
        let sessionID = UUID()
        let token = lifecycle.beginPlayback(reason: "nano_remote_stream")
        let session = StreamingSession(
            id: sessionID,
            lifecycleToken: token,
            onChunkGenerated: onChunkGenerated,
            onPipelineState: onPipelineState,
            completion: completion
        )
        streamingSession = session
        reportPipeline(session, event: "session_started")
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
            .flatMap {
                JarvisVoiceTTSChunker.chunks(
                    for: $0,
                    maxChunkBeforeSplit: NanoRemoteTTSConfiguration.maximumChunkCharacters
                )
            }
        guard !speakable.isEmpty else { return }
        session.chunks.append(contentsOf: speakable)
        reportPipeline(session, event: "text_appended")
        pump(session)
    }

    func finishStreaming(sessionID: UUID) {
        guard let session = streamingSession,
              session.id == sessionID,
              !session.didComplete else { return }
        session.inputFinished = true
        reportPipeline(session, event: "input_finished")
        guard !session.chunks.isEmpty else {
            finish(session, result: .failure(JarvisVoiceNanoRemoteSpeechOutputError.emptyAudio))
            return
        }
        pump(session)
        completeIfReady(session)
    }

    func stop() {
        lifecycle.cancelThroughCurrent(reason: "stop")
        requestTask?.cancel()
        requestTask = nil
        streamingSession = nil
        audio.stopPlayback()
    }

    private func pump(_ session: StreamingSession) {
        guard streamingSession === session,
              lifecycle.acceptGenerated(session.lifecycleToken) == .accept,
              !session.didComplete,
              lookaheadPolicy.canStartGeneration(
                generationInFlight: session.generationInFlight,
                scheduledOutstandingCount: session.scheduledOutstandingCount
              ) else {
            completeIfReady(session)
            return
        }
        guard session.nextChunkIndex < session.chunks.count else {
            completeIfReady(session)
            return
        }

        let index = session.nextChunkIndex
        let chunk = session.chunks[index]
        session.nextChunkIndex += 1
        session.generationInFlight = true
        let requestID = "\(session.id.uuidString.lowercased())-\(index)"
        let startedAt = Date()
        reportPipeline(session, event: "generation_started")
        requestTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let validated = try await self.client.synthesize(text: chunk, requestID: requestID)
                guard !Task.isCancelled,
                      self.streamingSession === session,
                      self.lifecycle.acceptGenerated(session.lifecycleToken) == .accept else { return }
                let buffer = try self.makePlaybackBuffer(from: validated.wave)
                let requestMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                try self.schedule(
                    buffer,
                    validated: validated,
                    requestMilliseconds: requestMilliseconds,
                    index: index,
                    session: session
                )
            } catch is CancellationError {
                return
            } catch NanoRemoteTTSError.cancelled {
                return
            } catch {
                guard self.streamingSession === session,
                      self.lifecycle.acceptGenerated(session.lifecycleToken) == .accept else { return }
                self.finish(
                    session,
                    result: .failure(JarvisVoiceNanoRemoteSpeechOutputError.chunkFailed(
                        index: index,
                        message: error.localizedDescription
                    ))
                )
            }
        }
    }

    private func schedule(
        _ buffer: AVAudioPCMBuffer,
        validated: NanoRemoteTTSValidatedAudio,
        requestMilliseconds: Int,
        index: Int,
        session: StreamingSession
    ) throws {
        guard streamingSession === session,
              lifecycle.acceptGenerated(session.lifecycleToken) == .accept else { return }
        var scheduledStats: JarvisVoiceNanoRemotePlaybackStats?
        let state = try audio.schedule(buffer) { [weak self, weak session] in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session,
                      self.streamingSession === session,
                      self.lifecycle.acceptGenerated(session.lifecycleToken) == .accept else { return }
                session.scheduledOutstandingCount = max(0, session.scheduledOutstandingCount - 1)
                session.completedClipCount += 1
                if let scheduledStats { session.lastStats = scheduledStats }
                self.reportPipeline(session, event: "clip_played")
                self.pump(session)
                self.completeIfReady(session)
            }
        }
        let stats = JarvisVoiceNanoRemotePlaybackStats(
            metadata: validated.metadata,
            requestMilliseconds: requestMilliseconds,
            audioRoute: state.routeDescription,
            playbackState: "scheduled_after_player_play",
            audioEngineRunning: state.engineRunning,
            playerNodePlaying: state.playerPlaying,
            scheduledBufferFrames: Int(buffer.frameLength),
            lifecycleEpoch: session.lifecycleToken.epoch,
            lifecycleGeneration: session.lifecycleToken.generation
        )
        scheduledStats = stats
        session.generationInFlight = false
        session.scheduledOutstandingCount += 1
        requestTask = nil
        session.onChunkGenerated(index, session.chunks.count, stats)
        reportPipeline(session, event: "clip_scheduled")
        pump(session)
    }

    private func makePlaybackBuffer(from wave: NanoRemoteTTSWave) throws -> AVAudioPCMBuffer {
        guard wave.frameCount > 0 else { throw JarvisVoiceNanoRemoteSpeechOutputError.emptyAudio }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(wave.frameCount)
              ) else {
            throw JarvisVoiceNanoRemoteSpeechOutputError.bufferCreationFailed
        }
        guard let channel = buffer.floatChannelData?[0] else {
            throw JarvisVoiceNanoRemoteSpeechOutputError.channelDataUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(wave.frameCount)
        let bytes = [UInt8](wave.pcm16LittleEndian)
        for frame in 0 ..< wave.frameCount {
            let low = UInt16(bytes[frame * 2])
            let high = UInt16(bytes[(frame * 2) + 1]) << 8
            let sample = Int16(bitPattern: low | high)
            channel[frame] = Float(sample) / 32_768.0
        }
        return buffer
    }

    private func completeIfReady(_ session: StreamingSession) {
        guard streamingSession === session,
              session.inputFinished,
              !session.generationInFlight,
              session.nextChunkIndex == session.chunks.count,
              session.scheduledOutstandingCount == 0,
              session.completedClipCount == session.chunks.count,
              let stats = session.lastStats else { return }
        finish(session, result: .success(stats))
    }

    private func finish(
        _ session: StreamingSession,
        result: Result<JarvisVoiceNanoRemotePlaybackStats, Error>
    ) {
        guard streamingSession === session, !session.didComplete else { return }
        if case .failure = result {
            let cleanup = NanoRemoteTTSFailureCleanupDecision.failClosed
            lifecycle.cancelThroughCurrent(reason: "chunk_failure")
            if cleanup.cancelRequest { requestTask?.cancel() }
            if cleanup.stopPlayback { audio.stopPlayback() }
            session.generationInFlight = cleanup.generationInFlight
            session.scheduledOutstandingCount = cleanup.scheduledOutstandingCount
        }
        session.didComplete = true
        reportPipeline(session, event: "session_completed")
        requestTask = nil
        streamingSession = nil
        session.completion(result)
    }

    private func reportPipeline(_ session: StreamingSession, event: String) {
        let snapshot = VoiceStreamingPipelineSnapshot(
            event: event,
            acceptedTextChunks: session.chunks.count,
            nextGenerationIndex: session.nextChunkIndex,
            generatedReadyCount: 0,
            scheduledOutstandingCount: session.scheduledOutstandingCount,
            completedClipCount: session.completedClipCount,
            generationInFlight: session.generationInFlight,
            inputFinished: session.inputFinished,
            maxOutstandingClips: lookaheadPolicy.maxScheduledOutstandingClips
        )
        guard snapshot != session.lastSnapshot else { return }
        session.lastSnapshot = snapshot
        session.onPipelineState(snapshot)
    }
}
