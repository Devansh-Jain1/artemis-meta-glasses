import Foundation

enum EspeakNGG2PError: LocalizedError {
    case missingResourceDirectory
    case initializationFailed(String)
    case phonemizationFailed(String)
    case invalidPronunciationMarkup
    case emptyPhonemes

    var errorDescription: String? {
        switch self {
        case .missingResourceDirectory:
            return "The app bundle has no resource directory for eSpeak data."
        case let .initializationFailed(message):
            return "Bundled eSpeak G2P initialization failed: \(message)"
        case let .phonemizationFailed(message):
            return "Bundled eSpeak G2P phonemization failed: \(message)"
        case .invalidPronunciationMarkup:
            return "Explicit pronunciation markup could not be parsed."
        case .emptyPhonemes:
            return "Bundled eSpeak G2P generated no phonemes."
        }
    }
}

final class EspeakNGG2PFrontend: JarvisVoiceKokoroG2PFrontend {
    let identifier = "espeak_ng_1.52_phonemizer_1.2.1_en_us"

    private static let errorBufferSize = 512
    private static let pronunciationMarkup = try! NSRegularExpression(
        pattern: #"\[([^\]\n]+)\]\(/([^/\n]+)/\)"#
    )
    private static let punctuation = try! NSRegularExpression(
        pattern: #"(\s*[;:,.!?(){}\[\]]+\s*)+"#
    )

    init(bundle: Bundle = .main) throws {
        guard let resourceURL = bundle.resourceURL else {
            throw EspeakNGG2PError.missingResourceDirectory
        }
        var errorBuffer = [CChar](repeating: 0, count: Self.errorBufferSize)
        let errorBufferSize = errorBuffer.count
        let initialized = resourceURL.path.withCString { resourcePath in
            artemis_espeak_initialize(
                resourcePath,
                &errorBuffer,
                errorBufferSize
            )
        }
        guard initialized else {
            throw EspeakNGG2PError.initializationFailed(Self.errorMessage(from: errorBuffer))
        }
    }

    func phonemize(text: String) throws -> JarvisVoiceKokoroG2PResult {
        let normalized = JarvisVoiceTTSChunker.normalizedEnglishText(text)
        let phonemes = try phonemizeMarkupAware(normalized)
        let processed = JarvisVoiceKokoroJSPhonemePostprocessor.processAmericanEnglish(phonemes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processed.isEmpty else {
            throw EspeakNGG2PError.emptyPhonemes
        }
        return JarvisVoiceKokoroG2PResult(
            sourceText: text,
            normalizedText: normalized,
            phonemes: processed,
            frontendID: identifier
        )
    }

    private func phonemizeMarkupAware(_ text: String) throws -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = Self.pronunciationMarkup.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            return try phonemizePreservingPunctuation(text)
        }

        var pieces: [String] = []
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let phonemeRange = Range(match.range(at: 2), in: text) else {
                throw EspeakNGG2PError.invalidPronunciationMarkup
            }
            if cursor < matchRange.lowerBound {
                pieces.append(try phonemizePreservingPunctuation(
                    String(text[cursor ..< matchRange.lowerBound])
                ))
            }
            pieces.append(String(text[phonemeRange]))
            cursor = matchRange.upperBound
        }
        if cursor < text.endIndex {
            pieces.append(try phonemizePreservingPunctuation(String(text[cursor...])))
        }
        return pieces.joined(separator: " ")
    }

    private func phonemizePreservingPunctuation(_ text: String) throws -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = Self.punctuation.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            return try nativePhonemes(text)
        }

        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            if cursor < matchRange.lowerBound {
                output += try nativePhonemes(String(text[cursor ..< matchRange.lowerBound]))
            }
            output += String(text[matchRange])
            cursor = matchRange.upperBound
        }
        if cursor < text.endIndex {
            output += try nativePhonemes(String(text[cursor...]))
        }
        return output
    }

    private func nativePhonemes(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard JarvisVoiceTTSChunker.containsSpeakableContent(trimmed) else { return text }

        var errorBuffer = [CChar](repeating: 0, count: Self.errorBufferSize)
        let errorBufferSize = errorBuffer.count
        let result = trimmed.withCString { textPointer in
            artemis_espeak_phonemize(
                textPointer,
                &errorBuffer,
                errorBufferSize
            )
        }
        guard let result else {
            throw EspeakNGG2PError.phonemizationFailed(Self.errorMessage(from: errorBuffer))
        }
        defer { artemis_espeak_free(result) }
        return String(cString: result)
            .replacingOccurrences(of: "\u{200D}", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static func errorMessage(from buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return "unknown eSpeak error" }
            return String(cString: baseAddress)
        }
    }
}
