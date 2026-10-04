import Foundation
import KanbanCodeRemoteKit

/// Which vault project a folder belongs to.
///
/// The project of a folder inside a git repository is the name of the
/// repository's main checkout folder, plus the path below it for a
/// subfolder: `~/Projects/shop/api` in the repository `shop` is `shop/api`.
/// A linked worktree counts as its main checkout, a submodule as a
/// subfolder of the repository that holds it. Outside a repository the
/// root is the nearest folder holding a `.env.vault` (or `.env.X.vault`)
/// manifest, else the folder itself. A `.vault-project` file in the root
/// holding one line replaces the folder name.
public enum VaultProjects {
    public static let overrideFile = ".vault-project"

    /// The projects a folder is in, the most specific first: the folder's
    /// own, then each parent folder up to the root.
    public static func candidates(forPath path: String?, home: String = NSHomeDirectory(),
                                  fileManager: FileManager = .default) -> [String] {
        guard let path, path.hasPrefix("/") else { return [] }
        let start = (path as NSString).standardizingPath
        guard let (root, below) = root(of: start, home: home, fileManager: fileManager) else { return [] }
        let name = slug(rootName(root, fileManager: fileManager))
        guard !name.isEmpty else { return [] }
        var out: [String] = []
        var parts = below.map(slug).filter { !$0.isEmpty }
        while true {
            out.append(([name] + parts).joined(separator: "/"))
            if parts.isEmpty { break }
            parts.removeLast()
        }
        return out
    }

    /// The most specific project of a folder.
    public static func project(forPath path: String?, home: String = NSHomeDirectory()) -> String? {
        candidates(forPath: path, home: home).first
    }

    /// A folder name as a project name: the characters secret names allow.
    public static func slug(_ name: String) -> String {
        let cleaned = String(name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII) || "_-.".unicodeScalars.contains(scalar)
                ? Character(scalar) : "-"
        })
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The root folder of the project holding `start` (a main checkout for
    /// a worktree) and the folders from the root down to `start`.
    static func root(of start: String, home: String, fileManager: FileManager) -> (root: String, below: [String])? {
        var current = start
        var below: [String] = []
        var manifestRoot: (String, [String])?
        for _ in 0..<64 {
            if current == home || current == "/" { break }
            let git = current + "/.git"
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: git, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return (current, below) }
                if let main = mainCheckout(ofGitFile: git, fileManager: fileManager) { return (main, below) }
                // A submodule: its folder is a subfolder of the repository that holds it.
            }
            if manifestRoot == nil, hasManifest(current, fileManager: fileManager) {
                manifestRoot = (current, below)
            }
            below.insert((current as NSString).lastPathComponent, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        if let manifestRoot { return manifestRoot }
        return start == home || start == "/" ? nil : (start, [])
    }

    /// The main checkout of a linked worktree, from its `.git` file
    /// (`gitdir: <main>/.git/worktrees/<name>`); nil for a main checkout.
    static func mainCheckout(ofGitFile git: String, fileManager: FileManager) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: git, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = fileManager.contents(atPath: git).map({ String(decoding: $0, as: UTF8.self) })
        else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("gitdir:") else { continue }
            let dir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard let range = dir.range(of: "/.git/worktrees/", options: .backwards) else { return nil }
            return String(dir[..<range.lowerBound])
        }
        return nil
    }

    static func hasManifest(_ dir: String, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: dir + "/" + overrideFile) || fileManager.fileExists(atPath: dir + "/.env.vault") {
            return true
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: dir)) ?? []
        return names.contains { $0.hasPrefix(".env.") && $0.hasSuffix(".vault") }
    }

    static func rootName(_ root: String, fileManager: FileManager) -> String {
        if let data = fileManager.contents(atPath: root + "/" + overrideFile) {
            let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return (root as NSString).lastPathComponent
    }
}
