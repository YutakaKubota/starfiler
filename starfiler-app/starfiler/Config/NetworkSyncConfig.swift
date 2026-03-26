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

struct NetworkSyncConfig: Codable, Sendable {
    var isEnabled: Bool
    var mode: SyncNodeMode
    var displayName: String
    var discoveryScope: String
    var rootPath: String
    var includedPaths: [String]
    var conflictPolicy: NetworkSyncConflictPolicy
    var heartbeatIntervalSeconds: Double
    var syncDebounceSeconds: Double
    var peers: [NetworkSyncPeerConfig]

    static var defaultClientRootPath: String {
        UserPaths.homeDirectoryPath + "/StarFilerSync"
    }

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
        if mode == .client {
            return Self.defaultClientRootPath
        }
        return ""
    }

    init(
        isEnabled: Bool = false,
        mode: SyncNodeMode = .server,
        displayName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        discoveryScope: String = "default",
        rootPath: String = "",
        includedPaths: [String] = [],
        conflictPolicy: NetworkSyncConflictPolicy = .keepBoth,
        heartbeatIntervalSeconds: Double = 30,
        syncDebounceSeconds: Double = 1,
        peers: [NetworkSyncPeerConfig] = []
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.displayName = displayName
        self.discoveryScope = discoveryScope
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rootPath = trimmedRootPath.isEmpty && mode == .client ? Self.defaultClientRootPath : rootPath
        self.includedPaths = includedPaths
        self.conflictPolicy = conflictPolicy
        self.heartbeatIntervalSeconds = max(5, heartbeatIntervalSeconds)
        self.syncDebounceSeconds = max(0.2, syncDebounceSeconds)
        self.peers = peers
    }
}
