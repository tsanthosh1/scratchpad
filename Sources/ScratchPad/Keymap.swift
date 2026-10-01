import AppKit

/// A shortcut stored in CodeMirror notation, e.g. `Ctrl-Shift-g`, `Cmd-Alt-l`, `Alt-Shift-ArrowUp`.
/// The same string drives both the CodeMirror keymap and the native menu key equivalents.
struct KeyCombo: Equatable {
    var ctrl = false
    var alt = false
    var shift = false
    var cmd = false
    var key: String

    init(ctrl: Bool = false, alt: Bool = false, shift: Bool = false, cmd: Bool = false, key: String) {
        self.ctrl = ctrl; self.alt = alt; self.shift = shift; self.cmd = cmd; self.key = key
    }

    init?(_ string: String) {
        guard !string.isEmpty else { return nil }
        // Split on "-" but keep a trailing "-" as the key itself (e.g. "Cmd--").
        var parts: [String] = []
        var rest = Substring(string)
        while let dash = rest.firstIndex(of: "-"), dash != rest.startIndex, rest.index(after: dash) != rest.endIndex {
            parts.append(String(rest[..<dash]))
            rest = rest[rest.index(after: dash)...]
        }
        parts.append(String(rest))
        key = parts.removeLast()
        for mod in parts {
            switch mod.lowercased() {
            case "ctrl", "control", "c": ctrl = true
            case "alt", "option", "a": alt = true
            case "shift", "s": shift = true
            case "cmd", "meta", "mod", "m": cmd = true
            default: return nil
            }
        }
        if key.count == 1 { key = key.lowercased() }
    }

    var string: String {
        var s = ""
        if ctrl { s += "Ctrl-" }
        if alt { s += "Alt-" }
        if shift { s += "Shift-" }
        if cmd { s += "Cmd-" }
        return s + key
    }

    var display: String {
        var s = ""
        if ctrl { s += "⌃" }
        if alt { s += "⌥" }
        if shift { s += "⇧" }
        if cmd { s += "⌘" }
        return s + Self.keyDisplay[key, default: key.count == 1 ? key.uppercased() : key]
    }

    private static let keyDisplay: [String: String] = [
        "ArrowUp": "↑", "ArrowDown": "↓", "ArrowLeft": "←", "ArrowRight": "→",
        "Enter": "↩", "Backspace": "⌫", "Delete": "⌦", "Tab": "⇥", "Escape": "⎋",
        "Space": "Space", "Home": "↖", "End": "↘", "PageUp": "⇞", "PageDown": "⇟",
    ]

    private static let keyEquivalents: [String: Int] = [
        "ArrowUp": NSUpArrowFunctionKey, "ArrowDown": NSDownArrowFunctionKey,
        "ArrowLeft": NSLeftArrowFunctionKey, "ArrowRight": NSRightArrowFunctionKey,
        "Enter": 0x0d, "Backspace": 0x08, "Delete": NSDeleteFunctionKey, "Tab": 0x09,
        "Escape": 0x1b, "Space": 0x20, "Home": NSHomeFunctionKey, "End": NSEndFunctionKey,
        "PageUp": NSPageUpFunctionKey, "PageDown": NSPageDownFunctionKey,
    ]

    /// Values for `NSMenuItem.keyEquivalent` / `keyEquivalentModifierMask`.
    var menuEquivalent: (String, NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if ctrl { mask.insert(.control) }
        if alt { mask.insert(.option) }
        if shift { mask.insert(.shift) }
        if cmd { mask.insert(.command) }
        // AppKit matches ⇧+digit/symbol against the shifted character (⇧8 arrives as "*").
        if shift, let shifted = Self.shiftedSymbols[key] {
            mask.remove(.shift)
            return (shifted, mask)
        }
        if let code = Self.keyEquivalents[key], let scalar = UnicodeScalar(code) {
            return (String(Character(scalar)), mask)
        }
        if key.hasPrefix("F"), let n = Int(key.dropFirst()), (1...20).contains(n),
           let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            return (String(Character(scalar)), mask)
        }
        return (key, mask)
    }

    private static let shiftedSymbols: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]

    private static let keyCodeNames: [UInt16: String] = [
        126: "ArrowUp", 125: "ArrowDown", 123: "ArrowLeft", 124: "ArrowRight",
        36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete", 48: "Tab", 53: "Escape",
        49: "Space", 115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Builds a combo from a key-down event (used by the shortcut recorder).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        ctrl = flags.contains(.control)
        alt = flags.contains(.option)
        shift = flags.contains(.shift)
        cmd = flags.contains(.command)
        if let name = Self.keyCodeNames[event.keyCode] {
            key = name
        } else if let chars = event.characters(byApplyingModifiers: []), let c = chars.first, !chars.isEmpty {
            key = String(c).lowercased()
        } else {
            return nil
        }
    }
}

