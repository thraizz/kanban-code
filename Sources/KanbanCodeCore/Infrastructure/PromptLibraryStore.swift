import Foundation

/// A reusable prompt the user keeps in the prompt library to spawn new tasks from.
public struct PromptPreset: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, title: String, body: String, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }

    /// Title to show in lists: the given title, else the first line of the body.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "Untitled prompt" : line
    }
}

/// Persists the prompt library at `~/.kanban-code/prompt-library.json`.
public actor PromptLibraryStore {
    private let filePath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("prompt-library.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// All presets in their saved order. A missing or unreadable file reads as empty.
    public func load() -> [PromptPreset] {
        guard let data = FileManager.default.contents(atPath: filePath) else { return [] }
        return (try? decoder.decode([PromptPreset].self, from: data)) ?? []
    }

    public func save(_ presets: [PromptPreset]) throws {
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(presets)
        try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }

    public var path: String { filePath }
}
