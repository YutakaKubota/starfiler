import Foundation

// MARK: - Peer Identity

struct SyncPeerID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

// MARK: - Peer Info

struct SyncPeerInfo: Codable, Sendable, Hashable {
    let peerID: SyncPeerID
    let displayName: String
    let isServer: Bool
    let protocolVersion: Int
    let syncRootPath: String?

    static let currentProtocolVersion = 1

    init(
        peerID: SyncPeerID = SyncPeerID(),
        displayName: String = Host.current().localizedName ?? "Unknown Mac",
        isServer: Bool,
        protocolVersion: Int = currentProtocolVersion,
        syncRootPath: String? = nil
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.isServer = isServer
        self.protocolVersion = protocolVersion
        self.syncRootPath = syncRootPath
    }
}

// MARK: - Connection State

enum SyncPeerConnectionState: Sendable, Equatable {
    case discovered
    case connecting
    case connected
    case disconnected(reason: String?)
    case rejected

    static func == (lhs: SyncPeerConnectionState, rhs: SyncPeerConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.discovered, .discovered): return true
        case (.connecting, .connecting): return true
        case (.connected, .connected): return true
        case (.disconnected(let a), .disconnected(let b)): return a == b
        case (.rejected, .rejected): return true
        default: return false
        }
    }
}

// MARK: - Connected Peer

struct SyncConnectedPeer: Sendable {
    let peerInfo: SyncPeerInfo
    var connectionState: SyncPeerConnectionState
    var lastSeen: Date

    init(peerInfo: SyncPeerInfo, connectionState: SyncPeerConnectionState = .discovered) {
        self.peerInfo = peerInfo
        self.connectionState = connectionState
        self.lastSeen = Date()
    }
}

// MARK: - Sync Node Mode

enum SyncNodeMode: String, Codable, Sendable, CaseIterable {
    case server
    case client
}

// MARK: - Conflict Strategy

enum ConflictStrategy: String, Codable, Sendable, CaseIterable {
    case lastWriterWins
    case serverWins
    case keepBoth
    case askUser

    var displayName: String {
        switch self {
        case .lastWriterWins: return "Last Writer Wins"
        case .serverWins: return "Server Wins"
        case .keepBoth: return "Keep Both"
        case .askUser: return "Ask User"
        }
    }
}

// MARK: - Peer Config (persisted)

struct SyncPeerConfig: Codable, Sendable, Hashable, Identifiable {
    var id: UUID { peerID.rawValue }
    let peerID: SyncPeerID
    var displayName: String
    var isApproved: Bool
    var selectiveSyncRules: SelectiveSyncRules?
}

// MARK: - Selective Sync Rules

struct SelectiveSyncRules: Codable, Sendable, Hashable {
    var includedPaths: [String]
    var excludeRules: [SyncExcludeRule]
    var maxFileSize: Int64?

    init(
        includedPaths: [String] = [],
        excludeRules: [SyncExcludeRule] = SyncExcludeRule.defaults,
        maxFileSize: Int64? = nil
    ) {
        self.includedPaths = includedPaths
        self.excludeRules = excludeRules
        self.maxFileSize = maxFileSize
    }
}

// MARK: - File Change

enum FileChangeType: String, Codable, Sendable {
    case created
    case modified
    case deleted
    case renamed
}

struct FileChangeMetadata: Codable, Sendable, Hashable {
    let isDirectory: Bool
    let size: Int64?
    let contentModificationDate: Date?
    let contentHash: String?
}

struct FileChangeEvent: Sendable {
    let relativePath: String
    let changeType: FileChangeType
    let metadata: FileChangeMetadata?
}

// MARK: - Sync Engine Status

enum SyncEngineStatus: Sendable, Equatable {
    case idle
    case scanning
    case syncing(itemsRemaining: Int)
    case error(String)
    case paused
}

// MARK: - Sync Conflict

struct SyncConflict: Sendable, Identifiable {
    let id: UUID
    let relativePath: String
    let localMetadata: FileChangeMetadata
    let remoteMetadata: FileChangeMetadata
    let remotePeerInfo: SyncPeerInfo
    var resolution: SyncConflictResolution?

    init(
        relativePath: String,
        localMetadata: FileChangeMetadata,
        remoteMetadata: FileChangeMetadata,
        remotePeerInfo: SyncPeerInfo
    ) {
        self.id = UUID()
        self.relativePath = relativePath
        self.localMetadata = localMetadata
        self.remoteMetadata = remoteMetadata
        self.remotePeerInfo = remotePeerInfo
        self.resolution = nil
    }
}

enum SyncConflictResolution: String, Codable, Sendable {
    case keepLocal
    case keepRemote
    case keepBoth
}

// MARK: - Transfer Progress

struct SyncTransferProgress: Sendable {
    let relativePath: String
    let totalBytes: Int64
    var transferredBytes: Int64
    let direction: SyncTransferDirection

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }
}

enum SyncTransferDirection: Sendable {
    case uploading
    case downloading
}

// MARK: - Peer Events

enum SyncPeerEvent: Sendable {
    case discovered(SyncPeerInfo)
    case lost(SyncPeerID)
    case connectionStateChanged(SyncPeerID, SyncPeerConnectionState)
}
