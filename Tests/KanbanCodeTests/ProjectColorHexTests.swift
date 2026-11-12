import AppKit
import KanbanCodeCore
import SwiftUI
import Testing

@testable import KanbanCode

/// The remote board API sends `ProjectColor.hex`, so web and phone clients
/// tint cards as the Mac does. It must stay the SwiftUI color the card strip
/// draws (dark appearance), or the clients drift from the app.
@Suite("Project color hex matches the app's palette")
struct ProjectColorHexTests {
    @Test("hex is the SwiftUI color in the dark appearance", arguments: ProjectColor.allCases)
    func hexMatchesSwiftUIColor(_ projectColor: ProjectColor) throws {
        var resolved = ""
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(projectColor.color).usingColorSpace(.sRGB) else { return }
            func byte(_ component: CGFloat) -> Int { Int((component * 255).rounded()) }
            resolved = String(format: "#%02x%02x%02x", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
        }
        #expect(resolved == projectColor.hex)
    }
}
