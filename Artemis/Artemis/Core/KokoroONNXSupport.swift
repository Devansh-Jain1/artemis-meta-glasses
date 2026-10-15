import Foundation

enum KokoroONNXSupportError: LocalizedError {
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

struct KokoroONNXConfig: Decodable {
    let vocab: [String: Int]

    static func load(from url: URL) throws -> KokoroONNXConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(KokoroONNXConfig.self, from: data)
    }
}

struct KokoroONNXTokenizedInput: Equatable {
    let phonemes: String
    let tokenIDs: [Int64]
    let paddedTokenIDs: [Int64]

    var unpaddedTokenCount: Int {
        tokenIDs.count
    }
}

struct KokoroONNXTokenizer {
    private let vocab: [String: Int]
    private let maxTokenCount = 510

    init(vocab: [String: Int]) {
        self.vocab = vocab
    }

    func tokenize(phonemes: String) throws -> KokoroONNXTokenizedInput {
        let tokenIDs = phonemes.compactMap { character -> Int64? in
            guard let tokenID = vocab[String(character)] else { return nil }
            return Int64(tokenID)
        }

        guard !tokenIDs.isEmpty else {
            throw KokoroONNXSupportError.noTokens
        }
        guard tokenIDs.count <= maxTokenCount else {
            throw KokoroONNXSupportError.tooManyTokens(count: tokenIDs.count)
        }

        return KokoroONNXTokenizedInput(
            phonemes: phonemes,
            tokenIDs: tokenIDs,
            paddedTokenIDs: [0] + tokenIDs + [0]
        )
    }
}

struct KokoroONNXVoiceStyle {
    private static let tokenStyleWidth = 256
    private static let maxStyleRows = 510
    private let samples: [Float]

    init(data: Data) throws {
        let expectedBytes = Self.maxStyleRows * Self.tokenStyleWidth * MemoryLayout<Float>.stride
        guard data.count == expectedBytes else {
            throw KokoroONNXSupportError.invalidVoiceStyleSize(actual: data.count)
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
