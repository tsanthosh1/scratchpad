import Foundation

/// The app-wide npm project whose `node_modules` every JavaScript/TypeScript scratch can import from.
/// Lives in `~/Library/Application Support/ScratchPad/packages` unless Settings points elsewhere.
enum SharedPackages {
    static var folder: URL {
        let custom = Settings.shared.nodePackagesDir.trimmingCharacters(in: .whitespaces)
        guard !custom.isEmpty else { return AppPaths.packages }
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var manifest: URL { folder.appendingPathComponent("package.json") }
    static var modules: URL { folder.appendingPathComponent("node_modules", isDirectory: true) }

    /// Creates the folder and a starter package.json when missing.
    @discardableResult
    static func ensureManifest() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: manifest.path) else { return manifest }
        let starter = """
        {
          "name": "scratchpad-packages",
          "private": true,
          "description": "Packages every ScratchPad JavaScript/TypeScript scratch can require/import. Press Run to npm install.",
          "dependencies": {}
        }

        """
        try starter.write(to: manifest, atomically: true, encoding: .utf8)
        return manifest
    }
}
