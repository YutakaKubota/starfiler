import Foundation

@MainActor
final class NetworkSyncCoordinator: NetworkSyncControlling {
    var onSnapshot: ((NetworkSyncRuntimeSnapshot) -> Void)?

    private let configManager: ConfigManager
    private let serverService: any NetworkSyncControlling
    private let clientService: any NetworkSyncControlling

    private var config: NetworkSyncConfig
    private var serverSnapshot: NetworkSyncRuntimeSnapshot = .disabled
    private var clientSnapshot: NetworkSyncRuntimeSnapshot = .disabled

    init(
        configManager: ConfigManager = ConfigManager(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared,
        fileManager: FileManager = .default,
        serverService: (any NetworkSyncControlling)? = nil,
        clientService: (any NetworkSyncControlling)? = nil
    ) {
        self.configManager = configManager
        self.config = configManager.loadNetworkSyncConfig()
        self.serverService = serverService ?? NetworkSyncService(
            role: .server,
            configManager: configManager,
            securityScopedBookmarkService: securityScopedBookmarkService,
            fileManager: fileManager
        )
        self.clientService = clientService ?? NetworkSyncService(
            role: .client,
            configManager: configManager,
            securityScopedBookmarkService: securityScopedBookmarkService,
            fileManager: fileManager
        )

        bindServices()
    }

    func start() {
        reload(config: configManager.loadNetworkSyncConfig())
    }

    func stop() {
        serverService.stop()
        clientService.stop()
        serverSnapshot = .disabled
        clientSnapshot = .disabled
        publishSnapshot()
    }

    func reload(config: NetworkSyncConfig) {
        self.config = config

        if config.serverEnabled {
            serverService.reload(config: config)
        } else {
            serverService.stop()
            serverSnapshot = .disabled
        }

        if config.clientEnabled {
            clientService.reload(config: config)
        } else {
            clientService.stop()
            clientSnapshot = .disabled
        }

        publishSnapshot()
    }

    func requestRefresh() {
        if config.serverEnabled {
            serverService.requestRefresh()
        }
        if config.clientEnabled {
            clientService.requestRefresh()
        }
        publishSnapshot()
    }

    private func bindServices() {
        serverService.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.serverSnapshot = snapshot
                self?.publishSnapshot()
            }
        }

        clientService.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.clientSnapshot = snapshot
                self?.publishSnapshot()
            }
        }
    }

    private func publishSnapshot() {
        onSnapshot?(combinedSnapshot())
    }

    private func combinedSnapshot() -> NetworkSyncRuntimeSnapshot {
        guard config.isEnabled else {
            return .disabled
        }

        let enabledSnapshots = [
            config.serverEnabled ? labeledSnapshot("Server", snapshot: serverSnapshot) : nil,
            config.clientEnabled ? labeledSnapshot("Client", snapshot: clientSnapshot) : nil,
        ].compactMap { $0 }

        let status = aggregateStatus(enabledSnapshots.map(\.snapshot.status))
        let detail = enabledSnapshots
            .map { "\($0.label): \($0.snapshot.detail)" }
            .joined(separator: "\n")

        let peers = enabledSnapshots.flatMap { entry in
            entry.snapshot.peers.map { peer in
                NetworkSyncPeerRuntime(
                    id: "\(entry.label.lowercased())::\(peer.id)",
                    name: peer.name,
                    role: peer.role,
                    state: peer.state,
                    hostname: peer.hostname,
                    isConnected: peer.isConnected,
                    lastSeenAt: peer.lastSeenAt
                )
            }
        }

        let conflicts = enabledSnapshots.flatMap { entry in
            entry.snapshot.conflicts.map { conflict in
                NetworkSyncConflictRecord(
                    id: "\(entry.label.lowercased())::\(conflict.id)",
                    relativePath: conflict.relativePath,
                    detail: "[\(entry.label)] \(conflict.detail)",
                    timestamp: conflict.timestamp
                )
            }
        }
        .sorted { $0.timestamp > $1.timestamp }

        let transfers = enabledSnapshots.flatMap { entry in
            entry.snapshot.transfers.map { transfer in
                NetworkSyncTransferRecord(
                    id: "\(entry.label.lowercased())::\(transfer.id)",
                    relativePath: transfer.relativePath,
                    direction: transfer.direction,
                    status: transfer.status,
                    progress: transfer.progress,
                    detail: "[\(entry.label)] \(transfer.detail)",
                    timestamp: transfer.timestamp
                )
            }
        }
        .sorted { $0.timestamp > $1.timestamp }

        var activeTransfers = clientSnapshot.activeTransfers
        for (path, activity) in serverSnapshot.activeTransfers where activeTransfers[path] == nil {
            activeTransfers[path] = activity
        }

        return NetworkSyncRuntimeSnapshot(
            status: status,
            detail: detail.isEmpty ? "Network sync is enabled." : detail,
            peers: peers,
            conflicts: Array(conflicts.prefix(20)),
            transfers: Array(transfers.prefix(20)),
            activeTransfers: activeTransfers
        )
    }

    private func labeledSnapshot(_ label: String, snapshot: NetworkSyncRuntimeSnapshot) -> (label: String, snapshot: NetworkSyncRuntimeSnapshot) {
        (label, snapshot)
    }

    private func aggregateStatus(_ statuses: [NetworkSyncRuntimeStatus]) -> NetworkSyncRuntimeStatus {
        if statuses.contains(.error) {
            return .error
        }
        if statuses.contains(.starting) {
            return .starting
        }
        if statuses.contains(.syncing) {
            return .syncing
        }
        if statuses.contains(.idle) {
            return .idle
        }
        return .offline
    }
}
