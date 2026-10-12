import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var text: String
    var raw: String
    var app: String?
    var seconds: Double
    var latencyMs: Double

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let limit = 500

    @Published private(set) var entries: [HistoryEntry] = []
    private let url: URL

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhistleFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("history.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
