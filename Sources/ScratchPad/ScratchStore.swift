import Foundation
import CoreServices

/// Path of `url` relative to the scratches folder ("" for the folder itself), or nil when outside it.
func relativePath(_ url: URL) -> String? {
    let root = AppPaths.scratches.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == root { return "" }
    return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
}

/// Folders from elsewhere on disk (added with the `scratchpad` command, the Dock, Finder or "Add Folder…") that the
/// sidebar and Find in Files show next to the scratches folder. Folders inside them use absolute paths as ids.
enum ExternalFolders {
    private static var cache: [String]?

    /// Root paths, in the order they were added.
    static var all: [String] {
        if let cache { return cache }
        let loaded = Settings.shared.externalFolders
        cache = loaded
        return loaded
    }

    private static func store(_ paths: [String]) {
        Settings.shared.externalFolders = paths
        cache = paths
    }

    /// The external folder containing `path` (or equal to it).
    static func root(containing path: String) -> String? {
        all.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Adds a folder; returns its root (an existing one when the folder is already inside it) or throws.
    @discardableResult
    static func add(_ url: URL) throws -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let scratches = AppPaths.scratches.standardizedFileURL.resolvingSymlinksInPath().path
        if path == scratches || path.hasPrefix(scratches + "/") {
            throw ScratchStore.error("“\(url.lastPathComponent)” is already in the scratches folder.")
        }
        if scratches.hasPrefix(path + "/") || path == "/" || path == NSHomeDirectory() {
            throw ScratchStore.error("“\(url.lastPathComponent)” is too large to add: it contains the scratches folder.")
        }
        if let existing = root(containing: path) { return existing }
        // A parent replaces the folders already added inside it.
        store(all.filter { !$0.hasPrefix(path + "/") } + [path])
        return path
    }

    static func remove(_ path: String) {
        store(all.filter { $0 != path })
    }

    static func displayPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// Folder id for a directory: its path relative to the scratches folder, or its absolute path inside an
/// external folder; nil anywhere else.
func folderId(for url: URL) -> String? {
    if let relative = relativePath(url) { return relative }
    let path = url.standardizedFileURL.path
    return ExternalFolders.root(containing: path) != nil ? path : nil
}

/// The directory a folder id names ("" is the scratches folder itself).
func folderURL(forId id: String) -> URL {
    if id.hasPrefix("/") { return URL(fileURLWithPath: id, isDirectory: true) }
    return id.isEmpty ? AppPaths.scratches : AppPaths.scratches.appendingPathComponent(id, isDirectory: true)
}

/// Which tree a folder id belongs to: "" for the scratches folder, else the external folder's root path.
func storageRoot(ofFolder id: String) -> String {
    id.hasPrefix("/") ? (ExternalFolders.root(containing: id) ?? id) : ""
}

struct Scratch: Hashable {
    let url: URL
    /// Path relative to the scratches folder ("work/api.http"); just the name for top-level scratches, and
    /// the full path for documents opened from elsewhere so they can't collide with a scratch of the same name.
    let id: String
    /// Relative path of the containing folder, "" at the top level.
    let folder: String
    let created: Date
    let modified: Date

    /// `readAttributes: false` leaves the file untouched (dates unknown): stat-ing a file in Downloads, Desktop or
    /// Documents makes macOS ask for folder access, so lists of files opened from elsewhere don't.
    init(url: URL) { self.init(url: url, readAttributes: true) }

    init(url: URL, readAttributes: Bool) {
        self.url = url.standardizedFileURL
        let id = relativePath(self.url) ?? self.url.path
        self.id = id
        folder = id.lastIndex(of: "/").map { String(id[..<$0]) } ?? ""
        guard readAttributes else {
            modified = .distantPast
            created = .distantPast
            return
        }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let now = Date()
        modified = attrs[.modificationDate] as? Date ?? now
        created = attrs[.creationDate] as? Date ?? modified
    }

