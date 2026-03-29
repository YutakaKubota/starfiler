import XCTest
@testable import Starfiler

@MainActor
final class NetworkSyncServiceIntegrationTests: XCTestCase {
    func testServerFileOperationsPropagateToClient() async throws {
        let harness = try NetworkSyncHarness()
        defer {
            harness.stop()
            harness.cleanup()
        }

        harness.start()
        await waitForConnection(in: harness)

        let sourceURL = harness.url(for: .server, relativePath: "docs/original.txt")
        try writeText("server-original", to: sourceURL)
        await waitForText("server-original", at: harness.url(for: .client, relativePath: "docs/original.txt"), description: "Server create syncs to client")

        let copiedURL = harness.url(for: .server, relativePath: "docs/copied.txt")
        try copyItem(at: sourceURL, to: copiedURL)
        await waitForText("server-original", at: harness.url(for: .client, relativePath: "docs/copied.txt"), description: "Server copy syncs to client")

        let movedURL = harness.url(for: .server, relativePath: "docs/moved.txt")
        try moveItem(at: copiedURL, to: movedURL)
        let clientCopiedURL = harness.url(for: .client, relativePath: "docs/copied.txt")
        let clientMovedURL = harness.url(for: .client, relativePath: "docs/moved.txt")
        await waitForCondition(timeout: 15, description: "Server move syncs to client") {
            !FileManager.default.fileExists(atPath: clientCopiedURL.path) &&
                ((try? String(contentsOf: clientMovedURL, encoding: .utf8)) == "server-original")
        }

        try FileManager.default.removeItem(at: movedURL)
        await waitForCondition(timeout: 15, description: "Server delete syncs to client") {
            !FileManager.default.fileExists(atPath: clientMovedURL.path)
        }
    }

    func testClientFileOperationsPropagateToServer() async throws {
        let harness = try NetworkSyncHarness()
        defer {
            harness.stop()
            harness.cleanup()
        }

        harness.start()
        await waitForConnection(in: harness)

        let sourceURL = harness.url(for: .client, relativePath: "docs/local-original.txt")
        try writeText("client-original", to: sourceURL)
        await waitForText("client-original", at: harness.url(for: .server, relativePath: "docs/local-original.txt"), description: "Client create syncs to server")

        let copiedURL = harness.url(for: .client, relativePath: "docs/local-copied.txt")
        try copyItem(at: sourceURL, to: copiedURL)
        await waitForText("client-original", at: harness.url(for: .server, relativePath: "docs/local-copied.txt"), description: "Client copy syncs to server")

        let movedURL = harness.url(for: .client, relativePath: "docs/local-moved.txt")
        try moveItem(at: copiedURL, to: movedURL)
        let serverCopiedURL = harness.url(for: .server, relativePath: "docs/local-copied.txt")
        let serverMovedURL = harness.url(for: .server, relativePath: "docs/local-moved.txt")
        let moveSynced = await waitForConditionResult(timeout: 15) {
            !FileManager.default.fileExists(atPath: serverCopiedURL.path) &&
                ((try? String(contentsOf: serverMovedURL, encoding: .utf8)) == "client-original")
        }
        if !moveSynced {
            XCTFail("""
            Client move syncs to server
            serverCopiedExists=\(FileManager.default.fileExists(atPath: serverCopiedURL.path))
            serverMovedText=\((try? String(contentsOf: serverMovedURL, encoding: .utf8)) ?? "<missing>")
            serverSnapshot=\(harness.serverSnapshot)
            clientSnapshot=\(harness.clientSnapshot)
            serverTree=\(directoryListing(at: harness.serverRoot))
            clientTree=\(directoryListing(at: harness.clientRoot))
            """)
            return
        }

        try FileManager.default.removeItem(at: movedURL)
        let deleteSynced = await waitForConditionResult(timeout: 15) {
            !FileManager.default.fileExists(atPath: serverMovedURL.path)
        }
        if !deleteSynced {
            XCTFail("""
            Client delete syncs to server
            serverMovedExists=\(FileManager.default.fileExists(atPath: serverMovedURL.path))
            clientMovedExists=\(FileManager.default.fileExists(atPath: movedURL.path))
            serverSnapshot=\(harness.serverSnapshot)
            clientSnapshot=\(harness.clientSnapshot)
            serverTree=\(directoryListing(at: harness.serverRoot))
            clientTree=\(directoryListing(at: harness.clientRoot))
            """)
        }
    }

