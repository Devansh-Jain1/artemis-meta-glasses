import Foundation

struct JarvisVoiceKokoroG2PResult: Equatable, Sendable {
    let sourceText: String
    let normalizedText: String
    let phonemes: String
    let frontendID: String
}

protocol JarvisVoiceKokoroG2PFrontend {
    var identifier: String { get }
    func phonemize(text: String) throws -> JarvisVoiceKokoroG2PResult
}

enum JarvisVoiceKokoroJSPhonemePostprocessor {
    static func processAmericanEnglish(_ input: String) -> String {
        var output = input
            .replacingOccurrences(of: "kəkˈoːɹoʊ", with: "kˈoʊkəɹoʊ")
            .replacingOccurrences(of: "kəkˈɔːɹəʊ", with: "kˈəʊkəɹəʊ")
            .replacingOccurrences(of: "ʲ", with: "j")
            .replacingOccurrences(of: "r", with: "ɹ")
            .replacingOccurrences(of: "x", with: "k")
            .replacingOccurrences(of: "ɬ", with: "l")
        output = replacing(
            pattern: #"(?<=[a-zɹː])(?=hˈʌndɹɪd)"#,
            with: " ",
            in: output
        )
        output = replacing(
            pattern: #" z(?=[;:,.!?(){}\[\] ]|$)"#,
            with: "z",
            in: output
        )
        return replacing(
            pattern: #"(?<=nˈaɪn)ti(?!ː)"#,
            with: "di",
            in: output
        )
    }

    private static func replacing(pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}

enum JarvisVoiceKokoroONNXSupportError: LocalizedError {
    case missingConfig
    case invalidConfig
    case missingVoiceStyle(String)
    case invalidVoiceStyleSize(actual: Int)
    case tooManyTokens(count: Int)
    case noTokens

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Kokoro ONNX config asset kokoro-config.json is missing."
        case .invalidConfig:
            return "Kokoro ONNX config asset could not be parsed."
        case let .missingVoiceStyle(voice):
            return "Kokoro ONNX voice style \(voice).bin is missing."
        case let .invalidVoiceStyleSize(actual):
            return "Kokoro ONNX voice style has invalid byte size: \(actual)."
        case let .tooManyTokens(count):
            return "Kokoro ONNX tokenized text is too long: \(count) tokens."
        case .noTokens:
            return "Kokoro ONNX tokenized text was empty."
        }
    }
}

struct JarvisVoiceKokoroONNXConfig: Decodable {
    let vocab: [String: Int]

    static func load(from url: URL) throws -> JarvisVoiceKokoroONNXConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JarvisVoiceKokoroONNXConfig.self, from: data)
    }
}

struct JarvisVoiceKokoroONNXTokenizedInput: Equatable {
    let phonemes: String
    let tokenIDs: [Int64]
    let paddedTokenIDs: [Int64]

    var unpaddedTokenCount: Int {
        tokenIDs.count
    }
}

struct JarvisVoiceKokoroONNXTokenizer {
    private let vocab: [String: Int]
    private let maxTokenCount = 510

    init(vocab: [String: Int]) {
        self.vocab = vocab
    }

    func tokenize(phonemes: String) throws -> JarvisVoiceKokoroONNXTokenizedInput {
        let tokenIDs = phonemes.compactMap { character -> Int64? in
            guard let tokenID = vocab[String(character)] else { return nil }
            return Int64(tokenID)
        }

        guard !tokenIDs.isEmpty else {
            throw JarvisVoiceKokoroONNXSupportError.noTokens
        }
        guard tokenIDs.count <= maxTokenCount else {
            throw JarvisVoiceKokoroONNXSupportError.tooManyTokens(count: tokenIDs.count)
        }

        return JarvisVoiceKokoroONNXTokenizedInput(
            phonemes: phonemes,
            tokenIDs: tokenIDs,
            paddedTokenIDs: [0] + tokenIDs + [0]
        )
    }
}

struct JarvisVoiceKokoroONNXVoiceStyle {
    private static let tokenStyleWidth = 256
    private static let maxStyleRows = 510
    private let samples: [Float]

    init(data: Data) throws {
        let expectedBytes = Self.maxStyleRows * Self.tokenStyleWidth * MemoryLayout<Float>.stride
        guard data.count == expectedBytes else {
            throw JarvisVoiceKokoroONNXSupportError.invalidVoiceStyleSize(actual: data.count)
        }

        self.samples = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    func vector(forPaddedTokenCount paddedTokenCount: Int) -> [Float] {
        let unpaddedCount = max(paddedTokenCount - 2, 0)
        let row = min(max(unpaddedCount, 0), Self.maxStyleRows - 1)
        let start = row * Self.tokenStyleWidth
        let end = start + Self.tokenStyleWidth
        return Array(samples[start ..< end])
    }
}
