import Foundation

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func decide(
    frameID: Int = 42,
    frameAgeMS: Int = 250,
    sceneChanged: Bool = false,
    confidence: Double = 0.82,
    summary: String = "desk with laptop",
    visibleText: String = "",
    userPrompt: String = "",
    detectedFailure: Bool = false,
    lastExpensiveVisionAtMS: Int? = nil,
    nowMS: Int = 10_000
) -> HierarchicalVisionPolicyDecision {
    HierarchicalVisionPolicy.decide(
        frameID: frameID,
        frameAgeMS: frameAgeMS,
        sceneChanged: sceneChanged,
        confidence: confidence,
        summary: summary,
        visibleText: visibleText,
        userPrompt: userPrompt,
        detectedFailure: detectedFailure,
        lastExpensiveVisionAtMS: lastExpensiveVisionAtMS,
        nowMS: nowMS,
        sentinelModel: "LFM2.5-VL-450M",
        sentinelLatencyMS: 640,
        evidenceClass: "component"
    )
}

@main
struct TestHierarchicalVisionPolicy {
    static func main() {
        let noChange = decide()
        expect(noChange.lane == .noChangeSuppressed, "unchanged confident scene should be suppressed")
        expect(noChange.reason == "no_scene_change", "no-change suppression should be explicit")

        let sceneChange = decide(sceneChanged: true)
        expect(sceneChange.lane == .sentinel, "scene change should trigger lightweight sentinel description")
        expect(sceneChange.reason == "scene_change_sentinel", "scene change reason should be explicit")

        let lowConfidence = decide(confidence: 0.32)
        expect(lowConfidence.lane == .deepInspector, "low confidence should request a deep inspector")
        expect(lowConfidence.reason == "low_confidence_deep_inspector", "low-confidence reason should be explicit")
        expect(lowConfidence.escalationAllowed, "low-confidence deep inspector should be allowed when not rate limited")

        let explicit = decide(userPrompt: "look carefully at this and inspect it")
        expect(explicit.lane == .deepInspector, "explicit inspect request should request deep inspector")
        expect(explicit.reason == "explicit_user_deep_inspector_request", "explicit request reason should be explicit")

        let ocr = decide(visibleText: "Settings", userPrompt: "read the screen text")
        expect(ocr.lane == .ocrSelectedCrop, "screen text request should use OCR/crop lane")
        expect(ocr.reason == "screen_text_ocr_selected_crop", "OCR reason should be explicit")

        let rateLimited = decide(confidence: 0.20, lastExpensiveVisionAtMS: 9_500, nowMS: 10_000)
        expect(rateLimited.lane == .sentinel, "rate-limited expensive request should fall back to sentinel")
        expect(rateLimited.rateLimited, "rate-limited decision should be labeled")
        expect(!rateLimited.escalationAllowed, "rate-limited decision must not allow escalation")

        let stale = decide(frameAgeMS: 3_500, sceneChanged: true, confidence: 0.90)
        expect(stale.lane == .staleRejected, "stale frame should be rejected before escalation")
        expect(stale.staleRejected, "stale rejection should be labeled")
        expect(!stale.escalationAllowed, "stale context must not allow escalation")

        print("PASS: hierarchical vision policy")
    }
}
