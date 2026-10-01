import Foundation
import CoreServices

/// Path of `url` relative to the scratches folder ("" for the folder itself), or nil when outside it.
func relativePath(_ url: URL) -> String? {
    let root = AppPaths.scratches.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == root { return "" }
    return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
}

struct Scratch: Hashable {
    let url: URL
    let created: Date
    let modified: Date

    init(url: URL) {
        self.url = url.standardizedFileURL
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let now = Date()
        modified = attrs[.modificationDate] as? Date ?? now
        created = attrs[.creationDate] as? Date ?? modified
    }

    var name: String { url.lastPathComponent }
    /// Path relative to the scratches folder ("work/api.http"); just the name for top-level scratches.
    var id: String { relativePath(url) ?? url.lastPathComponent }
    /// Relative path of the containing folder, "" at the top level.
    var folder: String { (id as NSString).deletingLastPathComponent }
    var language: Language { Language(fileExtension: url.pathExtension) }
    /// False for documents opened from elsewhere, such as the shared package.json.
    var isInScratchFolder: Bool { relativePath(url) != nil }
    var isSharedManifest: Bool { url.standardizedFileURL.path == SharedPackages.manifest.standardizedFileURL.path }

    static func == (a: Scratch, b: Scratch) -> Bool { a.url.path == b.url.path }
    func hash(into hasher: inout Hasher) { hasher.combine(url.path) }
}

/// A sub-folder of the scratches folder, identified by its relative path ("work/api").
struct ScratchFolder: Hashable {
    let id: String

    var url: URL { AppPaths.scratches.appendingPathComponent(id, isDirectory: true) }
    var name: String { (id as NSString).lastPathComponent }
    var parent: String { (id as NSString).deletingLastPathComponent }

    func contains(_ path: String) -> Bool { path.hasPrefix(id + "/") }
}

/// Scratches are plain files in `~/Library/Application Support/ScratchPad/scratches` (and folders
/// inside it), so they can be opened, grepped or backed up with any other tool.
final class ScratchStore {
    let dir = AppPaths.scratches
    private let fm = FileManager.default
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?
    private var watchDebounce: DispatchWorkItem?

    /// Folders the tree never descends into.
    private static let ignoredFolders: Set<String> = ["node_modules", ".git"]

