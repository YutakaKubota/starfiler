import Foundation
import Observation

@MainActor
@Observable
final class NetworkSyncViewModel: SyncStatusBarPresenting {
    var isEnabled: Bool
    var mode: SyncNodeMode
    var displayName: String
    var rootPath: String
    var includedPathsText: String
    var conflictPolicy: NetworkSyncConflictPolicy
    var heartbeatIntervalSeconds: Double
    var syncDebounceSeconds: Double
    var peerSummaries: [NetworkSyncPeerSummary]
    var statusMessage: String

    var statusLevel: SyncStatusLevel = .offline
    var statusTitle: String = "Network Sync"
    var statusDetail: String?
    var peers: [SyncPeerSummary] = []
    var conflicts: [SyncConflictSummary] = []
    var recentTransfers: [SyncTransferSummary] = []
    var onDidChange: (() -> Void)?

    private let configManager: ConfigManager
    private let peerSummaryDateFormatter: DateFormatter
    private let service: any NetworkSyncControlling
    private var config: NetworkSyncConfig

    init(
        configManager: ConfigManager = ConfigManager(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared,
        service: (any NetworkSyncControlling)? = nil
    ) {
        self.configManager = configManager
        self.peerSummaryDateFormatter = DateFormatter()
        peerSummaryDateFormatter.dateStyle = .short
        peerSummaryDateFormatter.timeStyle = .short

        let loadedConfig = configManager.loadNetworkSyncConfig()
        self.config = loadedConfig
        self.isEnabled = loadedConfig.isEnabled
        self.mode = loadedConfig.mode
        self.displayName = loadedConfig.displayName
        self.rootPath = loadedConfig.rootPath
        self.includedPathsText = loadedConfig.includedPaths.joined(separator: "\n")
        self.conflictPolicy = loadedConfig.conflictPolicy
        self.heartbeatIntervalSeconds = loadedConfig.heartbeatIntervalSeconds
        self.syncDebounceSeconds = loadedConfig.syncDebounceSeconds
        self.peerSummaries = []
        self.statusMessage = loadedConfig.isEnabled ? "Sync is enabled" : "Sync is disabled"
        self.service = service ?? NetworkSyncService(
            configManager: configManager,
            securityScopedBookmarkService: securityScopedBookmarkService
        )

        refreshPeerSummaries()
        bindService()
        if loadedConfig.isEnabled {
            self.service.start()
        } else {
            applySnapshot(.disabled)
        }
    }

    func reload() {
        config = configManager.loadNetworkSyncConfig()
        isEnabled = config.isEnabled
        mode = config.mode
        displayName = config.displayName
        rootPath = config.rootPath
        includedPathsText = config.includedPaths.joined(separator: "\n")
        conflictPolicy = config.conflictPolicy
        heartbeatIntervalSeconds = config.heartbeatIntervalSeconds
        syncDebounceSeconds = config.syncDebounceSeconds
        refreshPeerSummaries()
        statusMessage = "Reloaded from disk"
        if config.isEnabled {
            service.reload(config: config)
        } else {
            service.stop()
            applySnapshot(.disabled)
        }
    }

    func save() {
        let sanitizedDisplayName = sanitized(displayName, fallback: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        let sanitizedRootPath = sanitized(rootPath)
        let sanitizedIncludedPaths = includedPathsText
            .split(whereSeparator: \.isNewline)
            .map { sanitized(String($0)) }
            .filter { !$0.isEmpty }

        let nextConfig = NetworkSyncConfig(
            isEnabled: isEnabled,
            mode: mode,
            displayName: sanitizedDisplayName,
            rootPath: sanitizedRootPath,
            includedPaths: sanitizedIncludedPaths,
            conflictPolicy: conflictPolicy,
            heartbeatIntervalSeconds: heartbeatIntervalSeconds,
            syncDebounceSeconds: syncDebounceSeconds,
            peers: config.peers
        )

        do {
            try configManager.saveNetworkSyncConfig(nextConfig)
            config = nextConfig
            displayName = nextConfig.displayName
            rootPath = nextConfig.rootPath
            includedPathsText = nextConfig.includedPaths.joined(separator: "\n")
            refreshPeerSummaries()
            statusMessage = "Saved"
            if nextConfig.isEnabled {
                service.reload(config: nextConfig)
            } else {
                service.stop()
                applySnapshot(.disabled)
            }
        } catch {
            statusMessage = error.localizedDescription
            statusDetail = error.localizedDescription
            onDidChange?()
        }
    }

    func updatePeerSummaries(with peers: [NetworkSyncPeerConfig]) {
        config.peers = peers
        refreshPeerSummaries()
    }

    func requestRefresh() {
        service.requestRefresh()
    }

    func stop() {
        service.stop()
    }

    private func bindService() {
        service.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.applySnapshot(snapshot)
            }
        }
    }

    private func applySnapshot(_ snapshot: NetworkSyncRuntimeSnapshot) {
        statusLevel = Self.statusLevel(for: snapshot.status)
        statusTitle = snapshot.status == .disabled ? "Network Sync Disabled" : "Network Sync"
        statusDetail = snapshot.detail
        statusMessage = snapshot.detail
        peers = snapshot.peers.map { peer in
            SyncPeerSummary(
                id: peer.id,
                name: peer.name,
                role: peer.role.displayName,
                status: peer.state.displayName,
                isConnected: peer.isConnected,
                isServer: peer.role == .server
            )
        }
        conflicts = snapshot.conflicts.map { conflict in
            SyncConflictSummary(
                id: conflict.id,
                relativePath: conflict.relativePath,
                detail: conflict.detail,
                timestamp: conflict.timestamp
            )
        }
        recentTransfers = snapshot.transfers.map { transfer in
            SyncTransferSummary(
                id: transfer.id,
                relativePath: transfer.relativePath,
                direction: transfer.direction == .upload ? "Upload" : "Download",
                status: transfer.status,
                progress: transfer.progress,
                detail: transfer.detail
            )
        }
        onDidChange?()
    }

    private func refreshPeerSummaries() {
        peerSummaries = config.peers.map { peer in
            NetworkSyncPeerSummary(peer: peer, formatter: peerSummaryDateFormatter)
        }
    }

    private func sanitized(_ value: String, fallback: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func statusLevel(for status: NetworkSyncRuntimeStatus) -> SyncStatusLevel {
        switch status {
        case .disabled, .offline:
            return .offline
        case .starting, .syncing:
            return .syncing
        case .idle:
            return .idle
        case .error:
            return .attention
        }
    }
}
