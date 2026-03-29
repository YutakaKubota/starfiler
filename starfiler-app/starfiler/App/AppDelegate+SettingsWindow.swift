import AppKit

// MARK: - Settings Window & Network Sync Configuration
extension AppDelegate {
    @MainActor
    func configureNetworkSyncIfNeeded() {
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
    func presentSettingsWindow() {
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

    func playShootingStarTest() {
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
