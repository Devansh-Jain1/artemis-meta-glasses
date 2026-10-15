import Foundation

enum VoiceLifecycleEventV1: String, CaseIterable, Codable, Sendable {
    case requestAccepted = "request_accepted"
    case normalizationCompleted = "normalization_completed"
    case chunkQueued = "chunk_queued"
    case synthesisStarted = "synthesis_started"
    case firstAudioScheduled = "first_audio_scheduled"
    case playbackStarted = "playback_started"
    case chunkFinished = "chunk_finished"
    case playbackFinished = "playback_finished"
    case listeningResumed = "listening_resumed"
    case cancelled
    case staleAudioRejected = "stale_audio_rejected"
    case failed
}

enum VoiceFailureCodeV1: String, Codable, Sendable {
    case emptyText = "empty_text"
    case unsupportedExpressionControl = "unsupported_expression_control"
    case modelAssetsMissing = "model_assets_missing"
    case modelProvenanceMismatch = "model_provenance_mismatch"
    case voiceStyleMismatch = "voice_style_mismatch"
    case runtimeUnavailable = "runtime_unavailable"
    case synthesisFailed = "synthesis_failed"
    case emptyAudio = "empty_audio"
    case playbackBufferFailed = "playback_buffer_failed"
    case staleGeneration = "stale_generation"
    case cancelled
}

struct VoiceContractErrorV1: LocalizedError, Equatable, Sendable {
    let code: VoiceFailureCodeV1
    let detail: String

    var errorDescription: String? {
        "\(code.rawValue): \(detail)"
    }
}

struct VoiceContractV1: Codable, Equatable, Sendable {
    struct TextReplacement: Codable, Equatable, Sendable {
        let source: String
        let replacement: String
    }

    struct PronunciationOverride: Codable, Equatable, Sendable {
        let source: String
        let spoken: String
        let matchPolicy: String
    }

    struct NormalizationPolicy: Codable, Equatable, Sendable {
        let policyID: String
        let unicodeForm: String
        let punctuationReplacements: [TextReplacement]
        let markdownPattern: String
        let whitespacePattern: String
        let pronunciationOverrides: [PronunciationOverride]
    }

    struct RuntimeIdentity: Codable, Equatable, Sendable {
        let engine: String
        let adapter: String
        let adapterRevision: String
        let upstreamModelRevision: String
        let coreMLModelRevision: String
        let modelManifestSHA256: String
        let voiceID: String
        let voiceStyleSHA256: String
        let vectorEstimator: String
    }

    struct SampleFormat: Codable, Equatable, Sendable {
        let sampleRate: Int
        let channels: Int
        let representation: String
        let playbackHeadroomPeak: Float
        let edgeFadeMilliseconds: Int
    }

    struct ChunkingPolicy: Codable, Equatable, Sendable {
        let policyID: String
        let maximumCharacters: Int
        let preferredMinimumCharacters: Int
        let maximumOutstandingClips: Int
        let interChunkSilenceSeconds: Float
    }

    struct SeedPolicy: Codable, Equatable, Sendable {
        let policyID: String
        let baseSeed: UInt64
        let scope: String
    }

    let schema: String
    let normalization: NormalizationPolicy
    let runtime: RuntimeIdentity
    let sampleFormat: SampleFormat
    let chunking: ChunkingPolicy
    let seed: SeedPolicy
    let language: String
    let speed: Float
    let denoisingSteps: Int
    let supportedExpressionControls: [String]
    let documentedExpressionProbeTags: [String]
    let communityExpressionProbeTags: [String]
    let cancellationSemantics: String
    let failureSemantics: String
    let lifecycleEvents: [VoiceLifecycleEventV1]

    static let canonical = VoiceContractV1(
        schema: "artemis_voice_contract_v1",
        normalization: NormalizationPolicy(
            policyID: "nfkd_ascii_punctuation_markdown_whitespace_v1",
            unicodeForm: "NFKD",
            punctuationReplacements: [
                TextReplacement(source: "\u{2018}", replacement: "'"),
                TextReplacement(source: "\u{2019}", replacement: "'"),
                TextReplacement(source: "\u{201C}", replacement: "\""),
                TextReplacement(source: "\u{201D}", replacement: "\""),
                TextReplacement(source: "\u{2013}", replacement: "-"),
                TextReplacement(source: "\u{2014}", replacement: "-"),
                TextReplacement(source: "\u{2026}", replacement: "..."),
                TextReplacement(source: "\u{00A0}", replacement: " "),
            ],
            markdownPattern: #"[*_~`]+"#,
            whitespacePattern: #"\s+"#,
            pronunciationOverrides: [
                PronunciationOverride(
                    source: "EmbeddingGemma",
                    spoken: "Embedding Gemma",
                    matchPolicy: "case_insensitive_literal"
                ),
            ]
        ),
        runtime: RuntimeIdentity(
            engine: "supertonic_3_coreml",
            adapter: "FluidAudio",
            adapterRevision: "0a1baf7a2fa4b5458b918b54bfb09305e3226a93",
            upstreamModelRevision: "3cadd1ee6394adea1bd021217a0e650ede09a323",
            coreMLModelRevision: "9f3606bf5c5ff9d6680cf6226614ac61358a24f3",
            modelManifestSHA256: "719170fcb59ae4c5616aff9e9d33f22459e9cc7a7bad7073c004b031d2c4bd60",
            voiceID: "F1",
            voiceStyleSHA256: "bbdec6ee00231c2c742ad05483df5334cab3b52fda3ba38e6a07059c4563dbc2",
            vectorEstimator: "ane_bucketed_int4"
        ),
        sampleFormat: SampleFormat(
            sampleRate: 44_100,
            channels: 1,
            representation: "float32_pcm",
            playbackHeadroomPeak: 0.85,
            edgeFadeMilliseconds: 5
        ),
        chunking: ChunkingPolicy(
            policyID: "sentence_clause_max70_v1",
            maximumCharacters: 70,
            preferredMinimumCharacters: 20,
            maximumOutstandingClips: 3,
            interChunkSilenceSeconds: 0
        ),
        seed: SeedPolicy(
            policyID: "splitmix64_per_contract_chunk_v1",
            baseSeed: 0x4152_5445_4D49_5331,
            scope: "fixed_product_seed_then_stable_contract_chunk_derivation"
        ),
        language: "en",
        speed: 1.05,
        denoisingSteps: 8,
        supportedExpressionControls: [],
        documentedExpressionProbeTags: ["<laugh>", "<breath>", "<sigh>"],
        communityExpressionProbeTags: [
            "<surprise>", "<scream>", "<throatclear>", "<sad>",
            "<angry>", "<cough>", "<yawn>",
        ],
        cancellationSemantics: "cancel_through_current_epoch_and_reject_stale_audio",
        failureSemantics: "fail_closed_without_alternate_tts",
        lifecycleEvents: VoiceLifecycleEventV1.allCases
    )