    func testSelectiveSyncViewModelTransitionsFromWaitingToSyncedAfterDownload() async throws {
        let harness = try NetworkSyncHarness(clientSyncEntireRoot: false, clientIncludedPaths: ["selected.txt"])
        defer {
            harness.stop()
            harness.cleanup()
        }

        let coordinatorConfig = NetworkSyncConfig(
            displayName: "Coordinator-\(UUID().uuidString)",
            discoveryScope: harness.discoveryScope,
            serverEnabled: true,
            serverRootPath: harness.sharedServerRoot.path,
            clientEnabled: true,
            clientRootPath: harness.sharedClientRoot.path,
            clientSyncEntireRoot: false,
            clientIncludedPaths: ["selected.txt"]
        )
        try harness.sharedConfigManager.saveNetworkSyncConfig(coordinatorConfig)

        let coordinator = NetworkSyncCoordinator(
            configManager: harness.sharedConfigManager,
            securityScopedBookmarkService: harness.sharedBookmarkService
        )
        let viewModel = NetworkSyncViewModel(
            configManager: harness.sharedConfigManager,
            securityScopedBookmarkService: harness.sharedBookmarkService,
            service: coordinator
        )

        defer {
            coordinator.stop()
        }

        let selectedServerURL = harness.sharedServerRoot.appendingPathComponent("selected.txt")
        try writeText("selected", to: selectedServerURL)

        await waitForCondition(timeout: 15, description: "Selected node appears in view model") {
            viewModel.selectiveSyncNodes.contains(where: { $0.path == "selected.txt" })
        }

        let selectedSynced = await waitForConditionResult(timeout: 15) {
            guard let node = viewModel.selectiveSyncNodes.first(where: { $0.path == "selected.txt" }) else {
                return false
            }
            return node.runtimeState == .synced &&
                node.statusText == "Synced locally" &&
                FileManager.default.fileExists(atPath: harness.sharedClientRoot.appendingPathComponent("selected.txt").path)
        }
        if !selectedSynced {
            let nodeDescription = viewModel.selectiveSyncNodes
                .map { "\($0.path)=\($0.runtimeState):\($0.statusText)" }
                .joined(separator: ", ")
            XCTFail("""
            Selected node finishes syncing
            nodes=\(nodeDescription)
            sharedClientTree=\(directoryListing(at: harness.sharedClientRoot))
            sharedServerTree=\(directoryListing(at: harness.sharedServerRoot))
            """)
        }
    }

    private func waitForConnection(in harness: NetworkSyncHarness) async {
        await waitForCondition(timeout: 15, description: "Server starts advertising") {
            harness.serverSnapshot.status == .idle &&
                harness.serverSnapshot.detail.contains("advertising")
        }
        await waitForCondition(timeout: 15, description: "Client connects to server") {
            harness.clientSnapshot.peers.contains(where: { $0.isConnected }) &&
                harness.clientSnapshot.detail.contains("Connected to")
        }
    }

    private func waitForText(_ expected: String, at url: URL, description: String) async {
        await waitForCondition(timeout: 15, description: description) {
            (try? String(contentsOf: url, encoding: .utf8)) == expected
        }
    }

    private func waitForConditionResult(
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.01,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return true
    }

    private func directoryListing(at rootURL: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else {
                return nil
            }
            return url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        }
        .sorted()
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }
}

@MainActor
private final class NetworkSyncHarness {
    enum Side {
        case server
        case client
    }

