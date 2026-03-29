import AppKit

private struct LaunchOptions {
    let isUITest: Bool
    let sandboxRoot: URL?
    let configRoot: URL?
    let disableAnimations: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        isUITest = arguments.contains("--uitest")
        sandboxRoot = Self.pathValue(for: "--sandbox-root", arguments: arguments).map {
            URL(fileURLWithPath: UserPaths.expandHomeVariables(in: $0), isDirectory: true).standardizedFileURL
        }
        configRoot = Self.pathValue(for: "--config-root", arguments: arguments).map {
            URL(fileURLWithPath: UserPaths.expandHomeVariables(in: $0), isDirectory: true).standardizedFileURL
        }
        disableAnimations = arguments.contains("--disable-animations")
    }

    private static func pathValue(for option: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

private actor UITestSecurityScopedBookmarkService: SecurityScopedBookmarkProviding {
    func loadBookmarks() async throws {}

    func hasBookmarks() async throws -> Bool { true }

    func saveBookmark(for url: URL) async throws {}

    func resolveBookmark(for url: URL) async throws -> URL? { url.standardizedFileURL }

    func startAccessing(_ url: URL) async throws {}

    func stopAccessing(_ url: URL) async {}
}

@main
enum StarfilerMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum FileClipboardPasteboard {
        static let operationType = NSPasteboard.PasteboardType("com.nilone.starfiler.clipboard-operation")
        static let copyOperationValue = "copy"
        static let cutOperationValue = "cut"
    }

    private let launchOptions = LaunchOptions()
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var syncStatusBarController: SyncStatusBarController?
    private var networkSyncViewModel: NetworkSyncViewModel?
    private var launchTask: Task<Void, Never>?
    private var pendingOpenDirectories: [URL] = []
    private var fileClipboardChangeCount: Int?
    private let securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared
    private lazy var activeSecurityScopedBookmarkService: any SecurityScopedBookmarkProviding = {
        launchOptions.isUITest ? UITestSecurityScopedBookmarkService() : securityScopedBookmarkService
    }()
    private lazy var sharedConfigManager: ConfigManager = {
        makeConfigManagerOverride() ?? ConfigManager()
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        launchTask = Task { @MainActor in
            await launchMainWindow()
            launchTask = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(networkSyncViewModel?.isEnabled ?? false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkSyncViewModel?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueOpenDirectories(from: urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        enqueueOpenDirectories(from: urls)
        sender.reply(toOpenOrPrint: .success)
    }

    @MainActor
    private func launchMainWindow() async {
        do {
            try await activeSecurityScopedBookmarkService.loadBookmarks()

            let hasBookmarks = try await activeSecurityScopedBookmarkService.hasBookmarks()
            if !hasBookmarks, !launchOptions.isUITest {
                guard let selectedStartupDisk = requestStartupDiskAccess() else {
                    NSApp.terminate(nil)
                    return
                }
                try await activeSecurityScopedBookmarkService.saveBookmark(for: selectedStartupDisk)
            }

            let initialDirectory = launchOptions.sandboxRoot ?? UserPaths.homeDirectoryURL
            let controller = MainWindowController(
                securityScopedBookmarkService: activeSecurityScopedBookmarkService,
                initialDirectory: initialDirectory,
                configManager: sharedConfigManager,
                disableAnimations: launchOptions.disableAnimations,
                persistLaunchMetadata: !launchOptions.isUITest
            )
            mainWindowController = controller
            controller.showWindow(self)
            configureNetworkSyncIfNeeded()
            processPendingOpenDirectories()

            NSApp.activate(ignoringOtherApps: true)
        } catch {
            presentStartupError(error)
        }
    }

    private func makeConfigManagerOverride() -> ConfigManager? {
        guard let configRoot = launchOptions.configRoot else {
            return nil
        }
        return ConfigManager(configDirectory: configRoot)
    }

    @MainActor
    private func requestStartupDiskAccess() -> URL? {
        let startupDiskURL = URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL
        let panel = NSOpenPanel()
        panel.directoryURL = startupDiskURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Grant Access"
        panel.message = "starfiler requires directory access. Select the startup disk (Macintosh HD) to reduce future permission prompts."

        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            return nil
        }

        return selectedURL
    }

    @MainActor
    private func presentStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Failed to initialize sandbox access."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func enqueueOpenDirectories(from urls: [URL]) {
        let directories = urls.compactMap(resolveDirectoryToOpen(from:))
        guard !directories.isEmpty else {
            return
        }

        pendingOpenDirectories.append(contentsOf: directories)
        Task { @MainActor in
            processPendingOpenDirectories()
        }
    }

    private func resolveDirectoryToOpen(from url: URL) -> URL? {
        let fileURL = url.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return fileURL
        }

        return fileURL.deletingLastPathComponent().standardizedFileURL
    }

    @MainActor
    private func processPendingOpenDirectories() {
        guard let mainWindowController, !pendingOpenDirectories.isEmpty else {
            return
        }

        let targetDirectory = pendingOpenDirectories.removeLast()
        pendingOpenDirectories.removeAll(keepingCapacity: true)

        mainWindowController.performAction {
            $0.activePane.navigate(to: targetDirectory)
        }
    }

    private func buildMainMenu() {
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

    @objc private func menuCreateDirectory(_ sender: Any?) {
        mainWindowController?.performAction { $0.createDirectory() }
    }

    @objc private func menuOpenFile(_ sender: Any?) {
        mainWindowController?.openSelectedItemInActivePane()
    }

    @objc private func menuRevealInFinder(_ sender: Any?) {
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

    @objc private func menuCopySelectedItemPath(_ sender: Any?) {
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

    @objc private func menuPasteAsMove(_ sender: Any?) {
        syncFileClipboardFromPasteboardIfNeeded()
        mainWindowController?.performAction { $0.pasteToActivePaneAsMove() }
    }

    @objc private func menuDelete(_ sender: Any?) {
        mainWindowController?.requestDeleteFromActivePane()
    }

    private func writeFileURLsToPasteboard(_ urls: [URL], operation: ClipboardOperation) {
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

    private func syncFileClipboardFromPasteboardIfNeeded() {
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

    private func pasteboardOperation(from pasteboard: NSPasteboard) -> ClipboardOperation {
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

    private func pasteboardOperationValue(for operation: ClipboardOperation) -> String {
        switch operation {
        case .copy:
            return FileClipboardPasteboard.copyOperationValue
        case .cut:
            return FileClipboardPasteboard.cutOperationValue
        }
    }

    @objc private func menuRename(_ sender: Any?) {
        mainWindowController?.performAction { $0.rename() }
    }

    @objc private func menuBatchRename(_ sender: Any?) {
        mainWindowController?.presentBatchRename()
    }

    @objc private func menuSyncLeftToRight(_ sender: Any?) {
        mainWindowController?.performAction { $0.syncPanesLeftToRight() }
    }

    @objc private func menuSyncRightToLeft(_ sender: Any?) {
        mainWindowController?.performAction { $0.syncPanesRightToLeft() }
    }

    @objc private func menuSelectAll(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.markAll() }
    }

    @objc private func menuShowFilesMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.setDisplayMode(.browser) }
    }

    @objc private func menuShowMediaMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.setDisplayMode(.media) }
    }

    @objc private func menuToggleLeftPane(_ sender: Any?) {
        mainWindowController?.toggleLeftPane()
    }

    @objc private func menuToggleRightPane(_ sender: Any?) {
        mainWindowController?.toggleRightPane()
    }

    @objc private func menuToggleSinglePane(_ sender: Any?) {
        mainWindowController?.toggleSinglePane()
    }

    @objc private func menuEqualizePaneWidths(_ sender: Any?) {
        mainWindowController?.equalizePaneWidths()
    }

    @objc private func menuToggleMediaMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleDisplayMode() }
    }

    @objc private func menuToggleRecursive(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleRecursive() }
    }

    @objc private func menuToggleHiddenFiles(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleHiddenFiles() }
    }

    @objc private func menuRefresh(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.refresh() }
    }

    @objc private func menuGoBack(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goBack() }
    }

    @objc private func menuGoForward(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goForward() }
    }

    @objc private func menuGoToParent(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goToParent() }
    }

    @objc private func menuGoToPath(_ sender: Any?) {
        mainWindowController?.presentGoToPathPrompt()
    }

    @objc private func menuGoHD(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: URL(fileURLWithPath: "/", isDirectory: true))
        }
    }

    @objc private func menuGoHome(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.homeDirectoryURL)
        }
    }

    @objc private func menuGoDesktop(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.desktopDirectoryURL)
        }
    }

    @objc private func menuGoDocuments(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.documentsDirectoryURL)
        }
    }

    @objc private func menuGoDownloads(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.downloadsDirectoryURL)
        }
    }

    @objc private func menuGoApplications(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
    }

    @objc private func menuSortByName(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortByName() }
    }

    @objc private func menuSortBySize(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortBySize() }
    }

    @objc private func menuSortByDate(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortByDate() }
    }

    @objc private func menuSortBySelectionOrder(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortBySelectionOrder() }
    }

    @objc private func menuReverseSortOrder(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.reverseSortOrder() }
    }

    @objc private func menuToggleSidebar(_ sender: Any?) {
        mainWindowController?.toggleSidebarPane()
    }

    @objc private func menuSwitchPane(_ sender: Any?) {
        mainWindowController?.performAction { $0.switchActivePane() }
    }

    @objc private func menuLaunchClaude(_ sender: Any?) {
        mainWindowController?.launchTerminalSession(command: .claude)
    }

    @objc private func menuLaunchCodex(_ sender: Any?) {
        mainWindowController?.launchTerminalSession(command: .codex)
    }

    @objc private func menuToggleSessionManager(_ sender: Any?) {
        mainWindowController?.toggleSessionManager()
    }

    @MainActor
    @objc private func menuShowSettings(_ sender: Any?) {
        presentSettingsWindow()
    }

    @MainActor
    private func configureNetworkSyncIfNeeded() {
        guard !isRunningTests else {
            return
        }
        guard networkSyncViewModel == nil else {
            syncStatusBarController?.refresh()
            return
        }

        let viewModel = NetworkSyncViewModel(
            configManager: sharedConfigManager,
            securityScopedBookmarkService: activeSecurityScopedBookmarkService
        )
        let statusBarController = SyncStatusBarController(viewModel: viewModel)
        statusBarController.onOpenSettingsRequested = { [weak self] in
            self?.presentSettingsWindow()
        }

        self.networkSyncViewModel = viewModel
        self.syncStatusBarController = statusBarController
    }

    @MainActor
    private func presentSettingsWindow() {
        if let existing = settingsWindowController {
            existing.showWindow(self)
            return
        }

        let currentTheme = mainWindowController?.currentFilerTheme ?? .system
        let currentTransparentBackground = mainWindowController?.isTransparentBackgroundEnabled ?? false
        let currentTransparentBackgroundOpacity = mainWindowController?.currentTransparentBackgroundOpacity ?? 0.7
        let currentActionFeedbackEnabled = mainWindowController?.isActionFeedbackEnabled ?? true
        let currentSpotlightSearchScope = mainWindowController?.currentSpotlightSearchScope ?? .currentDirectory
        let currentFileIconSize = mainWindowController?.currentFileIconSize ?? 16
        let currentSidebarFavoritesVisible = mainWindowController?.isSidebarFavoritesVisible ?? true
        let currentSidebarRecentItemsLimit = mainWindowController?.currentSidebarRecentItemsLimit ?? 10
        let currentStarEffectsEnabled = mainWindowController?.isStarEffectsEnabled ?? true
        let currentAnimationEffectSettings = mainWindowController?.currentAnimationEffectSettings ?? .allEnabled
        let currentShortcutGuideEnabled = mainWindowController?.isShortcutGuideEnabled ?? false

        let appearanceVC = AppearanceSettingsViewController(
            selectedTheme: currentTheme,
            isTransparentBackgroundEnabled: currentTransparentBackground,
            transparentBackgroundOpacity: currentTransparentBackgroundOpacity,
            isActionFeedbackEnabled: currentActionFeedbackEnabled,
            selectedSpotlightSearchScope: currentSpotlightSearchScope,
            initialFileIconSize: currentFileIconSize,
            initialSidebarFavoritesVisible: currentSidebarFavoritesVisible,
            initialSidebarRecentItemsLimit: currentSidebarRecentItemsLimit,
            initialStarEffectsEnabled: currentStarEffectsEnabled,
            initialAnimationEffectSettings: currentAnimationEffectSettings,
            initialShortcutGuideEnabled: currentShortcutGuideEnabled
        )
        appearanceVC.onThemeChanged = { [weak self] theme in
            self?.mainWindowController?.updateFilerTheme(theme)
        }
        appearanceVC.onTransparentBackgroundChanged = { [weak self] enabled in
            self?.mainWindowController?.updateTransparentBackground(enabled)
        }
        appearanceVC.onTransparentBackgroundOpacityChanged = { [weak self] opacity in
            self?.mainWindowController?.updateTransparentBackgroundOpacity(opacity)
        }
        appearanceVC.onActionFeedbackChanged = { [weak self] enabled in
            self?.mainWindowController?.updateActionFeedbackEnabled(enabled)
        }
        appearanceVC.onSpotlightSearchScopeChanged = { [weak self] scope in
            self?.mainWindowController?.updateSpotlightSearchScope(scope)
        }
        appearanceVC.onFileIconSizeChanged = { [weak self] size in
            self?.mainWindowController?.updateFileIconSize(size)
        }
        appearanceVC.onSidebarFavoritesVisibilityChanged = { [weak self] visible in
            self?.mainWindowController?.updateSidebarFavoritesVisible(visible)
        }
        appearanceVC.onSidebarRecentItemsLimitChanged = { [weak self] limit in
            self?.mainWindowController?.updateSidebarRecentItemsLimit(limit)
        }
        appearanceVC.onStarEffectsChanged = { [weak self] enabled in
            self?.mainWindowController?.updateStarEffectsEnabled(enabled)
        }
        appearanceVC.onAnimationEffectSettingsChanged = { [weak self] settings in
            self?.mainWindowController?.updateAnimationEffectSettings(settings)
        }
        appearanceVC.onShortcutGuideChanged = { [weak self] enabled in
            self?.mainWindowController?.updateShortcutGuideEnabled(enabled)
        }
        appearanceVC.onShootingStarTestRequested = { [weak self] in
            self?.playShootingStarTest()
        }

        let keybindingsVC = KeybindingsViewController()
        keybindingsVC.onKeybindingsChanged = { [weak self] in
            self?.mainWindowController?.reloadKeybindings()
        }

        let bookmarksVC = BookmarksSettingsViewController(
            securityScopedBookmarkService: activeSecurityScopedBookmarkService
        )
        bookmarksVC.onBookmarksChanged = { [weak self] in
            self?.mainWindowController?.reloadBookmarksConfig()
        }

        let advancedVC = AdvancedSettingsViewController()
        advancedVC.onConfigDirectoryChanged = {
            let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            try? process.run()
            NSApp.terminate(nil)
        }

        let resolvedNetworkSyncViewModel: NetworkSyncViewModel
        if let existing = networkSyncViewModel {
            resolvedNetworkSyncViewModel = existing
        } else {
            let created = NetworkSyncViewModel(
                configManager: sharedConfigManager,
                securityScopedBookmarkService: activeSecurityScopedBookmarkService
            )
            networkSyncViewModel = created
            resolvedNetworkSyncViewModel = created
        }

        let networkSyncVC = NetworkSyncSettingsViewController(viewModel: resolvedNetworkSyncViewModel)

        let controller = SettingsWindowController(
            appearanceVC: appearanceVC,
            keybindingsVC: keybindingsVC,
            bookmarksVC: bookmarksVC,
            networkSyncVC: networkSyncVC,
            advancedVC: advancedVC
        )
        controller.showWindow(self)
        settingsWindowController = controller
    }

    private func playShootingStarTest() {
        guard let mainWindowController else {
            NSSound.beep()
            return
        }

        let visibleWindows = NSApp.windows.filter(\.isVisible)
        if visibleWindows.isEmpty {
            mainWindowController.playShootingStarTestEffect()
            return
        }

        for window in visibleWindows {
            mainWindowController.playShootingStarTestEffect(in: window)
        }
    }
}
