import XCTest
@testable import Starfiler

final class ConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempConfigDir: URL!
    private var sut: ConfigManager!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        tempConfigDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigManagerTests-\(UUID().uuidString)", isDirectory: true)
        sut = ConfigManager(configDirectory: tempConfigDir)
    }

    override func tearDown() {
        ConfigManager.setCustomConfigDirectory(nil)
        try? FileManager.default.removeItem(at: tempConfigDir)
        super.tearDown()
    }

    // MARK: - AppConfig

    func testLoadAppConfigReturnsDefaultWhenNoFile() {
        let config = sut.loadAppConfig()

        // Default AppConfig values
        XCTAssertTrue(config.showHiddenFiles)
        XCTAssertEqual(config.defaultSortColumn, .date)
        XCTAssertFalse(config.defaultSortAscending)
        XCTAssertFalse(config.shortcutGuideEnabled)
    }

    func testSaveAndLoadAppConfig() throws {
        var config = AppConfig()
        config.showHiddenFiles = false
        config.defaultSortColumn = .size
        config.defaultSortAscending = false
        config.shortcutGuideEnabled = true

        try sut.saveAppConfig(config)
        let loaded = sut.loadAppConfig()

        XCTAssertFalse(loaded.showHiddenFiles)
        XCTAssertEqual(loaded.defaultSortColumn, .size)
        XCTAssertFalse(loaded.defaultSortAscending)
        XCTAssertTrue(loaded.shortcutGuideEnabled)
    }

    func testSaveAndLoadAppConfigPersistsPaneHistoryPaths() throws {
        var config = AppConfig()
        config.leftPaneBackHistoryPaths = ["/tmp/left-back-1", "/tmp/left-back-2"]
        config.leftPaneForwardHistoryPaths = ["/tmp/left-forward-1"]
        config.rightPaneBackHistoryPaths = ["/tmp/right-back-1"]
        config.rightPaneForwardHistoryPaths = ["/tmp/right-forward-1", "/tmp/right-forward-2"]

        try sut.saveAppConfig(config)
        let loaded = sut.loadAppConfig()

        XCTAssertEqual(loaded.leftPaneBackHistoryPaths, ["/tmp/left-back-1", "/tmp/left-back-2"])
        XCTAssertEqual(loaded.leftPaneForwardHistoryPaths, ["/tmp/left-forward-1"])
        XCTAssertEqual(loaded.rightPaneBackHistoryPaths, ["/tmp/right-back-1"])
        XCTAssertEqual(loaded.rightPaneForwardHistoryPaths, ["/tmp/right-forward-1", "/tmp/right-forward-2"])
    }

    // MARK: - BookmarksConfig

    func testLoadBookmarksConfigReturnsDefaultWhenNoFile() {
        let config = sut.loadBookmarksConfig()

        XCTAssertTrue(config.groups.isEmpty)
    }

    func testSaveAndLoadBookmarksConfig() throws {
        let group = BookmarkGroup(
            name: "TestGroup",
            entries: [BookmarkEntry(displayName: "Test", path: "/tmp/test")],
            shortcutKey: "t",
            isDefault: false
        )
        let config = BookmarksConfig(groups: [group])

        try sut.saveBookmarksConfig(config)
        let loaded = sut.loadBookmarksConfig()

        XCTAssertEqual(loaded.groups.count, 1)
        XCTAssertEqual(loaded.groups[0].name, "TestGroup")
        XCTAssertEqual(loaded.groups[0].entries.count, 1)
        XCTAssertEqual(loaded.groups[0].entries[0].displayName, "Test")
    }

    func testSaveBookmarksConfigNormalizesHomePathToTilde() throws {
        let homePath = UserPaths.homeDirectoryPath
        let config = BookmarksConfig(groups: [
            BookmarkGroup(
                name: "Default",
                entries: [BookmarkEntry(displayName: "Workspace", path: homePath + "/workspace", shortcutKey: "w")],
                shortcutKey: nil,
                isDefault: true
            ),
        ])

        try sut.saveBookmarksConfig(config)
        let loaded = sut.loadBookmarksConfig()

        XCTAssertEqual(loaded.groups.first?.entries.first?.path, "~/workspace")
    }

    func testSaveBookmarksConfigNormalizesHomeAliasToTilde() throws {
        let config = BookmarksConfig(groups: [
            BookmarkGroup(
                name: "Default",
                entries: [BookmarkEntry(displayName: "Home Alias", path: "Home", shortcutKey: "h")],
                shortcutKey: nil,
                isDefault: true
            ),
        ])

        try sut.saveBookmarksConfig(config)
        let loaded = sut.loadBookmarksConfig()

        XCTAssertEqual(loaded.groups.first?.entries.first?.path, "~")
    }

    func testSaveBookmarksConfigNormalizesRelativePathToHomeTilde() throws {
        let config = BookmarksConfig(groups: [
            BookmarkGroup(
                name: "Default",
                entries: [BookmarkEntry(displayName: "Workspace", path: "workspace", shortcutKey: "w")],
                shortcutKey: nil,
                isDefault: true
            ),
        ])

        try sut.saveBookmarksConfig(config)
        let loaded = sut.loadBookmarksConfig()

        XCTAssertEqual(loaded.groups.first?.entries.first?.path, "~/workspace")
    }

    func testLoadBookmarksConfigMigratesLegacyAbsoluteUserPathToTilde() throws {
        let legacyConfig = BookmarksConfig(groups: [
            BookmarkGroup(
                name: "Default",
                entries: [BookmarkEntry(displayName: "Legacy", path: "/Users/legacy-user/workspace", shortcutKey: "w")],
                shortcutKey: nil,
                isDefault: true
            ),
        ])
        try legacyConfig.save(to: sut.bookmarksConfigURL)

        let loaded = sut.loadBookmarksConfig()

        XCTAssertEqual(loaded.groups.first?.entries.first?.path, "~/workspace")
    }

    func testFirstShortcutConflictDetectsDuplicateEffectiveSequence() {
        let config = BookmarksConfig(groups: [
            BookmarkGroup(
                name: "Default",
                entries: [BookmarkEntry(displayName: "Docs", path: "/tmp/docs", shortcutKey: "d u")],
                shortcutKey: nil,
                isDefault: true
            ),
            BookmarkGroup(
                name: "Projects",
                entries: [BookmarkEntry(displayName: "Unity", path: "/tmp/unity", shortcutKey: "u")],
                shortcutKey: "d",
                isDefault: false
            ),
        ])

        let conflict = config.firstShortcutConflict()

        XCTAssertNotNil(conflict)
        XCTAssertEqual(conflict?.sequence, ["d", "u"])
        XCTAssertEqual(conflict?.existing.groupName, "Default")
        XCTAssertEqual(conflict?.incoming.groupName, "Projects")
    }

    func testFirstShortcutConflictReturnsNilWhenEffectiveSequencesAreUnique() {
        let config = BookmarksConfig(groups: [
            BookmarkGroup(
                name: "Default",
                entries: [BookmarkEntry(displayName: "Docs", path: "/tmp/docs", shortcutKey: "d u")],
                shortcutKey: nil,
                isDefault: true
            ),
            BookmarkGroup(
                name: "Projects",
                entries: [BookmarkEntry(displayName: "Unity", path: "/tmp/unity", shortcutKey: "u")],
                shortcutKey: "r",
                isDefault: false
            ),
        ])

        XCTAssertNil(config.firstShortcutConflict())
    }

    func testSaveBookmarksConfigThrowsWhenShortcutConflicts() {
        let config = BookmarksConfig(groups: [
            BookmarkGroup(
                name: "Default",
                entries: [BookmarkEntry(displayName: "Docs", path: "/tmp/docs", shortcutKey: "d u")],
                shortcutKey: nil,
                isDefault: true
            ),
            BookmarkGroup(
                name: "Projects",
                entries: [BookmarkEntry(displayName: "Unity", path: "/tmp/unity", shortcutKey: "u")],
                shortcutKey: "d",
                isDefault: false
            ),
        ])

        XCTAssertThrowsError(try sut.saveBookmarksConfig(config)) { error in
            guard case ConfigManagerError.bookmarkShortcutConflict(let conflict) = error else {
                return XCTFail("Expected bookmarkShortcutConflict, got \(error)")
            }
            XCTAssertEqual(conflict.sequence, ["d", "u"])
        }
    }

    // MARK: - BatchRenamePresetsConfig

    func testSaveAndLoadBatchRenamePresetsConfig() throws {
        let preset = BatchRenamePreset(
            name: "My Preset",
            rules: [.findReplace(find: "old", replace: "new")]
        )
        let config = BatchRenamePresetsConfig(presets: [preset])

        try sut.saveBatchRenamePresetsConfig(config)
        let loaded = sut.loadBatchRenamePresetsConfig()

        XCTAssertEqual(loaded.presets.count, 1)
        XCTAssertEqual(loaded.presets[0].name, "My Preset")
    }

    // MARK: - NetworkSyncConfig

    func testLoadNetworkSyncConfigMigratesLegacyMissingFields() throws {
        let legacyJSON = """
        {
          "isEnabled": true,
          "mode": "client",
          "displayName": "Legacy Client",
          "rootPath": "/tmp/legacy-root",
          "includedPaths": ["docs"],
          "conflictPolicy": "keepBoth",
          "heartbeatIntervalSeconds": 15,
          "syncDebounceSeconds": 0.8,
          "peers": []
        }
        """
        try FileManager.default.createDirectory(at: sut.networkSyncConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyJSON.data(using: .utf8)?.write(to: sut.networkSyncConfigURL)

        let loaded = sut.loadNetworkSyncConfig()

        XCTAssertEqual(loaded.displayName, "Legacy Client")
        XCTAssertEqual(loaded.discoveryScope, "default")
        XCTAssertFalse(loaded.serverEnabled)
        XCTAssertTrue(loaded.clientEnabled)
        XCTAssertEqual(loaded.clientEffectiveRootPath, "/tmp/legacy-root")
        XCTAssertFalse(loaded.clientSyncEntireRoot)
        XCTAssertEqual(loaded.clientIncludedPaths, ["docs"])
    }

    func testLoadNetworkSyncConfigMigratesLegacySharedConfigToLocalStorage() throws {
        let legacyJSON = """
        {
          "isEnabled": true,
          "mode": "server",
          "displayName": "Shared Legacy",
          "rootPath": "/tmp/server-root",
          "includedPaths": [],
          "conflictPolicy": "keepBoth",
          "heartbeatIntervalSeconds": 20,
          "syncDebounceSeconds": 1.2,
          "peers": []
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: sut.sharedNetworkSyncConfigURL)

        let loaded = sut.loadNetworkSyncConfig()

        XCTAssertEqual(loaded.displayName, "Shared Legacy")
        XCTAssertTrue(loaded.serverEnabled)
        XCTAssertEqual(loaded.serverEffectiveRootPath, "/tmp/server-root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sut.networkSyncConfigURL.path))
        XCTAssertNotEqual(
            sut.networkSyncConfigURL.deletingLastPathComponent().standardizedFileURL,
            sut.configDirectory.standardizedFileURL
        )
    }

    func testSaveAndLoadNetworkSyncConfigPreservesEmptyExplicitSelection() throws {
        let config = NetworkSyncConfig(
            displayName: "Client",
            discoveryScope: "local-smoke",
            serverEnabled: false,
            serverRootPath: "",
            clientEnabled: true,
            clientRootPath: "/tmp/client-root",
            clientSyncEntireRoot: false,
            clientIncludedPaths: [],
            conflictPolicy: .keepBoth,
            heartbeatIntervalSeconds: 10,
            syncDebounceSeconds: 0.5,
            peers: []
        )

        try sut.saveNetworkSyncConfig(config)
        let loaded = sut.loadNetworkSyncConfig()

        XCTAssertFalse(loaded.clientSyncEntireRoot)
        XCTAssertEqual(loaded.clientIncludedPaths, [])
        XCTAssertTrue(loaded.clientEnabled)
        XCTAssertEqual(loaded.discoveryScope, "local-smoke")
    }

    func testSaveAndLoadNetworkSyncConfigKeepsServerAndClientRootsSeparate() throws {
        let config = NetworkSyncConfig(
            displayName: "Dual Role",
            discoveryScope: "dual-role",
            serverEnabled: true,
            serverRootPath: "/Volumes/HD-ADU3/StarFilerSync",
            clientEnabled: true,
            clientRootPath: "/Users/harry/StarFilerSync",
            clientSyncEntireRoot: true,
            clientIncludedPaths: [],
            conflictPolicy: .keepBoth,
            heartbeatIntervalSeconds: 10,
            syncDebounceSeconds: 0.5,
            peers: []
        )

        try sut.saveNetworkSyncConfig(config)
        let loaded = sut.loadNetworkSyncConfig()

        XCTAssertEqual(loaded.serverEffectiveRootPath, "/Volumes/HD-ADU3/StarFilerSync")
        XCTAssertEqual(loaded.clientEffectiveRootPath, "/Users/harry/StarFilerSync")
        XCTAssertNotEqual(loaded.serverEffectiveRootPath, loaded.clientEffectiveRootPath)
    }

    // MARK: - Config Directory

    func testConfigDirectoryIsCreated() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempConfigDir.path))
    }

    func testConfigURLsPointToCorrectFiles() {
        XCTAssertTrue(sut.appConfigURL.path.hasSuffix("AppConfig.json"))
        XCTAssertTrue(sut.bookmarksConfigURL.path.hasSuffix("Bookmarks.json"))
        XCTAssertTrue(sut.batchRenamePresetsConfigURL.path.hasSuffix("BatchRenamePresets.json"))
        XCTAssertTrue(sut.syncletsConfigURL.path.hasSuffix("Synclets.json"))
        XCTAssertTrue(sut.visitHistoryConfigURL.path.hasSuffix("VisitHistory.json"))
        XCTAssertTrue(sut.pinnedItemsConfigURL.path.hasSuffix("PinnedItems.json"))
    }

    func testNetworkSyncConfigURLUsesLocalStorageDirectory() {
        XCTAssertTrue(sut.networkSyncConfigURL.path.hasSuffix("NetworkSync.json"))
        XCTAssertNotEqual(
            sut.networkSyncConfigURL.deletingLastPathComponent().standardizedFileURL,
            sut.configDirectory.standardizedFileURL
        )
    }

    func testDefaultFallbackConfigDirectoryUsesICloudDotfilesPath() {
        let url = ConfigManager.defaultFallbackConfigDirectory()

        XCTAssertEqual(
            url.path,
            UserPaths.homeDirectoryURL
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/myiclouddrive/dotfiles/Starfiler", isDirectory: true)
                .standardizedFileURL
                .path
        )
    }

    func testExpandHomeVariablesResolvesHomeEnvironmentPath() {
        let resolved = UserPaths.expandHomeVariables(
            in: "$HOME/Library/Mobile Documents/com~apple~CloudDocs/myiclouddrive/dotfiles/Starfiler"
        )

        XCTAssertEqual(
            resolved,
            UserPaths.homeDirectoryURL
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/myiclouddrive/dotfiles/Starfiler", isDirectory: true)
                .standardizedFileURL
                .path
        )
    }

    func testCustomConfigDirectoryURLResolvesHomeEnvironmentPath() {
        UserDefaults.standard.set(
            "$HOME/Library/Mobile Documents/com~apple~CloudDocs/myiclouddrive/dotfiles/Starfiler",
            forKey: "customConfigDirectory"
        )

        let url = ConfigManager.customConfigDirectoryURL()

        XCTAssertEqual(
            url?.path,
            UserPaths.homeDirectoryURL
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/myiclouddrive/dotfiles/Starfiler", isDirectory: true)
                .standardizedFileURL
                .path
        )
    }

    // MARK: - PinnedItemsConfig

    func testLoadPinnedItemsConfigReturnsDefaultWhenNoFile() {
        let config = sut.loadPinnedItemsConfig()

        XCTAssertTrue(config.items.isEmpty)
        XCTAssertEqual(config.maxItems, 50)
    }

    func testSaveAndLoadPinnedItemsConfig() throws {
        let item = PinnedItem(path: "/tmp/pinned", displayName: "pinned", isDirectory: true)
        let config = PinnedItemsConfig(items: [item], maxItems: 30)

        try sut.savePinnedItemsConfig(config)
        let loaded = sut.loadPinnedItemsConfig()

        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.items[0].path, "/tmp/pinned")
        XCTAssertEqual(loaded.items[0].displayName, "pinned")
        XCTAssertTrue(loaded.items[0].isDirectory)
        XCTAssertEqual(loaded.maxItems, 30)
    }
}
