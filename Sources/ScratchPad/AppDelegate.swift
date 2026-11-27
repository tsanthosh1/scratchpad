import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController!
    private var settingsWindow: SettingsWindowController?
    private var actionItems: [String: [NSMenuItem]] = [:]
    /// Files handed over (dock drop, Finder "Open With") before the window exists.
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        applyKeyEquivalents()
        NotificationCenter.default.addObserver(forName: .keymapChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyKeyEquivalents()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let main = self?.main, let combo = KeyCombo(event: event) else { return event }
            let keys = KeymapStore.shared
            // Extra shortcuts of app actions: a menu item holds only one key equivalent.
            if let action = keys.alternateAction(for: combo), main.performShortcut(action.id) { return nil }
            if keys.action(for: combo, scope: .app) == nil, let digit = KeyCombo(digitKeyOf: event),
               let action = keys.action(for: digit, scope: .app), main.performShortcut(action.id) {
                return nil
            }
            return event
        }

        main = MainWindowController()
        main.window?.isReleasedWhenClosed = false
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !pendingFiles.isEmpty {
            main.openFiles(pendingFiles)
            pendingFiles = []
        }

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

    /// Files dropped on the Dock icon or opened with ScratchPad from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let main else {
            pendingFiles += urls
            return
        }
        main.openFiles(urls)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showMainWindow(_ sender: Any?) {
        main.showWindow(nil)
    }

    /// Reached only when the main window isn't key: ⌘W (Close Tab) then closes the window in front, such as Settings.
    @objc func performAction(_ sender: Any?) {
        guard (sender as? NSMenuItem)?.representedObject as? String == "closeTab" else { return }
        NSApp.keyWindow?.performClose(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performAction(_:)) else { return true }
        return menuItem.representedObject as? String == "closeTab" && NSApp.keyWindow != nil
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
            action("installCLI"),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        mainMenu.addItem(submenu("Scratch", [
            action("newScratch"), action("newFromClipboard"), action("openFile"), action("addExternalFolder"), .separator(),
            action("save"), .separator(),
            action("renameScratch"), action("deleteScratch"), action("revealScratch"), action("revealInSidebar"), .separator(),
            action("copyPath"), action("copyFile"), .separator(),
            action("compareWithClipboard"), .separator(),
            action("navigateBack"), action("navigateForward"), .separator(),
            action("gotoScratch"), action("gotoSymbol"), action("recentScratches"), action("nextScratch"), action("previousScratch"), .separator(),
            action("commandPalette"), .separator(),
            action("nextTab"), action("previousTab"), action("closeTab"), action("closeOtherTabs"), action("closeAllTabs"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
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

        mainMenu.addItem(submenu("Format", [
            action("formatBold"), action("formatItalic"), action("formatUnderline"), action("formatStrikethrough"), .separator(),
            action("formatBigger"), action("formatSmaller"), action("formatFonts"), .separator(),
            action("formatAlignLeft"), action("formatAlignCenter"), action("formatAlignRight"), action("formatJustify"), .separator(),
            action("formatBulletList"), action("formatNumberedList"), .separator(),
            action("formatInsertImage"), action("formatClear"),
        ]))

        mainMenu.addItem(submenu("View", [
            action("toggleSidebar"), action("revealInSidebar"), action("toggleConsole"), action("editorOnly"), action("clearConsole"), .separator(),
            action("togglePreview"), action("fullPreview"), action("copyRichText"), action("exportPreview"), action("exportPreviewPDF"), action("exportPreviewHTML"), action("exportPreviewMHTML"), .separator(),
            action("specViewerSwagger"), action("specViewerScalar"), action("specViewerKong"), .separator(), action("groupByType"), action("groupByDate"), action("toggleFoldersPane"), .separator(),
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
