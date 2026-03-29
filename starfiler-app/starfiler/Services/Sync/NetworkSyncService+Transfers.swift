import Foundation
import Network

// MARK: - File Transfers

extension NetworkSyncService {
    func sendFile(entry: NetworkSyncFileEntry, baseRevision: Int, over connection: NWConnection) async throws {
        let start = NetworkSyncFileTransferStartPayload(
            transferID: UUID(),
            relativePath: entry.relativePath,
            isDirectory: entry.isDirectory,
            revision: entry.revision,
            baseRevision: baseRevision,
            modificationTimestamp: entry.modificationTimestamp,
            totalBytes: entry.size,
            originDeviceID: deviceID
        )

        markTransferActive(relativePath: entry.relativePath, activity: .upload)
        defer { finishTransferActivity(relativePath: entry.relativePath) }

        try sendEnvelope(.make(.fileTransferStart, payload: start, encoder: encoder), over: connection)

        if !entry.isDirectory, let rootURL {
            let fileURL = rootURL.appendingPathComponent(entry.relativePath)
            let chunks = try await executionContext.readFileChunks(at: fileURL, chunkSize: chunkSize)
            for data in chunks {
                try sendEnvelope(
                    .make(
                        .fileTransferChunk,
                        payload: NetworkSyncFileTransferChunkPayload(transferID: start.transferID, data: data),
                        encoder: encoder
                    ),
                    over: connection
                )
            }
        }

        try sendEnvelope(.make(.fileTransferEnd, payload: NetworkSyncFileTransferEndPayload(transferID: start.transferID, contentHash: entry.contentHash), encoder: encoder), over: connection)
        appendTransfer(relativePath: entry.relativePath, direction: .upload, status: "Sent", progress: 1, detail: "Queued over network")
    }

    func broadcast(entry: NetworkSyncFileEntry, excluding originDeviceID: UUID?) async throws {
        for context in connections.values {
            guard let hello = context.hello, hello.mode == .client else { continue }
            guard hello.deviceID != originDeviceID else { continue }
            guard shouldSyncPath(entry.relativePath, syncEntireRoot: hello.syncEntireRoot, includedPaths: hello.includedPaths) else { continue }
            try await sendFile(entry: entry, baseRevision: entry.revision, over: context.connection)
        }
    }

    func broadcastDelete(_ entry: NetworkSyncFileEntry, excluding originDeviceID: UUID?) throws {
        for context in connections.values {
            guard let hello = context.hello, hello.mode == .client else { continue }
            guard hello.deviceID != originDeviceID else { continue }
            guard shouldSyncPath(entry.relativePath, syncEntireRoot: hello.syncEntireRoot, includedPaths: hello.includedPaths) else { continue }
            let payload = NetworkSyncDeletePayload(
                relativePath: entry.relativePath,
                baseRevision: max(entry.revision - 1, 0),
                revision: entry.revision,
                originDeviceID: originDeviceID ?? deviceID
            )
            try sendEnvelope(.make(.delete, payload: payload, encoder: encoder), over: context.connection)
        }
    }