    /// Every scratch in every folder, newest first by creation date, so the list doesn't reshuffle while you type.
    func list() -> [Scratch] {
        walk().files.map(Scratch.init)
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.id < $1.id }
    }

    /// Every folder, sorted by path.
    static func folders() -> [ScratchFolder] {
        ScratchStore.walk(AppPaths.scratches).folders
            .compactMap { relativePath($0).map(ScratchFolder.init(id:)) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func walk() -> (files: [URL], folders: [URL]) { Self.walk(dir) }

    private static func walk(_ root: URL) -> (files: [URL], folders: [URL]) {
        var files: [URL] = [], folders: [URL] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], [])
        }
        for case let url as URL in e {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if ignoredFolders.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        return (files, folders)
    }

    func read(_ scratch: Scratch) -> String {
        (try? String(contentsOf: scratch.url, encoding: .utf8)) ?? ""
    }

    func create(language: Language, content: String = "", in folder: String = "") throws -> Scratch {
        let url = uniqueURL(base: "scratch", ext: language.fileExtension, in: folderURL(folder))
        try content.write(to: url, atomically: true, encoding: .utf8)
        return Scratch(url: url)
    }

    /// Copies an external file into a scratch folder (keeping its name when possible).
    func importFile(_ source: URL, into folder: String = "") throws -> Scratch {
        let ext = source.pathExtension.isEmpty ? "txt" : source.pathExtension
        let target = uniqueURL(base: source.deletingPathExtension().lastPathComponent, ext: ext, in: folderURL(folder))
        try fm.copyItem(at: source, to: target)
        return Scratch(url: target)
    }

    /// Debounced write so rapid edits don't hammer the disk.
    func save(_ scratch: Scratch, text: String) {
        pendingWrites[scratch.id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // A missing file means the scratch was renamed or deleted since the edit; writing would resurrect it.
            if self?.fm.fileExists(atPath: scratch.url.path) == true {
                try? text.write(to: scratch.url, atomically: true, encoding: .utf8)
            }
            self?.pendingWrites.removeValue(forKey: scratch.id)
        }
        pendingWrites[scratch.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func flushWrites() {
        for item in pendingWrites.values { item.perform() }
        pendingWrites.removeAll()
    }

    func rename(_ scratch: Scratch, to newName: String) throws -> Scratch {
        flushWrites()
        let cleaned = try Self.cleanName(newName)
        let target = scratch.url.deletingLastPathComponent().appendingPathComponent(cleaned)
        if target == scratch.url { return scratch }
        // Allow case-only renames (the file system is case-insensitive).
        if fm.fileExists(atPath: target.path) && target.path.lowercased() != scratch.url.path.lowercased() {
            throw Self.error("A scratch named “\(cleaned)” already exists here.")
        }
        try fm.moveItem(at: scratch.url, to: target)
        return Scratch(url: target)
    }

    func changeLanguage(_ scratch: Scratch, to language: Language) throws -> Scratch {
        let stem = scratch.url.deletingPathExtension().lastPathComponent
        let target = uniqueURL(base: stem, ext: language.fileExtension, in: scratch.url.deletingLastPathComponent(),
                               ignoring: scratch.url)
        if target == scratch.url { return scratch }
        flushWrites()
        try fm.moveItem(at: scratch.url, to: target)
        return Scratch(url: target)
    }

    /// Moves a scratch into another folder ("" = top level), renaming it if the name is taken there.
    func move(_ scratch: Scratch, to folder: String) throws -> Scratch {
        guard scratch.folder != folder else { return scratch }
        flushWrites()
        let stem = scratch.url.deletingPathExtension().lastPathComponent
        let target = uniqueURL(base: stem, ext: scratch.url.pathExtension, in: folderURL(folder))
        try fm.moveItem(at: scratch.url, to: target)
        return Scratch(url: target)
    }

    func delete(_ scratch: Scratch) throws {
        pendingWrites[scratch.id]?.cancel()
        pendingWrites.removeValue(forKey: scratch.id)
        try fm.trashItem(at: scratch.url, resultingItemURL: nil)
    }

    // MARK: Folders

    func createFolder(named name: String = "New Folder", in parent: String = "") throws -> ScratchFolder {
        let base = try Self.cleanName(name)
        let parentURL = folderURL(parent)
        var candidate = parentURL.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parentURL.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        return ScratchFolder(id: relativePath(candidate) ?? candidate.lastPathComponent)
    }

    func renameFolder(_ folder: ScratchFolder, to newName: String) throws -> ScratchFolder {
        flushWrites()
        let cleaned = try Self.cleanName(newName)
        let target = folder.url.deletingLastPathComponent().appendingPathComponent(cleaned, isDirectory: true)
        if target.path == folder.url.path { return folder }
        if fm.fileExists(atPath: target.path) && target.path.lowercased() != folder.url.path.lowercased() {
            throw Self.error("A folder named “\(cleaned)” already exists here.")
        }
        try fm.moveItem(at: folder.url, to: target)
        return ScratchFolder(id: relativePath(target) ?? cleaned)
    }

    /// Moves a folder (with everything in it) into another folder ("" = top level).
    func moveFolder(_ folder: ScratchFolder, to parent: String) throws -> ScratchFolder {
        guard folder.parent != parent else { return folder }
        guard parent != folder.id, !folder.contains(parent) else {
            throw Self.error("A folder can't be moved into itself.")
        }
        flushWrites()
        let parentURL = folderURL(parent)
        var target = parentURL.appendingPathComponent(folder.name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = parentURL.appendingPathComponent("\(folder.name) \(n)", isDirectory: true)
            n += 1
        }
        try fm.moveItem(at: folder.url, to: target)
        return ScratchFolder(id: relativePath(target) ?? folder.name)
    }

    func deleteFolder(_ folder: ScratchFolder) throws {
        flushWrites()
        try fm.trashItem(at: folder.url, resultingItemURL: nil)
    }

    // MARK: Watching

    /// Calls `onChange` (debounced, on the main queue) when anything in the scratch folder tree is added,
    /// removed, renamed or written, including changes made outside the app.
    func watch(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ScratchStore>.fromOpaque(info).takeUnretainedValue().scheduleChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [dir.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func scheduleChange() {
        watchDebounce?.cancel()
        guard let onChange else { return }
        let item = DispatchWorkItem(block: onChange)
        watchDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: Helpers

    private func folderURL(_ folder: String) -> URL {
        folder.isEmpty ? dir : dir.appendingPathComponent(folder, isDirectory: true)
    }

    private static func cleanName(_ name: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { throw error("Enter a name.") }
        return cleaned
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ScratchPad", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func uniqueURL(base: String, ext: String, in folder: URL, ignoring: URL? = nil) -> URL {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = folder.appendingPathComponent("\(base)\(suffix)")
        var n = 1
        while fm.fileExists(atPath: candidate.path) && candidate.path != ignoring?.path {
            candidate = folder.appendingPathComponent("\(base)_\(n)\(suffix)")
            n += 1
        }
        return candidate
    }
}
