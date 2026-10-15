import Foundation

/// Durable local transcript for the single Artemis conversation. This is
/// intentionally separate from the high-volume evidence ledger.
final class ConversationStore {
    private let queue = DispatchQueue(label: "artemis.conversation-store")
    private let url: URL

    init() {
        let documents = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("Conversation", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("thread.json")
    }

    func load() -> [ConversationLine] {
        guard let data = try? Data(contentsOf: url),
              let lines = try? JSONDecoder().decode([ConversationLine].self, from: data) else {
            return []
        }
        return lines
    }

    func save(_ lines: [ConversationLine]) {
        let durable = Array(lines.filter { $0.state == .complete }.suffix(240))
        queue.async { [url] in
            guard let data = try? JSONEncoder().encode(durable) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
}
