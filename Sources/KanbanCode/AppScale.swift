import SwiftUI

/// App-wide UI scale factor. Reads from UserDefaults so it works from both
/// SwiftUI (@AppStorage-triggered re-renders) and plain code.
enum AppScale {
    static var factor: CGFloat {
        let uiTextSize = UserDefaults.standard.object(forKey: "uiTextSize") != nil
            ? UserDefaults.standard.integer(forKey: "uiTextSize") : 1
        switch uiTextSize {
        case 0: return 0.85
        case 2: return 1.15
        case 3: return 1.3
        case 4: return 1.5
        default: return 1.0
        }
    }
}

// MARK: - Session detail font (used for history, transcript and prompt panes)

/// The monospace font size setting of the session detail panes. The
/// terminal takes its font from the Ghostty config instead.
enum SessionDetailFont {
    static let defaultSize: CGFloat = 12
    static let key = "sessionDetailFontSize"
}

extension Font {
    /// Monospaced font sized to the user's session detail font size setting.
    static func sessionDetail(weight: Weight = .regular) -> Font {
        let stored = UserDefaults.standard.double(forKey: "sessionDetailFontSize")
        let size = stored > 0 ? stored : 12.0
        return .system(size: CGFloat(size), weight: weight, design: .monospaced)
    }
}

// MARK: - Scaled fonts

extension Font {
    /// Scaled semantic font style.
    static func app(_ style: TextStyle, weight: Weight? = nil, design: Design? = nil) -> Font {
        let size = baseSize(for: style) * AppScale.factor
        return .system(size: size, weight: weight ?? defaultWeight(for: style), design: design ?? .default)
    }

    /// Scaled explicit size.
    static func app(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font {
        .system(size: size * AppScale.factor, weight: weight, design: design)
    }

    // macOS default sizes for semantic text styles
    static func baseSize(for style: TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .subheadline: 11
        case .body: 13
        case .callout: 12
        case .footnote: 10
        case .caption: 10
        case .caption2: 9
        @unknown default: 13
        }
    }

    private static func defaultWeight(for style: TextStyle) -> Weight {
        style == .headline ? .semibold : .regular
    }
}

// MARK: - Scaled AppKit fonts

extension NSFont {
    /// Scaled semantic font style, matching `Font.app(_:weight:design:)`.
    ///
    /// Text rendered through AppKit needs the same sizes as the SwiftUI side,
    /// so both read from the one scale factor.
    static func app(_ style: Font.TextStyle, weight: NSFont.Weight? = nil) -> NSFont {
        let size = Font.baseSize(for: style) * AppScale.factor
        return .systemFont(ofSize: size, weight: weight ?? (style == .headline ? .semibold : .regular))
    }
}

// MARK: - Scaled icon/image size

extension CGFloat {
    /// Scale a point size by the app UI factor.
    var scaled: CGFloat { self * AppScale.factor }
}
