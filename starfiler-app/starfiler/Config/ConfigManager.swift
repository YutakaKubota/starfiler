import Foundation

enum ConfigManagerError: LocalizedError {
    case bookmarkShortcutConflict(BookmarksConfig.ShortcutConflict)

    var errorDescription: String? {
        switch self {
        case .bookmarkShortcutConflict(let conflict):
            return
                "Shortcut \"\(conflict.sequenceDisplayText)\" is already used by " +
                "\"\(conflict.existing.entryLabel)\" (group: \(conflict.existing.groupName)). " +
                "Change the shortcut and try again."
        }
    }
}

final class ConfigManager {
    private static let defaultConfigDirectoryPath = "$HOME/Library/Mobile Documents/com~apple~CloudDocs/myiclouddrive/dotfiles/Starfiler"
    private static let previousFixedDefaultConfigDirectoryPaths = [
        "/Users/eipoc/Library/Mobile Documents/com~apple~CloudDocs/myiclouddrive/dotfiles/Starfiler",
        "/Users/eipoc/Library/CloudStorage/GoogleDrive-yutaka.kubota@nil-one.com/My Drive/DropBox/dotfiles/Starfiler",
    ]
    private static let legacyConfigMigrationMarkerPrefix = "legacyConfigMigratedToFixedDefault"

    private enum FileName {
        static let appConfig = "AppConfig.json"
        static let keybindingsConfig = "Keybindings.json"
        static let bookmarksConfig = "Bookmarks.json"
        static let batchRenamePresetsConfig = "BatchRenamePresets.json"
        static let syncletsConfig = "Synclets.json"
        static let networkSyncConfig = "NetworkSync.json"
        static let visitHistoryConfig = "VisitHistory.json"
        static let pinnedItemsConfig = "PinnedItems.json"
        static let terminalSessionsConfig = "TerminalSessions.json"
    }

    let configDirectory: URL

    private let fileManager: FileManager
    private let bundleIdentifier: String

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.nilone.starfiler",
        configDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundleIdentifier = bundleIdentifier

        if let configDirectory {
            self.configDirectory = configDirectory
        } else {
            self.configDirectory = Self.defaultConfigDirectory(
                fileManager: fileManager,
                bundleIdentifier: bundleIdentifier
            )
        }

