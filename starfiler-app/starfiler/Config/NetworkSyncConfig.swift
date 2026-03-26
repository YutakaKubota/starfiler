import Foundation

enum SyncNodeMode: String, Codable, CaseIterable, Sendable {
    case server
    case client

    var displayName: String {
        switch self {
        case .server:
            "Server"
        case .client:
            "Client"
        }
    }
}

extension SyncNodeMode {
    var rootPathDescription: String {
        switch self {
        case .server:
            return "Authoritative sync root on the server Mac, typically on the external drive."
        case .client:
            return "Local sync folder on this Mac. Checked items are downloaded here."
        }
    }
}

enum NetworkSyncConflictPolicy: String, Codable, CaseIterable, Sendable {
    case keepBoth
    case serverWins
    case lastWriterWins

    var displayName: String {
        switch self {
        case .keepBoth:
            "Keep Both"
        case .serverWins:
            "Server Wins"
        case .lastWriterWins:
            "Last Writer Wins"
        }
    }
}

enum NetworkSyncPeerRole: String, Codable, Sendable {
    case server
    case client

    var displayName: String {
        switch self {
        case .server:
            "Server"
        case .client:
            "Client"
        }
    }
}

enum NetworkSyncPeerState: String, Codable, Sendable {
    case discovered
    case connected
    case paused
    case offline
    case rejected

    var displayName: String {
        switch self {
        case .discovered:
            "Discovered"
        case .connected:
            "Connected"
        case .paused:
            "Paused"
        case .offline:
            "Offline"
        case .rejected:
            "Rejected"
        }
    }
}

struct SelectiveSyncRules: Codable, Hashable, Sendable {
    var includedPaths: [String]
    var excludeRules: [SyncExcludeRule]

    init(
        includedPaths: [String] = [],
        excludeRules: [SyncExcludeRule] = SyncExcludeRule.defaults
    ) {
        self.includedPaths = includedPaths
        self.excludeRules = excludeRules
    }
}

struct NetworkSyncPeerConfig: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var hostname: String
    var role: NetworkSyncPeerRole
    var state: NetworkSyncPeerState
    var selectedRootPath: String?
    var lastSeenAt: Date?
    var notes: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        role: NetworkSyncPeerRole = .client,
        state: NetworkSyncPeerState = .discovered,
        selectedRootPath: String? = nil,
        lastSeenAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.role = role
        self.state = state
        self.selectedRootPath = selectedRootPath
        self.lastSeenAt = lastSeenAt
        self.notes = notes
    }
}

