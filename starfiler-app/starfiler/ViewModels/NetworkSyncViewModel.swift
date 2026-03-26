import Foundation
import Observation

@MainActor
@Observable
final class NetworkSyncViewModel {
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

    private let configManager: ConfigManager
    private let peerSummaryDateFormatter: DateFormatter
    private var config: NetworkSyncConfig

    init(configManager: ConfigManager = ConfigManager()) {
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
        self.statusMessage = "Not saved yet"

        refreshPeerSummaries()
        statusMessage = loadedConfig.isEnabled ? "Sync is enabled" : "Sync is disabled"
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
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func updatePeerSummaries(with peers: [NetworkSyncPeerConfig]) {
        config.peers = peers
        refreshPeerSummaries()
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
}
