import Foundation

enum VoiceTurnTakingPolicy {
    static func isNonInterruptingBackchannel(_ transcript: String) -> Bool {
        let phrase = normalizedWords(transcript).joined(separator: " ")
        return [
            "mhm", "mmhm", "mmhmm", "uh huh", "uhuh"
        ].contains(phrase)
    }

    static func isMeaningfulSpeechSegment(
        durationSeconds: TimeInterval,
        maximumVADProbability: Float
    ) -> Bool {
        durationSeconds >= 0.8 && maximumVADProbability >= 0.75
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
