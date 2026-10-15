import Foundation

enum VisionFreshnessState: String, Equatable, Sendable {
    case currentConfident = "current_confident"
    case currentLowConfidence = "current_low_confidence"
    case stale
    case unavailable
    case streamStopped = "stream_stopped"

    var supportsDirectVisualClaim: Bool {
        self == .currentConfident
    }
}

struct VisionFreshnessVerdict: Equatable, Sendable {
    let state: VisionFreshnessState
    let reason: String

    var supportsDirectVisualClaim: Bool {
        state.supportsDirectVisualClaim
    }
}

enum VisionFreshnessPolicy {
    static let defaultStaleAfterMS = 2_500
    static let defaultMinimumConfidence = 0.55

    static func classify(
        frameID: Int,
        timestampMS: Int,
        ageMS: Int,
        confidence: Double,
        summary: String,
        visibleText: String,
        streamState: String,
        staleAfterMS: Int = defaultStaleAfterMS,
        minimumConfidence: Double = defaultMinimumConfidence
    ) -> VisionFreshnessVerdict {
        guard frameID > 0, timestampMS > 0, ageMS >= 0 else {
            return VisionFreshnessVerdict(
                state: .unavailable,
                reason: "no_usable_live_vision_frame"
            )
        }

        if isStoppedStreamState(streamState) {
            return VisionFreshnessVerdict(
                state: .streamStopped,
                reason: "dat_stream_not_live"
            )
        }

        if ageMS > staleAfterMS {
            return VisionFreshnessVerdict(
                state: .stale,
                reason: "vision_frame_age_exceeded_\(staleAfterMS)ms"
            )
        }

        let hasSemanticContent =
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard confidence >= minimumConfidence, hasSemanticContent else {
            return VisionFreshnessVerdict(
                state: .currentLowConfidence,
                reason: confidence < minimumConfidence
                    ? "vision_confidence_below_\(minimumConfidence)"
                    : "vision_semantic_content_empty"
            )
        }

        return VisionFreshnessVerdict(
            state: .currentConfident,
            reason: "vision_current_confident"
        )
    }

    private static func isStoppedStreamState(_ streamState: String) -> Bool {
        let normalized = streamState
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "stopped" ||
            normalized == "failed" ||
            normalized == "disconnected" ||
            normalized == "stream_stopped"
    }
}
