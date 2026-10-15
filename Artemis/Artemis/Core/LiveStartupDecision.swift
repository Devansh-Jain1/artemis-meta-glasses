import Foundation

enum LiveStartupTrigger: Equatable {
    case wait
    case queueWithoutVision
    case queueWithPreview
}

enum LiveStartupDecision {
    static func trigger(
        shouldSpeakStartupGreeting: Bool,
        didSpeakStartupGreeting: Bool,
        liveGoldenModeEnabled: Bool,
        appLifecycleState: String,
        previewImageAvailable: Bool
    ) -> LiveStartupTrigger {
        guard shouldSpeakStartupGreeting, !didSpeakStartupGreeting else {
            return .wait
        }
        if previewImageAvailable {
            return .queueWithPreview
        }
        if liveGoldenModeEnabled && appLifecycleState == "active" {
            return .queueWithoutVision
        }
        return .wait
    }
}
