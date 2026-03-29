import AppKit
import CryptoKit

// MARK: - Config Monitoring

extension MainWindowController {
    func startConfigMonitoring() {
        observedConfigSnapshots = currentObservedConfigSnapshots()

        primaryConfigMonitor.startMonitoring(url: configManager.configDirectory) { [weak self] in
            self?.handleObservedConfigDirectoryChange()
        }

        guard let keybindingsConfigURL else {
            return
        }

        let keybindingsDirectory = keybindingsConfigURL.deletingLastPathComponent().standardizedFileURL
        let primaryDirectory = configManager.configDirectory.standardizedFileURL
        guard keybindingsDirectory.path != primaryDirectory.path else {
            return
        }

        keybindingsConfigMonitor.startMonitoring(url: keybindingsDirectory) { [weak self] in
            self?.handleObservedConfigDirectoryChange()
        }
    }

    private func handleObservedConfigDirectoryChange() {
        let changedFiles = refreshObservedConfigSnapshots()
        guard !changedFiles.isEmpty else {
            return
        }

        if changedFiles.contains(.appConfig) {
            applyAppConfigFromDiskWithoutPersisting()
        }
        if changedFiles.contains(.bookmarks) {
            mainSplitViewController.reloadBookmarksConfig()
        }
        if changedFiles.contains(.keybindings) {
            mainSplitViewController.reloadKeybindings()
        }
    }

    func applyAppConfigFromDiskWithoutPersisting() {
        let appConfig = configManager.loadAppConfig()

        let clampedOpacity = min(max(CGFloat(appConfig.transparentBackgroundOpacity), 0.15), 1.0)
        if filerTheme != appConfig.filerTheme
            || transparentBackground != appConfig.transparentBackground
            || abs(transparentBackgroundOpacity - clampedOpacity) > 0.001
        {
            filerTheme = appConfig.filerTheme
            transparentBackground = appConfig.transparentBackground
            transparentBackgroundOpacity = clampedOpacity
            applyCurrentAppearance()
        }

        if actionFeedbackEnabled != appConfig.actionFeedbackEnabled {
            actionFeedbackEnabled = appConfig.actionFeedbackEnabled
            mainSplitViewController.setActionFeedbackEnabled(actionFeedbackEnabled)
        }

        if spotlightSearchScope != appConfig.spotlightSearchScope {
            spotlightSearchScope = appConfig.spotlightSearchScope
            mainSplitViewController.setSpotlightSearchScope(spotlightSearchScope)
        }

        if mainViewModel.leftPane.directoryContents.showHiddenFiles != appConfig.showHiddenFiles {
            mainViewModel.leftPane.setShowHiddenFiles(appConfig.showHiddenFiles)
        }
        if mainViewModel.rightPane.directoryContents.showHiddenFiles != appConfig.showHiddenFiles {
            mainViewModel.rightPane.setShowHiddenFiles(appConfig.showHiddenFiles)
        }

        let sortDescriptor = Self.sortDescriptor(
            from: appConfig.defaultSortColumn,
            ascending: appConfig.defaultSortAscending
        )
        if mainViewModel.leftPane.directoryContents.sortDescriptor != sortDescriptor {
            mainViewModel.leftPane.setSortDescriptor(sortDescriptor)
        }
        if mainViewModel.rightPane.directoryContents.sortDescriptor != sortDescriptor {
            mainViewModel.rightPane.setSortDescriptor(sortDescriptor)
        }

        if mainViewModel.leftPane.displayMode != appConfig.leftPaneDisplayMode {
            mainViewModel.leftPane.setDisplayMode(appConfig.leftPaneDisplayMode)
        }
        if mainViewModel.rightPane.displayMode != appConfig.rightPaneDisplayMode {
            mainViewModel.rightPane.setDisplayMode(appConfig.rightPaneDisplayMode)
        }
        if mainViewModel.leftPane.mediaRecursiveEnabled != appConfig.leftPaneMediaRecursiveEnabled {
            mainViewModel.leftPane.setMediaRecursiveEnabled(appConfig.leftPaneMediaRecursiveEnabled)
        }
        if mainViewModel.rightPane.mediaRecursiveEnabled != appConfig.rightPaneMediaRecursiveEnabled {
            mainViewModel.rightPane.setMediaRecursiveEnabled(appConfig.rightPaneMediaRecursiveEnabled)
        }

        let clampedGlobalIconSize = min(max(CGFloat(appConfig.fileIconSize), 12), 40)
        if abs(fileIconSize - clampedGlobalIconSize) > .ulpOfOne {
            fileIconSize = clampedGlobalIconSize
        }

        let clampedLeftIconSize = min(max(CGFloat(appConfig.leftPaneFileIconSize), 12), 40)
        if abs(leftPaneFileIconSize - clampedLeftIconSize) > .ulpOfOne {
            leftPaneFileIconSize = clampedLeftIconSize
            mainSplitViewController.setFileIconSize(clampedLeftIconSize, for: .left)
        }

        let clampedRightIconSize = min(max(CGFloat(appConfig.rightPaneFileIconSize), 12), 40)
        if abs(rightPaneFileIconSize - clampedRightIconSize) > .ulpOfOne {
            rightPaneFileIconSize = clampedRightIconSize
            mainSplitViewController.setFileIconSize(clampedRightIconSize, for: .right)
        }

        let clampedSidebarRecentItemsLimit = min(
            max(appConfig.sidebarRecentItemsLimit, AppConfig.sidebarRecentItemsLimitRange.lowerBound),
            AppConfig.sidebarRecentItemsLimitRange.upperBound
        )
        var requiresSidebarReload = false
        if sidebarFavoritesVisible != appConfig.sidebarFavoritesVisible {
            sidebarFavoritesVisible = appConfig.sidebarFavoritesVisible
            requiresSidebarReload = true
        }
        if sidebarRecentItemsLimit != clampedSidebarRecentItemsLimit {
            sidebarRecentItemsLimit = clampedSidebarRecentItemsLimit
            requiresSidebarReload = true
        }
        if requiresSidebarReload {
            mainSplitViewController.reloadSidebarSections()
        }

        if starEffectsEnabled != appConfig.starEffectsEnabled {
            starEffectsEnabled = appConfig.starEffectsEnabled
            mainSplitViewController.setStarEffectsEnabled(starEffectsEnabled)
            mainContainerViewController.setStatusBarStarEffectsEnabled(starEffectsEnabled)
        }

        if animationEffectSettings != appConfig.animationEffectSettings {
            animationEffectSettings = appConfig.animationEffectSettings
            mainSplitViewController.setAnimationEffectSettings(animationEffectSettings)
            mainContainerViewController.setStatusBarAnimationEffectSettings(animationEffectSettings)
        }

        if shortcutGuideEnabled != appConfig.shortcutGuideEnabled {
            shortcutGuideEnabled = appConfig.shortcutGuideEnabled
            mainSplitViewController.setShortcutGuideEnabled(shortcutGuideEnabled)
        }
    }

