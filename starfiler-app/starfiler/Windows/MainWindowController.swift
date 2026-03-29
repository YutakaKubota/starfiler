import AppKit
import CryptoKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    enum LaunchMetadata {
        static let observedConfigSnapshotsKey = "MainWindowController.observedConfigSnapshots"
    }

    enum ObservedConfigFile: String, CaseIterable {
        case appConfig
        case bookmarks
        case keybindings
    }

    struct ConfigFileSnapshot: Codable, Equatable {
        let exists: Bool
        let modificationDate: Date?
        let fileSize: UInt64?
        let contentDigest: String?
    }

    let mainViewModel: MainViewModel
    let configManager: ConfigManager
    let fileManager: FileManager
    let primaryConfigMonitor: any DirectoryMonitoring
    let keybindingsConfigMonitor: any DirectoryMonitoring
    let keybindingsConfigURL: URL?
    var filerTheme: FilerTheme
    var transparentBackground: Bool
    var transparentBackgroundOpacity: CGFloat
    var actionFeedbackEnabled: Bool
    var spotlightSearchScope: SpotlightSearchScope
    var fileIconSize: CGFloat
    var leftPaneFileIconSize: CGFloat
    var rightPaneFileIconSize: CGFloat
    var sidebarFavoritesVisible: Bool
    var sidebarRecentItemsLimit: Int
    var sidebarWidth: CGFloat
    private var leftPaneVisible: Bool
    private var rightPaneVisible: Bool
    var starEffectsEnabled: Bool
    var animationEffectSettings: AnimationEffectSettings
    var shortcutGuideEnabled: Bool
    lazy var mainSplitViewController = MainSplitViewController(
        viewModel: mainViewModel,
        configManager: configManager,
        actionFeedbackEnabled: actionFeedbackEnabled,
        leftPaneFileIconSize: leftPaneFileIconSize,
        rightPaneFileIconSize: rightPaneFileIconSize,
        initialSidebarWidth: sidebarWidth,
        initialLeftPaneVisible: leftPaneVisible,
        initialRightPaneVisible: rightPaneVisible
    )
    lazy var mainContainerViewController = MainContainerViewController(
        mainSplitViewController: mainSplitViewController
    )
    private var sessionManagerWindowController: TerminalSessionManagerWindowController?
    var sessionManagerViewModel: TerminalSessionManagerViewModel?
    private var sessionWindows: [UUID: TerminalSessionWindowController] = [:]
    private var persistTimer: Timer?
    private let appUndoManager = UndoManager()
    private var footerBaseStatusText: String
    private var footerItemCount: Int
    private var footerMarkedCount: Int
    private var footerContextText: String?
    var observedConfigSnapshots: [ObservedConfigFile: ConfigFileSnapshot] = [:]
    private let disableAnimations: Bool
    let persistLaunchMetadata: Bool
    var isConstrainingWindowFrame = false
    var hasPendingWindowFrameConstraint = false
    enum ExternalSessionImport {
        static let maxSessions = 200
        static let codexRelativePath = ".codex/sessions"
        static let claudeRelativePath = ".claude/projects"
        static let maxReadBytesPerFile = 96 * 1024
        static let codexScanMultiplier = 6
        static let claudeScanMultiplier = 3
    }

    init(
        fileSystemService: FileSystemProviding = FileSystemService(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared,
        initialDirectory: URL = UserPaths.homeDirectoryURL,
        configManager: ConfigManager? = nil,
        visitHistoryService: (any VisitHistoryProviding)? = nil,
        pinnedItemsService: (any PinnedItemsProviding)? = nil,
        terminalSessionService: (any TerminalSessionProviding)? = nil,
        fileManager: FileManager = .default,
        primaryConfigMonitor: any DirectoryMonitoring = DirectoryMonitor(),
        keybindingsConfigMonitor: any DirectoryMonitoring = DirectoryMonitor(),
        disableAnimations: Bool = false,
        persistLaunchMetadata: Bool = true
    ) {
        self.fileManager = fileManager
        self.primaryConfigMonitor = primaryConfigMonitor
        self.keybindingsConfigMonitor = keybindingsConfigMonitor
        self.keybindingsConfigURL = KeybindingManager.defaultUserConfigURL(fileManager: fileManager)
        self.disableAnimations = disableAnimations
        self.persistLaunchMetadata = persistLaunchMetadata
        let previousConfigSnapshots = persistLaunchMetadata ? Self.loadPersistedObservedConfigSnapshots() : [:]

        let resolvedConfigManager = configManager ?? ConfigManager()
        self.configManager = resolvedConfigManager

        Self.initializeDefaultBookmarksIfNeeded(configManager: resolvedConfigManager)

        let appConfig = resolvedConfigManager.loadAppConfig()
        let bookmarksConfig = resolvedConfigManager.loadBookmarksConfig()
        self.filerTheme = appConfig.filerTheme
        self.transparentBackground = appConfig.transparentBackground
        self.transparentBackgroundOpacity = min(max(CGFloat(appConfig.transparentBackgroundOpacity), 0.15), 1.0)
        self.actionFeedbackEnabled = appConfig.actionFeedbackEnabled
        self.spotlightSearchScope = appConfig.spotlightSearchScope
        self.fileIconSize = CGFloat(appConfig.fileIconSize)
        self.leftPaneFileIconSize = CGFloat(appConfig.leftPaneFileIconSize)
        self.rightPaneFileIconSize = CGFloat(appConfig.rightPaneFileIconSize)
        self.sidebarFavoritesVisible = appConfig.sidebarFavoritesVisible
        self.sidebarRecentItemsLimit = appConfig.sidebarRecentItemsLimit
        self.sidebarWidth = Self.initialSidebarWidth(appConfig: appConfig, bookmarksConfig: bookmarksConfig)
        self.leftPaneVisible = appConfig.leftPaneVisible
        self.rightPaneVisible = appConfig.rightPaneVisible
        self.starEffectsEnabled = appConfig.starEffectsEnabled
        self.animationEffectSettings = appConfig.animationEffectSettings
        self.shortcutGuideEnabled = appConfig.shortcutGuideEnabled
        let fallbackDirectory = initialDirectory.standardizedFileURL
        let leftDirectory = Self.resolveDirectory(path: appConfig.lastLeftPanePath, fallback: fallbackDirectory)
        let rightDirectory = Self.resolveDirectory(path: appConfig.lastRightPanePath, fallback: leftDirectory)
        let leftNavigationHistory = Self.resolveNavigationHistory(
            backPaths: appConfig.leftPaneBackHistoryPaths,
            forwardPaths: appConfig.leftPaneForwardHistoryPaths
        )
        let rightNavigationHistory = Self.resolveNavigationHistory(
            backPaths: appConfig.rightPaneBackHistoryPaths,
            forwardPaths: appConfig.rightPaneForwardHistoryPaths
        )

        let resolvedVisitHistoryService = visitHistoryService ?? VisitHistoryService(configManager: resolvedConfigManager)
        let resolvedPinnedItemsService = pinnedItemsService ?? PinnedItemsService(configManager: resolvedConfigManager)
        let resolvedTerminalSessionService = terminalSessionService ?? TerminalSessionService()

        self.mainViewModel = MainViewModel(
            fileSystemService: fileSystemService,
            securityScopedBookmarkService: securityScopedBookmarkService,
            visitHistoryService: resolvedVisitHistoryService,
            pinnedItemsService: resolvedPinnedItemsService,
            terminalSessionService: resolvedTerminalSessionService,
            initialShowHiddenFiles: appConfig.showHiddenFiles,
            initialSortColumn: appConfig.defaultSortColumn,
            initialSortAscending: appConfig.defaultSortAscending,
            initialPreviewVisible: false,
            initialSidebarVisible: appConfig.sidebarVisible,
            initialSpotlightSearchScope: appConfig.spotlightSearchScope,
            initialLeftPaneDisplayMode: appConfig.leftPaneDisplayMode,
            initialRightPaneDisplayMode: appConfig.rightPaneDisplayMode,
            initialLeftPaneMediaRecursiveEnabled: appConfig.leftPaneMediaRecursiveEnabled,
            initialRightPaneMediaRecursiveEnabled: appConfig.rightPaneMediaRecursiveEnabled,
            initialLeftDirectory: leftDirectory,
            initialRightDirectory: rightDirectory,
            initialLeftNavigationHistory: leftNavigationHistory,
            initialRightNavigationHistory: rightNavigationHistory
        )

        if appConfig.lastActivePane == "right" {
            self.mainViewModel.setActivePane(.right)
        }
        let activePane = self.mainViewModel.activePane
        self.footerBaseStatusText = activePane.paneState.currentDirectory.path
        self.footerItemCount = activePane.directoryContents.displayedItems.count
        self.footerMarkedCount = activePane.markedCount
        self.footerContextText = nil
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)
        mainViewModel.undoManager = appUndoManager
        configureWindow()
        applyConfigChangesSinceLastLaunch(previousSnapshots: previousConfigSnapshots)
        if persistLaunchMetadata {
            Self.savePersistedObservedConfigSnapshots(currentObservedConfigSnapshots())
        }
        startConfigMonitoring()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        primaryConfigMonitor.stopMonitoring()
        keybindingsConfigMonitor.stopMonitoring()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if let window {
            attachWindowControlButtons(to: window)
        }
        mainSplitViewController.focusActivePane()

        if !disableAnimations, starEffectsEnabled, animationEffectSettings.windowIntroAnimation, let contentView = window?.contentView {
            contentView.wantsLayer = true
            contentView.alphaValue = 0

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                guard let self, self.starEffectsEnabled, let layer = contentView.layer else { return }
                let palette = self.filerTheme.palette
                let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.maxY - 20)
                StarSparkleAnimator.singleStar(in: layer, at: center, color: palette.starGlowColor, size: 14)
            })

            if let layer = contentView.layer {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.97
                scale.toValue = 1.0
                scale.duration = 0.25
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(scale, forKey: "introScale")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        persistAppConfig()
        persistSessions()
        persistTimer?.invalidate()
        persistTimer = nil
        for wc in sessionWindows.values {
            wc.window?.close()
        }
        sessionWindows.removeAll()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        guard let window else {
            return
        }
        attachWindowControlButtons(to: window)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window else {
            return
        }
        attachWindowControlButtons(to: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window else {
            return
        }
        attachWindowControlButtons(to: window)
        scheduleWindowFrameConstraintIfNeeded(for: window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else {
            return
        }
        scheduleWindowFrameConstraintIfNeeded(for: window)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else {
            return
        }
        scheduleWindowFrameConstraintIfNeeded(for: window)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window else {
            return
        }
        scheduleWindowFrameConstraintIfNeeded(for: window)
    }

    func performAction(_ block: (MainViewModel) -> Void) {
        block(mainViewModel)
    }

    var currentFilerTheme: FilerTheme {
        filerTheme
    }

    var isTransparentBackgroundEnabled: Bool {
        transparentBackground
    }

    var currentTransparentBackgroundOpacity: CGFloat {
        transparentBackgroundOpacity
    }

    var isActionFeedbackEnabled: Bool {
        actionFeedbackEnabled
    }

    var currentSpotlightSearchScope: SpotlightSearchScope {
        spotlightSearchScope
    }

    var currentFileIconSize: CGFloat {
        fileIconSize
    }

    var currentSidebarRecentItemsLimit: Int {
        sidebarRecentItemsLimit
    }

    var isSidebarFavoritesVisible: Bool {
        sidebarFavoritesVisible
    }

    var isStarEffectsEnabled: Bool {
        starEffectsEnabled
    }

    var currentAnimationEffectSettings: AnimationEffectSettings {
        animationEffectSettings
    }

    var isShortcutGuideEnabled: Bool {
        shortcutGuideEnabled
    }

    func playShootingStarTestEffect(in targetWindow: NSWindow? = nil) {
        let destinationWindow = targetWindow ?? window
        guard let contentView = destinationWindow?.contentView else {
            return
        }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else {
            return
        }

        let palette = filerTheme.palette
        StarSparkleAnimator.shootingStar(
            in: layer,
            accentColor: palette.starAccentColor,
            glowColor: palette.starGlowColor
        )
    }

    func updateFilerTheme(_ theme: FilerTheme) {
        guard filerTheme != theme else {
            return
        }

        filerTheme = theme
        applyCurrentAppearance()
        persistAppConfig()
    }

    func updateTransparentBackground(_ enabled: Bool) {
        guard transparentBackground != enabled else {
            return
        }

        transparentBackground = enabled
        applyCurrentAppearance()
        persistAppConfig()
    }

    func updateTransparentBackgroundOpacity(_ opacity: CGFloat) {
        let clampedOpacity = min(max(opacity, 0.15), 1.0)
        guard abs(transparentBackgroundOpacity - clampedOpacity) > 0.001 else {
            return
        }

        transparentBackgroundOpacity = clampedOpacity
        applyCurrentAppearance()
        persistAppConfig()
    }

    func updateActionFeedbackEnabled(_ enabled: Bool) {
        guard actionFeedbackEnabled != enabled else {
            return
        }

        actionFeedbackEnabled = enabled
        mainSplitViewController.setActionFeedbackEnabled(enabled)
        persistAppConfig()
    }

    func updateSpotlightSearchScope(_ scope: SpotlightSearchScope) {
        guard spotlightSearchScope != scope else {
            return
        }

        spotlightSearchScope = scope
        mainViewModel.setSpotlightSearchScope(scope)
        mainSplitViewController.setSpotlightSearchScope(scope)
        persistAppConfig()
    }

    func updateFileIconSize(_ size: CGFloat) {
        let clamped = min(max(size, 12), 40)
        guard abs(fileIconSize - clamped) > .ulpOfOne else {
            return
        }

        fileIconSize = clamped
        leftPaneFileIconSize = clamped
        rightPaneFileIconSize = clamped
        mainSplitViewController.setFileIconSize(clamped)
        persistAppConfig()
    }

    private func updatePaneFileIconSize(_ size: CGFloat, for side: PaneSide) {
        let clamped = min(max(size, 12), 40)
        switch side {
        case .left:
            guard abs(leftPaneFileIconSize - clamped) > .ulpOfOne else {
                return
            }
            leftPaneFileIconSize = clamped
        case .right:
            guard abs(rightPaneFileIconSize - clamped) > .ulpOfOne else {
                return
            }
            rightPaneFileIconSize = clamped
        }
        persistAppConfig()
    }

    func updateSidebarRecentItemsLimit(_ limit: Int) {
        let clampedLimit = min(
            max(limit, AppConfig.sidebarRecentItemsLimitRange.lowerBound),
            AppConfig.sidebarRecentItemsLimitRange.upperBound
        )
        guard sidebarRecentItemsLimit != clampedLimit else {
            return
        }

        sidebarRecentItemsLimit = clampedLimit
        persistAppConfig()
        mainSplitViewController.reloadSidebarSections()
    }

    func updateSidebarFavoritesVisible(_ visible: Bool) {
        guard sidebarFavoritesVisible != visible else {
            return
        }

        sidebarFavoritesVisible = visible
        persistAppConfig()
        mainSplitViewController.reloadSidebarSections()
    }

    func updateStarEffectsEnabled(_ enabled: Bool) {
        guard starEffectsEnabled != enabled else {
            return
        }

        starEffectsEnabled = enabled
        mainSplitViewController.setStarEffectsEnabled(enabled)
        mainContainerViewController.setStatusBarStarEffectsEnabled(enabled)
        persistAppConfig()
    }

    func updateAnimationEffectSettings(_ settings: AnimationEffectSettings) {
        guard animationEffectSettings != settings else {
            return
        }

        animationEffectSettings = settings
        mainSplitViewController.setAnimationEffectSettings(settings)
        mainContainerViewController.setStatusBarAnimationEffectSettings(settings)
        persistAppConfig()
    }

    func updateShortcutGuideEnabled(_ enabled: Bool) {
        guard shortcutGuideEnabled != enabled else {
            return
        }

        shortcutGuideEnabled = enabled
        mainSplitViewController.setShortcutGuideEnabled(enabled)
        persistAppConfig()
    }

    func presentBatchRename() {
        mainSplitViewController.presentBatchRenameWindow()
    }

    func togglePreviewPane() {
        mainSplitViewController.togglePreviewPane()
    }

    func toggleSidebarPane() {
        mainSplitViewController.toggleSidebarPane()
    }

    func toggleLeftPane() {
        mainSplitViewController.toggleLeftPane()
    }

    func toggleRightPane() {
        mainSplitViewController.toggleRightPane()
    }

    func toggleSinglePane() {
        mainSplitViewController.toggleSinglePane()
    }

    func equalizePaneWidths() {
        mainSplitViewController.equalizePaneWidths()
    }

    func toggleSessionManager() {
        if let existing = sessionManagerWindowController, existing.window?.isVisible == true {
            existing.window?.close()
        } else {
            showSessionManager()
        }
    }

    func openSelectedItemInActivePane() {
        mainSplitViewController.openSelectedItemInActivePane()
    }

    func showSessionManager() {
        if let existing = sessionManagerWindowController {
            existing.showWindow(self)
            sessionManagerViewModel?.reloadSessions()
            return
        }

        let service = mainViewModel.terminalSessionListViewModel
        let managerVM = TerminalSessionManagerViewModel(service: service.service)
        self.sessionManagerViewModel = managerVM

        let managerVC = TerminalSessionManagerViewController(viewModel: managerVM, listViewModel: mainViewModel.terminalSessionListViewModel)
        managerVC.onOpenSession = { [weak self] id in
            self?.openSessionWindow(id: id)
        }
        managerVC.onCreateSession = { [weak self] command in
            self?.launchTerminalSession(command: command)
        }
        managerVC.onCloseSession = { [weak self] id in
            self?.closeSessionWindow(id: id)
        }

        let windowController = TerminalSessionManagerWindowController(managerVC: managerVC)
        self.sessionManagerWindowController = windowController
        windowController.showWindow(self)
        managerVM.reloadSessions()
    }

    func openSessionWindow(id: UUID) {
        if let existing = sessionWindows[id] {
            existing.showWindow(self)
            return
        }

        guard let session = mainViewModel.terminalSessionListViewModel.sessions.first(where: { $0.id == id }) else { return }

        let sessionVM = TerminalSessionViewModel(sessionId: session.id)
        sessionVM.onStatusChanged = { [weak self] status in
            self?.mainViewModel.terminalSessionListViewModel.updateSessionStatus(id: session.id, status: status)
            self?.sessionManagerViewModel?.reloadSessions()
        }

        let contentVC = TerminalContentViewController(sessionId: session.id, sessionViewModel: sessionVM)
        contentVC.onProcessExited = { [weak self] id, exitCode in
            self?.mainViewModel.terminalSessionListViewModel.updateSessionExitCode(id: id, exitCode: exitCode)
            self?.sessionManagerViewModel?.reloadSessions()
        }
        contentVC.onOutputReceived = { [weak self] id, text in
            Task {
                await self?.mainViewModel.terminalSessionListViewModel.service.appendOutput(id: id, text: text)
            }
        }

        let windowController = TerminalSessionWindowController(sessionId: session.id, terminalContentVC: contentVC)
        windowController.updateTitle(session.title)
        windowController.onWindowClosed = { [weak self] id in
            self?.sessionWindows.removeValue(forKey: id)
        }
        sessionWindows[session.id] = windowController
        windowController.showWindow(self)

        if session.status == .stopped || session.status == .completed || session.status == .error {
            contentVC.launchProcess(command: session.command, workingDirectory: session.workingDirectory)
        } else {
            contentVC.launchProcess(command: session.command, workingDirectory: session.workingDirectory)
        }
    }

    private func closeSessionWindow(id: UUID) {
        if let wc = sessionWindows[id] {
            wc.window?.close()
            sessionWindows.removeValue(forKey: id)
        }
        mainViewModel.terminalSessionListViewModel.removeSession(id: id)
        sessionManagerViewModel?.reloadSessions()
    }

    private func startSessionPersistTimer() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.persistSessions()
            }
        }
    }

    private func persistSessions() {
        Task {
            let data = await mainViewModel.terminalSessionListViewModel.service.allSessionsWithLogs()
            let config = TerminalSessionsConfig(sessions: data.sessions, logs: data.logs)
            try? configManager.saveTerminalSessionsConfig(config)
        }
    }

    func reloadBookmarksConfig() {
        mainSplitViewController.reloadBookmarksConfig()
    }

    func reloadKeybindings() {
        mainSplitViewController.reloadKeybindings()
    }

    func presentGoToPathPrompt() {
        mainSplitViewController.presentGoToPathPrompt()
    }

    func requestDeleteFromActivePane() {
        mainSplitViewController.requestDeleteFromActivePane()
    }

    private func handleTerminalAction(_ action: KeyAction) {
        switch action {
        case .launchClaude:
            launchTerminalSession(command: .claude)
        case .launchCodex:
            launchTerminalSession(command: .codex)
        case .toggleTerminalPanel:
            toggleSessionManager()
        default:
            break
        }
    }

    private func configureWindow() {
        guard let window else {
            return
        }

        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 800, height: 600)
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self

        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        constrainWindowFrameToVisibleScreenIfNeeded(window)

        mainSplitViewController.onSpotlightSearchScopeChanged = { [weak self] scope in
            self?.updateSpotlightSearchScope(scope)
        }
        mainSplitViewController.onStatusChanged = { [weak self] statusText, itemCount, markedCount in
            self?.updateFooterBaseStatus(statusText, itemCount: itemCount, markedCount: markedCount)
        }
        mainSplitViewController.onStatusContextTextChanged = { [weak self] text in
            self?.updateFooterContextText(text)
        }
        mainSplitViewController.onPaneVisibilityChanged = { [weak self] leftVisible, rightVisible in
            self?.leftPaneVisible = leftVisible
            self?.rightPaneVisible = rightVisible
            self?.persistAppConfig()
        }
        mainSplitViewController.onSidebarWidthChanged = { [weak self] width in
            self?.handleSidebarWidthChanged(width)
        }
        mainSplitViewController.onFileIconSizeChanged = { [weak self] side, size in
            self?.updatePaneFileIconSize(size, for: side)
        }
        mainSplitViewController.onTerminalAction = { [weak self] action in
            self?.handleTerminalAction(action)
        }

        applyCurrentAppearance()
        let effectiveStarEffects = disableAnimations ? false : starEffectsEnabled
        let effectiveAnimationSettings = disableAnimations ? AnimationEffectSettings.allDisabled : animationEffectSettings
        mainSplitViewController.setStarEffectsEnabled(effectiveStarEffects)
        mainSplitViewController.setAnimationEffectSettings(effectiveAnimationSettings)
        mainSplitViewController.setShortcutGuideEnabled(shortcutGuideEnabled)
        mainContainerViewController.setStatusBarStarEffectsEnabled(effectiveStarEffects)
        mainContainerViewController.setStatusBarAnimationEffectSettings(effectiveAnimationSettings)
        mainContainerViewController.bindTaskCenter(mainViewModel.taskCenter)
        window.contentViewController = mainContainerViewController
        renderFooterStatus()
        attachWindowControlButtons(to: window)

        loadPersistedSessions()
        startSessionPersistTimer()
    }

    private func attachWindowControlButtons(to window: NSWindow) {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = buttonTypes.compactMap { window.standardWindowButton($0) }
        guard buttons.count == buttonTypes.count else {
            return
        }

        mainSplitViewController.embedWindowControlButtons(buttons)
    }

    private var backgroundOpacity: CGFloat {
        transparentBackground ? transparentBackgroundOpacity : 1.0
    }

    func applyCurrentAppearance() {
        let opacity = backgroundOpacity

        mainSplitViewController.setFilerTheme(filerTheme, backgroundOpacity: opacity)
        mainContainerViewController.applyStatusBarTheme(filerTheme, backgroundOpacity: opacity)

        if let window {
            window.isOpaque = !transparentBackground
            if transparentBackground {
                window.backgroundColor = .clear
            } else {
                window.backgroundColor = filerTheme.palette.windowBackgroundColor
            }
            window.hasShadow = true
        }
    }

    private func updateFooterBaseStatus(_ text: String, itemCount: Int, markedCount: Int) {
        footerBaseStatusText = text
        footerItemCount = itemCount
        footerMarkedCount = markedCount
        renderFooterStatus()
    }

    private func updateFooterContextText(_ text: String?) {
        footerContextText = text
        renderFooterStatus()
    }

    private func renderFooterStatus() {
        let primaryText: String
        if let footerContextText, !footerContextText.isEmpty {
            primaryText = footerContextText
        } else {
            primaryText = footerBaseStatusText
        }

        mainContainerViewController.updateStatusBar(
            primaryText: primaryText,
            itemCount: footerItemCount,
            markedCount: footerMarkedCount
        )
    }

    func persistAppConfig() {
        if mainSplitViewController.isViewLoaded {
            sidebarWidth = Self.clampedSidebarWidth(mainSplitViewController.currentSidebarWidth())
        }

        let activeSortDescriptor = mainViewModel.activePane.directoryContents.sortDescriptor
        let appConfig = AppConfig(
            showHiddenFiles: mainViewModel.activePane.directoryContents.showHiddenFiles,
            defaultSortColumn: Self.sortColumn(from: activeSortDescriptor.column),
            defaultSortAscending: activeSortDescriptor.ascending,
            previewPaneVisible: false,
            sidebarVisible: mainViewModel.sidebarVisible,
            lastLeftPanePath: mainViewModel.leftPane.paneState.currentDirectory.path,
            lastRightPanePath: mainViewModel.rightPane.paneState.currentDirectory.path,
            leftPaneBackHistoryPaths: mainViewModel.leftPane.navigationHistory.backStack.map(\.path),
            leftPaneForwardHistoryPaths: mainViewModel.leftPane.navigationHistory.forwardStack.map(\.path),
            rightPaneBackHistoryPaths: mainViewModel.rightPane.navigationHistory.backStack.map(\.path),
            rightPaneForwardHistoryPaths: mainViewModel.rightPane.navigationHistory.forwardStack.map(\.path),
            lastActivePane: mainViewModel.activePaneSide == .left ? "left" : "right",
            filerTheme: filerTheme,
            transparentBackground: transparentBackground,
            transparentBackgroundOpacity: Double(transparentBackgroundOpacity),
            actionFeedbackEnabled: actionFeedbackEnabled,
            spotlightSearchScope: spotlightSearchScope,
            fileIconSize: Double(fileIconSize),
            leftPaneFileIconSize: Double(leftPaneFileIconSize),
            rightPaneFileIconSize: Double(rightPaneFileIconSize),
            sidebarFavoritesVisible: sidebarFavoritesVisible,
            sidebarRecentItemsLimit: sidebarRecentItemsLimit,
            sidebarWidth: Double(sidebarWidth),
            leftPaneDisplayMode: mainViewModel.leftPane.displayMode,
            rightPaneDisplayMode: mainViewModel.rightPane.displayMode,
            leftPaneMediaRecursiveEnabled: mainViewModel.leftPane.mediaRecursiveEnabled,
            rightPaneMediaRecursiveEnabled: mainViewModel.rightPane.mediaRecursiveEnabled,
            leftPaneVisible: leftPaneVisible,
            rightPaneVisible: rightPaneVisible,
            starEffectsEnabled: starEffectsEnabled,
            animationEffectSettings: animationEffectSettings,
            shortcutGuideEnabled: shortcutGuideEnabled,
            terminalPanelVisible: false,
            terminalPanelHeight: 300
        )

        try? configManager.saveAppConfig(appConfig)
    }

    private static func resolveDirectory(path: String, fallback: URL) -> URL {
        let resolvedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return resolvedURL
        }

        return fallback
    }

    private static func resolveNavigationHistory(
        backPaths: [String],
        forwardPaths: [String]
    ) -> NavigationHistory {
        NavigationHistory(
            backStack: resolveExistingDirectoryURLs(from: backPaths),
            forwardStack: resolveExistingDirectoryURLs(from: forwardPaths)
        )
    }

    private static func resolveExistingDirectoryURLs(from paths: [String]) -> [URL] {
        paths.compactMap { path in
            let resolvedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return resolvedURL
        }
    }

    private static func initializeDefaultBookmarksIfNeeded(configManager: ConfigManager) {
        let existingConfig = configManager.loadBookmarksConfig()
        guard existingConfig.groups.isEmpty else {
            return
        }

        let defaultConfig = BookmarksConfig.withDefaults()
        try? configManager.saveBookmarksConfig(defaultConfig)
    }

    private static func sortColumn(from column: DirectoryContents.SortDescriptor.Column) -> AppConfig.SortColumn {
        switch column {
        case .name:
            return .name
        case .size:
            return .size
        case .date:
            return .date
        case .selection:
            return .selection
        }
    }

    static func sortDescriptor(
        from column: AppConfig.SortColumn,
        ascending: Bool
    ) -> DirectoryContents.SortDescriptor {
        switch column {
        case .name:
            return .name(ascending: ascending)
        case .size:
            return .size(ascending: ascending)
        case .date:
            return .date(ascending: ascending)
        case .selection:
            return .selection(ascending: ascending)
        }
    }

}