struct NetworkSyncPeerSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let detail: String

    init(peer: NetworkSyncPeerConfig, formatter: DateFormatter) {
        id = peer.id
        title = peer.displayName
        subtitle = "\(peer.role.displayName) • \(peer.state.displayName)"
        let lastSeen = peer.lastSeenAt.map { formatter.string(from: $0) } ?? "Never"
        let root = peer.selectedRootPath?.isEmpty == false ? peer.selectedRootPath! : "No root selected"
        let note = peer.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = [
            peer.hostname,
            "Last seen: \(lastSeen)",
            "Root: \(root)",
            note.flatMap { $0.isEmpty ? nil : $0 },
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}

struct NetworkSyncRoleRuntimeConfig: Sendable {
    var role: SyncNodeMode
    var isEnabled: Bool
    var displayName: String
    var discoveryScope: String
    var rootPath: String
    var syncEntireRoot: Bool
    var includedPaths: [String]
    var conflictPolicy: NetworkSyncConflictPolicy
    var heartbeatIntervalSeconds: Double
    var syncDebounceSeconds: Double

    var effectiveDiscoveryScope: String {
        let trimmed = discoveryScope.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    var advertisedServiceName: String {
        "[\(effectiveDiscoveryScope)] \(displayName)"
    }

    var effectiveRootPath: String {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if role == .client {
            return NetworkSyncConfig.defaultClientRootPath
        }
        return ""
    }
}

struct NetworkSyncConfig: Codable, Sendable {
    var displayName: String
    var discoveryScope: String
    var serverEnabled: Bool
    var serverRootPath: String
    var clientEnabled: Bool
    var clientRootPath: String
    var clientSyncEntireRoot: Bool
    var clientIncludedPaths: [String]
    var conflictPolicy: NetworkSyncConflictPolicy
    var heartbeatIntervalSeconds: Double
    var syncDebounceSeconds: Double
    var peers: [NetworkSyncPeerConfig]

    static var defaultClientRootPath: String {
        "~/StarFilerSync"
    }

    var isEnabled: Bool {
        serverEnabled || clientEnabled
    }

    var effectiveDiscoveryScope: String {
        let trimmed = discoveryScope.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    var serverEffectiveRootPath: String {
        let trimmed = serverRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    var clientEffectiveRootPath: String {
        let trimmed = clientRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultClientRootPath : trimmed
    }

    init(
        displayName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        discoveryScope: String = "default",
        serverEnabled: Bool = false,
        serverRootPath: String = "",
        clientEnabled: Bool = false,
        clientRootPath: String = Self.defaultClientRootPath,
        clientSyncEntireRoot: Bool = true,
        clientIncludedPaths: [String] = [],
        conflictPolicy: NetworkSyncConflictPolicy = .keepBoth,
        heartbeatIntervalSeconds: Double = 30,
        syncDebounceSeconds: Double = 1,
        peers: [NetworkSyncPeerConfig] = []
    ) {
        self.displayName = displayName
        self.discoveryScope = discoveryScope
        self.serverEnabled = serverEnabled
        self.serverRootPath = serverRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientEnabled = clientEnabled
        let trimmedClientRootPath = clientRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientRootPath = trimmedClientRootPath.isEmpty ? Self.defaultClientRootPath : trimmedClientRootPath
        self.clientSyncEntireRoot = clientSyncEntireRoot
        self.clientIncludedPaths = clientIncludedPaths
        self.conflictPolicy = conflictPolicy
        self.heartbeatIntervalSeconds = max(5, heartbeatIntervalSeconds)
        self.syncDebounceSeconds = max(0.2, syncDebounceSeconds)
        self.peers = peers
    }

    func runtimeConfig(for role: SyncNodeMode) -> NetworkSyncRoleRuntimeConfig {
        switch role {
        case .server:
            return NetworkSyncRoleRuntimeConfig(
                role: .server,
                isEnabled: serverEnabled,
                displayName: displayName,
                discoveryScope: effectiveDiscoveryScope,
                rootPath: serverEffectiveRootPath,
                syncEntireRoot: true,
                includedPaths: [],
                conflictPolicy: conflictPolicy,
                heartbeatIntervalSeconds: heartbeatIntervalSeconds,
                syncDebounceSeconds: syncDebounceSeconds
            )
        case .client:
            return NetworkSyncRoleRuntimeConfig(
                role: .client,
                isEnabled: clientEnabled,
                displayName: displayName,
                discoveryScope: effectiveDiscoveryScope,
                rootPath: clientEffectiveRootPath,
                syncEntireRoot: clientSyncEntireRoot,
                includedPaths: clientIncludedPaths,
                conflictPolicy: conflictPolicy,
                heartbeatIntervalSeconds: heartbeatIntervalSeconds,
                syncDebounceSeconds: syncDebounceSeconds
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case discoveryScope
        case serverEnabled
        case serverRootPath
        case clientEnabled
        case clientRootPath
        case clientSyncEntireRoot
        case clientIncludedPaths
        case conflictPolicy
        case heartbeatIntervalSeconds
        case syncDebounceSeconds
        case peers

        case isEnabled
        case mode
        case rootPath
        case syncEntireRoot
        case includedPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let legacyDisplayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        let legacyDiscoveryScope = try container.decodeIfPresent(String.self, forKey: .discoveryScope) ?? "default"
        let legacyConflictPolicy = try container.decodeIfPresent(NetworkSyncConflictPolicy.self, forKey: .conflictPolicy) ?? .keepBoth
        let legacyHeartbeat = try container.decodeIfPresent(Double.self, forKey: .heartbeatIntervalSeconds) ?? 30
        let legacyDebounce = try container.decodeIfPresent(Double.self, forKey: .syncDebounceSeconds) ?? 1
        let legacyPeers = try container.decodeIfPresent([NetworkSyncPeerConfig].self, forKey: .peers) ?? []

        if container.contains(.serverEnabled) || container.contains(.clientEnabled) {
            self.init(
                displayName: legacyDisplayName,
                discoveryScope: legacyDiscoveryScope,
                serverEnabled: try container.decodeIfPresent(Bool.self, forKey: .serverEnabled) ?? false,
                serverRootPath: try container.decodeIfPresent(String.self, forKey: .serverRootPath) ?? "",
                clientEnabled: try container.decodeIfPresent(Bool.self, forKey: .clientEnabled) ?? false,
                clientRootPath: try container.decodeIfPresent(String.self, forKey: .clientRootPath) ?? Self.defaultClientRootPath,
                clientSyncEntireRoot: try container.decodeIfPresent(Bool.self, forKey: .clientSyncEntireRoot) ?? true,
                clientIncludedPaths: try container.decodeIfPresent([String].self, forKey: .clientIncludedPaths) ?? [],
                conflictPolicy: legacyConflictPolicy,
                heartbeatIntervalSeconds: legacyHeartbeat,
                syncDebounceSeconds: legacyDebounce,
                peers: legacyPeers
            )
            return
        }

        let legacyMode = try container.decodeIfPresent(SyncNodeMode.self, forKey: .mode) ?? .server
        let legacyIsEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let legacyRootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) ?? ""
        let legacyIncludedPaths = try container.decodeIfPresent([String].self, forKey: .includedPaths) ?? []
        let legacySyncEntireRoot = try container.decodeIfPresent(Bool.self, forKey: .syncEntireRoot) ?? legacyIncludedPaths.isEmpty

        self.init(
            displayName: legacyDisplayName,
            discoveryScope: legacyDiscoveryScope,
            serverEnabled: legacyMode == .server ? legacyIsEnabled : false,
            serverRootPath: legacyMode == .server ? legacyRootPath : "",
            clientEnabled: legacyMode == .client ? legacyIsEnabled : false,
            clientRootPath: legacyMode == .client ? legacyRootPath : Self.defaultClientRootPath,
            clientSyncEntireRoot: legacyMode == .client ? legacySyncEntireRoot : true,
            clientIncludedPaths: legacyMode == .client ? legacyIncludedPaths : [],
            conflictPolicy: legacyConflictPolicy,
            heartbeatIntervalSeconds: legacyHeartbeat,
            syncDebounceSeconds: legacyDebounce,
            peers: legacyPeers
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(effectiveDiscoveryScope, forKey: .discoveryScope)
        try container.encode(serverEnabled, forKey: .serverEnabled)
        try container.encode(serverRootPath, forKey: .serverRootPath)
        try container.encode(clientEnabled, forKey: .clientEnabled)
        try container.encode(clientEffectiveRootPath, forKey: .clientRootPath)
        try container.encode(clientSyncEntireRoot, forKey: .clientSyncEntireRoot)
        try container.encode(clientIncludedPaths, forKey: .clientIncludedPaths)
        try container.encode(conflictPolicy, forKey: .conflictPolicy)
        try container.encode(heartbeatIntervalSeconds, forKey: .heartbeatIntervalSeconds)
        try container.encode(syncDebounceSeconds, forKey: .syncDebounceSeconds)
        try container.encode(peers, forKey: .peers)
    }
}
