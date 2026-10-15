import Foundation

struct STTTurnFinalizationMetadata: Equatable, Sendable {
    let segmentCount: Int
    let confidenceMean: Double
    let confidenceMin: Double
    let durationSeconds: Double
    let lastSegmentText: String

    var hasUsableConfidence: Bool {
        segmentCount > 0 && confidenceMean > 0
    }
}

struct STTTurnFinalizationDecision: Equatable, Sendable {
    let shouldRoute: Bool
    let reason: String
    let delayNanoseconds: UInt64
}

enum STTTurnFinalizationPolicy {
    private static let commandWords: Set<String> = ["stop", "wait", "pause", "resume", "help"]
    private static let interruptionWords: Set<String> = ["cancel", "interrupt", "nevermind", "never mind"]
    private static let fillerPhrases: Set<String> = [
        "any", "ok", "okay", "yeah", "yep", "yes", "no", "nah", "uh", "um", "hmm", "mhm",
        "thanks", "thank you"
    ]
    private static let trailingFunctionWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "but", "for", "from", "if", "in",
        "is", "my", "of", "or", "that", "the", "then", "to", "was", "with", "you", "your"
    ]
    private static let shortIntentWords: Set<String> = [
        "answer", "check", "describe", "explain", "find", "help", "how", "look", "open",
        "read", "see", "show", "start", "stop", "tell", "test", "wait", "what", "where",
        "who", "why"
    ]
    private static let punctuationTerminators: Set<Character> = [".", "?", "!"]

    static func decision(
        transcript: String,
        isFinal: Bool,
        metadata: STTTurnFinalizationMetadata,
        stablePartialCount: Int,
        silenceDurationMS: Int,
        commandDelayNanoseconds: UInt64,
        shortUtteranceDelayNanoseconds: UInt64,
        readyUtteranceDelayNanoseconds: UInt64
    ) -> STTTurnFinalizationDecision {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let words = normalizedWords(in: lower)
        let wordCount = words.count

        guard !trimmed.isEmpty, wordCount > 0 else {
            return block("empty_partial", readyUtteranceDelayNanoseconds)
        }

        if wordCount == 1, let word = words.first {
            if interruptionWords.contains(word) {
                return allow("interruption_or_cancel", commandDelayNanoseconds)
            }
            if commandWords.contains(word) {
                return allow("explicit_short_command", commandDelayNanoseconds)
            }
        }

        if fillerPhrases.contains(lower) || (wordCount <= 2 && words.allSatisfy { fillerPhrases.contains($0) }) {
            return block("backchannel_or_filler_partial", shortUtteranceDelayNanoseconds)
        }

        if metadata.hasUsableConfidence, metadata.confidenceMean < 0.45 {
            return block("low_confidence_partial", shortUtteranceDelayNanoseconds)
        }

        if isFinal {
            return allow("final", readyUtteranceDelayNanoseconds)
        }

        if endsWithTerminator(trimmed) {
            return allow("punctuation_completion", shortUtteranceDelayNanoseconds)
        }

        if wordCount <= 1 {
            return block("single_word_non_command_partial", shortUtteranceDelayNanoseconds)
        }

        if let last = words.last, trailingFunctionWords.contains(last) {
            return block("trailing_function_word_partial", shortUtteranceDelayNanoseconds)
        }

        if silenceDurationMS >= 900, wordCount >= 2 {
            return allow("silence_completion", shortUtteranceDelayNanoseconds)
        }

        if wordCount <= 3 {
            guard words.contains(where: { shortIntentWords.contains($0) }) else {
                return block("short_partial_without_intent", shortUtteranceDelayNanoseconds)
            }
            guard stablePartialCount >= 2 else {
                return block("repeated_partial_unstable", shortUtteranceDelayNanoseconds)
            }
            return allow("repeated_partial_stable", shortUtteranceDelayNanoseconds)
        }

        return allow("semantic_completion", readyUtteranceDelayNanoseconds)
    }

    private static func normalizedWords(in lowercasedTranscript: String) -> [String] {
        lowercasedTranscript
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

    private static func endsWithTerminator(_ transcript: String) -> Bool {
        guard let last = transcript.last else { return false }
        return punctuationTerminators.contains(last)
    }

    private static func allow(_ reason: String, _ delayNanoseconds: UInt64) -> STTTurnFinalizationDecision {
        STTTurnFinalizationDecision(
            shouldRoute: true,
            reason: reason,
            delayNanoseconds: delayNanoseconds
        )
    }

    private static func block(_ reason: String, _ delayNanoseconds: UInt64) -> STTTurnFinalizationDecision {
        STTTurnFinalizationDecision(
            shouldRoute: false,
            reason: reason,
            delayNanoseconds: delayNanoseconds
        )
    }
}
