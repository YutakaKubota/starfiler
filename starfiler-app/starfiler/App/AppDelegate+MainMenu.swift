import AppKit

// MARK: - Main Menu Construction & Menu Actions
extension AppDelegate {
    func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(menuShowSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let newFolderItem = fileMenu.addItem(withTitle: "New Folder", action: #selector(menuCreateDirectory(_:)), keyEquivalent: "n")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        let openItem = fileMenu.addItem(withTitle: "Open", action: #selector(menuOpenFile(_:)), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        let showInFinderItem = fileMenu.addItem(withTitle: "Show in Finder", action: #selector(menuRevealInFinder(_:)), keyEquivalent: "f")
        showInFinderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        let copyItemPathItem = editMenu.addItem(withTitle: "Copy File/Folder Path", action: #selector(menuCopySelectedItemPath(_:)), keyEquivalent: "c")
        copyItemPathItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        let moveItemHereItem = editMenu.addItem(withTitle: "Move Item Here", action: #selector(menuPasteAsMove(_:)), keyEquivalent: "v")
        moveItemHereItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Move to Trash", action: #selector(menuDelete(_:)), keyEquivalent: "\u{08}")
        editMenu.addItem(withTitle: "Rename...", action: #selector(menuRename(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Batch Rename...", action: #selector(menuBatchRename(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Sync: Left → Right", action: #selector(menuSyncLeftToRight(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Sync: Right → Left", action: #selector(menuSyncRightToLeft(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(menuSelectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(menuToggleSidebar(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command]
        let showFilesModeItem = viewMenu.addItem(withTitle: "Show Files", action: #selector(menuShowFilesMode(_:)), keyEquivalent: "1")
        showFilesModeItem.keyEquivalentModifierMask = [.command]
        let showMediaModeItem = viewMenu.addItem(withTitle: "Show Media", action: #selector(menuShowMediaMode(_:)), keyEquivalent: "2")
        showMediaModeItem.keyEquivalentModifierMask = [.command]
        let toggleLeftPaneItem = viewMenu.addItem(withTitle: "Toggle Left Pane", action: #selector(menuToggleLeftPane(_:)), keyEquivalent: "1")
        toggleLeftPaneItem.keyEquivalentModifierMask = [.control]
        let toggleRightPaneItem = viewMenu.addItem(withTitle: "Toggle Right Pane", action: #selector(menuToggleRightPane(_:)), keyEquivalent: "2")
        toggleRightPaneItem.keyEquivalentModifierMask = [.control]
        let toggleSinglePaneItem = viewMenu.addItem(withTitle: "Toggle Single Pane", action: #selector(menuToggleSinglePane(_:)), keyEquivalent: "3")
        toggleSinglePaneItem.keyEquivalentModifierMask = [.control]
        let equalizePaneWidthsItem = viewMenu.addItem(withTitle: "Equalize Pane Widths", action: #selector(menuEqualizePaneWidths(_:)), keyEquivalent: "4")
        equalizePaneWidthsItem.keyEquivalentModifierMask = [.control]
        let toggleMediaModeItem = viewMenu.addItem(withTitle: "Toggle Media Mode", action: #selector(menuToggleMediaMode(_:)), keyEquivalent: "0")
        toggleMediaModeItem.keyEquivalentModifierMask = [.control]
        let toggleRecursiveItem = viewMenu.addItem(withTitle: "Toggle Recursive Mode", action: #selector(menuToggleRecursive(_:)), keyEquivalent: "f")
        toggleRecursiveItem.keyEquivalentModifierMask = [.control, .shift]
        viewMenu.addItem(withTitle: "Toggle Hidden Files", action: #selector(menuToggleHiddenFiles(_:)), keyEquivalent: ".")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Sort by Name", action: #selector(menuSortByName(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Sort by Size", action: #selector(menuSortBySize(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Sort by Date Modified", action: #selector(menuSortByDate(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Sort by Selection Order", action: #selector(menuSortBySelectionOrder(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Reverse Sort Order", action: #selector(menuReverseSortOrder(_:)), keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Refresh", action: #selector(menuRefresh(_:)), keyEquivalent: "r")
        viewMenuItem.submenu = viewMenu

        // Go menu
        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Back", action: #selector(menuGoBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "Forward", action: #selector(menuGoForward(_:)), keyEquivalent: "]")
        goMenu.addItem(withTitle: "Enclosing Folder", action: #selector(menuGoToParent(_:)), keyEquivalent: "\u{1B}")
        let goToFolderItem = goMenu.addItem(withTitle: "Go to File or Folder...", action: #selector(menuGoToPath(_:)), keyEquivalent: "g")
        goToFolderItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(NSMenuItem.separator())
        let hdItem = goMenu.addItem(withTitle: "HD", action: #selector(menuGoHD(_:)), keyEquivalent: "c")
        hdItem.keyEquivalentModifierMask = [.command, .shift]
        let homeItem = goMenu.addItem(withTitle: "Home", action: #selector(menuGoHome(_:)), keyEquivalent: "h")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        let desktopItem = goMenu.addItem(withTitle: "Desktop", action: #selector(menuGoDesktop(_:)), keyEquivalent: "d")
        desktopItem.keyEquivalentModifierMask = [.command, .shift]
        let documentsItem = goMenu.addItem(withTitle: "Documents", action: #selector(menuGoDocuments(_:)), keyEquivalent: "o")
        documentsItem.keyEquivalentModifierMask = [.command, .shift]
        let downloadsItem = goMenu.addItem(withTitle: "Downloads", action: #selector(menuGoDownloads(_:)), keyEquivalent: "l")
        downloadsItem.keyEquivalentModifierMask = [.command, .option]
        let applicationsItem = goMenu.addItem(withTitle: "Applications", action: #selector(menuGoApplications(_:)), keyEquivalent: "a")
        applicationsItem.keyEquivalentModifierMask = [.command, .shift]
        goMenuItem.submenu = goMenu

        // Terminal menu
        let terminalMenuItem = NSMenuItem()
        mainMenu.addItem(terminalMenuItem)
        let terminalMenu = NSMenu(title: "Terminal")
        let sessionManagerItem = terminalMenu.addItem(withTitle: "Session Manager", action: #selector(menuToggleSessionManager(_:)), keyEquivalent: "`")
        sessionManagerItem.keyEquivalentModifierMask = [.control]
        terminalMenu.addItem(NSMenuItem.separator())
        let launchClaudeItem = terminalMenu.addItem(withTitle: "Launch Claude Code", action: #selector(menuLaunchClaude(_:)), keyEquivalent: "")
        let launchCodexItem = terminalMenu.addItem(withTitle: "Launch Codex CLI", action: #selector(menuLaunchCodex(_:)), keyEquivalent: "")
        terminalMenuItem.submenu = terminalMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Switch Pane", action: #selector(menuSwitchPane(_:)), keyEquivalent: "\t")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help menu (enables menu item search via AppKit spotlight for help)
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    @objc func menuCreateDirectory(_ sender: Any?) {
        mainWindowController?.performAction { $0.createDirectory() }
    }

    @objc func menuOpenFile(_ sender: Any?) {
        mainWindowController?.openSelectedItemInActivePane()
    }

    @objc func menuRevealInFinder(_ sender: Any?) {
        mainWindowController?.performAction { vm in
            guard let url = vm.activePane.selectedItem?.url.standardizedFileURL else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc func undo(_ sender: Any?) {
        mainWindowController?.performAction { $0.undo() }
    }

    @objc func copy(_ sender: Any?) {
        mainWindowController?.performAction { vm in
            let copiedURLs = vm.copyMarkedToClipboard()
            guard !copiedURLs.isEmpty else {
                NSSound.beep()
                return
            }
            writeFileURLsToPasteboard(copiedURLs, operation: .copy)
        }
    }

    @objc func cut(_ sender: Any?) {
        mainWindowController?.performAction { vm in
            let cutURLs = vm.cutMarkedToClipboard()
            guard !cutURLs.isEmpty else {
                NSSound.beep()
                return
            }
            writeFileURLsToPasteboard(cutURLs, operation: .cut)
        }
    }

    @objc func menuCopySelectedItemPath(_ sender: Any?) {
        mainWindowController?.performAction { vm in
            let paths = vm.activePane.markedOrSelectedPaths()
            guard !paths.isEmpty else {
                NSSound.beep()
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        }
    }

    @objc func paste(_ sender: Any?) {
        syncFileClipboardFromPasteboardIfNeeded()
        mainWindowController?.performAction { $0.pasteToActivePane() }
    }

    @objc func menuPasteAsMove(_ sender: Any?) {
        syncFileClipboardFromPasteboardIfNeeded()
        mainWindowController?.performAction { $0.pasteToActivePaneAsMove() }
    }

    @objc func menuDelete(_ sender: Any?) {
        mainWindowController?.requestDeleteFromActivePane()
    }

    func writeFileURLsToPasteboard(_ urls: [URL], operation: ClipboardOperation) {
        let pasteboard = NSPasteboard.general
        let normalizedURLs = urls.map(\.standardizedFileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects(normalizedURLs as [NSURL])
        pasteboard.setString(
            pasteboardOperationValue(for: operation),
            forType: FileClipboardPasteboard.operationType
        )
        fileClipboardChangeCount = pasteboard.changeCount
    }

    func syncFileClipboardFromPasteboardIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard fileClipboardChangeCount != pasteboard.changeCount else {
            return
        }

        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let pastedURLs = pasteboard.readObjects(forClasses: classes, options: options) as? [URL], !pastedURLs.isEmpty else {
            fileClipboardChangeCount = pasteboard.changeCount
            mainWindowController?.performAction { $0.replaceClipboard(urls: [], operation: .copy) }
            return
        }

        let normalizedURLs = pastedURLs.map(\.standardizedFileURL)
        let operation = pasteboardOperation(from: pasteboard)
        fileClipboardChangeCount = pasteboard.changeCount
        mainWindowController?.performAction { $0.replaceClipboard(urls: normalizedURLs, operation: operation) }
    }

    func pasteboardOperation(from pasteboard: NSPasteboard) -> ClipboardOperation {
        guard let rawValue = pasteboard.string(forType: FileClipboardPasteboard.operationType) else {
            return .copy
        }

        switch rawValue {
        case FileClipboardPasteboard.cutOperationValue:
            return .cut
        default:
            return .copy
        }
    }

    func pasteboardOperationValue(for operation: ClipboardOperation) -> String {
        switch operation {
        case .copy:
            return FileClipboardPasteboard.copyOperationValue
        case .cut:
            return FileClipboardPasteboard.cutOperationValue
        }
    }

    @objc func menuRename(_ sender: Any?) {
        mainWindowController?.performAction { $0.rename() }
    }

    @objc func menuBatchRename(_ sender: Any?) {
        mainWindowController?.presentBatchRename()
    }

    @objc func menuSyncLeftToRight(_ sender: Any?) {
        mainWindowController?.performAction { $0.syncPanesLeftToRight() }
    }

    @objc func menuSyncRightToLeft(_ sender: Any?) {
        mainWindowController?.performAction { $0.syncPanesRightToLeft() }
    }

    @objc func menuSelectAll(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.markAll() }
    }

    @objc func menuShowFilesMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.setDisplayMode(.browser) }
    }

    @objc func menuShowMediaMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.setDisplayMode(.media) }
    }

    @objc func menuToggleLeftPane(_ sender: Any?) {
        mainWindowController?.toggleLeftPane()
    }

    @objc func menuToggleRightPane(_ sender: Any?) {
        mainWindowController?.toggleRightPane()
    }

    @objc func menuToggleSinglePane(_ sender: Any?) {
        mainWindowController?.toggleSinglePane()
    }

    @objc func menuEqualizePaneWidths(_ sender: Any?) {
        mainWindowController?.equalizePaneWidths()
    }

    @objc func menuToggleMediaMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleDisplayMode() }
    }

    @objc func menuToggleRecursive(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleRecursive() }
    }

    @objc func menuToggleHiddenFiles(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleHiddenFiles() }
    }

    @objc func menuRefresh(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.refresh() }
    }

    @objc func menuGoBack(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goBack() }
    }

    @objc func menuGoForward(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goForward() }
    }

    @objc func menuGoToParent(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goToParent() }
    }

    @objc func menuGoToPath(_ sender: Any?) {
        mainWindowController?.presentGoToPathPrompt()
    }

    @objc func menuGoHD(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: URL(fileURLWithPath: "/", isDirectory: true))
        }
    }

    @objc func menuGoHome(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.homeDirectoryURL)
        }
    }

    @objc func menuGoDesktop(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.desktopDirectoryURL)
        }
    }

    @objc func menuGoDocuments(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.documentsDirectoryURL)
        }
    }

    @objc func menuGoDownloads(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.downloadsDirectoryURL)
        }
    }

    @objc func menuGoApplications(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
    }

    @objc func menuSortByName(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortByName() }
    }

    @objc func menuSortBySize(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortBySize() }
    }

    @objc func menuSortByDate(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortByDate() }
    }

    @objc func menuSortBySelectionOrder(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortBySelectionOrder() }
    }

    @objc func menuReverseSortOrder(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.reverseSortOrder() }
    }

    @objc func menuToggleSidebar(_ sender: Any?) {
        mainWindowController?.toggleSidebarPane()
    }

    @objc func menuSwitchPane(_ sender: Any?) {
        mainWindowController?.performAction { $0.switchActivePane() }
    }

    @objc func menuLaunchClaude(_ sender: Any?) {
        mainWindowController?.launchTerminalSession(command: .claude)
    }

    @objc func menuLaunchCodex(_ sender: Any?) {
        mainWindowController?.launchTerminalSession(command: .codex)
    }

    @objc func menuToggleSessionManager(_ sender: Any?) {
        mainWindowController?.toggleSessionManager()
    }

    @MainActor
    @objc func menuShowSettings(_ sender: Any?) {
        presentSettingsWindow()
    }
}
