import Foundation

struct VoiceSpeechPlaybackStats: Sendable {
    let engineID: String
    let voiceName: String
    let generationMilliseconds: Int
    let modelLoadMilliseconds: Int
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
    let normalizedText: String
    let seed: UInt64
    let seedPolicy: String
    let runtimeRevision: String
    let modelManifestSHA256: String
    let voiceStyleSHA256: String
    let peakResidentMemoryBytes: UInt64
    let thermalState: String

    var realTimeFactor: Double {
        guard audioDurationSeconds > 0 else { return 0 }
        return (Double(generationMilliseconds) / 1_000) / audioDurationSeconds
    }

    var routeProof: String {
        ArtemisTTSRouteProof(
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
    ) -> VoiceSpeechPlaybackStats {
        VoiceSpeechPlaybackStats(
            engineID: engineID,
            voiceName: voiceName,
            generationMilliseconds: generationMilliseconds,
            modelLoadMilliseconds: modelLoadMilliseconds,
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
            normalizedText: normalizedText,
            seed: seed,
            seedPolicy: seedPolicy,
            runtimeRevision: runtimeRevision,
            modelManifestSHA256: modelManifestSHA256,
            voiceStyleSHA256: voiceStyleSHA256,
            peakResidentMemoryBytes: peakResidentMemoryBytes,
            thermalState: thermalState
        )
    }
}

struct VoiceStreamingPipelineSnapshot: Equatable, Sendable {
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

@MainActor
protocol VoiceSpeechOutput: AnyObject {
    var selectedVoiceName: String { get }

    func speak(
        _ text: String,
        onGenerated: @escaping @MainActor (VoiceSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
    )

    func speakQueued(
        _ chunks: [String],
        onChunkGenerated: @escaping @MainActor (Int, Int, String, VoiceSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
    )

    func beginStreaming(
        onChunkGenerated: @escaping @MainActor (Int, Int, String, VoiceSpeechPlaybackStats) -> Void,
        onPipelineState: @escaping @MainActor (VoiceStreamingPipelineSnapshot) -> Void,
        completion: @escaping @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
    ) -> UUID

    func appendStreaming(_ chunks: [String], sessionID: UUID)
    func finishStreaming(sessionID: UUID)

    func generateOnly(
        _ text: String,
        completion: @escaping @MainActor (Result<VoiceSpeechPlaybackStats, Error>) -> Void
    )

    func stop()
}