    func applyConfigChangesSinceLastLaunch(previousSnapshots: [ObservedConfigFile: ConfigFileSnapshot]) {
        guard !previousSnapshots.isEmpty else {
            return
        }

        let changedFiles = changedObservedConfigFiles(
            previousSnapshots: previousSnapshots,
            latestSnapshots: currentObservedConfigSnapshots()
        )
        guard !changedFiles.isEmpty else {
            return
        }

        if changedFiles.contains(.appConfig) {
            applyAppConfigFromDiskWithoutPersisting()
        }
        if changedFiles.contains(.bookmarks) {
            mainSplitViewController.reloadBookmarksConfig()
        }
        if changedFiles.contains(.keybindings) {
            mainSplitViewController.reloadKeybindings()
        }
    }

    private func changedObservedConfigFiles(
        previousSnapshots: [ObservedConfigFile: ConfigFileSnapshot],
        latestSnapshots: [ObservedConfigFile: ConfigFileSnapshot]
    ) -> Set<ObservedConfigFile> {
        let allFiles = Set(previousSnapshots.keys).union(latestSnapshots.keys)
        return Set(allFiles.filter { previousSnapshots[$0] != latestSnapshots[$0] })
    }

    private func refreshObservedConfigSnapshots() -> Set<ObservedConfigFile> {
        let latestSnapshots = currentObservedConfigSnapshots()
        let changedFiles = changedObservedConfigFiles(
            previousSnapshots: observedConfigSnapshots,
            latestSnapshots: latestSnapshots
        )

        observedConfigSnapshots = latestSnapshots
        return changedFiles
    }

    func currentObservedConfigSnapshots() -> [ObservedConfigFile: ConfigFileSnapshot] {
        let observedURLs = observedConfigURLs
        return Dictionary(uniqueKeysWithValues: observedURLs.map { file, url in
            (file, configFileSnapshot(for: url))
        })
    }

    private var observedConfigURLs: [ObservedConfigFile: URL] {
        var urls: [ObservedConfigFile: URL] = [
            .appConfig: configManager.appConfigURL,
            .bookmarks: configManager.bookmarksConfigURL,
        ]

        if let keybindingsConfigURL {
            urls[.keybindings] = keybindingsConfigURL
        }

        return urls
    }

    private func configFileSnapshot(for url: URL) -> ConfigFileSnapshot {
        let path = url.standardizedFileURL.path
        guard fileManager.fileExists(atPath: path),
              let attributes = try? fileManager.attributesOfItem(atPath: path)
        else {
            return ConfigFileSnapshot(exists: false, modificationDate: nil, fileSize: nil, contentDigest: nil)
        }

        let modificationDate = attributes[.modificationDate] as? Date
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value
        let contentDigest = Self.sha256Hex(of: url)
        return ConfigFileSnapshot(
            exists: true,
            modificationDate: modificationDate,
            fileSize: fileSize,
            contentDigest: contentDigest
        )
    }

    static func loadPersistedObservedConfigSnapshots() -> [ObservedConfigFile: ConfigFileSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: LaunchMetadata.observedConfigSnapshotsKey),
              let decoded = try? JSONDecoder().decode([String: ConfigFileSnapshot].self, from: data)
        else {
            return [:]
        }

        return decoded.reduce(into: [:]) { result, pair in
            guard let file = ObservedConfigFile(rawValue: pair.key) else {
                return
            }
            result[file] = pair.value
        }
    }

    static func savePersistedObservedConfigSnapshots(_ snapshots: [ObservedConfigFile: ConfigFileSnapshot]) {
        let payload = snapshots.reduce(into: [String: ConfigFileSnapshot]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        UserDefaults.standard.set(data, forKey: LaunchMetadata.observedConfigSnapshotsKey)
    }

    static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
