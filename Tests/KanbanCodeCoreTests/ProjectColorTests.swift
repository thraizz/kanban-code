import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("ProjectColor")
struct ProjectColorTests {

    @Test("Configured projects get distinct colors by position")
    func distinctByPosition() {
        let projects = (0..<ProjectColor.allCases.count).map { Project(path: "/p/\($0)") }
        let colors = projects.map { ProjectColor.resolve(path: $0.path, in: projects) }
        #expect(Set(colors).count == ProjectColor.allCases.count)
    }

    @Test("Explicit color wins over position")
    func explicitWins() {
        let projects = [Project(path: "/a"), Project(path: "/b", color: .brown)]
        #expect(ProjectColor.resolve(path: "/b", in: projects) == .brown)
        #expect(ProjectColor.automatic(path: "/b", in: projects) == ProjectColor.allCases[1])
    }

    @Test("Unconfigured path hashes stably")
    func unconfiguredStable() {
        let first = ProjectColor.resolve(path: "/somewhere/else", in: [])
        #expect(ProjectColor.resolve(path: "/somewhere/else", in: [Project(path: "/a")]) == first)
    }

    @Test("Palette has no alert-like reds")
    func noRedShades() {
        #expect(ProjectColor(rawValue: "red") == nil)
        #expect(ProjectColor(rawValue: "pink") == nil)
    }

    @Test("Unknown stored color decodes as automatic")
    func unknownColorDecodes() throws {
        let json = #"{"path":"/a","name":"a","visible":true,"color":"chartreuse"}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.projectColor == nil)
        #expect(ProjectColor.resolve(path: "/a", in: [project]) == ProjectColor.allCases[0])
    }
}
