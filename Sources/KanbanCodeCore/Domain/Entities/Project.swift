import Foundation

/// A configured project (repository) that Kanban tracks.
public struct Project: Identifiable, Codable, Sendable, Equatable {
    public var id: String { path }
    public let path: String // Project directory (where Claude runs)
    public var name: String // Display name
    public var repoRoot: String? // Git repo root if different from path
    public var visible: Bool
    public var githubFilter: String? // Per-project gh filter, nil = inherit global default
    public var promptTemplate: String? // Per-project template, nil = inherit global
    public var githubIssuePromptTemplate: String? // Per-project issue template, nil = inherit global
    public var color: String? // ProjectColor raw value, nil = automatic; stored raw so an unknown value can't break settings decoding

    public init(
        path: String,
        name: String? = nil,
        repoRoot: String? = nil,
        visible: Bool = true,
        githubFilter: String? = nil,
        promptTemplate: String? = nil,
        githubIssuePromptTemplate: String? = nil,
        color: ProjectColor? = nil
    ) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.repoRoot = repoRoot
        self.visible = visible
        self.githubFilter = githubFilter
        self.promptTemplate = promptTemplate
        self.githubIssuePromptTemplate = githubIssuePromptTemplate
        self.color = color?.rawValue
    }

    public var projectColor: ProjectColor? {
        get { color.flatMap(ProjectColor.init(rawValue:)) }
        set { color = newValue?.rawValue }
    }

    /// The effective git repository root (repoRoot if set, otherwise path).
    public var effectiveRepoRoot: String {
        repoRoot ?? path
    }
}
