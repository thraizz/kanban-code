import Foundation

/// A vault secret's name, taken apart. A shared secret is just its key
/// (`OPENAI_API_KEY`, `aws:lw-dev`). A project's secret is
/// `project/environment/KEY`; the project may itself hold slashes for a
/// subfolder (`shop/api/dev/DATABASE_URL` is project `shop/api`).
public struct VaultSecretName: Sendable, Equatable, Hashable {
    public static let defaultEnvironment = "dev"

    /// The environment variable name, or the whole name of a shared secret.
    public var key: String
    /// Nil for a shared secret.
    public var project: String?
    /// Nil for a shared secret.
    public var environment: String?

    public init(key: String, project: String? = nil, environment: String? = nil) {
        self.key = key
        let project = project.flatMap { $0.isEmpty ? nil : $0 }
        self.project = project
        self.environment = project == nil ? nil : (environment.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultEnvironment)
    }

    /// Reads a stored name: the last part is the key, the one before it
    /// the environment, everything before that the project.
    public init(_ name: String) {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, !parts.contains(where: \.isEmpty) {
            key = parts[parts.count - 1]
            environment = parts[parts.count - 2]
            project = parts[0..<(parts.count - 2)].joined(separator: "/")
        } else {
            key = name
            project = nil
            environment = nil
        }
    }

    /// The name the vault stores and every listing shows.
    public var canonical: String {
        guard let project, let environment else { return key }
        return "\(project)/\(environment)/\(key)"
    }

    /// The project and environment as the human reads them after the label.
    public var scopeParts: [String] {
        [project, environment].compactMap { $0 }
    }
}
