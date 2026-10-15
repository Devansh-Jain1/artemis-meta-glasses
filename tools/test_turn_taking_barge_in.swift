import Foundation

private final class CapturingTurnDelegate: TurnTakingDelegate {
    var stopTTSCount = 0
    var detectedBargeIns: [String] = []
    var completedTurns: [String] = []
    var startedListeningCount = 0
    var processingTimeouts: [Double] = []
    var states: [TurnState] = []

    func turnTakingDidChangeState(from: TurnState, to: TurnState) {
        states.append(to)
    }

    func turnTakingDidDetectBargeIn(transcribedText: String) {
        detectedBargeIns.append(transcribedText)
    }

    func turnTakingDidCompleteTurn(userText: String) {
        completedTurns.append(userText)
    }

    func turnTakingDidTimeoutProcessing(afterMilliseconds milliseconds: Double) {
        processingTimeouts.append(milliseconds)
    }

    func turnTakingShouldStartListening() {
        startedListeningCount += 1
    }

    func turnTakingShouldStopTTS() {
        stopTTSCount += 1
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TurnTakingBargeInTestMain {
    static func main() {
        let manager = TurnTakingManager.shared
        let delegate = CapturingTurnDelegate()
        manager.delegate = delegate
        manager.reset()

        manager.onTTSStart(text: "Hello! I am online. What would you like to test?")
        manager.onTranscript("Hello", isFinal: false)

        require(delegate.stopTTSCount == 0, "short TTS fragment should be rejected as echo")
        require(delegate.detectedBargeIns.isEmpty, "short TTS fragment must not be reported as barge-in")
        require(manager.currentState == .agentSpeaking, "manager should keep speaking after rejecting short echo")

        manager.onTranscript("Hello what would you like to", isFinal: false)
        require(delegate.stopTTSCount == 0, "multi-word TTS phrase fragment should be rejected as echo")
        require(delegate.detectedBargeIns.isEmpty, "multi-word TTS phrase fragment must not be reported as barge-in")
        require(manager.currentState == .agentSpeaking, "manager should keep speaking after rejecting multi-word echo")

        manager.reset()
        delegate.stopTTSCount = 0
        delegate.detectedBargeIns.removeAll()
        delegate.completedTurns.removeAll()
        delegate.states.removeAll()

        manager.onTTSStart(text: "Artemis is live. I am listening and ready for your first request.")
        manager.onTranscript("describe the room around me", isFinal: false)

        require(delegate.stopTTSCount == 1, "valid non-echo speech during TTS should stop TTS")
        require(delegate.detectedBargeIns == ["describe the room around me"], "barge-in text should be reported")
        require(manager.currentState == .userSpeaking, "manager should transition back to userSpeaking after barge-in")

        manager.reset()
        delegate.stopTTSCount = 0
        delegate.detectedBargeIns.removeAll()
        delegate.completedTurns.removeAll()
        delegate.states.removeAll()

        manager.onTTSStart(text: "Artemis is live. I am listening and ready for your first request.")
        manager.onTranscript("wait what do you see", isFinal: true)

        require(delegate.stopTTSCount == 1, "final barge-in should stop TTS")
        require(delegate.detectedBargeIns == ["wait what do you see"], "final barge-in text should be reported")
        require(delegate.completedTurns == ["wait what do you see"], "final barge-in must route as a completed user turn")
        require(manager.currentState == .processing, "final barge-in should transition into processing")

        print("TurnTaking barge-in tests passed")
    }
}
