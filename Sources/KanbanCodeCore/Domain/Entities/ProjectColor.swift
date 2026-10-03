import Foundation

/// Preconfigured palette used to tint cards by project.
/// No red or pink: those read as the "needs input" alert. A stored `red`/`pink` decodes as automatic.
public enum ProjectColor: String, CaseIterable, Codable, Sendable {
    case blue, green, orange, purple, teal, yellow, indigo, mint, cyan, brown

    public var displayName: String { rawValue.capitalized }

    /// The project's explicit color, else its automatic one.
    public static func resolve(path: String, in projects: [Project]) -> ProjectColor {
        projects.first(where: { $0.path == path })?.projectColor ?? automatic(path: path, in: projects)
    }

    /// Position in the configured list keeps the first ten projects distinct; unconfigured paths fall back to a stable hash.
    public static func automatic(path: String, in projects: [Project]) -> ProjectColor {
        guard let index = projects.firstIndex(where: { $0.path == path }) else { return hashed(path) }
        return allCases[index % allCases.count]
    }

    /// FNV-1a, because `String.hashValue` is seeded per process and would reshuffle colors on every launch.
    static func hashed(_ path: String) -> ProjectColor {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return allCases[Int(hash % UInt64(allCases.count))]
    }
}
