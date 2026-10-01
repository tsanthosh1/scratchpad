import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController!
    private var settingsWindow: SettingsWindowController?
    private var actionItems: [String: [NSMenuItem]] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        applyKeyEquivalents()
        NotificationCenter.default.addObserver(forName: .keymapChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyKeyEquivalents()
        }

        main = MainWindowController()
        main.window?.isReleasedWhenClosed = false
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Warm the Node lookup so the first run doesn't wait on a login shell.
        DispatchQueue.global(qos: .utility).async { _ = Toolchains.resolveNode() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        main.flushAll()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { main.showWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showMainWindow(_ sender: Any?) {
        main.showWindow(nil)
    }

    // MARK: Menu

    private func action(_ id: String) -> NSMenuItem {
        let def = Actions.byId[id]!
        let item = NSMenuItem(title: def.title, action: #selector(MainWindowController.performAction(_:)), keyEquivalent: "")
        item.representedObject = id
        actionItems[id, default: []].append(item)
        return item
    }

    private func item(_ title: String, _ selector: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appName = "ScratchPad"

        let settings = item("Settings…", #selector(showSettings(_:)), ",")
        settings.target = self
        mainMenu.addItem(submenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            settings,
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        mainMenu.addItem(submenu("Scratch", [
            action("newScratch"), action("newFromClipboard"), .separator(),
            action("renameScratch"), action("deleteScratch"), action("revealScratch"), action("revealInSidebar"), .separator(),
            action("copyPath"), action("copyFile"), .separator(),
            action("compareWithClipboard"), .separator(),
            action("navigateBack"), action("navigateForward"), .separator(),
            action("recentScratches"), action("nextScratch"), action("previousScratch"), .separator(),
            action("commandPalette"), .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        mainMenu.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu("Find", [action("find"), action("findNext"), action("findPrevious"), .separator(),
                             action("findInScratches"), .separator(), action("gotoLine")]),
            .separator(),
            action("duplicateLine"), action("deleteLine"), action("moveLineUp"), action("moveLineDown"),
            action("startNewLine"), action("jumpToBracket"), .separator(),
            action("toggleLineComment"), action("toggleBlockComment"),
        ]))

        mainMenu.addItem(submenu("Selection", [
            action("addNextOccurrence"), action("unselectOccurrence"), action("selectAllOccurrences"), .separator(),
            action("addCursorAbove"), action("addCursorBelow"), action("addCursorsToLineEnds"), action("singleCursor"),
            .separator(),
            action("expandSelection"), action("shrinkSelection"), action("selectLine"),
        ]))

        let languageItems = Language.allCases.enumerated().map { i, lang in
            let item = NSMenuItem(title: lang.displayName, action: #selector(MainWindowController.changeLanguageFromMenu(_:)),
                                  keyEquivalent: "")
            item.tag = i
            return item
        }
        mainMenu.addItem(submenu("Code", [
            action("format"), action("compact"), submenu("Language", languageItems), .separator(),
            action("run"), action("stop"), action("chooseJDK"), .separator(),
            action("openSharedPackages"), action("installSharedPackages"), .separator(),
            submenu("HTTP", [action("httpRunAll"), .separator(), action("httpImportCurl"), action("httpCopyCurl"),
                             .separator(), action("httpOpenResponse")]), .separator(),
            action("fold"), action("unfold"), action("foldAll"), action("unfoldAll"),
        ]))

        mainMenu.addItem(submenu("View", [
            action("toggleSidebar"), action("revealInSidebar"), action("toggleConsole"), action("clearConsole"), .separator(),
            action("togglePreview"), action("fullPreview"), action("groupByType"), action("groupByDate"), action("toggleFoldersPane"), .separator(),
            action("toggleWrap"), action("zoomIn"), action("zoomOut"), action("zoomReset"), .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        let showMain = item("ScratchPad", #selector(showMainWindow(_:)), "0")
        showMain.target = self
        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            showMain,
        ])
        NSApp.windowsMenu = windowMenu.submenu
        mainMenu.addItem(windowMenu)
        return mainMenu
    }

    /// Editor-scoped shortcuts only get a menu key equivalent when they use ⌘ or ⌃; plain keys such as
    /// Escape or ⌥↑ must reach the focused text view (CodeMirror handles those itself).
    private func applyKeyEquivalents() {
        for (id, items) in actionItems {
            let combo = KeymapStore.shared.key(for: id)
            let useMenuKey: Bool
            if let combo, Actions.byId[id]?.scope == .editor {
                useMenuKey = (combo.cmd || combo.ctrl) && combo.key != "Escape"
            } else {
                useMenuKey = combo != nil
            }
            for item in items {
                if let combo, useMenuKey {
                    let (key, mask) = combo.menuEquivalent
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = mask
                } else {
                    item.keyEquivalent = ""
                    item.keyEquivalentModifierMask = []
                }
            }
        }
    }
}
