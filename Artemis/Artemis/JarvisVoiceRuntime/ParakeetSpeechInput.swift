@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation

@MainActor
protocol ParakeetSpeechInputDelegate: AnyObject {
    func speechInputDidUpdateTranscript(_ transcript: String, isFinal: Bool)
    func speechInputDidDetectVAD(_ event: SileroVADDetectionEvent)
    func speechInputDidObserveAudioLevel(rms: Float, peak: Float)
    func speechInputDidReplayStartupAudio(durationSeconds: Double, bufferCount: Int)
    func speechInputDidUpdateRuntimeStatus(_ status: String)
    func speechInputDidFail(_ error: Error)
}

private actor ParakeetStreamingRuntime {
    struct StartupReplay: Sendable {
        let durationSeconds: Double
        let bufferCount: Int
    }

    private let manager: StreamingEouAsrManager
    private var onPartial: (@Sendable (String) -> Void)?
    private var onFinal: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?
    private var modelsReady = false
    private var drainingStartupAudio = false
    private var startupAudio: [AVAudioPCMBuffer] = []
    private var startupAudioDurationSeconds = 0.0
    private let maximumStartupAudioDurationSeconds = 2.5

    init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        manager = StreamingEouAsrManager(
            configuration: configuration,
            chunkSize: .ms160,
            eouDebounceMs: 640
        )
    }

    func configureCallbacks(
        onPartial: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async {
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
        await manager.setPartialCallback { text in onPartial(text) }
    }

    func loadModels(progress: @escaping ProgressHandler) async throws -> StartupReplay {
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: progress)
        await manager.reset()
        modelsReady = true
        drainingStartupAudio = true
        let replayDuration = startupAudioDurationSeconds
        let replayBufferCount = startupAudio.count
        while !startupAudio.isEmpty {
            let batch = startupAudio
            startupAudio.removeAll(keepingCapacity: true)
            startupAudioDurationSeconds = 0
            for buffer in batch {
                await process(buffer)
            }
        }
        drainingStartupAudio = false
        return StartupReplay(
            durationSeconds: replayDuration,
            bufferCount: replayBufferCount
        )
    }

    func accept(_ buffer: AVAudioPCMBuffer) async {
        guard modelsReady, !drainingStartupAudio else {
            bufferStartupAudio(buffer)
            return
        }
        await process(buffer)
    }

    private func process(_ buffer: AVAudioPCMBuffer) async {
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            if await manager.eouDetected {
                let transcript = await manager.getPartialTranscript()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await manager.reset()
                if !transcript.isEmpty { onFinal?(transcript) }
            }
        } catch {
            onError?(error)
        }
    }

    func reset() async {
        startupAudio.removeAll(keepingCapacity: true)
        startupAudioDurationSeconds = 0
        drainingStartupAudio = false
        await manager.reset()
    }

    func finalizeCurrentTranscript() async -> String? {
        let transcript = await manager.getPartialTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }
        await manager.reset()
        return transcript
    }

    private func bufferStartupAudio(_ buffer: AVAudioPCMBuffer) {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return }
        startupAudio.append(buffer)
        startupAudioDurationSeconds += Double(buffer.frameLength) / sampleRate
        while startupAudioDurationSeconds > maximumStartupAudioDurationSeconds,
              let oldest = startupAudio.first {
            startupAudio.removeFirst()
            startupAudioDurationSeconds -= Double(oldest.frameLength) / oldest.format.sampleRate
        }
    }
}

/// True streaming, on-device ASR. FluidAudio Parakeet owns transcription and
/// EOU; Silero provides the faster local speech boundaries used by the hybrid
/// endpoint and barge-in path.
@MainActor
final class ParakeetSpeechInput {
    weak var delegate: ParakeetSpeechInputDelegate?

    private let audio: FullDuplexAudioCoordinator
    private let runtime = ParakeetStreamingRuntime()
    private let vadMonitor = SileroVADMonitor()
    private var modelsLoaded = false
    private var isStarting = false
    private var captureActive = false
    private var lastAudioLevelReport = Date.distantPast

    init(audio: FullDuplexAudioCoordinator) {
        self.audio = audio
    }

    var isRunning: Bool { captureActive && audio.isRunning }

    func start() async throws -> FullDuplexAudioState {
        guard !isStarting else { throw LocalSpeechInputError.alreadyStarting }
        isStarting = true
        defer { isStarting = false }

        await runtime.configureCallbacks(
            onPartial: { [weak self] text in
                Task { @MainActor in self?.delegate?.speechInputDidUpdateTranscript(text, isFinal: false) }
            },
            onFinal: { [weak self] text in
                Task { @MainActor in self?.delegate?.speechInputDidUpdateTranscript(text, isFinal: true) }
            },
            onError: { [weak self] error in
                Task { @MainActor in self?.delegate?.speechInputDidFail(error) }
            }
        )

        vadMonitor.onEvent = { [weak self] event in
            Task { @MainActor in self?.delegate?.speechInputDidDetectVAD(event) }
        }
        vadMonitor.reset()

        let state = try await audio.start { [weak self] buffer in
            self?.vadMonitor.accept(buffer: buffer)
            self?.reportAudioLevelIfNeeded(buffer)
            guard let self else { return }
            Task { await self.runtime.accept(buffer) }
        }
        captureActive = true

        do {
            if !modelsLoaded {
                delegate?.speechInputDidUpdateRuntimeStatus("Loading on-device Parakeet EOU")
                let replay = try await runtime.loadModels { [weak self] progress in
                    let percent = Int(progress.fractionCompleted * 100)
                    Task { @MainActor in
                        self?.delegate?.speechInputDidUpdateRuntimeStatus("Preparing Parakeet EOU \(percent)%")
                    }
                }
                modelsLoaded = true
                delegate?.speechInputDidReplayStartupAudio(
                    durationSeconds: replay.durationSeconds,
                    bufferCount: replay.bufferCount
                )
                delegate?.speechInputDidUpdateRuntimeStatus("Parakeet EOU ready")
            }
            return state
        } catch {
            captureActive = false
            audio.stop()
            throw error
        }
    }

    func stop() {
        captureActive = false
        audio.stop()
        vadMonitor.reset()
        Task { await runtime.reset() }
    }

    func restart() async throws -> FullDuplexAudioState {
        captureActive = false
        audio.stop()
        vadMonitor.reset()
        await runtime.reset()
        delegate?.speechInputDidUpdateRuntimeStatus("Restarting with warm Parakeet EOU")
        return try await start()
    }

    func finalizeCurrentTranscript() async -> String? {
        await runtime.finalizeCurrentTranscript()
    }

    func resetTranscriptState() async {
        await runtime.reset()
    }

    private nonisolated func reportAudioLevelIfNeeded(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        Task { @MainActor [weak self] in
            guard let self, now.timeIntervalSince(lastAudioLevelReport) >= 0.75,
                  let samples = buffer.floatChannelData?.pointee else { return }
            lastAudioLevelReport = now
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sumSquares: Float = 0
            var peak: Float = 0
            for index in 0..<count {
                let sample = samples[index]
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
            delegate?.speechInputDidObserveAudioLevel(rms: sqrt(sumSquares / Float(count)), peak: peak)
        }
    }
}