        createConfigDirectoryIfNeeded()
    }

    func loadAppConfig() -> AppConfig {
        load(AppConfig.self, from: appConfigURL) ?? AppConfig()
    }

    func saveAppConfig(_ config: AppConfig) throws {
        try save(config, to: appConfigURL)
    }

    func loadKeybindingsConfig() -> KeybindingsConfig {
        load(KeybindingsConfig.self, from: keybindingsConfigURL) ?? KeybindingsConfig()
    }

    func saveKeybindingsConfig(_ config: KeybindingsConfig) throws {
        try save(config, to: keybindingsConfigURL)
    }

    func loadBookmarksConfig() -> BookmarksConfig {
        let loadedConfig = load(BookmarksConfig.self, from: bookmarksConfigURL) ?? BookmarksConfig()
        let migrationResult = loadedConfig.migratingLegacyPaths(fileManager: fileManager)
        if migrationResult.didChange {
            try? migrationResult.config.save(to: bookmarksConfigURL, fileManager: fileManager)
        }
        return migrationResult.config
    }

    func saveBookmarksConfig(_ config: BookmarksConfig) throws {
        let normalizedConfig = config.normalizedForStorage(fileManager: fileManager)
        if let conflict = normalizedConfig.firstShortcutConflict() {
            throw ConfigManagerError.bookmarkShortcutConflict(conflict)
        }
        try normalizedConfig.save(to: bookmarksConfigURL, fileManager: fileManager)
    }

    var appConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.appConfig, isDirectory: false)
    }

    var keybindingsConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.keybindingsConfig, isDirectory: false)
    }

    var bookmarksConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.bookmarksConfig, isDirectory: false)
    }

    func loadBatchRenamePresetsConfig() -> BatchRenamePresetsConfig {
        load(BatchRenamePresetsConfig.self, from: batchRenamePresetsConfigURL) ?? BatchRenamePresetsConfig()
    }

    func saveBatchRenamePresetsConfig(_ config: BatchRenamePresetsConfig) throws {
        try save(config, to: batchRenamePresetsConfigURL)
    }

    var batchRenamePresetsConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.batchRenamePresetsConfig, isDirectory: false)
    }

    func loadSyncletsConfig() -> SyncletsConfig {
        load(SyncletsConfig.self, from: syncletsConfigURL) ?? SyncletsConfig()
    }

    func saveSyncletsConfig(_ config: SyncletsConfig) throws {
        try save(config, to: syncletsConfigURL)
    }

    var syncletsConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.syncletsConfig, isDirectory: false)
    }

    func loadNetworkSyncConfig() -> NetworkSyncConfig {
        let loadedConfig = load(NetworkSyncConfig.self, from: networkSyncConfigURL) ?? NetworkSyncConfig()
        return normalizedNetworkSyncConfig(loadedConfig)
    }

    func saveNetworkSyncConfig(_ config: NetworkSyncConfig) throws {
        try save(normalizedNetworkSyncConfig(config), to: networkSyncConfigURL)
    }

    var networkSyncConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.networkSyncConfig, isDirectory: false)
    }

    private func normalizedNetworkSyncConfig(_ config: NetworkSyncConfig) -> NetworkSyncConfig {
        var normalized = config
        if normalized.mode == .client {
            normalized.rootPath = normalized.effectiveRootPath
        }
        return normalized
    }

    func loadVisitHistoryConfig() -> VisitHistoryConfig {
        load(VisitHistoryConfig.self, from: visitHistoryConfigURL) ?? VisitHistoryConfig()
    }

    func saveVisitHistoryConfig(_ config: VisitHistoryConfig) throws {
        try save(config, to: visitHistoryConfigURL)
    }

    var visitHistoryConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.visitHistoryConfig, isDirectory: false)
    }

    func loadPinnedItemsConfig() -> PinnedItemsConfig {
        load(PinnedItemsConfig.self, from: pinnedItemsConfigURL) ?? PinnedItemsConfig()
    }

    func savePinnedItemsConfig(_ config: PinnedItemsConfig) throws {
        try save(config, to: pinnedItemsConfigURL)
    }

    var pinnedItemsConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.pinnedItemsConfig, isDirectory: false)
    }

    func loadTerminalSessionsConfig() -> TerminalSessionsConfig? {
        load(TerminalSessionsConfig.self, from: terminalSessionsConfigURL)
    }

    func saveTerminalSessionsConfig(_ config: TerminalSessionsConfig) throws {
        try save(config, to: terminalSessionsConfigURL)
    }

    var terminalSessionsConfigURL: URL {
        configDirectory.appendingPathComponent(FileName.terminalSessionsConfig, isDirectory: false)
    }

    // MARK: - Custom Config Directory

    private static let customConfigDirectoryKey = "customConfigDirectory"

    static func customConfigDirectoryURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: customConfigDirectoryKey) else {
            return nil
        }
        let resolvedPath = UserPaths.expandHomeVariables(in: path)
        return URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
    }

    static func setCustomConfigDirectory(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: customConfigDirectoryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customConfigDirectoryKey)
        }
    }

    static func defaultFallbackConfigDirectory(
        fileManager _: FileManager = .default,
        bundleIdentifier _: String = Bundle.main.bundleIdentifier ?? "com.nilone.starfiler"
    ) -> URL {
        let resolvedPath = UserPaths.expandHomeVariables(in: defaultConfigDirectoryPath)
        return URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
    }

    static func existingConfigFileNames(in directory: URL, fileManager: FileManager = .default) -> [String] {
        guard fileManager.fileExists(atPath: directory.path),
              let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "json" }
            .map { $0.lastPathComponent }
    }

    static func migrateConfigFiles(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for fileURL in contents where fileURL.pathExtension == "json" {
            let destFileURL = destination.appendingPathComponent(fileURL.lastPathComponent)
            if fileManager.fileExists(atPath: destFileURL.path) {
                try fileManager.removeItem(at: destFileURL)
            }
            try fileManager.copyItem(at: fileURL, to: destFileURL)
        }
    }

    private static func defaultConfigDirectory(fileManager: FileManager, bundleIdentifier: String) -> URL {
        if let customURL = customConfigDirectoryURL() {
            return customURL
        }

        let defaultDirectory = defaultFallbackConfigDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
        migrateLegacyDefaultConfigIfNeeded(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier,
            destinationDirectory: defaultDirectory
        )
        return defaultDirectory
    }

    private static func migrateLegacyDefaultConfigIfNeeded(
        fileManager: FileManager,
        bundleIdentifier: String,
        destinationDirectory: URL
    ) {
        let migrationMarkerKey = "\(legacyConfigMigrationMarkerPrefix).\(bundleIdentifier).\(destinationDirectory.path)"
        if UserDefaults.standard.bool(forKey: migrationMarkerKey) {
            return
        }
        defer {
            UserDefaults.standard.set(true, forKey: migrationMarkerKey)
        }

        let sourceDirectories = migrationSourceDirectories(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
            .filter { $0.standardizedFileURL != destinationDirectory.standardizedFileURL }

        for sourceDirectory in sourceDirectories {
            let sourceFiles = existingConfigFileNames(in: sourceDirectory, fileManager: fileManager)
            guard !sourceFiles.isEmpty else {
                continue
            }

            for fileName in primaryConfigFileNames {
                copyConfigFileIfNeeded(
                    named: fileName,
                    from: sourceDirectory,
                    to: destinationDirectory,
                    overwrite: false,
                    fileManager: fileManager
                )
            }

            // If Bookmarks.json in the new location was auto-generated defaults, prefer
            // existing bookmarks from the migration source so users keep real sets.
            restoreBookmarksFromLegacyIfDestinationHasDefaults(
                legacyDirectory: sourceDirectory,
                destinationDirectory: destinationDirectory,
                fileManager: fileManager
            )
        }
    }

    private static func migrationSourceDirectories(fileManager: FileManager, bundleIdentifier: String) -> [URL] {
        var directories: [URL] = [
            legacyApplicationSupportConfigDirectory(fileManager: fileManager, bundleIdentifier: bundleIdentifier),
        ]

        directories.append(
            contentsOf: previousFixedDefaultConfigDirectoryPaths.map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            }
        )

        var uniqueDirectories: [URL] = []
        var seenPaths = Set<String>()
        for directory in directories {
            let path = directory.path
            if seenPaths.insert(path).inserted {
                uniqueDirectories.append(directory)
            }
        }
        return uniqueDirectories
    }

    private static var primaryConfigFileNames: [String] {
        [
            FileName.appConfig,
            FileName.keybindingsConfig,
            FileName.bookmarksConfig,
            FileName.batchRenamePresetsConfig,
            FileName.syncletsConfig,
            FileName.networkSyncConfig,
            FileName.visitHistoryConfig,
            FileName.pinnedItemsConfig,
            FileName.terminalSessionsConfig,
        ]
    }

    @discardableResult
    private static func copyConfigFileIfNeeded(
        named fileName: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        overwrite: Bool,
        fileManager: FileManager
    ) -> Bool {
        let sourceURL = sourceDirectory.appendingPathComponent(fileName, isDirectory: false)
        let destinationURL = destinationDirectory.appendingPathComponent(fileName, isDirectory: false)

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return false
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard overwrite else {
                return false
            }
            try? fileManager.removeItem(at: destinationURL)
        } else if !fileManager.fileExists(atPath: destinationDirectory.path) {
            try? fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            return false
        }
    }

    private static func restoreBookmarksFromLegacyIfDestinationHasDefaults(
        legacyDirectory: URL,
        destinationDirectory: URL,
        fileManager: FileManager
    ) {
        let legacyURL = legacyDirectory.appendingPathComponent(FileName.bookmarksConfig, isDirectory: false)
        let destinationURL = destinationDirectory.appendingPathComponent(FileName.bookmarksConfig, isDirectory: false)

        guard fileManager.fileExists(atPath: legacyURL.path),
              fileManager.fileExists(atPath: destinationURL.path),
              let legacyBookmarks = try? BookmarksConfig.load(from: legacyURL, fileManager: fileManager),
              let destinationBookmarks = try? BookmarksConfig.load(from: destinationURL, fileManager: fileManager)
        else {
            return
        }

        let defaultBookmarks = BookmarksConfig.withDefaults()
        guard destinationBookmarks.groups == defaultBookmarks.groups else {
            return
        }

        guard !legacyBookmarks.groups.isEmpty,
              legacyBookmarks.groups != destinationBookmarks.groups
        else {
            return
        }

        _ = copyConfigFileIfNeeded(
            named: FileName.bookmarksConfig,
            from: legacyDirectory,
            to: destinationDirectory,
            overwrite: true,
            fileManager: fileManager
        )
    }

    private static func legacyApplicationSupportConfigDirectory(fileManager: FileManager, bundleIdentifier: String) -> URL {
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? UserPaths.homeDirectoryURL

        return baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Config", isDirectory: true)
    }

    private func createConfigDirectoryIfNeeded() {
        guard !fileManager.fileExists(atPath: configDirectory.path) else {
            return
        }

        try? fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }
}
