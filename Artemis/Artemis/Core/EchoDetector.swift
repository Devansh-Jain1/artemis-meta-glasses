import Foundation
import AVFoundation

// MARK: - Echo Detection System
/// Multi-layered echo detection to prevent false barge-in triggers
/// Combines: text similarity, timing correlation, and audio energy analysis

public final class EchoDetector {
    
    public static let shared = EchoDetector()
    
    // MARK: - Configuration
    
    private struct Config {
        static let textSimilarityThreshold: Double = 0.4      // Lower = more strict
        static let echoWindowMs: Double = 3000                // Window to check for echo
        static let minWordOverlap: Int = 2                    // Min words to consider echo
        static let energyRatioThreshold: Float = 0.3          // Audio energy comparison
        static let recentUtteranceLimit: Int = 5              // Keep last N utterances
    }
    
    // MARK: - State
    
    /// Recent TTS outputs for comparison
    private var recentTTSOutputs: [(text: String, timestamp: Date)] = []
    
    /// Recent audio energy levels during TTS
    private var ttsAudioEnergy: [Float] = []
    
    /// Whether TTS is currently playing
    private(set) var isTTSActive: Bool = false
    
    /// Timestamp when TTS started
    private var ttsStartTime: Date?
    
    /// Timestamp when TTS ended
    private var ttsEndTime: Date?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - TTS State Management
    
    /// Call when TTS starts speaking
    public func ttsDidStart(text: String) {
        isTTSActive = true
        ttsStartTime = Date()
        ttsEndTime = nil
        
        // Store the TTS output for echo comparison
        recentTTSOutputs.append((text: text.lowercased(), timestamp: Date()))
        
        // Trim old entries
        if recentTTSOutputs.count > Config.recentUtteranceLimit {
            recentTTSOutputs.removeFirst()
        }
        
        print("[EchoDetector] TTS started: \"\(text.prefix(50))...\"")
    }
    
    /// Call when TTS finishes speaking
    public func ttsDidEnd() {
        isTTSActive = false
        ttsEndTime = Date()
        print("[EchoDetector] TTS ended")
    }
    
    // MARK: - Echo Detection
    
    /// Main detection function - returns true if input appears to be echo
    public func isEcho(transcribedText: String) -> EchoDetectionResult {
        let inputLower = transcribedText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check 1: During active TTS, only reject text that resembles recent TTS.
        // Treating all active-TTS transcripts as echo blocks real barge-in.
        if isTTSActive {
            if let fragmentResult = checkActiveTTSFragment(input: inputLower) {
                print("[EchoDetector] ⚠️ Active TTS phrase fragment detected: \(fragmentResult)")
                return EchoDetectionResult(
                    isEcho: true,
                    confidence: 0.9,
                    reason: "Active TTS phrase fragment: \(fragmentResult)"
                )
            }

            let textResult = checkTextSimilarity(input: inputLower)
            if textResult.isSimilar {
                print("[EchoDetector] ⚠️ Active TTS text similarity detected: \(textResult.similarity)")
                return EchoDetectionResult(
                    isEcho: true,
                    confidence: textResult.similarity,
                    reason: "Active TTS text similarity: \(String(format: "%.2f", textResult.similarity))"
                )
            }

            let overlapResult = checkWordOverlap(input: inputLower)
            if overlapResult.hasSignificantOverlap {
                print("[EchoDetector] ⚠️ Active TTS word overlap detected: \(overlapResult.overlappingWords)")
                return EchoDetectionResult(
                    isEcho: true,
                    confidence: Double(overlapResult.overlapCount) / Double(max(inputLower.split(separator: " ").count, 1)),
                    reason: "Active TTS word overlap: \(overlapResult.overlappingWords.joined(separator: ", "))"
                )
            }

            if inputLower.count < 3 {
                return EchoDetectionResult(isEcho: true, confidence: 0.7, reason: "Too short during active TTS")
            }

            print("[EchoDetector] ✅ Active TTS but transcript differs from TTS")
            return EchoDetectionResult(isEcho: false, confidence: 0.0, reason: "Active TTS but no echo pattern")
        }
        
        // Check 2: Is this within the echo window after TTS?
        if let endTime = ttsEndTime {
            let timeSinceTTS = Date().timeIntervalSince(endTime) * 1000 // ms
            if timeSinceTTS < Config.echoWindowMs {
                // Within echo window - do text comparison
                let textResult = checkTextSimilarity(input: inputLower)
                if textResult.isSimilar {
                    print("[EchoDetector] ⚠️ Text similarity detected: \(textResult.similarity)")
                    return EchoDetectionResult(
                        isEcho: true,
                        confidence: textResult.similarity,
                        reason: "Text matches recent TTS (similarity: \(String(format: "%.2f", textResult.similarity)))"
                    )
                }
            }
        }
        
        // Check 3: Word overlap detection
        let overlapResult = checkWordOverlap(input: inputLower)
        if overlapResult.hasSignificantOverlap {
            print("[EchoDetector] ⚠️ Word overlap detected: \(overlapResult.overlappingWords)")
            return EchoDetectionResult(
                isEcho: true,
                confidence: Double(overlapResult.overlapCount) / Double(max(inputLower.split(separator: " ").count, 1)),
                reason: "Word overlap with TTS: \(overlapResult.overlappingWords.joined(separator: ", "))"
            )
        }
        
        // Check 4: Exact substring match
        for ttsOutput in recentTTSOutputs {
            if ttsOutput.text.contains(inputLower) || inputLower.contains(ttsOutput.text.prefix(20)) {
                let timeSince = Date().timeIntervalSince(ttsOutput.timestamp) * 1000
                if timeSince < Config.echoWindowMs * 2 {
                    print("[EchoDetector] ⚠️ Substring match detected")
                    return EchoDetectionResult(
                        isEcho: true,
                        confidence: 0.8,
                        reason: "Substring match with recent TTS"
                    )
                }
            }
        }
        
        // Not detected as echo
        print("[EchoDetector] ✅ Not echo: \"\(inputLower.prefix(30))...\"")
        return EchoDetectionResult(isEcho: false, confidence: 0.0, reason: "No echo patterns detected")
    }
    
