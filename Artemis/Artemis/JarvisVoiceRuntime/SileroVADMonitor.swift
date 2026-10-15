import AVFoundation
import CoreML
import Foundation

enum SileroVADPhase: String, Sendable {
    case unavailable
    case ready
    case probability
    case speechStarted
    case speechEnded
}

struct SileroVADDetectionEvent: Sendable {
    let phase: SileroVADPhase
    let probability: Float
    let rms: Float
    let peak: Float
    let reason: String
}

final class SileroVADMonitor {
    var onEvent: (@Sendable (SileroVADDetectionEvent) -> Void)?

    private let queue = DispatchQueue(label: "artemis.silero-vad")
    private let targetSampleRate: Double = 16_000
    private let windowSampleCount = 4_160
    private let hopSampleCount = 512
    private let stateSampleCount = 128
    private let speechProbabilityThreshold: Float = 0.50
    private let silenceProbabilityThreshold: Float = 0.25
    private let silenceWindowsForEnd = 5
    private let modelResourceName = "silero-vad-unified-256ms-v6.0.0"

    private var model: MLModel?
    private var isSpeechActive = false
    private var silentWindowCount = 0
    private var targetSamples: [Float] = []
    private var sourceCursor: Double = 0
    private var hiddenState: MLMultiArray?
    private var cellState: MLMultiArray?
    private var lastUnavailableReport = Date.distantPast

    func accept(buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        guard let copied = Self.copyMonoSamples(from: buffer) else { return }
        let sourceRate = buffer.format.sampleRate
        queue.async { [weak self] in
            self?.acceptCopiedSamples(copied, sourceSampleRate: sourceRate)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isSpeechActive = false
            self.silentWindowCount = 0
            self.targetSamples.removeAll(keepingCapacity: true)
            self.sourceCursor = 0
            self.hiddenState = Self.zeroArray(width: self.stateSampleCount)
            self.cellState = Self.zeroArray(width: self.stateSampleCount)
        }
    }

    private func acceptCopiedSamples(_ samples: [Float], sourceSampleRate: Double) {
        guard ensureModelLoaded() else {
            emitUnavailable(reason: "silero_coreml_model_unavailable")
            return
        }

        appendResampled(samples, sourceSampleRate: sourceSampleRate)
        while targetSamples.count >= windowSampleCount {
            let window = Array(targetSamples.prefix(windowSampleCount))
            targetSamples.removeFirst(min(hopSampleCount, targetSamples.count))
            runPrediction(window)
        }
    }

    private func ensureModelLoaded() -> Bool {
        if model != nil { return true }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let bundleURL = Bundle.main.url(forResource: modelResourceName, withExtension: "mlmodelc")
        let packageURL = Bundle.main.url(forResource: modelResourceName, withExtension: "mlpackage")
        guard let url = bundleURL ?? packageURL else { return false }
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
            hiddenState = Self.zeroArray(width: stateSampleCount)
            cellState = Self.zeroArray(width: stateSampleCount)
            onEvent?(SileroVADDetectionEvent(
                phase: .ready,
                probability: 0,
                rms: 0,
                peak: 0,
                reason: "silero_coreml_model_ready"
            ))
            return true
        } catch {
            emitUnavailable(reason: "silero_coreml_load_failed:\(error.localizedDescription)")
            return false
        }
    }

    private func appendResampled(_ samples: [Float], sourceSampleRate: Double) {
        guard sourceSampleRate > 0 else { return }
        let step = sourceSampleRate / targetSampleRate
        var cursor = sourceCursor
        while cursor < Double(samples.count) {
            let lowerIndex = Int(cursor)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(cursor - Double(lowerIndex))
            let lower = samples[lowerIndex]
            let upper = samples[upperIndex]
            targetSamples.append(lower + ((upper - lower) * fraction))
            cursor += step
        }
        sourceCursor = cursor - Double(samples.count)
        if targetSamples.count > windowSampleCount * 4 {
            targetSamples.removeFirst(targetSamples.count - windowSampleCount * 2)
        }
    }

    private func runPrediction(_ samples: [Float]) {
        guard let model,
              let hiddenState,
              let cellState,
              let audio = Self.array(samples: samples, width: windowSampleCount) else {
            return
        }
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: audio),
                "hidden_state": MLFeatureValue(multiArray: hiddenState),
                "cell_state": MLFeatureValue(multiArray: cellState)
            ])
            let output = try model.prediction(from: input)
            guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue?[0].floatValue else { return }
            self.hiddenState = output.featureValue(for: "new_hidden_state")?.multiArrayValue ?? hiddenState
            self.cellState = output.featureValue(for: "new_cell_state")?.multiArrayValue ?? cellState
            updateState(probability: probability, samples: samples)
        } catch {
            emitUnavailable(reason: "silero_coreml_prediction_failed:\(error.localizedDescription)")
        }
    }

    private func updateState(probability: Float, samples: [Float]) {
        let levels = Self.audioLevels(samples)
        onEvent?(SileroVADDetectionEvent(
            phase: .probability,
            probability: probability,
            rms: levels.rms,
            peak: levels.peak,
            reason: "silero_probability"
        ))

        if probability >= speechProbabilityThreshold {
            silentWindowCount = 0
            guard !isSpeechActive else { return }
            isSpeechActive = true
            onEvent?(SileroVADDetectionEvent(
                phase: .speechStarted,
                probability: probability,
                rms: levels.rms,
                peak: levels.peak,
                reason: "silero_probability_start"
            ))
            return
        }

        guard isSpeechActive, probability <= silenceProbabilityThreshold else { return }
        silentWindowCount += 1
        guard silentWindowCount >= silenceWindowsForEnd else { return }
        isSpeechActive = false
        silentWindowCount = 0
        onEvent?(SileroVADDetectionEvent(
            phase: .speechEnded,
            probability: probability,
            rms: levels.rms,
            peak: levels.peak,
            reason: "silero_probability_end"
        ))
    }

    private func emitUnavailable(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastUnavailableReport) > 5 else { return }
        lastUnavailableReport = now
        onEvent?(SileroVADDetectionEvent(
            phase: .unavailable,
            probability: 0,
            rms: 0,
            peak: 0,
            reason: reason
        ))
    }

    private static func copyMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = max(1, Int(buffer.format.channelCount))
        let frameCount = Int(buffer.frameLength)
        var samples = Array(repeating: Float(0), count: frameCount)
        for frame in 0..<frameCount {
            var sum = Float(0)
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            samples[frame] = sum / Float(channelCount)
        }
        return samples
    }

    private static func audioLevels(_ samples: [Float]) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var sumSquares = Float(0)
        var peak = Float(0)
        for sample in samples {
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        return (sqrt(sumSquares / Float(samples.count)), peak)
    }

    private static func array(samples: [Float], width: Int) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: width)], dataType: .float32) else {
            return nil
        }
        for index in 0..<min(width, samples.count) {
            array[index] = NSNumber(value: samples[index])
        }
        return array
    }

    private static func zeroArray(width: Int) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: width)], dataType: .float32) else {
            return nil
        }
        for index in 0..<width {
            array[index] = 0
        }
        return array
    }
}
