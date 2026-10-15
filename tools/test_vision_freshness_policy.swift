import Foundation

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TestVisionFreshnessPolicy {
    static func main() {
        let unavailable = VisionFreshnessPolicy.classify(
            frameID: 0,
            timestampMS: 0,
            ageMS: -1,
            confidence: 0.90,
            summary: "clear desk",
            visibleText: "",
            streamState: "Streaming"
        )
        expect(unavailable.state == .unavailable, "missing frame should be unavailable")
        expect(unavailable.state.rawValue == "unavailable", "unavailable raw value should be telemetry-safe")
        expect(!unavailable.supportsDirectVisualClaim, "unavailable vision must not support direct visual claims")

        let streamStopped = VisionFreshnessPolicy.classify(
            frameID: 12,
            timestampMS: 1_000,
            ageMS: 200,
            confidence: 0.90,
            summary: "laptop on desk",
            visibleText: "",
            streamState: "Stopped"
        )
        expect(streamStopped.state == .streamStopped, "stopped stream should be distinct from stale frame")
        expect(!streamStopped.supportsDirectVisualClaim, "stopped stream must not support direct visual claims")

        let stale = VisionFreshnessPolicy.classify(
            frameID: 12,
            timestampMS: 1_000,
            ageMS: 2_501,
            confidence: 0.90,
            summary: "laptop on desk",
            visibleText: "",
            streamState: "Streaming"
        )
        expect(stale.state == .stale, "old frame should be stale")
        expect(!stale.supportsDirectVisualClaim, "stale frame must not support direct visual claims")

        let lowConfidence = VisionFreshnessPolicy.classify(
            frameID: 12,
            timestampMS: 1_000,
            ageMS: 400,
            confidence: 0.35,
            summary: "maybe something",
            visibleText: "",
            streamState: "Streaming"
        )
        expect(lowConfidence.state == .currentLowConfidence, "low confidence current frame should be gated")
        expect(!lowConfidence.supportsDirectVisualClaim, "low confidence frame must not support direct visual claims")

        let lowInformation = VisionFreshnessPolicy.classify(
            frameID: 12,
            timestampMS: 1_000,
            ageMS: 400,
            confidence: 0.90,
            summary: "   ",
            visibleText: "",
            streamState: "Streaming"
        )
        expect(lowInformation.state == .currentLowConfidence, "empty semantic content should be low confidence")

        let confident = VisionFreshnessPolicy.classify(
            frameID: 12,
            timestampMS: 1_000,
            ageMS: 400,
            confidence: 0.75,
            summary: "laptop and notebook on desk",
            visibleText: "Artemis",
            streamState: "Streaming"
        )
        expect(confident.state == .currentConfident, "fresh high-confidence semantic frame should be current confident")
        expect(confident.state.rawValue == "current_confident", "confident raw value should match evidence contract")
        expect(confident.supportsDirectVisualClaim, "only current confident vision should support direct visual claims")

        print("PASS: vision freshness policy")
    }
}
