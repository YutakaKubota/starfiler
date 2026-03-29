import CryptoKit
import Foundation

// MARK: - Diffing and Comparison

extension NetworkSyncService {
    func diff(old: [String: NetworkSyncFileEntry], new: [String: NetworkSyncFileEntry]) -> [LocalDiff] {
        let keys = Set(old.keys).union(new.keys)
        return keys.sorted().compactMap { path in
            switch (old[path], new[path]) {
            case (_, let next?) where !metadataEquivalent(old[path], next):
                return .upsert(next)
            case (let previous?, nil):
                if previous.deleted {
                    return nil
                }
                return .delete(path)
            default:
                return nil
            }
        }
    }

    func diffAgainstKnown(known: [String: NetworkSyncFileEntry], local: [String: NetworkSyncFileEntry]) -> [LocalDiff] {
        let keys = Set(known.keys).union(local.keys)
        return keys.sorted().compactMap { path in
            let knownEntry = known[path]
            let localEntry = local[path]
            switch (knownEntry, localEntry) {
            case (let knownEntry?, let localEntry?):
                return metadataEquivalent(knownEntry, localEntry) ? nil : .upsert(localEntry)
            case (nil, let localEntry?):
                return .upsert(localEntry)
            case (let knownEntry?, nil):
                return knownEntry.deleted ? nil : .delete(path)
            case (nil, nil):
                return nil
            }
        }
    }

    func hasUnsyncedLocalChange(
        path: String,
        currentLocal: [String: NetworkSyncFileEntry],
        materializedPaths: Set<String>,
        pendingDeletionPaths: Set<String>
    ) -> Bool {
        let knownEntry = clientState.knownEntries[path]
        let localEntry = currentLocal[path]
        switch (knownEntry, localEntry) {
        case (let knownEntry?, let localEntry?):
            return !metadataEquivalent(knownEntry, localEntry)
        case (nil, let localEntry?):
            return !localEntry.deleted
        case (let knownEntry?, nil):
            if hasPendingDeletion(for: path, pendingDeletionPaths: pendingDeletionPaths) {
                return true
            }
            guard materializedPaths.contains(path) else {
                return false
            }
            return !knownEntry.deleted
        case (nil, nil):
            return false
        }
    }

    func metadataEquivalent(_ lhs: NetworkSyncFileEntry?, _ rhs: NetworkSyncFileEntry?) -> Bool {
        guard let lhs, let rhs else {
            return lhs == nil && rhs == nil
        }

        if lhs.isDirectory && rhs.isDirectory {
            return lhs.relativePath == rhs.relativePath &&
                lhs.deleted == rhs.deleted
        }

        if let lhsHash = lhs.contentHash, let rhsHash = rhs.contentHash {
            return lhs.relativePath == rhs.relativePath &&
                lhs.isDirectory == rhs.isDirectory &&
                lhs.size == rhs.size &&
                lhs.deleted == rhs.deleted &&
                lhsHash == rhsHash
        }

        return lhs.relativePath == rhs.relativePath &&
            lhs.isDirectory == rhs.isDirectory &&
            lhs.size == rhs.size &&
            abs(lhs.modificationTimestamp - rhs.modificationTimestamp) < 1 &&
            lhs.deleted == rhs.deleted &&
            lhs.contentHash == rhs.contentHash
    }

    func hasPendingDeletion(for path: String, pendingDeletionPaths: Set<String>) -> Bool {
        pendingDeletionPaths.contains { pendingPath in
            path == pendingPath || path.hasPrefix(pendingPath + "/")
        }
    }

    func clearPendingDeletion(at path: String) {
        clientState.clearPendingDeletion(at: path)
    }

    func clearPendingDeletionTree(at path: String) {
        clientState.clearPendingDeletionTree(at: path)
    }

    func shouldSyncPath(_ relativePath: String, syncEntireRoot: Bool, includedPaths: [String]) -> Bool {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            return false
        }
        guard !syncEntireRoot else {
            return true
        }
        return includedPaths.map(normalizeRelativePath).contains { include in
            normalizedPath == include || normalizedPath.hasPrefix(include + "/")
        }
    }

    func normalizeRelativePath(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    func scanEntries(at rootURL: URL) async throws -> [String: NetworkSyncFileEntry] {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let entries = try await executionContext.scanEntries(
            at: rootURL,
            syncEntireRoot: config.syncEntireRoot,
            includedPaths: config.includedPaths,
            fileHashThresholdBytes: fileHashThresholdBytes
        )
        logDuration("scanEntries", startedAt: startedAt)
        return entries
    }

    func scanAllLocalRelativePaths(at rootURL: URL) async throws -> [String] {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let paths = try await executionContext.scanAllLocalRelativePaths(at: rootURL)
        logDuration("scanAllLocalRelativePaths", startedAt: startedAt)
        return paths
    }

    func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Private Helpers

private extension NetworkSyncService {
    func matchesExcludeRules(relativePath: String) -> Bool {
        for rule in SyncExcludeRule.defaults where rule.isEnabled {
            let pattern = rule.pattern
            let basename = URL(fileURLWithPath: relativePath).lastPathComponent
            if NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: basename) ||
                NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: relativePath) {
                return true
            }
        }
        return false
    }

    func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let trimmed = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : filePath
        return normalizeRelativePath(trimmed)
    }

    func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
