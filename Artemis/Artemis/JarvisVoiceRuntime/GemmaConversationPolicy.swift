import Foundation

struct GemmaConversationPolicy {
    static let maximumCompletedTurns = 5
    static let maximumEstimatedContextCharacters = 2_400
    static let maximumMemoryContextCharacters = 1_400

    static func rotationReason(
        completedTurns: Int,
        estimatedContextCharacters: Int,
        nextInputCharacters: Int
    ) -> String? {
        if completedTurns >= maximumCompletedTurns {
            return "completed_turn_budget"
        }
        if estimatedContextCharacters + nextInputCharacters
            >= maximumEstimatedContextCharacters {
            return "estimated_context_budget"
        }
        return nil
    }

    static func boundedMemoryContext(
        _ lines: [String],
        maximumCharacters: Int = maximumMemoryContextCharacters
    ) -> String {
        guard maximumCharacters > 0 else { return "" }

        var selected: [String] = []
        var usedCharacters = 0
        for line in lines.reversed() {
            let separatorCharacters = selected.isEmpty ? 0 : 1
            let remaining = maximumCharacters - usedCharacters - separatorCharacters
            guard remaining > 0 else { break }

            if line.count <= remaining {
                selected.append(line)
                usedCharacters += line.count + separatorCharacters
                continue
            }

            if selected.isEmpty {
                selected.append(String(line.suffix(remaining)))
            }
            break
        }
        return selected.reversed().joined(separator: "\n")
    }
}
