import AppKit
import XCTest
@testable import Starfiler

@MainActor
final class SyncViewModelTests: XCTestCase {

    // MARK: - Properties

    private var mockComparison: MockDirectoryComparing!
    private var mockExecution: MockSyncExecuting!
    private var tempConfigDir: URL!
    private var configManager: ConfigManager!

    private let leftDir = URL(fileURLWithPath: "/tmp/left")
    private let rightDir = URL(fileURLWithPath: "/tmp/right")

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        mockComparison = MockDirectoryComparing()
        mockExecution = MockSyncExecuting()
        tempConfigDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempConfigDir, withIntermediateDirectories: true)
        configManager = ConfigManager(configDirectory: tempConfigDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempConfigDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSUT() -> SyncViewModel {
        SyncViewModel(
            leftDirectory: leftDir,
            rightDirectory: rightDir,
            comparisonService: mockComparison,
            executionService: mockExecution,
            configManager: configManager
        )
    }

    private func makeSyncItem(
        relativePath: String,
        status: SyncItemStatus = .leftOnly,
        action: SyncItemAction = .copyToRight
    ) -> SyncItem {
        SyncItem(
            relativePath: relativePath,
            isDirectory: false,
            leftURL: leftDir.appendingPathComponent(relativePath),
            rightURL: nil,
            leftSize: 1024,
            rightSize: nil,
            leftDate: Date(),
            rightDate: nil,
            status: status,
            action: action
        )
    }

    private func makeNetworkSyncEntry(
        relativePath: String,
        isDirectory: Bool,
        size: Int64 = 0
    ) -> NetworkSyncFileEntry {
        NetworkSyncFileEntry(
            relativePath: relativePath,
            isDirectory: isDirectory,
            size: size,
            modificationTimestamp: Date().timeIntervalSince1970,
            contentHash: isDirectory ? nil : UUID().uuidString,
            revision: 1,
            deleted: false
        )
    }

    private func writeNetworkSyncState(
        rootPath: String,
        entries: [NetworkSyncFileEntry],
        materializedPaths: Set<String>
    ) throws {
        let runtimeDirectory = configManager.networkSyncRuntimeDirectory(rootPath: rootPath)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        let stateURL = runtimeDirectory.appendingPathComponent("client-state.json")
        let knownEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
        let state = NetworkSyncClientState(
            knownEntries: knownEntries,
            materializedPaths: materializedPaths,
            pendingDeletionPaths: []
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func createLocalPaths(rootURL: URL, paths: [String]) throws {
        for path in paths {
            let destinationURL = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else {
                _ = FileManager.default.createFile(atPath: destinationURL.path, contents: Data("test".utf8))
            }
        }
    }

    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outlineView = view as? NSOutlineView {
            return outlineView
        }
        for subview in view.subviews {
            if let outlineView = findOutlineView(in: subview) {
                return outlineView
            }
        }
        return nil
    }

    // MARK: - Initial State

    func testInitialState() {
        let sut = makeSUT()

        XCTAssertEqual(sut.direction, .leftToRight)
        XCTAssertFalse(sut.isBusy)
        XCTAssertFalse(sut.isPreviewReady)
        XCTAssertFalse(sut.canSync)
        XCTAssertTrue(sut.items.isEmpty)
    }

    // MARK: - Compare

    func testComparePopulatesItems() async {
        let sut = makeSUT()
        let syncItems = [
            makeSyncItem(relativePath: "file1.txt"),
            makeSyncItem(relativePath: "file2.txt"),
        ]
        mockComparison.compareResult = .success(syncItems)

        sut.compare()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(sut.items.count, 2)
        XCTAssertTrue(sut.isPreviewReady)
        XCTAssertEqual(mockComparison.compareCallCount, 1)
    }

    func testCompareErrorSetsErrorPhase() async {
        let sut = makeSUT()
        mockComparison.compareResult = .failure(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"]))

        sut.compare()
        try? await Task.sleep(for: .milliseconds(200))

        if case .error(let message) = sut.phase {
            XCTAssertEqual(message, "Test error")
        } else {
            XCTFail("Expected error phase")
        }
    }

    // MARK: - Item Selection

    func testToggleItemSelection() async {
        let sut = makeSUT()
        mockComparison.compareResult = .success([makeSyncItem(relativePath: "file.txt")])
        sut.compare()
        try? await Task.sleep(for: .milliseconds(200))

        sut.toggleItemSelection(at: 0)

        XCTAssertFalse(sut.items[0].isSelected)

        sut.toggleItemSelection(at: 0)

        XCTAssertTrue(sut.items[0].isSelected)
    }

    func testSelectAll() async {
        let sut = makeSUT()
        mockComparison.compareResult = .success([
            makeSyncItem(relativePath: "file1.txt"),
            makeSyncItem(relativePath: "file2.txt"),
        ])
        sut.compare()
        try? await Task.sleep(for: .milliseconds(200))

        sut.deselectAll()
        XCTAssertEqual(sut.selectedCount, 0)

        sut.selectAll()
        XCTAssertEqual(sut.selectedCount, 2)
    }

    func testDeselectAll() async {
        let sut = makeSUT()
        mockComparison.compareResult = .success([
            makeSyncItem(relativePath: "file1.txt"),
        ])
        sut.compare()
        try? await Task.sleep(for: .milliseconds(200))

        sut.deselectAll()

        XCTAssertEqual(sut.selectedCount, 0)
    }

    // MARK: - Set Item Action

    func testSetItemAction() async {
        let sut = makeSUT()
        mockComparison.compareResult = .success([makeSyncItem(relativePath: "file.txt")])
        sut.compare()
        try? await Task.sleep(for: .milliseconds(200))

        sut.setItemAction(.skip, at: 0)

        XCTAssertEqual(sut.items[0].action, .skip)
        XCTAssertFalse(sut.items[0].isSelected)
    }

    // MARK: - Filtered Items

    func testFilteredItemsExcludesIdentical() async {
        let sut = makeSUT()
        mockComparison.compareResult = .success([
            makeSyncItem(relativePath: "changed.txt", status: .leftOnly),
            makeSyncItem(relativePath: "same.txt", status: .identical, action: .skip),
        ])
        sut.compare()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(sut.showIdentical)
        XCTAssertEqual(sut.filteredItems.count, 1)
        XCTAssertEqual(sut.filteredItems[0].relativePath, "changed.txt")
    }

    // MARK: - Exclude Rules

    func testAddExcludeRule() {
        let sut = makeSUT()
        let initialCount = sut.excludeRules.count

        sut.addExcludeRule("*.log")

        XCTAssertEqual(sut.excludeRules.count, initialCount + 1)
        XCTAssertEqual(sut.excludeRules.last?.pattern, "*.log")
    }

    func testRemoveExcludeRule() {
        let sut = makeSUT()
        let initialCount = sut.excludeRules.count

        sut.removeExcludeRule(at: 0)

        XCTAssertEqual(sut.excludeRules.count, initialCount - 1)
    }

    func testToggleExcludeRule() {
        let sut = makeSUT()
        let initialEnabled = sut.excludeRules[0].isEnabled

        sut.toggleExcludeRule(at: 0)

        XCTAssertNotEqual(sut.excludeRules[0].isEnabled, initialEnabled)
    }

    // MARK: - Synclet Management

    func testSaveSynclet() {
        let sut = makeSUT()

        sut.saveSynclet(name: "Test Sync")

        XCTAssertEqual(sut.synclets.count, 1)
        XCTAssertEqual(sut.synclets[0].name, "Test Sync")
    }

    func testLoadSynclet() {
        let sut = makeSUT()
        let synclet = Synclet(
            name: "Saved",
            leftPath: "/tmp/savedLeft",
            rightPath: "/tmp/savedRight",
            direction: .rightToLeft
        )

        sut.loadSynclet(synclet)

        XCTAssertEqual(sut.leftDirectory.path, "/tmp/savedLeft")
        XCTAssertEqual(sut.rightDirectory.path, "/tmp/savedRight")
        XCTAssertEqual(sut.direction, .rightToLeft)
    }

    func testDeleteSynclet() {
        let sut = makeSUT()
        sut.saveSynclet(name: "ToDelete")
        let synclet = sut.synclets[0]

        sut.deleteSynclet(synclet)

        XCTAssertTrue(sut.synclets.isEmpty)
    }

    func testNetworkSyncViewModelKeepsSelectiveSyncTreeCachedAcrossStatusOnlySnapshots() async throws {
        let rootURL = tempConfigDir.appendingPathComponent("NetworkSyncRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let entries = [
            makeNetworkSyncEntry(relativePath: "docs", isDirectory: true),
            makeNetworkSyncEntry(relativePath: "docs/file.txt", isDirectory: false, size: 4),
        ]
        let config = NetworkSyncConfig(
            clientEnabled: true,
            clientRootPath: rootURL.path,
            clientSyncEntireRoot: false,
            clientIncludedPaths: ["docs"]
        )
        try configManager.saveNetworkSyncConfig(config)
        try writeNetworkSyncState(
            rootPath: config.clientEffectiveRootPath,
            entries: entries,
            materializedPaths: ["docs", "docs/file.txt"]
        )
        try createLocalPaths(rootURL: rootURL, paths: ["docs/file.txt"])

        let service = MockNetworkSyncController()
        let sut = NetworkSyncViewModel(configManager: configManager, service: service)
        await waitForCondition(description: "Selective sync nodes loaded") {
            !sut.selectiveSyncNodes.isEmpty
        }

        let initialNodes = sut.selectiveSyncNodes
        let stateURL = configManager
            .networkSyncRuntimeDirectory(rootPath: config.clientEffectiveRootPath)
            .appendingPathComponent("client-state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent("docs/file.txt"))

        service.emit(
            NetworkSyncRuntimeSnapshot(
                status: .idle,
                detail: "Idle",
                peers: [],
                conflicts: [],
                transfers: [],
                activeTransfers: [:],
                browserStateVersion: 0
            )
        )
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(sut.selectiveSyncNodes, initialNodes)
    }

    func testNetworkSyncViewModelRequestRefreshReloadsSelectiveSyncTreeFromDisk() async throws {
        let rootURL = tempConfigDir.appendingPathComponent("NetworkSyncRefreshRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let initialEntries = [
            makeNetworkSyncEntry(relativePath: "docs", isDirectory: true),
            makeNetworkSyncEntry(relativePath: "docs/file.txt", isDirectory: false, size: 4),
        ]
        let config = NetworkSyncConfig(
            clientEnabled: true,
            clientRootPath: rootURL.path,
            clientSyncEntireRoot: false,
            clientIncludedPaths: ["docs"]
        )
        try configManager.saveNetworkSyncConfig(config)
        try writeNetworkSyncState(
            rootPath: config.clientEffectiveRootPath,
            entries: initialEntries,
            materializedPaths: ["docs", "docs/file.txt"]
        )
        try createLocalPaths(rootURL: rootURL, paths: ["docs/file.txt"])

        let service = MockNetworkSyncController()
        let sut = NetworkSyncViewModel(configManager: configManager, service: service)
        await waitForCondition(description: "Initial selective sync nodes loaded") {
            sut.selectiveSyncNodes.count == 1 && sut.selectiveSyncNodes.first?.path == "docs"
        }

        let refreshedEntries = [
            makeNetworkSyncEntry(relativePath: "projects", isDirectory: true),
            makeNetworkSyncEntry(relativePath: "projects/readme.md", isDirectory: false, size: 7),
        ]
        try writeNetworkSyncState(
            rootPath: config.clientEffectiveRootPath,
            entries: refreshedEntries,
            materializedPaths: ["projects", "projects/readme.md"]
        )
        try createLocalPaths(rootURL: rootURL, paths: ["projects/readme.md"])

        sut.requestRefresh()

        await waitForCondition(description: "Selective sync nodes refreshed from disk") {
            sut.selectiveSyncNodes.count == 1 && sut.selectiveSyncNodes.first?.path == "projects"
        }
        XCTAssertEqual(service.requestRefreshCallCount, 1)
    }

    func testNetworkSyncSettingsViewControllerPreservesCollapsedOutlineStateAcrossUpdates() async throws {
        let rootURL = tempConfigDir.appendingPathComponent("NetworkSyncOutlineRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let entries = [
            makeNetworkSyncEntry(relativePath: "docs", isDirectory: true),
            makeNetworkSyncEntry(relativePath: "docs/file.txt", isDirectory: false, size: 4),
            makeNetworkSyncEntry(relativePath: "images", isDirectory: true),
            makeNetworkSyncEntry(relativePath: "images/photo.jpg", isDirectory: false, size: 8),
        ]
        let config = NetworkSyncConfig(
            clientEnabled: true,
            clientRootPath: rootURL.path,
            clientSyncEntireRoot: false,
            clientIncludedPaths: ["docs", "images"]
        )
        try configManager.saveNetworkSyncConfig(config)
        try writeNetworkSyncState(
            rootPath: config.clientEffectiveRootPath,
            entries: entries,
            materializedPaths: ["docs", "docs/file.txt", "images", "images/photo.jpg"]
        )
        try createLocalPaths(rootURL: rootURL, paths: ["docs/file.txt", "images/photo.jpg"])

        let service = MockNetworkSyncController()
        let viewModel = NetworkSyncViewModel(configManager: configManager, service: service)
        await waitForCondition(description: "Outline nodes loaded") {
            viewModel.selectiveSyncNodes.count == 2
        }

        let controller = NetworkSyncSettingsViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        guard let outlineView = findOutlineView(in: controller.view) else {
            XCTFail("Expected selective sync outline view")
            return
        }

        let imagesNode = try XCTUnwrap(viewModel.selectiveSyncNodes.first(where: { $0.path == "images" }))
        outlineView.collapseItem(imagesNode)
        XCTAssertFalse(outlineView.isItemExpanded(imagesNode))

        viewModel.setClientSyncEntireRoot(true)

        await waitForCondition(description: "Outline state restored after refresh") {
            guard let docsNode = viewModel.selectiveSyncNodes.first(where: { $0.path == "docs" }),
                  let refreshedImagesNode = viewModel.selectiveSyncNodes.first(where: { $0.path == "images" })
            else {
                return false
            }
            return outlineView.isItemExpanded(docsNode) && !outlineView.isItemExpanded(refreshedImagesNode)
        }
    }
}

@MainActor
private final class MockNetworkSyncController: NetworkSyncControlling {
    var onSnapshot: ((NetworkSyncRuntimeSnapshot) -> Void)?
    private(set) var requestRefreshCallCount = 0

    func start() {}

    func stop() {}

    func reload(config _: NetworkSyncConfig) {}

    func requestRefresh() {
        requestRefreshCallCount += 1
    }

    func emit(_ snapshot: NetworkSyncRuntimeSnapshot) {
        onSnapshot?(snapshot)
    }
}
