import Foundation

enum ArtemisTTSChunker {
    static func containsSpeakableContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    static func normalizedEnglishText(_ input: String) -> String {
        let punctuationNormalized = input
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let protected = protectPronunciationMarkup(in: punctuationNormalized)
        var normalized = protected.text
            .replacing(pattern: #"[*_~`]+"#, with: " ")
            .replacing(pattern: #"[^A-Za-z0-9\s.,!?;:'"()\-]+"#, with: " ")
            .replacing(pattern: #"\s+"#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for (marker, markup) in protected.markup {
            normalized = normalized.replacingOccurrences(of: marker, with: markup)
        }
        return normalized
    }

    static func chunks(
        for text: String,
        minChunkLength: Int = 20,
        maxChunkBeforeSplit: Int = 80
    ) -> [String] {
        let protectedText = text
            .replacing(pattern: #"(\d)\.(\d)"#, with: "$1<dot>$2")
            .replacing(
                pattern: #"\b(Tab|Tabs|Fig|Figs|Eq|Eqs|Sec|Secs|No|Nos|Ref|Refs|Dr|Mr|Mrs|Ms|Prof|vs|etc)\."#,
                with: "$1<dot>"
            )

        let coarse = splitTerminalSentences(protectedText)
        var fine: [String] = []

        for chunk in coarse {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.count <= maxChunkBeforeSplit {
                fine.append(trimmed)
                continue
            }

            fine.append(contentsOf: splitLongClause(
                trimmed,
                minChunkLength: minChunkLength
            ))
        }

        return fine
            .map { normalizedEnglishText($0.replacingOccurrences(of: "<dot>", with: ".")) }
            .filter { containsSpeakableContent($0) }
    }

    private static func splitTerminalSentences(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            current.unicodeScalars.append(scalar)

            if scalar == "." || scalar == "!" || scalar == "?" {
                var lookahead = index + 1
                while lookahead < scalars.count,
                      CharacterSet.whitespacesAndNewlines.contains(scalars[lookahead]) {
                    lookahead += 1
                }

                if lookahead >= scalars.count || isUppercaseLetterOrDigit(scalars[lookahead]) {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        chunks.append(trimmed)
                    }
                    current.removeAll(keepingCapacity: true)

                    while index + 1 < scalars.count,
                          CharacterSet.whitespacesAndNewlines.contains(scalars[index + 1]) {
                        index += 1
                    }
                }
            }

            index += 1
        }

        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            chunks.append(trailing)
        }
        return chunks
    }

    private static func splitLongClause(_ chunk: String, minChunkLength: Int) -> [String] {
        let clauses = splitAfterBoundaryWhitespace(chunk)
        var merged: [String] = []
        var leadingShortClause = ""

        for part in clauses {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.count < minChunkLength && merged.isEmpty {
                leadingShortClause = leadingShortClause.isEmpty
                    ? trimmed
                    : "\(leadingShortClause) \(trimmed)"
            } else if !leadingShortClause.isEmpty {
                merged.append("\(leadingShortClause) \(trimmed)")
                leadingShortClause = ""
            } else if let last = merged.indices.last, trimmed.count < minChunkLength {
                merged[last] = "\(merged[last]) \(trimmed)"
            } else {
                merged.append(trimmed)
            }
        }

        if !leadingShortClause.isEmpty {
            if let last = merged.indices.last {
                merged[last] = "\(merged[last]) \(leadingShortClause)"
            } else {
                merged.append(leadingShortClause)
            }
        }

        return merged
    }