    func sendEnvelope(_ envelope: NetworkSyncEnvelope, over connection: NWConnection) throws {
        let payload = try encoder.encode(envelope)
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.setError(error.localizedDescription)
                }
            }
        })
    }

    func sendStateSnapshot(over connection: NWConnection) throws {
        let entries = serverState.entries.values.sorted { $0.relativePath < $1.relativePath }
        try sendEnvelope(.make(.stateSnapshot, payload: NetworkSyncStateSnapshotPayload(entries: entries), encoder: encoder), over: connection)
    }

    func requestServerStateSnapshot() {
        guard config.role == .client,
              let connectionID = clientConnectionID,
              let connection = connections[connectionID]?.connection
        else {
            return
        }

        try? sendEnvelope(
            .make(
                .stateRequest,
                payload: NetworkSyncStateRequestPayload(syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths),
                encoder: encoder
            ),
            over: connection
        )
    }

    func applyServerSnapshot(_ entries: [NetworkSyncFileEntry], over connection: NWConnection) async throws {
        if isProcessingLocalRootChange || hasPendingLocalRootChange {
            needsStateRefreshAfterLocalChange = true
            return
        }

        let remoteEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
        let currentLocal = try await scanEntries(at: rootURL!)

        for entry in remoteEntries.values.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard shouldSyncPath(entry.relativePath, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths) else {
                clientState.knownEntries[entry.relativePath] = entry
                clientState.materializedPaths.remove(entry.relativePath)
                clearPendingDeletion(at: entry.relativePath)
                continue
            }

            if metadataEquivalent(currentLocal[entry.relativePath], entry) {
                clientState.knownEntries[entry.relativePath] = entry
                clearPendingDeletion(at: entry.relativePath)
                continue
            }

            if hasUnsyncedLocalChange(
                path: entry.relativePath,
                currentLocal: currentLocal,
                materializedPaths: clientState.materializedPaths,
                pendingDeletionPaths: clientState.pendingDeletionPaths
            ) {
                continue
            }

            if entry.deleted {
                try await applyIncomingServerDeletion(
                    NetworkSyncDeletePayload(
                        relativePath: entry.relativePath,
                        baseRevision: clientState.knownEntries[entry.relativePath]?.revision ?? 0,
                        revision: entry.revision,
                        originDeviceID: UUID()
                    )
                )
            } else if !metadataEquivalent(currentLocal[entry.relativePath], entry) {
                try sendEnvelope(.make(.fileRequest, payload: NetworkSyncFileRequestPayload(relativePath: entry.relativePath), encoder: encoder), over: connection)
            } else {
                clientState.knownEntries[entry.relativePath] = entry
                clearPendingDeletion(at: entry.relativePath)
            }
        }

        for (path, knownEntry) in clientState.knownEntries where remoteEntries[path] == nil && !knownEntry.deleted {
            clientState.knownEntries[path] = NetworkSyncFileEntry(
                relativePath: path,
                isDirectory: knownEntry.isDirectory,
                size: 0,
                modificationTimestamp: Date().timeIntervalSince1970,
                contentHash: nil,
                revision: knownEntry.revision + 1,
                deleted: true
            )
            clearPendingDeletion(at: path)
        }

        saveClientState()
        refreshClientFinderBadges()
        updateStatus(.idle, detail: "Connected to \(peerRuntimes.values.first?.name ?? "server").")
    }

    func applyIncomingServerTransfer(_ incoming: IncomingTransfer, hash: String?) async throws {
        guard let rootURL else { return }

        let relativePath = incoming.start.relativePath
        let currentLocal = try await scanEntries(at: rootURL)
        if hasUnsyncedLocalChange(
            path: relativePath,
            currentLocal: currentLocal,
            materializedPaths: clientState.materializedPaths,
            pendingDeletionPaths: clientState.pendingDeletionPaths
        ) {
            try await createLocalConflictCopy(for: relativePath, currentLocal: currentLocal)
        }

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        suppressLocalRootEvents(for: localRootEventSuppressionWindow())
        try await writeTransfer(incoming, hash: hash, under: rootURL)
        let entry = NetworkSyncFileEntry(
            relativePath: incoming.start.relativePath,
            isDirectory: incoming.start.isDirectory,
            size: incoming.start.totalBytes,
            modificationTimestamp: incoming.start.modificationTimestamp,
            contentHash: hash,
            revision: incoming.start.revision,
            deleted: false
        )
        clientState.knownEntries[relativePath] = entry
        clearPendingDeletion(at: relativePath)
        localSnapshot = try await scanEntries(at: rootURL)
        clientState.materializedPaths = Set(localSnapshot.keys)
        saveClientState()
        refreshClientFinderBadges()
        appendTransfer(relativePath: relativePath, direction: .download, status: "Completed", progress: 1, detail: "Downloaded from server")
    }

    func applyIncomingServerDeletion(_ payload: NetworkSyncDeletePayload) async throws {
        guard let rootURL else { return }

        let currentLocal = try await scanEntries(at: rootURL)
        if hasUnsyncedLocalChange(
            path: payload.relativePath,
            currentLocal: currentLocal,
            materializedPaths: clientState.materializedPaths,
            pendingDeletionPaths: clientState.pendingDeletionPaths
        ) {
            try await createLocalConflictCopy(for: payload.relativePath, currentLocal: currentLocal)
        }

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        let destinationURL = rootURL.appendingPathComponent(payload.relativePath)
        suppressLocalRootEvents(for: localRootEventSuppressionWindow())
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let tombstone = NetworkSyncFileEntry(
            relativePath: payload.relativePath,
            isDirectory: false,
            size: 0,
            modificationTimestamp: Date().timeIntervalSince1970,
            contentHash: nil,
            revision: payload.revision,
            deleted: true
        )
        clientState.knownEntries[payload.relativePath] = tombstone
        clearPendingDeletionTree(at: payload.relativePath)
        localSnapshot = try await scanEntries(at: rootURL)
        clientState.materializedPaths = Set(localSnapshot.keys)
        saveClientState()
        clearFinderBadge(for: payload.relativePath)
        appendTransfer(relativePath: payload.relativePath, direction: .download, status: "Deleted", progress: nil, detail: "Applied server deletion")
    }

    func applyIncomingClientTransfer(_ incoming: IncomingTransfer, hash: String?, from context: ConnectionContext) async throws {
        guard let rootURL else { return }

        let currentEntry = serverState.entries[incoming.start.relativePath]
        let payloadHash: String? = incoming.start.isDirectory ? nil : (hash ?? sha256Hex(for: incoming.data))

        let effectiveBaseRevision = effectiveClientBaseRevision(
            requestedBaseRevision: incoming.start.baseRevision,
            relativePath: incoming.start.relativePath,
            deviceID: incoming.start.originDeviceID
        )
        let hasRevisionConflict = currentEntry.map { $0.revision != effectiveBaseRevision } ?? (effectiveBaseRevision != 0)
        let sameContent: Bool
        if incoming.start.isDirectory {
            sameContent = currentEntry?.isDirectory == true && currentEntry?.deleted == false
        } else {
            sameContent = currentEntry?.contentHash == payloadHash && currentEntry?.deleted == false
        }

        if hasRevisionConflict && !sameContent {
            let conflictPath = conflictRelativePath(for: incoming.start.relativePath, peerName: context.hello?.displayName ?? "Client")
            let conflictTransfer = IncomingTransfer(
                start: NetworkSyncFileTransferStartPayload(
                    transferID: incoming.start.transferID,
                    relativePath: conflictPath,
                    isDirectory: incoming.start.isDirectory,
                    revision: nextServerRevision(),
                    baseRevision: incoming.start.baseRevision,
                    modificationTimestamp: incoming.start.modificationTimestamp,
                    totalBytes: incoming.start.totalBytes,
                    originDeviceID: incoming.start.originDeviceID
                ),
                data: incoming.data
            )
            try await writeTransfer(conflictTransfer, hash: payloadHash, under: rootURL)
            let entry = NetworkSyncFileEntry(
                relativePath: conflictPath,
                isDirectory: conflictTransfer.start.isDirectory,
                size: conflictTransfer.start.totalBytes,
                modificationTimestamp: conflictTransfer.start.modificationTimestamp,
                contentHash: payloadHash,
                revision: conflictTransfer.start.revision,
                deleted: false
            )
            serverState.entries[conflictPath] = entry
            try saveServerState()
            localSnapshot = try await scanEntries(at: rootURL)
            appendConflict(relativePath: incoming.start.relativePath, detail: "Stored conflicting upload as \(conflictPath)")
            try sendEnvelope(.make(.conflict, payload: NetworkSyncConflictPayload(relativePath: incoming.start.relativePath, conflictPath: conflictPath, detail: "Stored as a conflict copy on the server."), encoder: encoder), over: context.connection)
            try await broadcast(entry: entry, excluding: incoming.start.originDeviceID)
            return
        }

        let revision = nextServerRevision()
        let acceptedTransfer = IncomingTransfer(
            start: NetworkSyncFileTransferStartPayload(
                transferID: incoming.start.transferID,
                relativePath: incoming.start.relativePath,
                isDirectory: incoming.start.isDirectory,
                revision: revision,
                baseRevision: incoming.start.baseRevision,
                modificationTimestamp: incoming.start.modificationTimestamp,
                totalBytes: incoming.start.totalBytes,
                originDeviceID: incoming.start.originDeviceID
            ),
            data: incoming.data
        )

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        suppressLocalRootEvents(for: localRootEventSuppressionWindow())
        try await writeTransfer(acceptedTransfer, hash: payloadHash, under: rootURL)
        let entry = NetworkSyncFileEntry(
            relativePath: acceptedTransfer.start.relativePath,
            isDirectory: acceptedTransfer.start.isDirectory,
            size: acceptedTransfer.start.totalBytes,
            modificationTimestamp: acceptedTransfer.start.modificationTimestamp,
            contentHash: payloadHash,
            revision: revision,
            deleted: false
        )
        serverState.entries[entry.relativePath] = entry
        recordAcknowledgedClientRevision(
            revision,
            for: entry.relativePath,
            deviceID: incoming.start.originDeviceID
        )
        try saveServerState()
        localSnapshot = try await scanEntries(at: rootURL)
        appendTransfer(relativePath: entry.relativePath, direction: .upload, status: "Accepted", progress: 1, detail: "Uploaded to server")
        try sendStateSnapshot(over: context.connection)
        try await broadcast(entry: entry, excluding: incoming.start.originDeviceID)
    }

    func applyIncomingClientDeletion(_ payload: NetworkSyncDeletePayload, from context: ConnectionContext) async throws {
        guard let rootURL else { return }

        let currentEntry = serverState.entries[payload.relativePath]
        let effectiveBaseRevision = effectiveClientBaseRevision(
            requestedBaseRevision: payload.baseRevision,
            relativePath: payload.relativePath,
            deviceID: payload.originDeviceID
        )
        let hasRevisionConflict = currentEntry.map { $0.revision != effectiveBaseRevision } ?? (effectiveBaseRevision != 0)
        if hasRevisionConflict {
            appendConflict(relativePath: payload.relativePath, detail: "Deletion conflict from \(context.hello?.displayName ?? "client")")
            return
        }

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        let destinationURL = rootURL.appendingPathComponent(payload.relativePath)
        suppressLocalRootEvents(for: localRootEventSuppressionWindow())
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let tombstone = NetworkSyncFileEntry(
            relativePath: payload.relativePath,
            isDirectory: currentEntry?.isDirectory ?? false,
            size: 0,
            modificationTimestamp: Date().timeIntervalSince1970,
            contentHash: nil,
            revision: nextServerRevision(),
            deleted: true
        )
        serverState.entries[payload.relativePath] = tombstone
        recordAcknowledgedClientRevision(
            tombstone.revision,
            for: payload.relativePath,
            deviceID: payload.originDeviceID
        )
        try saveServerState()
        localSnapshot = try await scanEntries(at: rootURL)
        try sendStateSnapshot(over: context.connection)
        try broadcastDelete(tombstone, excluding: payload.originDeviceID)
    }

    func reconcileServerStateWithDisk(broadcast: Bool, originDeviceID: UUID?) async throws {
        guard let rootURL else { return }

        let diskEntries = try await scanEntries(at: rootURL)
        var changedEntries: [NetworkSyncFileEntry] = []
        var deletedEntries: [NetworkSyncFileEntry] = []

        for (path, diskEntry) in diskEntries {
            if let existing = serverState.entries[path], !existing.deleted, metadataEquivalent(existing, diskEntry) {
                continue
            }

            let updated = NetworkSyncFileEntry(
                relativePath: path,
                isDirectory: diskEntry.isDirectory,
                size: diskEntry.size,
                modificationTimestamp: diskEntry.modificationTimestamp,
                contentHash: diskEntry.contentHash,
                revision: nextServerRevision(),
                deleted: false
            )
            serverState.entries[path] = updated
            changedEntries.append(updated)
        }

        for (path, existing) in serverState.entries where !existing.deleted && diskEntries[path] == nil {
            let tombstone = NetworkSyncFileEntry(
                relativePath: path,
                isDirectory: existing.isDirectory,
                size: 0,
                modificationTimestamp: Date().timeIntervalSince1970,
                contentHash: nil,
                revision: nextServerRevision(),
                deleted: true
            )
            serverState.entries[path] = tombstone
            deletedEntries.append(tombstone)
        }

        localSnapshot = diskEntries
        try saveServerState()

        guard broadcast else { return }
        for entry in changedEntries {
            try await self.broadcast(entry: entry, excluding: originDeviceID)
        }
        for entry in deletedEntries {
            try self.broadcastDelete(entry, excluding: originDeviceID)
        }
    }

    func stageClientLocalChanges(_ changes: [LocalDiff]) {
        guard config.role == .client else {
            return
        }

        for change in changes {
            switch change {
            case .upsert(let entry):
                guard shouldSyncPath(entry.relativePath, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths) else {
                    continue
                }
                let previousRevision = clientState.knownEntries[entry.relativePath]?.revision ?? 0
                clientState.knownEntries[entry.relativePath] = NetworkSyncFileEntry(
                    relativePath: entry.relativePath,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modificationTimestamp: entry.modificationTimestamp,
                    contentHash: entry.contentHash,
                    revision: previousRevision,
                    deleted: false
                )
                clearPendingDeletion(at: entry.relativePath)
            case .delete(let path):
                guard shouldSyncPath(path, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths) else {
                    continue
                }
                let existingEntry = clientState.knownEntries[path]
                clientState.knownEntries[path] = NetworkSyncFileEntry(
                    relativePath: path,
                    isDirectory: existingEntry?.isDirectory ?? false,
                    size: 0,
                    modificationTimestamp: Date().timeIntervalSince1970,
                    contentHash: nil,
                    revision: existingEntry?.revision ?? 0,
                    deleted: true
                )
            }
        }
    }

    func pushClientChanges(_ changes: [LocalDiff]) async throws {
        guard config.role == .client, let connectionID = clientConnectionID, let connection = connections[connectionID]?.connection else {
            return
        }

        for change in changes {
            let relativePath: String
            switch change {
            case .upsert(let entry):
                relativePath = entry.relativePath
            case .delete(let path):
                relativePath = path
            }

            guard shouldSyncPath(relativePath, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths) else {
                continue
            }

            switch change {
            case .upsert(let entry):
                try await sendFile(entry: entry, baseRevision: clientState.knownEntries[entry.relativePath]?.revision ?? 0, over: connection)
            case .delete(let path):
                let payload = NetworkSyncDeletePayload(
                    relativePath: path,
                    baseRevision: clientState.knownEntries[path]?.revision ?? 0,
                    revision: 0,
                    originDeviceID: deviceID
                )
                try sendEnvelope(.make(.delete, payload: payload, encoder: encoder), over: connection)
            }
        }
    }

    func pruneDeselectedLocalEntriesIfNeeded(at rootURL: URL) async throws {
        guard config.role == .client, !config.syncEntireRoot else {
            return
        }

        let allLocalPaths = try await scanAllLocalRelativePaths(at: rootURL)
        let pathsToRemove = allLocalPaths
            .filter { !shouldSyncPath($0, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths) }
            .sorted { lhs, rhs in
                let lhsDepth = lhs.split(separator: "/").count
                let rhsDepth = rhs.split(separator: "/").count
                if lhsDepth != rhsDepth {
                    return lhsDepth > rhsDepth
                }
                return lhs > rhs
            }

        guard !pathsToRemove.isEmpty else {
            return
        }

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        for relativePath in pathsToRemove {
            let targetURL = rootURL.appendingPathComponent(relativePath)
            try await executionContext.removeItemIfExists(at: targetURL)
            clearFinderBadge(for: relativePath)
        }

        clientState.materializedPaths.subtract(pathsToRemove)
        saveClientState()
    }

    func writeTransfer(_ incoming: IncomingTransfer, hash: String?, under rootURL: URL) async throws {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let destinationURL = rootURL.appendingPathComponent(incoming.start.relativePath)
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        if incoming.start.isDirectory {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } else {
            let tempURL = temporaryDirectoryURL(under: rootURL).appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try incoming.data.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }

        let modificationDate = Date(timeIntervalSince1970: incoming.start.modificationTimestamp)
        try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: destinationURL.path)
        _ = hash
        logDuration("writeTransfer", startedAt: startedAt)
    }

    func createLocalConflictCopy(for relativePath: String, currentLocal: [String: NetworkSyncFileEntry]) async throws {
        guard let rootURL, let existing = currentLocal[relativePath], !existing.isDirectory else {
            return
        }
        let sourceURL = rootURL.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }
        let conflictPath = conflictRelativePath(for: relativePath, peerName: "Local")
        let destinationURL = rootURL.appendingPathComponent(conflictPath)
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        appendConflict(relativePath: relativePath, detail: "Saved a local conflict copy as \(conflictPath)")
    }

    func conflictRelativePath(for relativePath: String, peerName: String) -> String {
        let normalizedPath = normalizeRelativePath(relativePath)
        let pathNSString = normalizedPath as NSString
        let stem = (pathNSString.deletingPathExtension as NSString).lastPathComponent
        let ext = pathNSString.pathExtension
        let timestamp = Self.conflictDateFormatter.string(from: Date())
        let fileName = ext.isEmpty
            ? "\(stem) (Conflict from \(peerName) \(timestamp))"
            : "\(stem) (Conflict from \(peerName) \(timestamp)).\(ext)"
        let parent = pathNSString.deletingLastPathComponent
        if parent.isEmpty || parent == "." {
            return fileName
        }
        return (parent as NSString).appendingPathComponent(fileName)
    }
}