    let rootDirectory: URL
    let serverRoot: URL
    let clientRoot: URL
    let discoveryScope: String
    let sharedConfigManager: ConfigManager
    let sharedBookmarkService = MockSecurityScopedBookmarkService()
    let sharedServerRoot: URL
    let sharedClientRoot: URL

    private let fileManager = FileManager.default
    private let serverConfigManager: ConfigManager
    private let clientConfigManager: ConfigManager
    private let serverBookmarkService = MockSecurityScopedBookmarkService()
    private let clientBookmarkService = MockSecurityScopedBookmarkService()
    private let serverService: NetworkSyncService
    private let clientService: NetworkSyncService

    private(set) var serverSnapshot: NetworkSyncRuntimeSnapshot = .disabled
    private(set) var clientSnapshot: NetworkSyncRuntimeSnapshot = .disabled

    init(clientSyncEntireRoot: Bool = true, clientIncludedPaths: [String] = []) throws {
        rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("NetworkSyncIntegration-\(UUID().uuidString)", isDirectory: true)
        serverRoot = rootDirectory.appendingPathComponent("server-root", isDirectory: true)
        clientRoot = rootDirectory.appendingPathComponent("client-root", isDirectory: true)
        sharedServerRoot = rootDirectory.appendingPathComponent("shared-server-root", isDirectory: true)
        sharedClientRoot = rootDirectory.appendingPathComponent("shared-client-root", isDirectory: true)
        discoveryScope = "sync-test-\(UUID().uuidString)"

        let serverConfigDirectory = rootDirectory.appendingPathComponent("server-config", isDirectory: true)
        let clientConfigDirectory = rootDirectory.appendingPathComponent("client-config", isDirectory: true)
        let sharedConfigDirectory = rootDirectory.appendingPathComponent("shared-config", isDirectory: true)
        serverConfigManager = ConfigManager(configDirectory: serverConfigDirectory)
        clientConfigManager = ConfigManager(configDirectory: clientConfigDirectory)
        sharedConfigManager = ConfigManager(configDirectory: sharedConfigDirectory)

        for directory in [serverRoot, clientRoot, sharedServerRoot, sharedClientRoot, serverConfigDirectory, clientConfigDirectory, sharedConfigDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try serverConfigManager.saveNetworkSyncConfig(
            NetworkSyncConfig(
                displayName: "Server-\(UUID().uuidString)",
                discoveryScope: discoveryScope,
                serverEnabled: true,
                serverRootPath: serverRoot.path,
                clientEnabled: false
            )
        )
        try clientConfigManager.saveNetworkSyncConfig(
            NetworkSyncConfig(
                displayName: "Client-\(UUID().uuidString)",
                discoveryScope: discoveryScope,
                serverEnabled: false,
                clientEnabled: true,
                clientRootPath: clientRoot.path,
                clientSyncEntireRoot: clientSyncEntireRoot,
                clientIncludedPaths: clientIncludedPaths
            )
        )

        serverService = NetworkSyncService(
            role: .server,
            configManager: serverConfigManager,
            securityScopedBookmarkService: serverBookmarkService
        )
        clientService = NetworkSyncService(
            role: .client,
            configManager: clientConfigManager,
            securityScopedBookmarkService: clientBookmarkService
        )

        serverService.onSnapshot = { [weak self] snapshot in
            self?.serverSnapshot = snapshot
        }
        clientService.onSnapshot = { [weak self] snapshot in
            self?.clientSnapshot = snapshot
        }
    }

    func start() {
        serverService.start()
        clientService.start()
    }

    func stop() {
        clientService.stop()
        serverService.stop()
    }

    func cleanup() {
        try? fileManager.removeItem(at: rootDirectory)
    }

    func url(for side: Side, relativePath: String) -> URL {
        switch side {
        case .server:
            return serverRoot.appendingPathComponent(relativePath)
        case .client:
            return clientRoot.appendingPathComponent(relativePath)
        }
    }
}
