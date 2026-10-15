import Foundation

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func metadata(mean: Double = 0.82, min: Double = 0.75, segments: Int = 3) -> STTTurnFinalizationMetadata {
    STTTurnFinalizationMetadata(
        segmentCount: segments,
        confidenceMean: mean,
        confidenceMin: min,
        durationSeconds: 1.2,
        lastSegmentText: "test"
    )
}

private func decide(
    _ transcript: String,
    stablePartialCount: Int = 1,
    silenceMS: Int = 0,
    meanConfidence: Double = 0.82,
    isFinal: Bool = false
) -> STTTurnFinalizationDecision {
    STTTurnFinalizationPolicy.decision(
        transcript: transcript,
        isFinal: isFinal,
        metadata: metadata(mean: meanConfidence),
        stablePartialCount: stablePartialCount,
        silenceDurationMS: silenceMS,
        commandDelayNanoseconds: 700_000_000,
        shortUtteranceDelayNanoseconds: 1_800_000_000,
        readyUtteranceDelayNanoseconds: 1_200_000_000
    )
}

@main
struct TestSTTTurnFinalizationPolicy {
    static func main() {
        let fragment = decide("the")
        expect(!fragment.shouldRoute, "single-word fragment should not route")
        expect(fragment.reason == "single_word_non_command_partial", "fragment reason should be explicit")

        let sentence = decide("tell me what you see")
        expect(sentence.shouldRoute, "normal meaningful sentence should route")
        expect(sentence.reason == "semantic_completion", "normal sentence should use semantic completion")

        let stop = decide("stop")
        expect(stop.shouldRoute, "explicit short command stop should route")
        expect(stop.reason == "explicit_short_command", "stop should use explicit short-command reason")
        expect(stop.delayNanoseconds == 700_000_000, "short command should use command delay")

        let cancel = decide("cancel")
        expect(cancel.shouldRoute, "cancel interruption should route")
        expect(cancel.reason == "interruption_or_cancel", "cancel should use interruption/cancel reason")

        let unstableRepeatedCandidate = decide("what is this", stablePartialCount: 1)
        expect(!unstableRepeatedCandidate.shouldRoute, "short visual question should wait for a repeated stable partial")
        expect(unstableRepeatedCandidate.reason == "repeated_partial_unstable", "unstable repeated candidate should be named")

        let repeated = decide("what is this", stablePartialCount: 2)
        expect(repeated.shouldRoute, "repeated stable partial should route")
        expect(repeated.reason == "repeated_partial_stable", "repeated stable partial should carry stable reason")

        let punctuated = decide("what is on the desk?")
        expect(punctuated.shouldRoute, "punctuation completion should route")
        expect(punctuated.reason == "punctuation_completion", "punctuation should be identified")

        let silence = decide("read the label", silenceMS: 1_000)
        expect(silence.shouldRoute, "silence completion should route")
        expect(silence.reason == "silence_completion", "silence should be identified")

        let lowConfidence = decide("tell me what you see", meanConfidence: 0.20)
        expect(!lowConfidence.shouldRoute, "low confidence speech should not route")
        expect(lowConfidence.reason == "low_confidence_partial", "low confidence should be explicit")

        print("PASS: stt turn finalization policy")
    }
}
