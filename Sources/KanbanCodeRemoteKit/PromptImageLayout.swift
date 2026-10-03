import Foundation

/// Parses visible image placeholders embedded in prompt text.
///
/// The UI stores image position as plain text markers such as `[Image #1]`,
/// on the Mac and on the phone. When sending to assistants that support
/// image paste, those markers are replaced by clipboard image paste events;
/// rush takes the text with its markers and the images as files. Other
/// assistants receive markdown image references at the same positions.
public enum PromptImageLayout {
    public static let markerPrefix = "[Image #"

    public struct Part: Equatable, Sendable {
        public var text: String
        /// Zero-based image index, nil for text-only parts.
        public var imageIndex: Int?

        public init(text: String, imageIndex: Int? = nil) {
            self.text = text
            self.imageIndex = imageIndex
        }
    }

    public static func marker(for index: Int) -> String {
        "[Image #\(index)]"
    }

    public static func parts(in text: String, imageCount: Int) -> [Part] {
        guard imageCount > 0, text.contains(markerPrefix) else {
            return text.isEmpty ? [] : [Part(text: text)]
        }

        var parts: [Part] = []
        var cursor = text.startIndex
        while let markerStart = text.range(of: markerPrefix, range: cursor..<text.endIndex)?.lowerBound {
            guard let markerEnd = text[markerStart..<text.endIndex].firstIndex(of: "]") else {
                break
            }

            let numberStart = text.index(markerStart, offsetBy: markerPrefix.count)
            let numberText = String(text[numberStart..<markerEnd])
            guard numberText.allSatisfy(\.isASCII), let number = Int(numberText), number >= 1, number <= imageCount else {
                // Not a marker: the text goes on from just after "[Image #",
                // so a marker further on is still found.
                parts.append(Part(text: String(text[cursor..<numberStart])))
                cursor = numberStart
                continue
            }

            if markerStart > cursor {
                parts.append(Part(text: String(text[cursor..<markerStart])))
            }
            parts.append(Part(text: "", imageIndex: number - 1))
            cursor = text.index(after: markerEnd)
        }

        if cursor < text.endIndex {
            parts.append(Part(text: String(text[cursor..<text.endIndex])))
        }
        return coalescingAdjacentText(parts)
    }

    /// The prompt as sent: markers numbered in the order they appear, with
    /// the images in that order, and images whose marker was deleted left
    /// out. A marker named twice keeps one image. Text with no marker for
    /// any image (an older client) keeps every image, to go after the text.
    public static func arranged<T>(text: String, images: [T]) -> (text: String, images: [T]) {
        let parts = parts(in: text, imageCount: images.count)
        guard parts.contains(where: { $0.imageIndex != nil }) else { return (text, images) }
        var number: [Int: Int] = [:]
        var outText = ""
        var outImages: [T] = []
        for part in parts {
            guard let index = part.imageIndex else {
                outText += part.text
                continue
            }
            if number[index] == nil {
                outImages.append(images[index])
                number[index] = outImages.count
            }
            outText += marker(for: number[index]!)
        }
        return (outText, outImages)
    }

    /// The text with its image markers taken out, for a prompt whose images
    /// are not coming along.
    public static func removingMarkers(from text: String, imageCount: Int) -> String {
        let kept = parts(in: text, imageCount: imageCount).filter { $0.imageIndex == nil }.map(\.text).joined()
        return kept.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether every one of `imageCount` images has its marker in the text.
    public static func marksEveryImage(_ text: String, imageCount: Int) -> Bool {
        imageCount > 0 && Set(referencedImageIndices(in: text, imageCount: imageCount)).count == imageCount
    }

    /// Markdown image references to local files (`![](/path/x.png)`), as
    /// a prompt sent with images by path holds them, turned back into
    /// markers numbered after the ones already in the text.
    public static func replacingMarkdownImagesWithMarkers(in text: String) -> String {
        guard text.contains("![") else { return text }
        let pattern = #"!\[[^\]\n]*\]\((/[^)\s]+\.(?:png|jpe?g|gif|webp))\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var next = highestMarker(in: text) + 1
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += marker(for: next)
            next += 1
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func highestMarker(in text: String) -> Int {
        var highest = 0
        var cursor = text.startIndex
        while let start = text.range(of: markerPrefix, range: cursor..<text.endIndex) {
            guard let end = text[start.upperBound...].firstIndex(of: "]") else { break }
            if let n = Int(text[start.upperBound..<end]) { highest = max(highest, n) }
            cursor = text.index(after: end)
        }
        return highest
    }

    public static func referencedImageIndices(in text: String, imageCount: Int) -> [Int] {
        var out: [Int] = []
        for part in parts(in: text, imageCount: imageCount) {
            if let imageIndex = part.imageIndex {
                out.append(imageIndex)
            }
        }
        return out
    }

    public static func replacingMarkersWithMarkdown(in text: String, imagePaths: [String]) -> String {
        let parts = parts(in: text, imageCount: imagePaths.count)
        guard parts.contains(where: { $0.imageIndex != nil }) else {
            if imagePaths.isEmpty { return text }
            let refs = imagePaths.map { "![](\($0))" }.joined(separator: "\n")
            return text.isEmpty ? refs : text + "\n" + refs
        }

        return parts.map { part in
            if let imageIndex = part.imageIndex {
                return "![](\(imagePaths[imageIndex]))"
            }
            return part.text
        }.joined()
    }

    private static func coalescingAdjacentText(_ parts: [Part]) -> [Part] {
        var out: [Part] = []
        for part in parts {
            if part.imageIndex == nil,
               let last = out.last,
               last.imageIndex == nil {
                out[out.count - 1].text += part.text
            } else {
                out.append(part)
            }
        }
        return out
    }
}