    var name: String { url.lastPathComponent }
    var language: Language { Language(fileName: url.lastPathComponent) }
    /// False for documents opened from elsewhere, such as the shared package.json.
    var isInScratchFolder: Bool { !id.hasPrefix("/") }
    /// The external folder this file is listed under, if any.
    var externalRoot: String? { ExternalFolders.root(containing: url.path) }
    /// In the scratches folder or an external folder: listed in the sidebar and can be renamed, moved or deleted.
    var isListed: Bool { isInScratchFolder || externalRoot != nil }
    /// "" for scratches, the external folder's root path for files in one.
    var storageRoot: String { isInScratchFolder ? "" : externalRoot ?? url.deletingLastPathComponent().path }
    var isSharedManifest: Bool { url.standardizedFileURL.path == SharedPackages.manifest.standardizedFileURL.path }

    static func == (a: Scratch, b: Scratch) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A sub-folder of the scratches folder, identified by its relative path ("work/api"), or a folder inside an
/// external folder, identified by its absolute path. External roots sit at the top level of the tree.
struct ScratchFolder: Hashable {
    let id: String

    var url: URL { folderURL(forId: id) }
    var name: String { (id as NSString).lastPathComponent }
    var parent: String { isExternalRoot ? "" : (id as NSString).deletingLastPathComponent }
    var isExternal: Bool { id.hasPrefix("/") }
    var isExternalRoot: Bool { isExternal && ExternalFolders.all.contains(id) }
    var storageRoot: String { ScratchPad.storageRoot(ofFolder: id) }

    func contains(_ path: String) -> Bool { path.hasPrefix(id + "/") }
}

/// Scratches are plain files in `~/Library/Application Support/ScratchPad/scratches` (and folders
/// inside it), so they can be opened, grepped or backed up with any other tool.
final class ScratchStore {
    let dir = AppPaths.scratches
    private let fm = FileManager.default
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private let ioQueue = DispatchQueue(label: "dev.tsanthosh.scratchpad.io", qos: .userInitiated)
    /// Paths the app saved recently, so the watcher can tell its own atomic saves (which show up as a
    /// rename) from files added or renamed by other apps.
    private var recentWrites: [String: Date] = [:]
    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?
    private var watchDebounce: DispatchWorkItem?
    private var pendingChangeDelay: TimeInterval = 0

    /// Folders the tree never descends into.
    private static let ignoredFolders: Set<String> = ["node_modules", ".git"]
    /// Extra folders skipped inside external folders (build output and dependencies).
    private static let ignoredExternalFolders: Set<String> = [
        "build", "dist", "out", "target", "DerivedData", "Pods", "venv", "__pycache__", "coverage", "vendor",
    ]
    /// Files in external folders that are never text, so they aren't listed or searched.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "ico", "icns", "heic", "webp", "psd", "ai", "sketch",
        "pdf", "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso", "jar", "war", "class", "o", "a",
        "so", "dylib", "exe", "dll", "bin", "dat", "db", "sqlite", "sqlite3", "mp3", "mp4", "mov", "avi", "wav",
        "flac", "m4a", "ogg", "woff", "woff2", "ttf", "otf", "eot", "pyc", "wasm", "doc", "docx", "xls", "xlsx",
        "ppt", "pptx", "key", "pages", "numbers", "keychain",
    ]
    /// Upper bound per external folder, so adding a huge tree can't stall the app.
    static let maxExternalFiles = 5000
    private static var externalWalks: [String: (files: [Scratch], folders: [URL], truncated: Bool)] = [:]

    /// Forgets cached external folder listings (after a change to the list of folders, or one made by the app).
    static func invalidateExternal() { externalWalks.removeAll() }

    /// External roots whose listing stopped at `maxExternalFiles`.
    static var truncatedExternalRoots: [String] { externalWalks.filter(\.value.truncated).map(\.key) }

