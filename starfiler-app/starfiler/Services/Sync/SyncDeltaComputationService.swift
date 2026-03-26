import Foundation
import OSLog

private let logger = Logger(subsystem: "com.nilone.starfiler.sync", category: "Delta")

// MARK: - Protocol

protocol SyncDeltaComputing: Sendable {
    func computeDelta(
        localChanges: [FileChangeEvent],
        remoteChanges: [SyncFileChange],
        localStates: [SyncFileState],
        rules: SelectiveSyncRules?
    ) async -> SyncDelta
}

// MARK: - Delta Result

struct SyncDelta: Sendable {
    let filesToUpload: [SyncDeltaEntry]
    let filesToDownload: [SyncDeltaEntry]
    let filesToDelete: [SyncDeltaEntry]
    let conflicts: [SyncDeltaConflict]

    var isEmpty: Bool {
        filesToUpload.isEmpty && filesToDownload.isEmpty && filesToDelete.isEmpty && conflicts.isEmpty
    }

    var totalItems: Int {
        filesToUpload.count + filesToDownload.count + filesToDelete.count
    }
}

struct SyncDeltaEntry: Sendable {
    let relativePath: String
    let isDirectory: Bool
    let size: Int64?
    let contentModificationDate: Date?
    let contentHash: String?
    let syncVersion: UInt64
}

struct SyncDeltaConflict: Sendable {
    let relativePath: String
    let localMetadata: FileChangeMetadata
    let remoteMetadata: FileChangeMetadata
    let localVersion: UInt64
    let remoteVersion: UInt64
}

// MARK: - Implementation

actor SyncDeltaComputationService: SyncDeltaComputing {

    func computeDelta(
        localChanges: [FileChangeEvent],
        remoteChanges: [SyncFileChange],
        localStates: [SyncFileState],
        rules: SelectiveSyncRules?
    ) async -> SyncDelta {

        let stateMap = Dictionary(
            localStates.map { ($0.relativePath, $0) },
            uniquingKeysWith: { _, new in new }
        )

        var filesToUpload: [SyncDeltaEntry] = []
        var filesToDownload: [SyncDeltaEntry] = []
        var filesToDelete: [SyncDeltaEntry] = []
        var conflicts: [SyncDeltaConflict] = []

        // Build sets for cross-referencing
        let localChangedPaths = Set(localChanges.map(\.relativePath))
        let remoteChangedPaths = Set(remoteChanges.map(\.relativePath))

        // Process remote changes
        for remoteChange in remoteChanges {
            let path = remoteChange.relativePath

            // Check selective sync rules
            if let rules, !isPathIncluded(path, rules: rules) {
                continue
            }
            if let rules, isPathExcluded(path, rules: rules) {
                continue
            }
            if let rules, let maxSize = rules.maxFileSize,
               let size = remoteChange.metadata?.size, size > maxSize {
                continue
            }

            if localChangedPaths.contains(path) {
                // Both sides changed — conflict
                if let localChange = localChanges.first(where: { $0.relativePath == path }) {
                    let localMeta = localChange.metadata ?? FileChangeMetadata(isDirectory: false, size: nil, contentModificationDate: nil, contentHash: nil)
                    let remoteMeta = remoteChange.metadata ?? FileChangeMetadata(isDirectory: false, size: nil, contentModificationDate: nil, contentHash: nil)

                    // Same hash = no conflict
                    if let localHash = localMeta.contentHash,
                       let remoteHash = remoteMeta.contentHash,
                       localHash == remoteHash {
                        continue
                    }

                    conflicts.append(SyncDeltaConflict(
                        relativePath: path,
                        localMetadata: localMeta,
                        remoteMetadata: remoteMeta,
                        localVersion: stateMap[path]?.syncVersion ?? 0,
                        remoteVersion: remoteChange.syncVersion
                    ))
                }
            } else {
                // Only remote changed
                switch remoteChange.changeType {
                case .deleted:
                    filesToDelete.append(SyncDeltaEntry(
                        relativePath: path,
                        isDirectory: remoteChange.metadata?.isDirectory ?? false,
                        size: nil,
                        contentModificationDate: nil,
                        contentHash: nil,
                        syncVersion: remoteChange.syncVersion
                    ))
                case .created, .modified, .renamed:
                    filesToDownload.append(SyncDeltaEntry(
                        relativePath: path,
                        isDirectory: remoteChange.metadata?.isDirectory ?? false,
                        size: remoteChange.metadata?.size,
                        contentModificationDate: remoteChange.metadata?.contentModificationDate,
                        contentHash: remoteChange.metadata?.contentHash,
                        syncVersion: remoteChange.syncVersion
                    ))
                }
            }
        }

        // Process local-only changes (upload)
        for localChange in localChanges {
            let path = localChange.relativePath

            if remoteChangedPaths.contains(path) {
                continue // Already handled above
            }

            if let rules, !isPathIncluded(path, rules: rules) {
                continue
            }
            if let rules, isPathExcluded(path, rules: rules) {
                continue
            }
            if let rules, let maxSize = rules.maxFileSize,
               let size = localChange.metadata?.size, size > maxSize {
                continue
            }

            switch localChange.changeType {
            case .deleted:
                filesToDelete.append(SyncDeltaEntry(
                    relativePath: path,
                    isDirectory: localChange.metadata?.isDirectory ?? false,
                    size: nil,
                    contentModificationDate: nil,
                    contentHash: nil,
                    syncVersion: stateMap[path]?.syncVersion ?? 0
                ))
            case .created, .modified, .renamed:
                filesToUpload.append(SyncDeltaEntry(
                    relativePath: path,
                    isDirectory: localChange.metadata?.isDirectory ?? false,
                    size: localChange.metadata?.size,
                    contentModificationDate: localChange.metadata?.contentModificationDate,
                    contentHash: localChange.metadata?.contentHash,
                    syncVersion: stateMap[path]?.syncVersion ?? 0
                ))
            }
        }

        logger.info("Delta computed: \(filesToUpload.count) upload, \(filesToDownload.count) download, \(filesToDelete.count) delete, \(conflicts.count) conflicts")

        return SyncDelta(
            filesToUpload: filesToUpload,
            filesToDownload: filesToDownload,
            filesToDelete: filesToDelete,
            conflicts: conflicts
        )
    }

    // MARK: - Selective Sync Filtering

    private func isPathIncluded(_ path: String, rules: SelectiveSyncRules) -> Bool {
        guard !rules.includedPaths.isEmpty else { return true }
        return rules.includedPaths.contains { includedPath in
            path.hasPrefix(includedPath) || includedPath.hasPrefix(path)
        }
    }

    private func isPathExcluded(_ path: String, rules: SelectiveSyncRules) -> Bool {
        for rule in rules.excludeRules where rule.isEnabled {
            if matchesPattern(path, pattern: rule.pattern) {
                return true
            }
        }
        return false
    }

    private func matchesPattern(_ path: String, pattern: String) -> Bool {
        let fileName = (path as NSString).lastPathComponent

        if pattern.hasPrefix("*.") {
            let ext = String(pattern.dropFirst(2))
            return fileName.hasSuffix(".\(ext)")
        }

        return fileName == pattern || path == pattern
    }
}
