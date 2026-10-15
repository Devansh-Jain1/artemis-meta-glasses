import Foundation

struct JarvisVoiceTTSLifecycleToken: Equatable, Sendable {
    let epoch: Int
    let generation: Int
    let reason: String
}

enum JarvisVoiceTTSLifecycleDecision: Equatable, Sendable {
    case accept
    case rejectStale(reason: String)
}

struct JarvisVoiceTTSRouteProof: Equatable, Sendable {
    let routeDescription: String
    let playbackState: String
    let audioEngineRunning: Bool
    let playerNodePlaying: Bool
    let scheduledBufferFrames: Int

    var audibilityProof: String {
        guard !routeDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              playbackState == "scheduled_after_player_play",
              audioEngineRunning,
              playerNodePlaying,
              scheduledBufferFrames > 0 else {
            return "scheduled_buffer_not_human_audible"
        }
        return "scheduled_buffer_route_proven"
    }
}

struct JarvisVoiceTTSLifecycle: Sendable {
    private(set) var currentEpoch = 0
    private(set) var currentGeneration = 0
    private(set) var cancelledThroughEpoch = 0

    mutating func beginPlayback(reason: String) -> JarvisVoiceTTSLifecycleToken {
        currentEpoch += 1
        currentGeneration += 1
        return JarvisVoiceTTSLifecycleToken(
            epoch: currentEpoch,
            generation: currentGeneration,
            reason: reason
        )
    }

    @discardableResult
    mutating func cancelThroughCurrent(reason: String) -> Int {
        cancelledThroughEpoch = max(cancelledThroughEpoch, currentEpoch)
        return cancelledThroughEpoch
    }

    func acceptGenerated(_ token: JarvisVoiceTTSLifecycleToken) -> JarvisVoiceTTSLifecycleDecision {
        if token.epoch <= cancelledThroughEpoch {
            return .rejectStale(reason: "cancelled_through_epoch")
        }
        if token.epoch != currentEpoch || token.generation != currentGeneration {
            return .rejectStale(reason: "generation_mismatch")
        }
        return .accept
    }
}