    private static func externalWalk(_ root: String) -> (files: [Scratch], folders: [URL], truncated: Bool) {
        if let cached = externalWalks[root] { return cached }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ([], [], false)
        }
        let walked = walk(URL(fileURLWithPath: root, isDirectory: true), external: true)
        let result = (files: walked.files.map(Scratch.init), folders: walked.folders, truncated: walked.truncated)
        externalWalks[root] = result
        return result
    }

    /// Re-reads the dates of one file in a cached external listing after its contents changed.
    private static func refreshExternal(_ path: String, root: String) {
        guard var walk = externalWalks[root],
              let index = walk.files.firstIndex(where: { $0.url.path == path }) else { return }
        walk.files[index] = Scratch(url: walk.files[index].url)
        externalWalks[root] = walk
    }

    /// Every scratch in every folder (and every file in external folders), newest first by creation date, so the
    /// list doesn't reshuffle while you type.
    func list() -> [Scratch] {
        let files = Self.walk(dir).files.map(Scratch.init) + ExternalFolders.all.flatMap { Self.externalWalk($0).files }
        return files.sorted { $0.created != $1.created ? $0.created > $1.created : $0.id < $1.id }
    }

    /// Every folder (scratch folders, then external roots and their folders), sorted by path.
    static func folders() -> [ScratchFolder] {
        let own = ScratchStore.walk(AppPaths.scratches).folders
            .compactMap { relativePath($0).map(ScratchFolder.init(id:)) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let external = ExternalFolders.all.flatMap { root -> [ScratchFolder] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
            return [ScratchFolder(id: root)] + externalWalk(root).folders.map { ScratchFolder(id: $0.standardizedFileURL.path) }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
        return own + external
    }

    private static func walk(_ root: URL, external: Bool = false) -> (files: [URL], folders: [URL], truncated: Bool) {
        var files: [URL] = [], folders: [URL] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], [], false)
        }
        for case let url as URL in e {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir, RichTextIO.isPackage(url) {
                files.append(url)
                e.skipDescendants()
            } else if isDir {
                if ignoredFolders.contains(url.lastPathComponent)
                    || (external && ignoredExternalFolders.contains(url.lastPathComponent)) {
                    e.skipDescendants()
                    continue
                }
                folders.append(url)
            } else if !external || !binaryExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
                if external && files.count >= maxExternalFiles { return (files, folders, true) }
            }
        }
        return (files, folders, false)
    }

    /// The text of a scratch; for rich text documents, their plain text.
    func read(_ scratch: Scratch) -> String {
        ioQueue.sync {}
        if scratch.language.isRichText { return RichTextIO.load(scratch.url)?.string ?? "" }
        return (try? String(contentsOf: scratch.url, encoding: .utf8)) ?? ""
    }

    func readRich(_ scratch: Scratch) -> NSAttributedString {
        RichTextIO.load(scratch.url) ?? NSAttributedString()
    }

    func create(language: Language, content: String = "", in folder: String = "") throws -> Scratch {
        Self.invalidateExternal()
        let url = uniqueURL(base: "scratch", ext: language.fileExtension, in: folderURL(folder))
        if language.isRichText {
            try RichTextIO.write(RichTextIO.plain(content), to: url)
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return Scratch(url: url)
    }

    /// Copies an external file into a scratch folder (keeping its name when possible).
    func importFile(_ source: URL, into folder: String = "") throws -> Scratch {
        Self.invalidateExternal()
        let ext = source.pathExtension.isEmpty ? "txt" : source.pathExtension
        let target = uniqueURL(base: source.deletingPathExtension().lastPathComponent, ext: ext, in: folderURL(folder))
        try fm.copyItem(at: source, to: target)
        return Scratch(url: target)
    }

    /// Debounced write so rapid edits don't hammer the disk.
    func save(_ scratch: Scratch, text: String) {
        pendingWrites[scratch.id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWrites.removeValue(forKey: scratch.id)
            self.recentWrites[scratch.url.path] = Date()
            self.ioQueue.async {
                // A missing file means the scratch was renamed or deleted since the edit; writing would resurrect it.
                if FileManager.default.fileExists(atPath: scratch.url.path) {
                    try? text.write(to: scratch.url, atomically: true, encoding: .utf8)
                }
            }
        }
        pendingWrites[scratch.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Debounced write of a rich text document; `flushWrites` covers it like plain text saves.
    func saveRich(_ scratch: Scratch, text: NSAttributedString) {
        pendingWrites[scratch.id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.recentWrites[scratch.url.path] = Date()
            if self?.fm.fileExists(atPath: scratch.url.path) == true {
                do {
                    try RichTextIO.write(text, to: scratch.url)
                } catch {
                    NSLog("ScratchPad: saving \(scratch.url.path) failed: \(error)")
                }
            }
            self?.pendingWrites.removeValue(forKey: scratch.id)
        }
        pendingWrites[scratch.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Performs pending saves and waits until they're on disk.
    func flushWrites() {
        for item in pendingWrites.values { item.perform() }
        pendingWrites.removeAll()
        ioQueue.sync {}
    }

    func rename(_ scratch: Scratch, to newName: String) throws -> Scratch {
        Self.invalidateExternal()
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
        Self.invalidateExternal()
        let stem = Language.stem(of: scratch.url.lastPathComponent)
        let target = uniqueURL(base: stem, ext: language.fileExtension, in: scratch.url.deletingLastPathComponent(),
                               ignoring: scratch.url)
        if target == scratch.url { return scratch }
        flushWrites()
        if scratch.language.isRichText || language.isRichText {
            // Converting to or from rich text rewrites the content: rich text keeps only its plain text
            // when it becomes code, and plain text becomes an unformatted document.
            if language.isRichText {
                let text = read(scratch)
                let rich = scratch.language.isRichText ? readRich(scratch) : RichTextIO.plain(text)
                try RichTextIO.write(rich, to: target)
            } else {
                try read(scratch).write(to: target, atomically: true, encoding: .utf8)
            }
            try fm.removeItem(at: scratch.url)
            return Scratch(url: target)
        }
        try fm.moveItem(at: scratch.url, to: target)
        return Scratch(url: target)
    }

    /// Moves a scratch into another folder ("" = top level), renaming it if the name is taken there.
    func move(_ scratch: Scratch, to folder: String) throws -> Scratch {
        Self.invalidateExternal()
        guard scratch.folder != folder else { return scratch }
        guard scratch.storageRoot == storageRoot(ofFolder: folder) else {
            throw Self.error("Files can only be moved within the scratches folder or within one external folder.")
        }
        flushWrites()
        let stem = scratch.url.deletingPathExtension().lastPathComponent
        let target = uniqueURL(base: stem, ext: scratch.url.pathExtension, in: folderURL(folder))
        try fm.moveItem(at: scratch.url, to: target)
        return Scratch(url: target)
    }

    func delete(_ scratch: Scratch) throws {
        Self.invalidateExternal()
        pendingWrites[scratch.id]?.cancel()
        pendingWrites.removeValue(forKey: scratch.id)
        ioQueue.sync {}
        try fm.trashItem(at: scratch.url, resultingItemURL: nil)
    }

    // MARK: Folders

    func createFolder(named name: String = "New Folder", in parent: String = "") throws -> ScratchFolder {
        Self.invalidateExternal()
        let base = try Self.cleanName(name)
        let parentURL = folderURL(parent)
        var candidate = parentURL.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parentURL.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        return ScratchFolder(id: folderId(for: candidate) ?? candidate.lastPathComponent)
    }

    func renameFolder(_ folder: ScratchFolder, to newName: String) throws -> ScratchFolder {
        Self.invalidateExternal()
        flushWrites()
        let cleaned = try Self.cleanName(newName)
        let target = folder.url.deletingLastPathComponent().appendingPathComponent(cleaned, isDirectory: true)
        if target.path == folder.url.path { return folder }
        if fm.fileExists(atPath: target.path) && target.path.lowercased() != folder.url.path.lowercased() {
            throw Self.error("A folder named “\(cleaned)” already exists here.")
        }
        try fm.moveItem(at: folder.url, to: target)
        return ScratchFolder(id: folderId(for: target) ?? cleaned)
    }

    /// Moves a folder (with everything in it) into another folder ("" = top level).
    func moveFolder(_ folder: ScratchFolder, to parent: String) throws -> ScratchFolder {
        Self.invalidateExternal()
        guard folder.parent != parent else { return folder }
        guard parent != folder.id, !folder.contains(parent) else {
            throw Self.error("A folder can't be moved into itself.")
        }
        guard !folder.isExternalRoot, folder.storageRoot == storageRoot(ofFolder: parent) else {
            throw Self.error("Folders can only be moved within the scratches folder or within one external folder.")
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
        return ScratchFolder(id: folderId(for: target) ?? folder.name)
    }

    func deleteFolder(_ folder: ScratchFolder) throws {
        Self.invalidateExternal()
        guard !folder.isExternalRoot else { throw Self.error("Remove external folders from the sidebar instead.") }
        flushWrites()
        try fm.trashItem(at: folder.url, resultingItemURL: nil)
    }

    // MARK: Watching

    /// Calls `onChange` (debounced, on the main queue) when anything in the scratch folder tree is added,
    /// removed, renamed or written, including changes made outside the app.
    func watch(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        startStream()
    }

    /// Watches the external folders too; call after the list of external folders changes.
    func rewatch() {
        Self.invalidateExternal()
        stopStream()
        startStream()
    }

    private func startStream() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let events = (0..<count).map { (paths[$0], flags[$0]) }
            Unmanaged<ScratchStore>.fromOpaque(info).takeUnretainedValue().handle(events)
        }
        let paths = [dir.path] + ExternalFolders.all
        let flags = kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                               FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Sorts file events into edits of known files (cheap: only their dates change) and files or folders
    /// appearing, disappearing or being renamed (the affected external folder is walked again).
    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let now = Date()
        recentWrites = recentWrites.filter { now.timeIntervalSince($0.value) < 3 }
        let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        var relevant = false, onlyOwnSaves = true
        for (path, flags) in events {
            let root = ExternalFolders.root(containing: path) ?? ExternalFolders.all.first { path == $0 }
            let inside = path.dropFirst((root ?? dir.path).count)
            if flags & rescan == 0 {
                // Hidden files aren't listed, and atomic saves write a temporary "name.sb-1a2b3c4d-XyZ123" first.
                if inside.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                if inside.range(of: #"\.sb-[0-9a-f]+-[A-Za-z0-9]+$"#, options: .regularExpression) != nil { continue }
            }
            relevant = true
            let ownSave = recentWrites[path] != nil && flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0
            if !ownSave { onlyOwnSaves = false }
            if flags & structural != 0 && !ownSave {
                if let root {
                    Self.externalWalks.removeValue(forKey: root)
                } else if flags & rescan != 0 || !path.hasPrefix(dir.path) {
                    Self.invalidateExternal()
                }
            } else if let root {
                Self.refreshExternal(path, root: root)
            }
        }
        // The app's own saves only change modification dates, so the sidebar catches up once typing settles.
        if relevant { scheduleChange(after: onlyOwnSaves ? 3 : 0.3) }
    }

    private func scheduleChange(after delay: TimeInterval) {
        if let pending = watchDebounce, !pending.isCancelled, delay > pendingChangeDelay { return }
        watchDebounce?.cancel()
        guard let onChange else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.watchDebounce = nil
            onChange()
        }
        watchDebounce = item
        pendingChangeDelay = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit { stopStream() }

    // MARK: Helpers

    private func folderURL(_ folder: String) -> URL { ScratchPad.folderURL(forId: folder) }

    private static func cleanName(_ name: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { throw error("Enter a name.") }
        return cleaned
    }

    static func error(_ message: String) -> NSError {
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
