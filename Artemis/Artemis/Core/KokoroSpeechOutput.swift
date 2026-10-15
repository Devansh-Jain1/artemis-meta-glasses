import AVFoundation
import Foundation
import MisakiSwift
import OnnxRuntimeBindings

struct KokoroSpeechPlaybackStats: Sendable {
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

    var realTimeFactor: Double {
        guard generationMilliseconds > 0 else { return 0 }
        return audioDurationSeconds / (Double(generationMilliseconds) / 1000.0)
    }
}

enum KokoroAudioRouteMode: Sendable {
    case systemDefault
    case builtInSpeakerDiagnostic
    case duplexBargeIn
    case privateGlassesDuplex
}

enum KokoroAudioSampleMode: Sendable {
    case officialRawCopy
    case normalized
}

enum KokoroSpeechOutputError: LocalizedError {
    case missingModel
    case missingConfig
    case missingVoice(String)
    case runtimeUnavailable(String)
    case phonemeTokenizationFailed
    case emptyAudio
    case bufferCreationFailed
    case channelDataUnavailable
    case audioRouteNotAllowed(String)

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
        }
    }
}

@MainActor
final class KokoroSpeechOutput {
    private let preferredVoiceName = "af_bella"
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(KokoroONNXEngine.sampleRate),
        channels: 1
    )!
    private let generationQueue = DispatchQueue(label: "artemis.kokoro.onnx.generation", qos: .userInitiated)
    private var playbackID = UUID()
    private var routeMode: KokoroAudioRouteMode = .systemDefault
    private var sampleMode: KokoroAudioSampleMode = .normalized
    private var engineResult: Result<KokoroONNXEngine, Error>?

    init() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        playerNode.volume = 1.0
    }

    var isAvailable: Bool {
        switch loadEngine() {
        case .success:
            return true
        case let .failure(error):
            print("[KokoroSpeechOutput] ONNX unavailable: \(error.localizedDescription)")
            return false
        }
    }

    var selectedVoiceName: String {
        preferredVoiceName
    }

    func setRouteMode(_ routeMode: KokoroAudioRouteMode) {
        self.routeMode = routeMode
    }

    func setSampleMode(_ sampleMode: KokoroAudioSampleMode) {
        self.sampleMode = sampleMode
    }

    #if os(iOS)
    @discardableResult
    func prepareAudioSessionForPlayback() throws -> String {
        try configureAudioSession().routeDescription
    }
    #endif

    func speak(
        _ text: String,
        onGenerated: @escaping @MainActor (KokoroSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<KokoroSpeechPlaybackStats, Error>) -> Void
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
        onChunkGenerated: @escaping @MainActor (Int, Int, String, KokoroSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<KokoroSpeechPlaybackStats, Error>) -> Void
    ) {
        stop()
        let currentPlaybackID = UUID()
        playbackID = currentPlaybackID

        guard !chunks.isEmpty else {
            completion(.failure(KokoroSpeechOutputError.emptyAudio))
            return
        }

        let engineResult = loadEngine()
        guard case let .success(engine) = engineResult else {
            if case let .failure(error) = engineResult {
                completion(.failure(error))
            }
            return
        }

        #if os(iOS)
        let audioSessionState: AudioSessionState
        do {
            audioSessionState = try configureAudioSession()
        } catch {
            completion(.failure(error))
            return
        }
        #else
        let audioSessionState = AudioSessionState(
            routeDescription: "non-ios",
            sampleRate: Double(KokoroONNXEngine.sampleRate),
            outputLatency: 0
            )
        #endif

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
                    guard let self, self.playbackID == currentPlaybackID else { return }
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
            guard playbackID == currentPlaybackID else { return }
            if let result = generatedClips.removeValue(forKey: index) {
                receive(result)
                return
            }

            clipWaiters[index, default: []].append(receive)
            requestClip(at: index)
        }

        var completedClipCount = 0
        var lastCompletedStats: KokoroSpeechPlaybackStats?
        var didComplete = false

        func finish(_ result: Result<KokoroSpeechPlaybackStats, Error>) {
            guard !didComplete else { return }
            didComplete = true
            completion(result)
        }

        func scheduleIndex(_ index: Int) {
            guard playbackID == currentPlaybackID else { return }
            guard chunks.indices.contains(index) else {
                return
            }

            requestClip(at: index + 1)
            receiveClip(at: index) { [weak self] result in
                guard let self, self.playbackID == currentPlaybackID else { return }
                switch result {
                case let .success(generated):
                    self.scheduleQueuedClip(
                        generated,
                        audioSessionState: audioSessionState,
                        isFirstClip: index == 0,
                        playbackID: currentPlaybackID,
                        onGenerated: { stats in
                            onChunkGenerated(index, chunks.count, chunks[index], stats)
                        },
                        completion: { result in
                            guard self.playbackID == currentPlaybackID else { return }
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

    func generateOnly(
        _ text: String,
        completion: @escaping @MainActor (Result<KokoroSpeechPlaybackStats, Error>) -> Void
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
                                for: generated.samples,
                                generationMilliseconds: generated.generationMilliseconds,
                                audioSessionState: AudioSessionState(
                                    routeDescription: "generation-only",
                                    sampleRate: Double(KokoroONNXEngine.sampleRate),
                                    outputLatency: 0
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
        playbackID = UUID()
        playerNode.stop()
    }

    private func loadEngine() -> Result<KokoroONNXEngine, Error> {
        if let engineResult {
            return engineResult
        }

        let loaded: Result<KokoroONNXEngine, Error>
        do {
            loaded = .success(try KokoroONNXEngine(voiceName: preferredVoiceName))
        } catch {
            loaded = .failure(error)
        }
        engineResult = loaded
        return loaded
    }

    private func scheduleQueuedClip(
        _ generated: KokoroGeneratedAudio,
        audioSessionState: AudioSessionState,
        isFirstClip: Bool,
        playbackID currentPlaybackID: UUID,
        onGenerated: @escaping @MainActor (KokoroSpeechPlaybackStats) -> Void,
        completion: @escaping @MainActor (Result<KokoroSpeechPlaybackStats, Error>) -> Void
    ) {
        let bufferAndStats: (AVAudioPCMBuffer, KokoroSpeechPlaybackStats)
        do {
            bufferAndStats = try makePlaybackBuffer(
                from: generated,
                audioSessionState: audioSessionState
            )
        } catch {
            completion(.failure(error))
            return
        }

        let (buffer, stats) = bufferAndStats
        onGenerated(stats)

        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            let options: AVAudioPlayerNodeBufferOptions = isFirstClip ? .interrupts : []
            playerNode.scheduleBuffer(buffer, at: nil, options: options) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackID == currentPlaybackID else { return }
                    completion(.success(stats))
                }
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func makePlaybackBuffer(
        from generated: KokoroGeneratedAudio,
        audioSessionState: AudioSessionState
    ) throws -> (AVAudioPCMBuffer, KokoroSpeechPlaybackStats) {
        let audio = generated.samples
        guard !audio.isEmpty else {
            throw KokoroSpeechOutputError.emptyAudio
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(audio.count)
        ) else {
            throw KokoroSpeechOutputError.bufferCreationFailed
        }
        buffer.frameLength = buffer.frameCapacity
        guard let channel = buffer.floatChannelData?[0] else {
            throw KokoroSpeechOutputError.channelDataUnavailable
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
            let fadeSampleCount = min(audio.count / 2, Int(KokoroONNXEngine.sampleRate / 200))
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
        let stats = KokoroSpeechPlaybackStats(
            voiceName: preferredVoiceName,
            generationMilliseconds: generated.generationMilliseconds,
            audioDurationSeconds: Double(audio.count) / Double(KokoroONNXEngine.sampleRate),
            peakSample: peakSample,
            clippedSampleCount: clippedSampleCount,
            rawPeakSample: rawPeakSample,
            normalizationGain: normalizationGain,
            audioRoute: audioSessionState.routeDescription,
            sessionSampleRate: audioSessionState.sampleRate,
            outputLatencySeconds: audioSessionState.outputLatency,
            sampleMode: "onnxruntime_\(sampleMode.description)",
            diagnosticWavPath: diagnosticWavPath
        )
        return (buffer, stats)
    }

    private func stats(
        for audio: [Float],
        generationMilliseconds: Int,
        audioSessionState: AudioSessionState,
        diagnosticWavPath: String?
    ) -> KokoroSpeechPlaybackStats {
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

        return KokoroSpeechPlaybackStats(
            voiceName: preferredVoiceName,
            generationMilliseconds: generationMilliseconds,
            audioDurationSeconds: Double(audio.count) / Double(KokoroONNXEngine.sampleRate),
            peakSample: peakSample,
            clippedSampleCount: clippedSampleCount,
            rawPeakSample: rawPeakSample,
            normalizationGain: normalizationGain,
            audioRoute: audioSessionState.routeDescription,
            sessionSampleRate: audioSessionState.sampleRate,
            outputLatencySeconds: audioSessionState.outputLatency,
            sampleMode: "onnxruntime_generation_only",
            diagnosticWavPath: diagnosticWavPath
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
            print("[KokoroSpeechOutput] failed to write diagnostic wav: \(error.localizedDescription)")
            return nil
        }
    }

    private struct AudioSessionState {
        let routeDescription: String
        let sampleRate: Double
        let outputLatency: Double
    }

    #if os(iOS)
    private func configureAudioSession() throws -> AudioSessionState {
        let session = AVAudioSession.sharedInstance()
        switch routeMode {
        case .systemDefault:
            try configureSessionIfNeeded(
                session,
                category: .playback,
                mode: .default,
                options: [],
                shouldResetActiveSession: true
            )
            try session.setActive(true)
        case .builtInSpeakerDiagnostic:
            try configureSessionIfNeeded(
                session,
                category: .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .mixWithOthers],
                shouldResetActiveSession: true
            )
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
        case .duplexBargeIn:
            try configureSessionIfNeeded(
                session,
                category: .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .mixWithOthers],
                shouldResetActiveSession: false
            )
            try session.setActive(true)
            if let bluetoothInput = session.availableInputs?.first(where: { input in
                input.portType == .bluetoothHFP || input.portType == .bluetoothLE
            }) {
                try? session.setPreferredInput(bluetoothInput)
            }
        case .privateGlassesDuplex:
            do {
                _ = try ArtemisAudioRoutePolicy.activateMetaGlassesDuplexSession(resetActiveSession: true)
            } catch let error as ArtemisAudioRouteActivationError {
                throw KokoroSpeechOutputError.audioRouteNotAllowed(error.localizedDescription)
            }
        }
        return AudioSessionState(
            routeDescription: Self.describeCurrentRoute(session),
            sampleRate: session.sampleRate,
            outputLatency: session.outputLatency
        )
    }

    private func configureSessionIfNeeded(
        _ session: AVAudioSession,
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
        shouldResetActiveSession: Bool
    ) throws {
        let alreadyConfigured = session.category == category && session.mode == mode
        if !alreadyConfigured && shouldResetActiveSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        if !alreadyConfigured {
            try session.setCategory(category, mode: mode, options: options)
        }
    }

    private static func describeCurrentRoute(_ session: AVAudioSession) -> String {
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let routeCandidates = ArtemisAudioRoutePolicy.describeRouteCandidates(
            outputs: currentRouteEndpoints(session),
            availableInputs: availableInputEndpoints(session)
        )
        return "inputs=[\(inputs.joined(separator: ","))] \(routeCandidates)"
    }

    private static func currentRouteEndpoints(_ session: AVAudioSession) -> [ArtemisAudioRouteEndpoint] {
        session.currentRoute.outputs.map { output in
            ArtemisAudioRouteEndpoint(
                portType: output.portType.rawValue,
                portName: output.portName
            )
        }
    }

    private static func availableInputEndpoints(_ session: AVAudioSession) -> [ArtemisAudioRouteEndpoint] {
        (session.availableInputs ?? []).map { input in
            ArtemisAudioRouteEndpoint(
                portType: input.portType.rawValue,
                portName: input.portName
            )
        }
    }

    private static func currentRouteHasBluetoothOutput(_ session: AVAudioSession) -> Bool {
        session.currentRoute.outputs.contains { output in
            output.portType == .bluetoothA2DP
                || output.portType == .bluetoothHFP
                || output.portType == .bluetoothLE
        }
    }
    #endif
}

private final class KokoroONNXEngine {
    static let sampleRate = 24_000

    private let voiceName: String
    private let tokenizer: KokoroONNXTokenizer
    private let voiceStyle: KokoroONNXVoiceStyle
    private let phonemizer = EnglishG2P(british: false)
    private let env: ORTEnv
    private let session: ORTSession

    init(voiceName: String) throws {
        self.voiceName = voiceName
        guard let modelURL = Bundle.main.url(forResource: "kokoro", withExtension: "onnx") else {
            throw KokoroSpeechOutputError.missingModel
        }
        guard let configURL = Bundle.main.url(forResource: "kokoro-config", withExtension: "json") else {
            throw KokoroSpeechOutputError.missingConfig
        }
        guard let voiceURL = Bundle.main.url(forResource: voiceName, withExtension: "bin") else {
            throw KokoroSpeechOutputError.missingVoice(voiceName)
        }

        let config = try KokoroONNXConfig.load(from: configURL)
        self.tokenizer = KokoroONNXTokenizer(vocab: config.vocab)
        self.voiceStyle = try KokoroONNXVoiceStyle(data: Data(contentsOf: voiceURL))
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
            print("[KokoroONNXEngine] XNNPACK unavailable; continuing with default ORT provider: \(error.localizedDescription)")
        }

        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        let inputNames = (try? session.inputNames()) ?? []
        let outputNames = (try? session.outputNames()) ?? []
        print("[KokoroONNXEngine] loaded voice=\(voiceName) inputs=\(inputNames) outputs=\(outputNames)")
    }

    func generate(text: String) throws -> KokoroGeneratedAudio {
        let started = Date()
        let (phonemes, _) = phonemizer.phonemize(text: text, performPreprocess: true)
        let tokenized = try tokenizer.tokenize(phonemes: phonemes)
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
            throw KokoroSpeechOutputError.runtimeUnavailable("waveform output was missing")
        }
        let data = try waveform.tensorData()
        let samples = Self.floatArray(from: data)
        guard !samples.isEmpty else {
            throw KokoroSpeechOutputError.emptyAudio
        }

        return KokoroGeneratedAudio(
            samples: samples,
            generationMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            phonemes: phonemes,
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
    let phonemes: String
    let tokenCount: Int
}

private extension KokoroAudioSampleMode {
    var description: String {
        switch self {
        case .officialRawCopy:
            return "official_raw_copy"
        case .normalized:
            return "normalized"
        }
    }
}
