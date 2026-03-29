import Foundation

// MARK: - State Persistence

extension NetworkSyncService {
    func loadServerState() throws {
        let stateURL = serverStateURL()
        if !fileManager.fileExists(atPath: stateURL.path) {
            try migrateLegacyServerStateIfNeeded(to: stateURL)
        }

        if let data = try? Data(contentsOf: stateURL) {
            serverState = try decoder.decode(NetworkSyncServerState.self, from: data)
        } else {
            serverState = NetworkSyncServerState()
        }
    }

    func saveServerState() throws {
        let stateURL = serverStateURL()
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(serverState).write(to: stateURL, options: .atomic)
    }

    func loadClientState() {
        let stateURL = clientStateURL()
        if !fileManager.fileExists(atPath: stateURL.path) {
            migrateLegacyClientStateIfNeeded(to: stateURL)
        }

        if let data = try? Data(contentsOf: stateURL),
           let state = try? decoder.decode(NetworkSyncClientState.self, from: data) {
            clientState = state
            lastSavedClientStateData = data
        } else {
            clientState = NetworkSyncClientState()
            lastSavedClientStateData = nil
        }
    }

    func saveClientState() {
        let stateURL = clientStateURL()
        guard let data = try? encoder.encode(clientState) else {
            return
        }
        guard data != lastSavedClientStateData || !fileManager.fileExists(atPath: stateURL.path) else {
            return
        }
        try? fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
        lastSavedClientStateData = data
        browserStateVersion += 1
        snapshot.browserStateVersion = browserStateVersion
    }

    func serverStateURL() -> URL {
        configManager
            .networkSyncRuntimeDirectory(rootPath: rootURL!.path)
            .appendingPathComponent("server-state.json")
    }

    func clientStateURL() -> URL {
        configManager
            .networkSyncRuntimeDirectory(rootPath: config.effectiveRootPath)
            .appendingPathComponent("client-state.json")
    }

    func temporaryDirectoryURL(under rootURL: URL) -> URL {
        configManager
            .networkSyncRuntimeDirectory(rootPath: rootURL.path)
            .appendingPathComponent("tmp", isDirectory: true)
    }
}

// MARK: - Legacy Migration

private extension NetworkSyncService {
    func migrateLegacyServerStateIfNeeded(to destinationURL: URL) throws {
        guard let rootURL else {
            return
        }

        let legacyURL = rootURL.appendingPathComponent(".starfiler-sync/state.json")
        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: legacyURL, to: destinationURL)
    }

    func migrateLegacyClientStateIfNeeded(to destinationURL: URL) {
        let legacyURL = configManager.configDirectory.appendingPathComponent("NetworkSyncClientState.json")
        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }

        try? fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.copyItem(at: legacyURL, to: destinationURL)
    }
}
