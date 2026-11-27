import Foundation

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ScratchPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let scratches: URL = {
        let dir = support.appendingPathComponent("scratches", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let packages = support.appendingPathComponent("packages", isDirectory: true)

    static let runs: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ScratchPad/runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

enum FolderFilter: Equatable {
    case all, unfiled, packages, tools, folder(String)

    static let allKey = "\u{1}all"
    static let packagesKey = "\u{1}packages"
    static let toolsKey = "\u{1}tools"

    init(key: String) {
        switch key {
        case Self.allKey: self = .all
        case Self.packagesKey: self = .packages
        case Self.toolsKey: self = .tools
        case "": self = .unfiled
        default: self = .folder(key)
        }
    }

    var key: String {
        switch self {
        case .all: return Self.allKey
        case .packages: return Self.packagesKey
        case .tools: return Self.toolsKey
        case .unfiled: return ""
        case .folder(let id): return id
        }
    }

    /// Folder new scratches go into, nil for "All Scratches".
    var folderId: String? {
        switch self {
        case .all, .packages, .tools: return nil
        case .unfiled: return ""
        case .folder(let id): return id
        }
    }

    func includes(_ scratch: Scratch) -> Bool {
        if self == .packages { return scratch.isSharedManifest }
        if self == .tools { return false }
        // "All Scratches" means the scratches folder; external folders are browsed through their own rows.
        return folderId.map { scratch.folder == $0 } ?? scratch.isInScratchFolder
    }
}

enum SidebarGrouping: String, CaseIterable {
    case none, type, date

    var title: String {
        switch self {
        case .none: return "No Grouping"
        case .type: return "Group by File Type"
        case .date: return "Group by Date Edited"
        }
    }

    var symbol: String {
        switch self {
        case .none, .type: return "square.stack.3d.up"
        case .date: return "calendar"
        }
    }
}

enum ConsolePosition: String, CaseIterable {
    case bottom, right

    var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .right: return "Right"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    static let defaultFontSize = 13

    private init() {
        defaults.register(defaults: [
            "fontSize": Self.defaultFontSize,
            "fontFamily": "Menlo",
            "tabSize": 2,
            "lineWrap": false,
            "autoComplete": true,
            "javaHome": "",
            "nodePath": "",
            "javaVersion": 21,
        ])
    }

    var fontSize: Int {
        get { defaults.integer(forKey: "fontSize") }
        set { defaults.set(min(max(newValue, 8), 40), forKey: "fontSize"); changed() }
    }
    var fontFamily: String {
        get { defaults.string(forKey: "fontFamily") ?? "Menlo" }
        set { defaults.set(newValue, forKey: "fontFamily"); changed() }
    }
    var tabSize: Int {
        get { defaults.integer(forKey: "tabSize") }
        set { defaults.set(min(max(newValue, 1), 8), forKey: "tabSize"); changed() }
    }
    var lineWrap: Bool {
        get { defaults.bool(forKey: "lineWrap") }
        set { defaults.set(newValue, forKey: "lineWrap"); changed() }
    }
    var autoComplete: Bool {
        get { defaults.bool(forKey: "autoComplete") }
        set { defaults.set(newValue, forKey: "autoComplete"); changed() }
    }
    /// Empty means "auto-detect using `javaVersion`".
    var javaHome: String {
        get { defaults.string(forKey: "javaHome") ?? "" }
        set { defaults.set(newValue, forKey: "javaHome"); changed() }
    }
    var javaVersion: Int {
        get { defaults.integer(forKey: "javaVersion") }
        set { defaults.set(newValue, forKey: "javaVersion"); changed() }
    }
    /// Empty means "auto-detect".
    var nodePath: String {
        get { defaults.string(forKey: "nodePath") ?? "" }
        set { defaults.set(newValue, forKey: "nodePath"); changed() }
    }
    /// Folder holding the shared package.json whose node_modules JS/TS scratches can import.
    /// Empty means the app's own `packages` folder.
    var nodePackagesDir: String {
        get { defaults.string(forKey: "nodePackagesDir") ?? "" }
        set { defaults.set(newValue, forKey: "nodePackagesDir"); changed() }
    }

    var sidebarGrouping: SidebarGrouping {
        get {
            if let raw = defaults.string(forKey: "sidebarGrouping"), let mode = SidebarGrouping(rawValue: raw) { return mode }
            return defaults.bool(forKey: "groupByType") ? .type : .none
        }
        set { defaults.set(newValue.rawValue, forKey: "sidebarGrouping") }
    }
    /// Two-column sidebar: folders on the left, the chosen folder's scratches on the right.
    var foldersPane: Bool {
        get { defaults.bool(forKey: "foldersPane") }
        set { defaults.set(newValue, forKey: "foldersPane") }
    }
    /// Folder shown in the file column: `FolderFilter.allKey`, "" for unfiled, or a folder path.
    var folderFilter: String {
        get { defaults.string(forKey: "folderFilter") ?? FolderFilter.allKey }
        set { defaults.set(newValue, forKey: "folderFilter") }
    }
    var collapsedGroups: Set<String> {
        get { Set(defaults.stringArray(forKey: "collapsedGroups") ?? []) }
        set { defaults.set(Array(newValue), forKey: "collapsedGroups") }
    }
    /// Preview layout for Markdown/HTML scratches.
    var previewMode: PreviewMode {
        get { PreviewMode(rawValue: defaults.string(forKey: "previewMode") ?? "") ?? .split }
        set { defaults.set(newValue.rawValue, forKey: "previewMode") }
    }
    /// How OpenAPI specs are previewed.
    var specViewer: SpecViewer {
        get { SpecViewer(rawValue: defaults.string(forKey: "specViewer") ?? "") ?? .swagger }
        set { defaults.set(newValue.rawValue, forKey: "specViewer") }
    }
    /// Docking position for console (bottom vs right).
    var consolePosition: ConsolePosition {
        get {
            if let raw = defaults.string(forKey: "consolePosition"), let pos = ConsolePosition(rawValue: raw) { return pos }
            return .bottom
        }
        set { defaults.set(newValue.rawValue, forKey: "consolePosition"); changed() }
    }

    /// Scratch ids, most recently opened first.
    var recentScratches: [String] {
        get { defaults.stringArray(forKey: "recentScratches") ?? [] }
        set { defaults.set(Array(newValue.prefix(50)), forKey: "recentScratches") }
    }

    /// Ids of the files open as tabs, in tab order.
    var openTabs: [String] {
        get { defaults.stringArray(forKey: "openTabs") ?? [] }
        set { defaults.set(newValue, forKey: "openTabs") }
    }
    var lastScratch: String? {
        get { defaults.string(forKey: "lastScratch") }
        set { defaults.set(newValue, forKey: "lastScratch") }
    }
    var lastLanguage: Language {
        get { Language(rawValue: defaults.string(forKey: "lastLanguage") ?? "") ?? .json }
        set { defaults.set(newValue.rawValue, forKey: "lastLanguage") }
    }

    var editorSettings: [String: Any] {
        ["fontSize": fontSize, "fontFamily": fontFamily, "tabSize": tabSize, "lineWrap": lineWrap, "autoComplete": autoComplete]
    }

    /// Values a dev tool page remembers between launches (input text, options).
    func toolValue(_ tool: String, _ key: String) -> String? {
        defaults.string(forKey: "tool.\(tool).\(key)")
    }

    func setToolValue(_ tool: String, _ key: String, _ value: String) {
        defaults.set(value, forKey: "tool.\(tool).\(key)")
    }

    /// The dev tool page open at quit, reopened at launch.
    /// Folders shown in the sidebar from elsewhere on disk (see `ExternalFolders`).
    var externalFolders: [String] {
        get { defaults.stringArray(forKey: "externalFolders") ?? [] }
        set { defaults.set(newValue, forKey: "externalFolders") }
    }
    /// Files opened from outside the scratch folder (Dock, Finder, ⌘O), most recent first.
    var openedFiles: [String] {
        get { defaults.stringArray(forKey: "openedFiles") ?? [] }
        set { defaults.set(Array(newValue.prefix(30)), forKey: "openedFiles") }
    }
    var lastTool: String? {
        get { defaults.string(forKey: "lastTool") }
        set { defaults.set(newValue, forKey: "lastTool") }
    }

    private func changed() {
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}