enum ActionScope {
    /// Handled natively through the menu bar (and forwarded from the editor while it has focus).
    case app
    /// Forwarded to a CodeMirror command of the same id.
    case editor
    /// Only active while the scratch list has keyboard focus, so it can reuse editor keys like ⌘C or ⌘D.
    case sidebar
}

struct ActionDef {
    let id: String
    let title: String
    let category: String
    let scope: ActionScope
    let defaultKey: String?
}

/// Every bindable action. Defaults follow IntelliJ's macOS keymap where it makes sense.
enum Actions {
    static let all: [ActionDef] = [
        // Scratches
        .init(id: "newScratch", title: "New Scratch…", category: "Scratch", scope: .app, defaultKey: "Cmd-n"),
        .init(id: "newFromClipboard", title: "New Scratch from Clipboard", category: "Scratch", scope: .app, defaultKey: "Cmd-Shift-n"),
        .init(id: "renameScratch", title: "Rename Scratch…", category: "Scratch", scope: .app, defaultKey: "Shift-Cmd-r"),
        .init(id: "deleteScratch", title: "Delete Scratch", category: "Scratch", scope: .app, defaultKey: "Alt-Cmd-Backspace"),
        .init(id: "copyPath", title: "Copy File Path", category: "Scratch", scope: .app, defaultKey: "Alt-Cmd-c"),
        .init(id: "copyFile", title: "Copy File", category: "Scratch", scope: .app, defaultKey: "Shift-Cmd-c"),
        .init(id: "revealScratch", title: "Reveal in Finder", category: "Scratch", scope: .app, defaultKey: nil),
        .init(id: "revealInSidebar", title: "Reveal in Scratch List", category: "Scratch", scope: .app, defaultKey: "Cmd-1"),
        .init(id: "compareWithClipboard", title: "Compare with Clipboard", category: "Scratch", scope: .app, defaultKey: nil),
        .init(id: "nextScratch", title: "Next Scratch", category: "Scratch", scope: .app, defaultKey: "Shift-Cmd-]"),
        .init(id: "navigateBack", title: "Back", category: "Scratch", scope: .app, defaultKey: "Shift-Cmd-ArrowLeft"),
        .init(id: "navigateForward", title: "Forward", category: "Scratch", scope: .app, defaultKey: "Shift-Cmd-ArrowRight"),
        .init(id: "recentScratches", title: "Recent Scratches…", category: "Scratch", scope: .app, defaultKey: "Cmd-e"),
        .init(id: "previousScratch", title: "Previous Scratch", category: "Scratch", scope: .app, defaultKey: "Shift-Cmd-["),
        .init(id: "commandPalette", title: "Find Action / Dev Tools…", category: "Scratch", scope: .app, defaultKey: "Shift-Cmd-a"),

        // Scratch list (active while the list has focus)
        .init(id: "sidebarCompare", title: "Compare Selected Scratches", category: "Scratch List", scope: .sidebar, defaultKey: "Cmd-d"),
        .init(id: "sidebarCopyFile", title: "Copy Selected Files", category: "Scratch List", scope: .sidebar, defaultKey: "Cmd-c"),
        .init(id: "sidebarDelete", title: "Delete Selected Scratches", category: "Scratch List", scope: .sidebar, defaultKey: "Cmd-Backspace"),
        .init(id: "sidebarRename", title: "Rename Selected Scratch", category: "Scratch List", scope: .sidebar, defaultKey: "Enter"),

        // Code
        .init(id: "format", title: "Reformat Code", category: "Code", scope: .app, defaultKey: "Alt-Cmd-l"),
        .init(id: "compact", title: "Compact (Minify) JSON/XML", category: "Code", scope: .app, defaultKey: "Alt-Shift-Cmd-l"),
        .init(id: "run", title: "Run", category: "Code", scope: .app, defaultKey: "Ctrl-r"),
        .init(id: "stop", title: "Stop", category: "Code", scope: .app, defaultKey: "Cmd-F2"),
        .init(id: "openSharedPackages", title: "Open Shared package.json", category: "Code", scope: .app, defaultKey: nil),
        .init(id: "installSharedPackages", title: "Install Shared Packages (npm install)", category: "Code", scope: .app,
              defaultKey: nil),
        .init(id: "chooseJDK", title: "Choose JDK…", category: "Code", scope: .app, defaultKey: nil),
        .init(id: "httpRunAll", title: "Run All Requests in File", category: "HTTP", scope: .app, defaultKey: "Alt-Shift-Ctrl-r"),
        .init(id: "httpCopyCurl", title: "Copy Request as cURL", category: "HTTP", scope: .app, defaultKey: "Alt-Shift-Cmd-c"),
        .init(id: "httpImportCurl", title: "Paste cURL as HTTP Request", category: "HTTP", scope: .app, defaultKey: "Alt-Shift-Cmd-i"),
        .init(id: "httpOpenResponse", title: "Open Response in New Scratch", category: "HTTP", scope: .app, defaultKey: "Alt-Shift-Cmd-o"),
        .init(id: "toggleLineComment", title: "Comment with Line Comment", category: "Code", scope: .editor, defaultKey: "Cmd-/"),
        .init(id: "toggleBlockComment", title: "Comment with Block Comment", category: "Code", scope: .editor, defaultKey: "Alt-Cmd-/"),

        // Multi-cursor & selection
        .init(id: "addNextOccurrence", title: "Add Selection for Next Occurrence", category: "Selection", scope: .editor, defaultKey: "Ctrl-g"),
        .init(id: "unselectOccurrence", title: "Unselect Occurrence", category: "Selection", scope: .editor, defaultKey: "Ctrl-Shift-g"),
        .init(id: "selectAllOccurrences", title: "Select All Occurrences", category: "Selection", scope: .editor, defaultKey: "Ctrl-Cmd-g"),
        .init(id: "addCursorAbove", title: "Add Caret Above", category: "Selection", scope: .editor, defaultKey: "Alt-Cmd-ArrowUp"),
        .init(id: "addCursorBelow", title: "Add Caret Below", category: "Selection", scope: .editor, defaultKey: "Alt-Cmd-ArrowDown"),
        .init(id: "addCursorsToLineEnds", title: "Add Carets to Ends of Selected Lines", category: "Selection", scope: .editor, defaultKey: "Alt-Shift-g"),
        .init(id: "singleCursor", title: "Remove Extra Carets", category: "Selection", scope: .editor, defaultKey: "Escape"),
        .init(id: "expandSelection", title: "Extend Selection", category: "Selection", scope: .editor, defaultKey: "Alt-ArrowUp"),
        .init(id: "shrinkSelection", title: "Shrink Selection", category: "Selection", scope: .editor, defaultKey: "Alt-ArrowDown"),
        .init(id: "selectLine", title: "Select Line", category: "Selection", scope: .editor, defaultKey: "Cmd-l"),

        // Lines
        .init(id: "duplicateLine", title: "Duplicate Line or Selection", category: "Lines", scope: .editor, defaultKey: "Cmd-d"),
        .init(id: "deleteLine", title: "Delete Line", category: "Lines", scope: .editor, defaultKey: "Cmd-Backspace"),
        .init(id: "moveLineUp", title: "Move Line Up", category: "Lines", scope: .editor, defaultKey: "Alt-Shift-ArrowUp"),
        .init(id: "moveLineDown", title: "Move Line Down", category: "Lines", scope: .editor, defaultKey: "Alt-Shift-ArrowDown"),
        .init(id: "startNewLine", title: "Start New Line", category: "Lines", scope: .editor, defaultKey: "Shift-Enter"),
        .init(id: "jumpToBracket", title: "Jump to Matching Bracket", category: "Lines", scope: .editor, defaultKey: "Ctrl-m"),

        // Find & navigation
        .init(id: "find", title: "Find / Replace", category: "Find", scope: .editor, defaultKey: "Cmd-f"),
        .init(id: "findNext", title: "Find Next", category: "Find", scope: .editor, defaultKey: "Cmd-g"),
        .init(id: "findPrevious", title: "Find Previous", category: "Find", scope: .editor, defaultKey: "Shift-Cmd-g"),
        .init(id: "gotoLine", title: "Go to Line…", category: "Find", scope: .editor, defaultKey: "Ctrl-l"),
        .init(id: "findInScratches", title: "Find in Scratches…", category: "Find", scope: .app, defaultKey: "Shift-Cmd-f"),

        // Folding
        .init(id: "fold", title: "Collapse", category: "Folding", scope: .editor, defaultKey: "Shift-Cmd--"),
        .init(id: "unfold", title: "Expand", category: "Folding", scope: .editor, defaultKey: "Shift-Cmd-="),
        .init(id: "foldAll", title: "Collapse All", category: "Folding", scope: .editor, defaultKey: "Alt-Shift-Cmd--"),
        .init(id: "unfoldAll", title: "Expand All", category: "Folding", scope: .editor, defaultKey: "Alt-Shift-Cmd-="),

        // View
        .init(id: "toggleSidebar", title: "Toggle Scratch List", category: "View", scope: .app, defaultKey: "Shift-Cmd-m"),
        .init(id: "toggleConsole", title: "Toggle Run Console", category: "View", scope: .app, defaultKey: "Cmd-4"),
        .init(id: "clearConsole", title: "Clear Console", category: "View", scope: .app, defaultKey: "Cmd-k"),
        .init(id: "toggleWrap", title: "Toggle Soft Wrap", category: "View", scope: .app, defaultKey: nil),
        .init(id: "togglePreview", title: "Toggle Preview / Diff View", category: "View", scope: .app, defaultKey: "Shift-Cmd-v"),
        .init(id: "fullPreview", title: "Toggle Full Preview", category: "View", scope: .app, defaultKey: "Alt-Shift-Cmd-v"),
        .init(id: "groupByType", title: "Group Scratches by Type", category: "View", scope: .app, defaultKey: nil),
        .init(id: "toggleFoldersPane", title: "Show Folders Column", category: "View", scope: .app, defaultKey: nil),
        .init(id: "groupByDate", title: "Group Scratches by Date Edited", category: "View", scope: .app, defaultKey: nil),
        .init(id: "zoomIn", title: "Increase Font Size", category: "View", scope: .app, defaultKey: "Cmd-="),
        .init(id: "zoomOut", title: "Decrease Font Size", category: "View", scope: .app, defaultKey: "Cmd--"),
        .init(id: "zoomReset", title: "Reset Font Size", category: "View", scope: .app, defaultKey: "Cmd-0"),
    ]

