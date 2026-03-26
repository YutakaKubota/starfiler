import Foundation

enum NetworkSyncTransferDirection: String, Codable, Sendable {
    case upload
    case download
}

enum NetworkSyncRuntimeStatus: String, Codable, Sendable {
    case disabled
    case starting
    case idle
    case syncing
    case offline
    case error
}

struct NetworkSyncFileEntry: Codable, Hashable, Sendable {
    var relativePath: String
    var isDirectory: Bool
    var size: Int64
    var modificationTimestamp: TimeInterval
    var contentHash: String?
    var revision: Int
    var deleted: Bool
}

struct NetworkSyncPeerRuntime: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var role: NetworkSyncPeerRole
    var state: NetworkSyncPeerState
    var hostname: String
    var isConnected: Bool
    var lastSeenAt: Date?
}

struct NetworkSyncConflictRecord: Identifiable, Hashable, Sendable {
    var id: String
    var relativePath: String
    var detail: String
    var timestamp: Date
}

struct NetworkSyncTransferRecord: Identifiable, Hashable, Sendable {
    var id: String
    var relativePath: String
    var direction: NetworkSyncTransferDirection
    var status: String
    var progress: Double?
    var detail: String
    var timestamp: Date
}

struct NetworkSyncRuntimeSnapshot: Sendable {
    var status: NetworkSyncRuntimeStatus
    var detail: String
    var peers: [NetworkSyncPeerRuntime]
    var conflicts: [NetworkSyncConflictRecord]
    var transfers: [NetworkSyncTransferRecord]

    static let disabled = NetworkSyncRuntimeSnapshot(
        status: .disabled,
        detail: "Network sync is disabled.",
        peers: [],
        conflicts: [],
        transfers: []
    )
}

struct NetworkSyncHelloPayload: Codable, Sendable {
    var deviceID: UUID
    var displayName: String
    var mode: SyncNodeMode
    var protocolVersion: Int
    var includedPaths: [String]
}

struct NetworkSyncStateRequestPayload: Codable, Sendable {
    var includedPaths: [String]
}

struct NetworkSyncStateSnapshotPayload: Codable, Sendable {
    var entries: [NetworkSyncFileEntry]
}

struct NetworkSyncFileRequestPayload: Codable, Sendable {
    var relativePath: String
}

struct NetworkSyncFileTransferStartPayload: Codable, Sendable {
    var transferID: UUID
    var relativePath: String
    var isDirectory: Bool
    var revision: Int
    var baseRevision: Int
    var modificationTimestamp: TimeInterval
    var totalBytes: Int64
    var originDeviceID: UUID
}

struct NetworkSyncFileTransferChunkPayload: Codable, Sendable {
    var transferID: UUID
    var data: Data
}

struct NetworkSyncFileTransferEndPayload: Codable, Sendable {
    var transferID: UUID
    var contentHash: String?
}

struct NetworkSyncDeletePayload: Codable, Sendable {
    var relativePath: String
    var baseRevision: Int
    var revision: Int
    var originDeviceID: UUID
}

struct NetworkSyncConflictPayload: Codable, Sendable {
    var relativePath: String
    var conflictPath: String
    var detail: String
}

struct NetworkSyncErrorPayload: Codable, Sendable {
    var detail: String
}

enum NetworkSyncMessageKind: String, Codable, Sendable {
    case hello
    case stateRequest
    case stateSnapshot
    case fileRequest
    case fileTransferStart
    case fileTransferChunk
    case fileTransferEnd
    case delete
    case conflict
    case heartbeat
    case error
}

struct NetworkSyncEnvelope: Codable, Sendable {
    var kind: NetworkSyncMessageKind
    var payload: Data

    static func make<T: Encodable>(_ kind: NetworkSyncMessageKind, payload: T, encoder: JSONEncoder) throws -> NetworkSyncEnvelope {
        NetworkSyncEnvelope(kind: kind, payload: try encoder.encode(payload))
    }

    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder) throws -> T {
        try decoder.decode(type, from: payload)
    }
}

struct NetworkSyncServerState: Codable, Sendable {
    var nextRevision: Int
    var entries: [String: NetworkSyncFileEntry]

    init(nextRevision: Int = 1, entries: [String: NetworkSyncFileEntry] = [:]) {
        self.nextRevision = nextRevision
        self.entries = entries
    }
}

struct NetworkSyncClientState: Codable, Sendable {
    var knownEntries: [String: NetworkSyncFileEntry]
    var materializedPaths: Set<String>

    init(
        knownEntries: [String: NetworkSyncFileEntry] = [:],
        materializedPaths: Set<String> = []
    ) {
        self.knownEntries = knownEntries
        self.materializedPaths = materializedPaths
    }

    private enum CodingKeys: String, CodingKey {
        case knownEntries
        case materializedPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        knownEntries = try container.decodeIfPresent([String: NetworkSyncFileEntry].self, forKey: .knownEntries) ?? [:]
        materializedPaths = try container.decodeIfPresent(Set<String>.self, forKey: .materializedPaths) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(knownEntries, forKey: .knownEntries)
        try container.encode(materializedPaths, forKey: .materializedPaths)
    }
}
