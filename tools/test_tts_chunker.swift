import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TTSChunkerTestMain {
    static func main() {
        let normalized = ArtemisTTSChunker.normalizedEnglishText(" **Hello** ~~Artemis~~ `now` \u{1F44B} ")
        require(normalized == "Hello Artemis now", "normalization should strip markdown markers and emoji, got: \(normalized)")

        let protected = ArtemisTTSChunker.chunks(
            for: "Fig. 2 shows 3.14. Next sentence is clean.",
            minChunkLength: 20,
            maxChunkBeforeSplit: 80
        )
        require(protected.count == 2, "abbreviations and decimals should not create extra chunks: \(protected)")
        require(protected[0] == "Fig. 2 shows 3.14.", "first protected chunk mismatch: \(protected)")

        let clauseInput = "The first clause is definitely long enough, the second clause is also detailed enough, and the third clause closes the thought."
        let clauseChunks = ArtemisTTSChunker.chunks(
            for: clauseInput,
            minChunkLength: 20,
            maxChunkBeforeSplit: 80
        )
        require(clauseChunks.count >= 2, "long sentence should split on clause boundaries: \(clauseChunks)")
        require(clauseChunks.allSatisfy { !$0.isEmpty }, "chunks should never be empty: \(clauseChunks)")

        let compact = ArtemisTTSChunker.chunks(
            for: "Hi. OK. This final sentence carries the short leading bits.",
            minChunkLength: 20,
            maxChunkBeforeSplit: 80
        )
        require(compact.first == "Hi.", "short terminal sentences should remain valid chunks: \(compact)")

        print("TTSChunker tests passed")
    }
}
