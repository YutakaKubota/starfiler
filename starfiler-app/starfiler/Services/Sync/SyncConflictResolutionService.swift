import Foundation
import OSLog

private let logger = Logger(subsystem: "com.nilone.starfiler.sync", category: "Conflict")

// MARK: - Protocol

protocol SyncConflictResolving: Sendable {
    func resolve(
        conflict: SyncDeltaConflict,
        strategy: ConflictStrategy,
        localPeerID: SyncPeerID,
        remotePeerID: SyncPeerID
    ) async -> SyncConflictResolution?
}

// MARK: - Implementation

actor SyncConflictResolutionService: SyncConflictResolving {

    func resolve(
        conflict: SyncDeltaConflict,
        strategy: ConflictStrategy,
        localPeerID: SyncPeerID,
        remotePeerID: SyncPeerID
    ) async -> SyncConflictResolution? {
        // Same content hash means no real conflict
        if let localHash = conflict.localMetadata.contentHash,
           let remoteHash = conflict.remoteMetadata.contentHash,
           localHash == remoteHash {
            logger.info("Auto-resolved conflict for \(conflict.relativePath, privacy: .public): identical content")
            return .keepLocal
        }

        switch strategy {
        case .lastWriterWins:
            return resolveByTimestamp(conflict: conflict)

        case .serverWins:
            // If we're the server, keep local; otherwise keep remote
            // Use Lamport clock (syncVersion) as tiebreaker
            if conflict.localVersion >= conflict.remoteVersion {
                logger.info("Conflict resolved (serverWins, local): \(conflict.relativePath, privacy: .public)")
                return .keepLocal
            } else {
                logger.info("Conflict resolved (serverWins, remote): \(conflict.relativePath, privacy: .public)")
                return .keepRemote
            }

        case .keepBoth:
            logger.info("Conflict resolved (keepBoth): \(conflict.relativePath, privacy: .public)")
            return .keepBoth

        case .askUser:
            logger.info("Conflict requires user input: \(conflict.relativePath, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private

    private func resolveByTimestamp(conflict: SyncDeltaConflict) -> SyncConflictResolution {
        let localDate = conflict.localMetadata.contentModificationDate ?? .distantPast
        let remoteDate = conflict.remoteMetadata.contentModificationDate ?? .distantPast

        if localDate >= remoteDate {
            logger.info("Conflict resolved (lastWriterWins, local newer): \(conflict.relativePath, privacy: .public)")
            return .keepLocal
        } else {
            logger.info("Conflict resolved (lastWriterWins, remote newer): \(conflict.relativePath, privacy: .public)")
            return .keepRemote
        }
    }
}
