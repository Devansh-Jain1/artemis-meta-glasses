import Foundation

enum HierarchicalVisionLane: String, Equatable, Sendable {
    case noChangeSuppressed = "no_change_suppressed"
    case sentinel
    case ocrSelectedCrop = "ocr_selected_crop"
    case deepInspector = "deep_inspector"
    case staleRejected = "stale_rejected"
}

struct HierarchicalVisionPolicyDecision: Equatable, Sendable {
    let lane: HierarchicalVisionLane
    let reason: String
    let frameID: Int
    let model: String
    let latencyMS: Int
    let evidenceClass: String
    let escalationAllowed: Bool
    let rateLimited: Bool
    let staleRejected: Bool
}

enum HierarchicalVisionPolicy {
    static let defaultStaleAfterMS = 2_500
    static let defaultMinimumConfidence = 0.55
    static let defaultExpensiveVisionIntervalMS = 30_000
    static let defaultDeepInspectorModel = "async_inspector_unselected"
    static let defaultOCRModel = "selected_crop_ocr_unselected"

    static func decide(
        frameID: Int,
        frameAgeMS: Int,
        sceneChanged: Bool,
        confidence: Double,
        summary: String,
        visibleText: String,
        userPrompt: String,
        detectedFailure: Bool,
        lastExpensiveVisionAtMS: Int?,
        nowMS: Int,
        sentinelModel: String,
        sentinelLatencyMS: Int,
        evidenceClass: String,
        staleAfterMS: Int = defaultStaleAfterMS,
        minimumConfidence: Double = defaultMinimumConfidence,
        expensiveVisionIntervalMS: Int = defaultExpensiveVisionIntervalMS
    ) -> HierarchicalVisionPolicyDecision {
        if frameID <= 0 || frameAgeMS < 0 || frameAgeMS > staleAfterMS {
            return decision(
                lane: .staleRejected,
                reason: "stale_frame_rejected",
                frameID: frameID,
                model: sentinelModel,
                latencyMS: sentinelLatencyMS,
                evidenceClass: evidenceClass,
                escalationAllowed: false,
                rateLimited: false,
                staleRejected: true
            )
        }

        if shouldUseOCR(userPrompt: userPrompt, visibleText: visibleText) {
            return expensiveDecision(
                lane: .ocrSelectedCrop,
                reason: "screen_text_ocr_selected_crop",
                model: defaultOCRModel,
                frameID: frameID,
                latencyMS: sentinelLatencyMS,
                evidenceClass: evidenceClass,
                lastExpensiveVisionAtMS: lastExpensiveVisionAtMS,
                nowMS: nowMS,
                expensiveVisionIntervalMS: expensiveVisionIntervalMS
            )
        }

        if shouldUseDeepInspector(
            userPrompt: userPrompt,
            confidence: confidence,
            detectedFailure: detectedFailure,
            sceneChanged: sceneChanged,
            summary: summary
        ) {
            let reason: String
            if explicitDeepInspectorRequested(userPrompt) {
                reason = "explicit_user_deep_inspector_request"
            } else if confidence < minimumConfidence {
                reason = "low_confidence_deep_inspector"
            } else if detectedFailure || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = "detected_failure_deep_inspector"
            } else {
                reason = "scene_transition_deep_inspector"
            }
            return expensiveDecision(
                lane: .deepInspector,
                reason: reason,
                model: defaultDeepInspectorModel,
                frameID: frameID,
                latencyMS: sentinelLatencyMS,
                evidenceClass: evidenceClass,
                lastExpensiveVisionAtMS: lastExpensiveVisionAtMS,
                nowMS: nowMS,
                expensiveVisionIntervalMS: expensiveVisionIntervalMS
            )
        }

        if sceneChanged {
            return decision(
                lane: .sentinel,
                reason: "scene_change_sentinel",
                frameID: frameID,
                model: sentinelModel,
                latencyMS: sentinelLatencyMS,
                evidenceClass: evidenceClass,
                escalationAllowed: false,
                rateLimited: false,
                staleRejected: false
            )
        }

        return decision(
            lane: .noChangeSuppressed,
            reason: "no_scene_change",
            frameID: frameID,
            model: sentinelModel,
            latencyMS: sentinelLatencyMS,
            evidenceClass: evidenceClass,
            escalationAllowed: false,
            rateLimited: false,
            staleRejected: false
        )
    }

    private static func shouldUseOCR(userPrompt: String, visibleText: String) -> Bool {
        let lower = userPrompt.lowercased()
        let asksForText = lower.contains("read") ||
            lower.contains("text") ||
            lower.contains("screen") ||
            lower.contains("label") ||
            lower.contains("code")
        return asksForText ||
            (!visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lower.contains("what does"))
    }

    private static func shouldUseDeepInspector(
        userPrompt: String,
        confidence: Double,
        detectedFailure: Bool,
        sceneChanged: Bool,
        summary: String
    ) -> Bool {
        explicitDeepInspectorRequested(userPrompt) ||
            confidence < defaultMinimumConfidence ||
            detectedFailure ||
            summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            (sceneChanged && explicitVisualQuestion(userPrompt))
    }

    private static func explicitDeepInspectorRequested(_ userPrompt: String) -> Bool {
        let lower = userPrompt.lowercased()
        return lower.contains("inspect") ||
            lower.contains("look carefully") ||
            lower.contains("analyze this") ||
            lower.contains("zoom") ||
            lower.contains("deep")
    }

    private static func explicitVisualQuestion(_ userPrompt: String) -> Bool {
        let lower = userPrompt.lowercased()
        return lower.contains("what is this") ||
            lower.contains("what do you see") ||
            lower.contains("look at") ||
            lower.contains("in front of me")
    }

    private static func expensiveDecision(
        lane: HierarchicalVisionLane,
        reason: String,
        model: String,
        frameID: Int,
        latencyMS: Int,
        evidenceClass: String,
        lastExpensiveVisionAtMS: Int?,
        nowMS: Int,
        expensiveVisionIntervalMS: Int
    ) -> HierarchicalVisionPolicyDecision {
        if let lastExpensiveVisionAtMS,
           nowMS - lastExpensiveVisionAtMS < expensiveVisionIntervalMS {
            return decision(
                lane: .sentinel,
                reason: "expensive_vision_rate_limited",
                frameID: frameID,
                model: model,
                latencyMS: latencyMS,
                evidenceClass: evidenceClass,
                escalationAllowed: false,
                rateLimited: true,
                staleRejected: false
            )
        }

        return decision(
            lane: lane,
            reason: reason,
            frameID: frameID,
            model: model,
            latencyMS: latencyMS,
            evidenceClass: evidenceClass,
            escalationAllowed: true,
            rateLimited: false,
            staleRejected: false
        )
    }

    private static func decision(
        lane: HierarchicalVisionLane,
        reason: String,
        frameID: Int,
        model: String,
        latencyMS: Int,
        evidenceClass: String,
        escalationAllowed: Bool,
        rateLimited: Bool,
        staleRejected: Bool
    ) -> HierarchicalVisionPolicyDecision {
        HierarchicalVisionPolicyDecision(
            lane: lane,
            reason: reason,
            frameID: frameID,
            model: model,
            latencyMS: latencyMS,
            evidenceClass: evidenceClass,
            escalationAllowed: escalationAllowed,
            rateLimited: rateLimited,
            staleRejected: staleRejected
        )
    }
}
