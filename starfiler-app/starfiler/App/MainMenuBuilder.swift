import AppKit

/// Extracts main menu construction from AppDelegate into a dedicated builder.
/// Menu item actions remain on AppDelegate and are resolved via the responder chain.
final class MainMenuBuilder {
    func build() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.menuShowSettings(_:)), keyEquivalent: ",")
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
        let newFolderItem = fileMenu.addItem(withTitle: "New Folder", action: #selector(AppDelegate.menuCreateDirectory(_:)), keyEquivalent: "n")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        let openItem = fileMenu.addItem(withTitle: "Open", action: #selector(AppDelegate.menuOpenFile(_:)), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        let showInFinderItem = fileMenu.addItem(withTitle: "Show in Finder", action: #selector(AppDelegate.menuRevealInFinder(_:)), keyEquivalent: "f")
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
        let copyItemPathItem = editMenu.addItem(withTitle: "Copy File/Folder Path", action: #selector(AppDelegate.menuCopySelectedItemPath(_:)), keyEquivalent: "c")
        copyItemPathItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        let moveItemHereItem = editMenu.addItem(withTitle: "Move Item Here", action: #selector(AppDelegate.menuPasteAsMove(_:)), keyEquivalent: "v")
        moveItemHereItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Move to Trash", action: #selector(AppDelegate.menuDelete(_:)), keyEquivalent: "\u{08}")
        editMenu.addItem(withTitle: "Rename...", action: #selector(AppDelegate.menuRename(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Batch Rename...", action: #selector(AppDelegate.menuBatchRename(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Sync: Left \u{2192} Right", action: #selector(AppDelegate.menuSyncLeftToRight(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Sync: Right \u{2192} Left", action: #selector(AppDelegate.menuSyncRightToLeft(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(AppDelegate.menuSelectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(AppDelegate.menuToggleSidebar(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command]
        let showFilesModeItem = viewMenu.addItem(withTitle: "Show Files", action: #selector(AppDelegate.menuShowFilesMode(_:)), keyEquivalent: "1")
        showFilesModeItem.keyEquivalentModifierMask = [.command]
        let showMediaModeItem = viewMenu.addItem(withTitle: "Show Media", action: #selector(AppDelegate.menuShowMediaMode(_:)), keyEquivalent: "2")
        showMediaModeItem.keyEquivalentModifierMask = [.command]
        let toggleLeftPaneItem = viewMenu.addItem(withTitle: "Toggle Left Pane", action: #selector(AppDelegate.menuToggleLeftPane(_:)), keyEquivalent: "1")
        toggleLeftPaneItem.keyEquivalentModifierMask = [.control]
        let toggleRightPaneItem = viewMenu.addItem(withTitle: "Toggle Right Pane", action: #selector(AppDelegate.menuToggleRightPane(_:)), keyEquivalent: "2")
        toggleRightPaneItem.keyEquivalentModifierMask = [.control]
        let toggleSinglePaneItem = viewMenu.addItem(withTitle: "Toggle Single Pane", action: #selector(AppDelegate.menuToggleSinglePane(_:)), keyEquivalent: "3")
        toggleSinglePaneItem.keyEquivalentModifierMask = [.control]
        let equalizePaneWidthsItem = viewMenu.addItem(withTitle: "Equalize Pane Widths", action: #selector(AppDelegate.menuEqualizePaneWidths(_:)), keyEquivalent: "4")
        equalizePaneWidthsItem.keyEquivalentModifierMask = [.control]
        let toggleMediaModeItem = viewMenu.addItem(withTitle: "Toggle Media Mode", action: #selector(AppDelegate.menuToggleMediaMode(_:)), keyEquivalent: "0")
        toggleMediaModeItem.keyEquivalentModifierMask = [.control]
        let toggleRecursiveItem = viewMenu.addItem(withTitle: "Toggle Recursive Mode", action: #selector(AppDelegate.menuToggleRecursive(_:)), keyEquivalent: "f")
        toggleRecursiveItem.keyEquivalentModifierMask = [.control, .shift]
        viewMenu.addItem(withTitle: "Toggle Hidden Files", action: #selector(AppDelegate.menuToggleHiddenFiles(_:)), keyEquivalent: ".")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Sort by Name", action: #selector(AppDelegate.menuSortByName(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Sort by Size", action: #selector(AppDelegate.menuSortBySize(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Sort by Date Modified", action: #selector(AppDelegate.menuSortByDate(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Sort by Selection Order", action: #selector(AppDelegate.menuSortBySelectionOrder(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Reverse Sort Order", action: #selector(AppDelegate.menuReverseSortOrder(_:)), keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Refresh", action: #selector(AppDelegate.menuRefresh(_:)), keyEquivalent: "r")
        viewMenuItem.submenu = viewMenu

        // Go menu
        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Back", action: #selector(AppDelegate.menuGoBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "Forward", action: #selector(AppDelegate.menuGoForward(_:)), keyEquivalent: "]")
        goMenu.addItem(withTitle: "Enclosing Folder", action: #selector(AppDelegate.menuGoToParent(_:)), keyEquivalent: "\u{1B}")
        let goToFolderItem = goMenu.addItem(withTitle: "Go to File or Folder...", action: #selector(AppDelegate.menuGoToPath(_:)), keyEquivalent: "g")
        goToFolderItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(NSMenuItem.separator())
        let hdItem = goMenu.addItem(withTitle: "HD", action: #selector(AppDelegate.menuGoHD(_:)), keyEquivalent: "c")
        hdItem.keyEquivalentModifierMask = [.command, .shift]
        let homeItem = goMenu.addItem(withTitle: "Home", action: #selector(AppDelegate.menuGoHome(_:)), keyEquivalent: "h")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        let desktopItem = goMenu.addItem(withTitle: "Desktop", action: #selector(AppDelegate.menuGoDesktop(_:)), keyEquivalent: "d")
        desktopItem.keyEquivalentModifierMask = [.command, .shift]
        let documentsItem = goMenu.addItem(withTitle: "Documents", action: #selector(AppDelegate.menuGoDocuments(_:)), keyEquivalent: "o")
        documentsItem.keyEquivalentModifierMask = [.command, .shift]
        let downloadsItem = goMenu.addItem(withTitle: "Downloads", action: #selector(AppDelegate.menuGoDownloads(_:)), keyEquivalent: "l")
        downloadsItem.keyEquivalentModifierMask = [.command, .option]
        let applicationsItem = goMenu.addItem(withTitle: "Applications", action: #selector(AppDelegate.menuGoApplications(_:)), keyEquivalent: "a")
        applicationsItem.keyEquivalentModifierMask = [.command, .shift]
        goMenuItem.submenu = goMenu

        // Terminal menu
        let terminalMenuItem = NSMenuItem()
        mainMenu.addItem(terminalMenuItem)
        let terminalMenu = NSMenu(title: "Terminal")
        let sessionManagerItem = terminalMenu.addItem(withTitle: "Session Manager", action: #selector(AppDelegate.menuToggleSessionManager(_:)), keyEquivalent: "`")
        sessionManagerItem.keyEquivalentModifierMask = [.control]
        terminalMenu.addItem(NSMenuItem.separator())
        terminalMenu.addItem(withTitle: "Launch Claude Code", action: #selector(AppDelegate.menuLaunchClaude(_:)), keyEquivalent: "")
        terminalMenu.addItem(withTitle: "Launch Codex CLI", action: #selector(AppDelegate.menuLaunchCodex(_:)), keyEquivalent: "")
        terminalMenuItem.submenu = terminalMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Switch Pane", action: #selector(AppDelegate.menuSwitchPane(_:)), keyEquivalent: "\t")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help menu (enables menu item search via AppKit spotlight for help)
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        return mainMenu
    }
}
