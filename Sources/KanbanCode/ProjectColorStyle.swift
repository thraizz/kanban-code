import SwiftUI
import KanbanCodeCore

extension ProjectColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .teal: .teal
        case .yellow: .yellow
        case .indigo: .indigo
        case .mint: .mint
        case .cyan: .cyan
        case .brown: .brown
        }
    }
}

private struct ConfiguredProjectsKey: EnvironmentKey {
    static let defaultValue: [Project] = []
}

extension EnvironmentValues {
    var configuredProjects: [Project] {
        get { self[ConfiguredProjectsKey.self] }
        set { self[ConfiguredProjectsKey.self] = newValue }
    }
}