    private static func splitAfterBoundaryWhitespace(_ text: String) -> [String] {
        let boundaries = Set<Character>([",", ";", ":", "-", "\u{2013}", "\u{2014}"])
        var parts: [String] = []
        var current = ""
        var previous: Character?

        for character in text {
            if character.isWhitespace, let previous, boundaries.contains(previous) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
            previous = character
        }

        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            parts.append(trailing)
        }
        return parts
    }

    private static func isUppercaseLetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.decimalDigits.contains(scalar)
            || CharacterSet.uppercaseLetters.contains(scalar)
    }

    private static func protectPronunciationMarkup(
        in text: String
    ) -> (text: String, markup: [(String, String)]) {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[[^\]\n]+\]\(/[^/\n]+/\)"#
        ) else {
            return (text, [])
        }
        let matches = regex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        var protectedText = text
        var replacements: [(String, String)] = []
        for (offset, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range, in: protectedText) else { continue }
            let marker = "ARTEMISPHONEMARKER\(offset)END"
            let markup = String(protectedText[range])
            protectedText.replaceSubrange(range, with: marker)
            replacements.append((marker, markup))
        }
        return (protectedText, replacements)
    }

    static func firstStreamingBoundary(
        in text: String,
        preferredClauseLimit: Int = 96,
        hardWordLimit: Int = 140
    ) -> String.Index? {
        guard !text.isEmpty else { return nil }
        var index = text.startIndex
        var lastClauseBoundary: String.Index?
        var lastWordBoundary: String.Index?

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let prefixLength = text.distance(from: text.startIndex, to: next)

            if character.isWhitespace {
                lastWordBoundary = next
            }

            if ",;:\u{2013}\u{2014}-".contains(character),
               next == text.endIndex || text[next].isWhitespace {
                lastClauseBoundary = next
            }

            if ".!?".contains(character),
               !isProtectedStreamingPeriod(text, at: index),
               next == text.endIndex || text[next].isWhitespace {
                return next
            }

            if prefixLength >= preferredClauseLimit, let lastClauseBoundary {
                return lastClauseBoundary
            }
            if prefixLength >= hardWordLimit, let lastWordBoundary {
                return lastWordBoundary
            }
            index = next
        }
        return nil
    }

    private static func isProtectedStreamingPeriod(_ text: String, at index: String.Index) -> Bool {
        guard text[index] == "." else { return false }
        let previous = index > text.startIndex ? text[text.index(before: index)] : nil
        let next = text.index(after: index)
        if previous?.isNumber == true, next < text.endIndex, text[next].isNumber {
            return true
        }

        var tokenStart = index
        while tokenStart > text.startIndex {
            let candidate = text.index(before: tokenStart)
            guard text[candidate].isLetter else { break }
            tokenStart = candidate
        }
        let token = text[tokenStart..<index].lowercased()
        return [
            "tab", "tabs", "fig", "figs", "eq", "eqs", "sec", "secs",
            "no", "nos", "ref", "refs", "dr", "mr", "mrs", "ms", "prof",
            "vs", "etc"
        ].contains(token)
    }
}

struct ArtemisTTSStreamAccumulator: Sendable {
    private(set) var pendingText = ""

    mutating func append(_ fragment: String) -> [String] {
        pendingText += fragment
        return drainReadyChunks()
    }

    mutating func finish() -> [String] {
        let ready = drainReadyChunks()
        let trailing = ArtemisTTSChunker.chunks(for: pendingText)
        pendingText = ""
        return ready + trailing
    }

    private mutating func drainReadyChunks() -> [String] {
        var ready: [String] = []
        while let boundary = ArtemisTTSChunker.firstStreamingBoundary(in: pendingText) {
            let prefix = String(pendingText[..<boundary])
            pendingText = String(pendingText[boundary...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ready.append(contentsOf: ArtemisTTSChunker.chunks(for: prefix))
        }
        return ready
    }
}

struct ArtemisTTSLookaheadPolicy: Equatable, Sendable {
    let maxOutstandingClips: Int

    init(maxOutstandingClips: Int = 3) {
        self.maxOutstandingClips = max(1, maxOutstandingClips)
    }

    func canGenerate(
        scheduledClipCount: Int,
        completedClipCount: Int,
        generatedReadyCount: Int,
        generationInFlight: Bool
    ) -> Bool {
        let scheduledOutstanding = max(0, scheduledClipCount - completedClipCount)
        let pending = scheduledOutstanding
            + max(0, generatedReadyCount)
            + (generationInFlight ? 1 : 0)
        return pending < maxOutstandingClips
    }

    func canSchedule(scheduledClipCount: Int, completedClipCount: Int) -> Bool {
        max(0, scheduledClipCount - completedClipCount) < maxOutstandingClips
    }
}

private extension String {
    func replacing(pattern: String, with template: String) -> String {
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(startIndex..., in: self)
            return regex.stringByReplacingMatches(
                in: self,
                options: [],
                range: range,
                withTemplate: template
            )
        } catch {
            return self
        }
    }
}
