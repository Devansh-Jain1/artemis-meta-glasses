import Foundation

enum EmbeddingRouterAvailability: Equatable {
    case unavailable(reason: String)
    case ready
}

struct SemanticIntentDecision: Equatable {
    let route: String
    let confidence: Double
    let source: String
}

/// The source recovery run explicitly excluded the unvalidated router from its
/// golden path. Keep that lane fail-closed until its real runtime is ported and
/// independently accepted for this app.
final class EmbeddingGemmaIntentRouter: @unchecked Sendable {
    let availability = EmbeddingRouterAvailability.unavailable(
        reason: "embeddinggemma_experimental_runtime_not_ported"
    )

    func warm() async -> String {
        "embeddinggemma_experimental_runtime_not_ported"
    }

    func status() async -> String {
        "embeddinggemma_experimental_runtime_not_ported"
    }

    func route(finalTranscript: String) async -> SemanticIntentDecision? {
        nil
    }

    func probeDecision(finalTranscript: String) async -> SemanticIntentDecision? {
        nil
    }
}