    func normalize(_ source: String) throws -> String {
        let punctuationNormalized = normalization.punctuationReplacements.reduce(source) {
            value, replacement in
            value.replacingOccurrences(
                of: replacement.source,
                with: replacement.replacement
            )
        }

        if punctuationNormalized.range(
            of: #"<[A-Za-z][A-Za-z0-9_-]*>"#,
            options: .regularExpression
        ) != nil {
            throw VoiceContractErrorV1(
                code: .unsupportedExpressionControl,
                detail: "Expression tags are probe-only until seeded audible review passes."
            )
        }

        let markdownRemoved = punctuationNormalized.replacingOccurrences(
            of: normalization.markdownPattern,
            with: " ",
            options: .regularExpression
        )
        let whitespaceCollapsed = markdownRemoved.replacingOccurrences(
            of: normalization.whitespacePattern,
            with: " ",
            options: .regularExpression
        )
        var normalized = whitespaceCollapsed
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .decomposedStringWithCompatibilityMapping
        for pronunciation in normalization.pronunciationOverrides {
            let options: String.CompareOptions
            switch pronunciation.matchPolicy {
            case "case_insensitive_literal":
                options = [.caseInsensitive, .literal]
            default:
                options = [.literal]
            }
            normalized = normalized.replacingOccurrences(
                of: pronunciation.source,
                with: pronunciation.spoken,
                options: options
            )
        }
        guard normalized.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw VoiceContractErrorV1(
                code: .emptyText,
                detail: "Text contains no speakable letters or numbers."
            )
        }
        return normalized
    }

    func chunks(for source: String) throws -> [String] {
        let normalized = try normalize(source)
        var chunks: [String] = []
        var remaining = normalized[...]

        while !remaining.isEmpty {
            if remaining.count <= chunking.maximumCharacters {
                chunks.append(String(remaining))
                break
            }

            let hardEnd = remaining.index(
                remaining.startIndex,
                offsetBy: chunking.maximumCharacters
            )
            let search = remaining[..<hardEnd]
            let preferredStart = search.index(
                search.startIndex,
                offsetBy: min(chunking.preferredMinimumCharacters, search.count)
            )
            let preferred = search[preferredStart...]
            let boundary = preferred.lastIndex(where: { character in
                character.isWhitespace || ",;:!?.".contains(character)
            }) ?? search.lastIndex(where: \.isWhitespace) ?? hardEnd

            var split = boundary
            if split < remaining.endIndex,
               !remaining[split].isWhitespace,
               ",;:!?.".contains(remaining[split]) {
                split = remaining.index(after: split)
            }
            let chunk = remaining[..<split]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            remaining = remaining[split...]
                .drop(while: \.isWhitespace)
        }
        return chunks
    }

    func seed(forChunkIndex index: Int) -> UInt64 {
        var value = seed.baseSeed &+ UInt64(max(0, index)) &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct VoiceContractStreamAccumulatorV1: Sendable {
    private(set) var pendingText = ""
    private let contract: VoiceContractV1

    init(contract: VoiceContractV1 = .canonical) {
        self.contract = contract
    }

    mutating func append(_ fragment: String) throws -> [String] {
        pendingText += fragment
        guard let boundary = streamingBoundary(in: pendingText) else { return [] }
        let ready = String(pendingText[..<boundary])
        pendingText = String(pendingText[boundary...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try contract.chunks(for: ready)
    }

    mutating func finish() throws -> [String] {
        defer { pendingText = "" }
        guard pendingText.contains(where: { $0.isLetter || $0.isNumber }) else {
            return []
        }
        return try contract.chunks(for: pendingText)
    }

    private func streamingBoundary(in text: String) -> String.Index? {
        guard !text.isEmpty else { return nil }
        var index = text.startIndex
        var lastWhitespace: String.Index?
        while index < text.endIndex {
            let next = text.index(after: index)
            let length = text.distance(from: text.startIndex, to: next)
            let character = text[index]
            if character.isWhitespace {
                lastWhitespace = next
            }
            if ".!?".contains(character),
               next == text.endIndex || text[next].isWhitespace {
                return next
            }
            if length >= contract.chunking.maximumCharacters, let lastWhitespace {
                return lastWhitespace
            }
            index = next
        }
        return nil
    }
}