    static let byId: [String: ActionDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

extension Notification.Name {
    static let keymapChanged = Notification.Name("ScratchPad.keymapChanged")
    static let settingsChanged = Notification.Name("ScratchPad.settingsChanged")
}

/// Default bindings plus user overrides persisted in `keymap.json` (only overrides are written,
/// an empty string means "unbound").
final class KeymapStore {
    static let shared = KeymapStore()

    private(set) var overrides: [String: String] = [:]
    let fileURL = AppPaths.support.appendingPathComponent("keymap.json")

    private init() { reload() }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            overrides = [:]
            return
        }
        overrides = dict.filter { Actions.byId[$0.key] != nil }
    }

    func key(for id: String) -> KeyCombo? {
        let raw = overrides[id] ?? Actions.byId[id]?.defaultKey ?? ""
        return KeyCombo(raw)
    }

    func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    func set(_ combo: KeyCombo?, for id: String) {
        let value = combo?.string ?? ""
        if value == (Actions.byId[id]?.defaultKey ?? "") {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = value
        }
        save()
    }

    func reset(_ id: String) {
        overrides.removeValue(forKey: id)
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    /// Other actions bound to the same combo that could fire in the same context. Sidebar and editor
    /// shortcuts never compete with each other because only one of them has focus.
    func conflicts(for combo: KeyCombo, excluding id: String) -> [ActionDef] {
        guard let scope = Actions.byId[id]?.scope else { return [] }
        return Actions.all.filter { other in
            guard other.id != id, key(for: other.id) == combo else { return false }
            return other.scope == scope || other.scope == .app || scope == .app
        }
    }

    func action(for combo: KeyCombo, scope: ActionScope) -> ActionDef? {
        Actions.all.first { $0.scope == scope && key(for: $0.id) == combo }
    }

    /// Bindings for editor-scoped actions, in the `{ command: key }` shape the web editor expects.
    func bindings(for scope: ActionScope) -> [String: String] {
        var result: [String: String] = [:]
        for action in Actions.all where action.scope == scope {
            result[action.id] = key(for: action.id)?.string ?? ""
        }
        return result
    }

    private func save() {
        do {
            let data = try JSONSerialization.data(withJSONObject: overrides, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ScratchPad: failed to save keymap: \(error)")
        }
        NotificationCenter.default.post(name: .keymapChanged, object: nil)
    }
}
