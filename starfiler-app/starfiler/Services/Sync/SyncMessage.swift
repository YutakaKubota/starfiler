import Foundation

// MARK: - Wire Protocol Messages

enum SyncMessage: Codable, Sendable {
    case handshake(HandshakePayload)
    case handshakeAck(HandshakeAckPayload)
    case heartbeat(HeartbeatPayload)
    case disconnect(DisconnectPayload)
    case changeNotification(ChangeNotificationPayload)
    case changeAck(ChangeAckPayload)
    case fileRequest(FileRequestPayload)
    case fileHeader(FileHeaderPayload)
    case fileChunk(FileChunkPayload)
    case fileComplete(FileCompletePayload)
    case fileDeletion(FileDeletionPayload)
    case selectiveSyncUpdate(SelectiveSyncUpdatePayload)
    case stateSnapshotRequest(StateSnapshotRequestPayload)
    case stateSnapshot(StateSnapshotPayload)
    case conflictReport(ConflictReportPayload)
    case conflictResolution(ConflictResolutionPayload)
}

// MARK: - Payloads

struct HandshakePayload: Codable, Sendable {
    let peerInfo: SyncPeerInfo
    let requestedSyncRoot: String?
}

struct HandshakeAckPayload: Codable, Sendable {
    let peerInfo: SyncPeerInfo
    let accepted: Bool
    let reason: String?
    let syncRootPath: String?
}

struct HeartbeatPayload: Codable, Sendable {
    let timestamp: Date
    let syncVersion: UInt64
}

struct DisconnectPayload: Codable, Sendable {
    let reason: String?
}

struct ChangeNotificationPayload: Codable, Sendable {
    let changes: [SyncFileChange]
    let syncVersion: UInt64
}

struct SyncFileChange: Codable, Sendable {
    let relativePath: String
    let changeType: FileChangeType
    let metadata: FileChangeMetadata?
    let syncVersion: UInt64
}

struct ChangeAckPayload: Codable, Sendable {
    let acknowledgedVersion: UInt64
    let requestedFiles: [String]
}

struct FileRequestPayload: Codable, Sendable {
    let relativePath: String
    let fromOffset: Int64
}

struct FileHeaderPayload: Codable, Sendable {
    let relativePath: String
    let totalSize: Int64
    let contentHash: String?
    let isDirectory: Bool
    let contentModificationDate: Date?
    let permissions: UInt16?
}

struct FileChunkPayload: Codable, Sendable {
    let relativePath: String
    let offset: Int64
    let data: Data
    let isLastChunk: Bool
}

struct FileCompletePayload: Codable, Sendable {
    let relativePath: String
    let success: Bool
    let error: String?
    let syncVersion: UInt64
}

struct FileDeletionPayload: Codable, Sendable {
    let relativePath: String
    let syncVersion: UInt64
    let isDirectory: Bool
}

struct SelectiveSyncUpdatePayload: Codable, Sendable {
    let rules: SelectiveSyncRules
    let peerID: SyncPeerID
}

struct StateSnapshotRequestPayload: Codable, Sendable {
    let sinceVersion: UInt64?
}

struct StateSnapshotPayload: Codable, Sendable {
    let entries: [StateSnapshotEntry]
    let currentVersion: UInt64
}

struct StateSnapshotEntry: Codable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let size: Int64?
    let contentModificationDate: Date?
    let contentHash: String?
    let syncVersion: UInt64
    let isDeleted: Bool
}

struct ConflictReportPayload: Codable, Sendable {
    let relativePath: String
    let localMetadata: FileChangeMetadata
    let remoteMetadata: FileChangeMetadata
    let localSyncVersion: UInt64
    let remoteSyncVersion: UInt64
}

struct ConflictResolutionPayload: Codable, Sendable {
    let relativePath: String
    let resolution: SyncConflictResolution
    let syncVersion: UInt64
}
