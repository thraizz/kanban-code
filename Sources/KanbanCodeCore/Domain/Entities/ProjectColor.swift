import Foundation

/// Preconfigured palette used to tint cards by project.
/// No red or pink: those read as the "needs input" alert. A stored `red`/`pink` decodes as automatic.
public enum ProjectColor: String, CaseIterable, Codable, Sendable {
    case blue, green, orange, purple, teal, yellow, indigo, mint, cyan, brown

    public var displayName: String { rawValue.capitalized }

    /// The color as `#rrggbb` (sRGB), for clients without the system palette
    /// (the remote board API). The SwiftUI color of the same name in the dark
    /// appearance, as macOS 26 draws it; the app test `ProjectColorHexTests`
    /// keeps the two equal.
    public var hex: String {
        switch self {
        case .blue: "#0091ff"
        case .green: "#30d158"
        case .orange: "#ff9230"
        case .purple: "#db34f2"
        case .teal: "#00d2e0"
        case .yellow: "#ffd600"
        case .indigo: "#6d7cff"
        case .mint: "#00dac3"
        case .cyan: "#3cd3fe"
        case .brown: "#b78a66"
        }
    }

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