    // MARK: - Text Similarity
    
    private func checkTextSimilarity(input: String) -> (isSimilar: Bool, similarity: Double) {
        var maxSimilarity: Double = 0.0
        
        for ttsOutput in recentTTSOutputs {
            let similarity = calculateJaccardSimilarity(input, ttsOutput.text)
            maxSimilarity = max(maxSimilarity, similarity)
        }
        
        return (isSimilar: maxSimilarity >= Config.textSimilarityThreshold, similarity: maxSimilarity)
    }

    private func calculateJaccardSimilarity(_ str1: String, _ str2: String) -> Double {
        let words1 = Set(normalizedWords(str1))
        let words2 = Set(normalizedWords(str2))
        
        guard !words1.isEmpty || !words2.isEmpty else { return 0.0 }
        
        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count
        
        return Double(intersection) / Double(union)
    }
    
    // MARK: - Word Overlap

    private func checkActiveTTSFragment(input: String) -> String? {
        let inputWords = normalizedWords(input)
        guard !inputWords.isEmpty, inputWords.count <= 8 else { return nil }

        for ttsOutput in recentTTSOutputs {
            let ttsWords = normalizedWords(ttsOutput.text)
            if isOrderedPhrase(inputWords, in: ttsWords) {
                return (inputWords.joined(separator: " "))
            }
        }
        return nil
    }

    private func isOrderedPhrase(_ phrase: [String], in source: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= source.count else { return false }
        for startIndex in 0...(source.count - phrase.count) {
            let endIndex = startIndex + phrase.count
            if Array(source[startIndex..<endIndex]) == phrase {
                return true
            }
        }
        return false
    }
    
    private func checkWordOverlap(input: String) -> (hasSignificantOverlap: Bool, overlapCount: Int, overlappingWords: [String]) {
        let inputWords = Set(normalizedWords(input))
        var allOverlapping: [String] = []
        
        for ttsOutput in recentTTSOutputs {
            let ttsWords = Set(normalizedWords(ttsOutput.text))
            let overlap = inputWords.intersection(ttsWords)
            
            // Filter out common words
            let significantOverlap = overlap.filter { word in
                !isCommonWord(word)
            }
            
            allOverlapping.append(contentsOf: significantOverlap)
        }
        
        let uniqueOverlap = Array(Set(allOverlapping))
        return (
            hasSignificantOverlap: uniqueOverlap.count >= Config.minWordOverlap,
            overlapCount: uniqueOverlap.count,
            overlappingWords: uniqueOverlap
        )
    }
    
    private func isCommonWord(_ word: String) -> Bool {
        let commonWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "must", "shall", "can", "need", "dare",
            "i", "you", "he", "she", "it", "we", "they", "me", "him", "her",
            "us", "them", "my", "your", "his", "its", "our", "their",
            "this", "that", "these", "those", "what", "which", "who", "whom",
            "and", "but", "or", "nor", "for", "yet", "so", "as", "if", "then",
            "to", "of", "in", "on", "at", "by", "with", "from", "up", "down",
            "just", "very", "really", "quite", "too", "also", "only", "even",
            "yes", "no", "ok", "okay", "um", "uh", "like", "well", "so"
        ]
        return commonWords.contains(word.lowercased())
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
    
    // MARK: - Barge-in Detection
    
    /// Check if input is a valid barge-in (not echo, contains interrupt keywords)
    public func isValidBargeIn(transcribedText: String) -> BargeInResult {
        let inputLower = transcribedText.lowercased()

        if containsInterruptKeyword(inputLower) {
            return BargeInResult(
                isValid: true,
                reason: "Interrupt keyword detected",
                shouldInterrupt: true
            )
        }

        // First check if it's echo
        let echoResult = isEcho(transcribedText: transcribedText)
        if echoResult.isEcho {
            return BargeInResult(
                isValid: false,
                reason: "Detected as echo: \(echoResult.reason)",
                shouldInterrupt: false
            )
        }
        
        // Check for interrupt keywords
        if containsInterruptKeyword(inputLower) {
            return BargeInResult(
                isValid: true,
                reason: "Interrupt keyword detected",
                shouldInterrupt: true
            )
        }

        // Valid speech but not an interrupt command
        return BargeInResult(
            isValid: true,
            reason: "Valid user speech (no interrupt keyword)",
            shouldInterrupt: false
        )
    }

    private func containsInterruptKeyword(_ inputLower: String) -> Bool {
        let interruptKeywords = [
            "stop", "wait", "hold on", "actually", "no", "cancel",
            "nevermind", "never mind", "shut up", "quiet", "pause",
            "hey", "excuse me", "hang on", "one second", "hold up"
        ]

        return interruptKeywords.contains { inputLower.contains($0) }
    }
    
    // MARK: - Reset
    
    public func reset() {
        recentTTSOutputs.removeAll()
        ttsAudioEnergy.removeAll()
        isTTSActive = false
        ttsStartTime = nil
        ttsEndTime = nil
        print("[EchoDetector] Reset")
    }
}

// MARK: - Result Types

public struct EchoDetectionResult {
    public let isEcho: Bool
    public let confidence: Double
    public let reason: String
}

public struct BargeInResult {
    public let isValid: Bool
    public let reason: String
    public let shouldInterrupt: Bool
}
