import Foundation
import OSLog

private let logger = Logger(subsystem: "com.nilone.starfiler.sync", category: "Engine")

// MARK: - Protocol

protocol SyncEngineProviding: Sendable {
    func start(config: NetworkSyncConfig) async throws
    func stop() async
    func pause() async
    func resume() async
    var statusStream: AsyncStream<SyncEngineStatus> { get }
    var transferProgressStream: AsyncStream<SyncTransferProgress> { get }
    var conflictStream: AsyncStream<SyncConflict> { get }
    var peerEventStream: AsyncStream<SyncPeerEvent> { get }
    func resolveConflict(relativePath: String, resolution: SyncConflictResolution) async
}

// MARK: - Sync Engine

actor SyncEngine: SyncEngineProviding {
    private let discoveryService: any SyncDiscovering
    private let connectionService: any SyncConnectionManaging
    private let changeDetector: any FileChangeDetecting
    private let deltaService: any SyncDeltaComputing
    private let transferService: SyncFileTransferService
    private let conflictService: any SyncConflictResolving
    private let stateDB: any SyncStateStoring
    private let securityScopedBookmarkService: any SecurityScopedBookmarkProviding

    private var config: NetworkSyncConfig?
    private var syncRootURL: URL?
    private var isRunning = false
    private var isPaused = false

    private var monitorTask: Task<Void, Never>?
    private var messageHandlerTask: Task<Void, Never>?
    private var peerEventHandlerTask: Task<Void, Never>?

    private var pendingLocalChanges: [FileChangeEvent] = []
    private var pendingRemoteChanges: [SyncPeerID: [SyncFileChange]] = [:]
    private var activeTransfers: [String: URL] = [:]  // relativePath -> tempURL for in-progress downloads

    private var statusContinuation: AsyncStream<SyncEngineStatus>.Continuation?
    private var transferContinuation: AsyncStream<SyncTransferProgress>.Continuation?
    private var conflictContinuation: AsyncStream<SyncConflict>.Continuation?
    private var peerEventContinuation: AsyncStream<SyncPeerEvent>.Continuation?

    nonisolated let statusStream: AsyncStream<SyncEngineStatus>
    nonisolated let transferProgressStream: AsyncStream<SyncTransferProgress>
    nonisolated let conflictStream: AsyncStream<SyncConflict>
    nonisolated let peerEventStream: AsyncStream<SyncPeerEvent>

    init(
        discoveryService: any SyncDiscovering = SyncDiscoveryService(),
        connectionService: any SyncConnectionManaging,
        changeDetector: any FileChangeDetecting = FSEventsChangeDetectionService(),
        deltaService: any SyncDeltaComputing = SyncDeltaComputationService(),
        transferService: SyncFileTransferService = SyncFileTransferService(),
        conflictService: any SyncConflictResolving = SyncConflictResolutionService(),
        stateDB: any SyncStateStoring = SyncStateDatabase(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared
    ) {
        self.discoveryService = discoveryService
        self.connectionService = connectionService
        self.changeDetector = changeDetector
        self.deltaService = deltaService
        self.transferService = transferService
        self.conflictService = conflictService
        self.stateDB = stateDB
        self.securityScopedBookmarkService = securityScopedBookmarkService

        var sCont: AsyncStream<SyncEngineStatus>.Continuation!
        self.statusStream = AsyncStream { c in sCont = c }
        var tCont: AsyncStream<SyncTransferProgress>.Continuation!
        self.transferProgressStream = AsyncStream { c in tCont = c }
        var cCont: AsyncStream<SyncConflict>.Continuation!
        self.conflictStream = AsyncStream { c in cCont = c }
        var pCont: AsyncStream<SyncPeerEvent>.Continuation!
        self.peerEventStream = AsyncStream { c in pCont = c }

        Task {
            await self.storeContinuations(sCont, tCont, cCont, pCont)
        }
    }

    private func storeContinuations(
        _ s: AsyncStream<SyncEngineStatus>.Continuation,
        _ t: AsyncStream<SyncTransferProgress>.Continuation,
        _ c: AsyncStream<SyncConflict>.Continuation,
        _ p: AsyncStream<SyncPeerEvent>.Continuation
    ) {
        self.statusContinuation = s
        self.transferContinuation = t
        self.conflictContinuation = c
        self.peerEventContinuation = p
    }

    // MARK: - Lifecycle

    func start(config: NetworkSyncConfig) async throws {
        guard !isRunning else { return }

        self.config = config
        let rootURL = URL(fileURLWithPath: config.syncRootPath, isDirectory: true).standardizedFileURL
        self.syncRootURL = rootURL

        // Start security scoped access
        try await securityScopedBookmarkService.startAccessing(rootURL)

        // Open state database
        try await stateDB.open()

        // Build peer info
        let localPeerInfo = SyncPeerInfo(
            peerID: config.localPeerID,
            isServer: config.mode == .server,
            syncRootPath: config.mode == .server ? config.syncRootPath : nil
        )

        // Start network services
        let port: UInt16 = 51342
        if config.mode == .server {
            try await discoveryService.startAdvertising(peerInfo: localPeerInfo, port: port)
            try await connectionService.startListening(port: port)
        }

        await discoveryService.startBrowsing()

        // Start FSEvents monitoring
        await changeDetector.startMonitoring(rootURL: rootURL)

        isRunning = true
        isPaused = false
        statusContinuation?.yield(.idle)

        // Start event loops
        startEventHandlers()

        logger.info("Sync engine started in \(config.mode.rawValue, privacy: .public) mode at \(rootURL.path, privacy: .public)")
    }

    func stop() async {
        guard isRunning else { return }

        monitorTask?.cancel()
        messageHandlerTask?.cancel()
        peerEventHandlerTask?.cancel()
        monitorTask = nil
        messageHandlerTask = nil
        peerEventHandlerTask = nil

        await changeDetector.stopMonitoring()
        await connectionService.stop()
        await discoveryService.stop()
        await stateDB.close()

        if let rootURL = syncRootURL {
            await securityScopedBookmarkService.stopAccessing(rootURL)
        }

        isRunning = false
        isPaused = false
        config = nil
        syncRootURL = nil
        pendingLocalChanges.removeAll()
        pendingRemoteChanges.removeAll()
        activeTransfers.removeAll()

        statusContinuation?.yield(.idle)
        logger.info("Sync engine stopped")
    }

    func pause() async {
        isPaused = true
        statusContinuation?.yield(.paused)
        logger.info("Sync engine paused")
    }

    func resume() async {
        isPaused = false
        statusContinuation?.yield(.idle)
        logger.info("Sync engine resumed")
    }

    func resolveConflict(relativePath: String, resolution: SyncConflictResolution) async {
        // Forward resolution to connected peers
        guard let config else { return }
        let version = (try? await stateDB.getCurrentSyncVersion(for: config.localPeerID)) ?? 0

        let resolutionMsg = SyncMessage.conflictResolution(ConflictResolutionPayload(
            relativePath: relativePath,
            resolution: resolution,
            syncVersion: version
        ))

        for peer in config.peers where peer.isApproved {
            try? await connectionService.send(resolutionMsg, to: peer.peerID)
        }
    }

    // MARK: - Private: Event Handlers

    private func startEventHandlers() {
        // Monitor local file changes
        monitorTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.changeDetector.changeEvents {
                guard !Task.isCancelled else { break }
                await self.handleLocalChange(event)
            }
        }

        // Handle incoming messages from peers
        messageHandlerTask = Task { [weak self] in
            guard let self else { return }
            for await (peerID, message) in await self.connectionService.incomingMessages {
                guard !Task.isCancelled else { break }
                await self.handleIncomingMessage(from: peerID, message: message)
            }
        }

        // Handle peer events (discovery, connection state)
        peerEventHandlerTask = Task { [weak self] in
            guard let self else { return }

            // Forward discovery events
            for await event in await self.discoveryService.peerEvents {
                guard !Task.isCancelled else { break }
                await self.handlePeerEvent(event)
            }
        }
    }

    // MARK: - Private: Local Change Handling

    private func handleLocalChange(_ event: FileChangeEvent) {
        guard isRunning, !isPaused else { return }

        pendingLocalChanges.append(event)

        // Trigger sync after debounce (handled by FSEvents debounce)
        Task { [weak self] in
            guard let self else { return }
            await self.processPendingChanges()
        }
    }

    private func processPendingChanges() async {
        guard isRunning, !isPaused, !pendingLocalChanges.isEmpty else { return }
        guard let config, let syncRootURL else { return }

        let localChanges = pendingLocalChanges
        pendingLocalChanges.removeAll()

        statusContinuation?.yield(.scanning)

        // Convert to SyncFileChange for notification
        let version = (try? await stateDB.incrementSyncVersion(for: config.localPeerID)) ?? 0
        let syncChanges = localChanges.map { event in
            SyncFileChange(
                relativePath: event.relativePath,
                changeType: event.changeType,
                metadata: event.metadata,
                syncVersion: version
            )
        }

        // Notify connected peers
        let notification = SyncMessage.changeNotification(ChangeNotificationPayload(
            changes: syncChanges,
            syncVersion: version
        ))

        for peer in config.peers where peer.isApproved {
            try? await connectionService.send(notification, to: peer.peerID)
        }

        // Update state DB
        for change in localChanges {
            let fileState = SyncFileState(
                relativePath: change.relativePath,
                peerID: config.localPeerID,
                isDirectory: change.metadata?.isDirectory ?? false,
                size: change.metadata?.size,
                contentModificationDate: change.metadata?.contentModificationDate,
                contentHash: change.metadata?.contentHash,
                syncVersion: version,
                isDeleted: change.changeType == .deleted
            )
            try? await stateDB.upsertFileState(fileState)
        }

        statusContinuation?.yield(.idle)
    }

    // MARK: - Private: Incoming Message Handling

    private func handleIncomingMessage(from peerID: SyncPeerID, message: SyncMessage) async {
        guard isRunning else { return }

        switch message {
        case .changeNotification(let payload):
            await handleChangeNotification(from: peerID, payload: payload)

        case .changeAck(let payload):
            await handleChangeAck(from: peerID, payload: payload)

        case .fileRequest(let payload):
            await handleFileRequest(from: peerID, payload: payload)

        case .fileHeader(let payload):
            await handleFileHeader(from: peerID, payload: payload)

        case .fileChunk(let payload):
            await handleFileChunk(from: peerID, payload: payload)

        case .fileComplete(let payload):
            await handleFileComplete(from: peerID, payload: payload)

        case .fileDeletion(let payload):
            await handleFileDeletion(from: peerID, payload: payload)

        case .stateSnapshotRequest(let payload):
            await handleStateSnapshotRequest(from: peerID, payload: payload)

        case .stateSnapshot(let payload):
            await handleStateSnapshot(from: peerID, payload: payload)

        case .conflictReport(let payload):
            await handleConflictReport(from: peerID, payload: payload)

        case .conflictResolution(let payload):
            await handleConflictResolution(from: peerID, payload: payload)

        case .selectiveSyncUpdate(let payload):
            await handleSelectiveSyncUpdate(from: peerID, payload: payload)

        default:
            break
        }
    }

    private func handleChangeNotification(from peerID: SyncPeerID, payload: ChangeNotificationPayload) async {
        guard let config, let syncRootURL else { return }

        // Get selective sync rules for this peer
        let peerConfig = config.peers.first { $0.peerID == peerID }
        let rules = peerConfig?.selectiveSyncRules

        // Compute delta
        let localStates = (try? await stateDB.getAllFileStates(for: config.localPeerID)) ?? []
        let delta = await deltaService.computeDelta(
            localChanges: pendingLocalChanges,
            remoteChanges: payload.changes,
            localStates: localStates,
            rules: rules
        )

        if delta.isEmpty {
            let ack = SyncMessage.changeAck(ChangeAckPayload(
                acknowledgedVersion: payload.syncVersion,
                requestedFiles: []
            ))
            try? await connectionService.send(ack, to: peerID)
            return
        }

        // Handle conflicts
        for conflict in delta.conflicts {
            let resolved = await conflictService.resolve(
                conflict: conflict,
                strategy: config.conflictStrategy,
                localPeerID: config.localPeerID,
                remotePeerID: peerID
            )

            switch resolved {
            case .keepLocal:
                // Upload our version
                break
            case .keepRemote:
                // Request download
                let request = SyncMessage.fileRequest(FileRequestPayload(
                    relativePath: conflict.relativePath,
                    fromOffset: 0
                ))
                try? await connectionService.send(request, to: peerID)
            case .keepBoth:
                // Rename local and download remote
                break
            case nil:
                // Ask user
                let peerInfo = SyncPeerInfo(peerID: peerID, isServer: false)
                conflictContinuation?.yield(SyncConflict(
                    relativePath: conflict.relativePath,
                    localMetadata: conflict.localMetadata,
                    remoteMetadata: conflict.remoteMetadata,
                    remotePeerInfo: peerInfo
                ))
            }
        }

        // Request files to download
        let requestedFiles = delta.filesToDownload.map(\.relativePath)
        let ack = SyncMessage.changeAck(ChangeAckPayload(
            acknowledgedVersion: payload.syncVersion,
            requestedFiles: requestedFiles
        ))
        try? await connectionService.send(ack, to: peerID)

        // Handle deletions
        for deletion in delta.filesToDelete {
            let fileURL = syncRootURL.appendingPathComponent(deletion.relativePath)

            // Temporarily ignore this path to avoid FSEvents feedback loop
            await changeDetector.addToIgnoreSet(deletion.relativePath)
            defer {
                Task { await self.changeDetector.removeFromIgnoreSet(deletion.relativePath) }
            }

            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }

            let fileState = SyncFileState(
                relativePath: deletion.relativePath,
                peerID: config.localPeerID,
                isDirectory: deletion.isDirectory,
                syncVersion: deletion.syncVersion,
                isDeleted: true
            )
            try? await stateDB.upsertFileState(fileState)
        }

        statusContinuation?.yield(.syncing(itemsRemaining: delta.totalItems))
    }

    private func handleChangeAck(from peerID: SyncPeerID, payload: ChangeAckPayload) async {
        guard let syncRootURL else { return }

        // Send requested files
        for relativePath in payload.requestedFiles {
            let fileURL = syncRootURL.appendingPathComponent(relativePath)
            try? await transferService.sendFile(
                at: fileURL,
                relativePath: relativePath,
                to: peerID,
                fromOffset: 0,
                connection: connectionService
            )
        }
    }

    private func handleFileRequest(from peerID: SyncPeerID, payload: FileRequestPayload) async {
        guard let syncRootURL else { return }

        let fileURL = syncRootURL.appendingPathComponent(payload.relativePath)
        try? await transferService.sendFile(
            at: fileURL,
            relativePath: payload.relativePath,
            to: peerID,
            fromOffset: payload.fromOffset,
            connection: connectionService
        )
    }

    private func handleFileHeader(from peerID: SyncPeerID, payload: FileHeaderPayload) async {
        guard let syncRootURL else { return }

        if payload.isDirectory {
            let dirURL = syncRootURL.appendingPathComponent(payload.relativePath)
            await changeDetector.addToIgnoreSet(payload.relativePath)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            Task { await self.changeDetector.removeFromIgnoreSet(payload.relativePath) }
            return
        }

        // Create temp file for receiving
        let tempURL = await transferService.createTempFile(for: payload.relativePath, in: syncRootURL)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        activeTransfers[payload.relativePath] = tempURL

        transferContinuation?.yield(SyncTransferProgress(
            relativePath: payload.relativePath,
            totalBytes: payload.totalSize,
            transferredBytes: 0,
            direction: .downloading
        ))
    }

    private func handleFileChunk(from peerID: SyncPeerID, payload: FileChunkPayload) async {
        guard let tempURL = activeTransfers[payload.relativePath] else { return }

        try? await transferService.writeChunk(to: tempURL, chunk: payload)

        // Update progress
        transferContinuation?.yield(SyncTransferProgress(
            relativePath: payload.relativePath,
            totalBytes: payload.offset + Int64(payload.data.count),
            transferredBytes: payload.offset + Int64(payload.data.count),
            direction: .downloading
        ))

        if payload.isLastChunk {
            await finalizeDownload(relativePath: payload.relativePath, from: peerID)
        }
    }

    private func finalizeDownload(relativePath: String, from peerID: SyncPeerID) async {
        guard let syncRootURL, let config, let tempURL = activeTransfers.removeValue(forKey: relativePath) else { return }

        let finalURL = syncRootURL.appendingPathComponent(relativePath)

        // Suppress FSEvents for this file
        await changeDetector.addToIgnoreSet(relativePath)

        do {
            let parentDir = finalURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)

            // Update state DB
            let attributes = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
            let version = (try? await stateDB.incrementSyncVersion(for: config.localPeerID)) ?? 0
            let fileState = SyncFileState(
                relativePath: relativePath,
                peerID: config.localPeerID,
                isDirectory: false,
                size: (attributes?[.size] as? Int64),
                contentModificationDate: attributes?[.modificationDate] as? Date,
                syncVersion: version
            )
            try? await stateDB.upsertFileState(fileState)

            // Send completion
            let complete = SyncMessage.fileComplete(FileCompletePayload(
                relativePath: relativePath,
                success: true,
                error: nil,
                syncVersion: version
            ))
            try? await connectionService.send(complete, to: peerID)

            logger.info("Download complete: \(relativePath, privacy: .public)")
        } catch {
            logger.error("Failed to finalize download \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
        }

        Task { await self.changeDetector.removeFromIgnoreSet(relativePath) }
    }

    private func handleFileComplete(from peerID: SyncPeerID, payload: FileCompletePayload) async {
        guard let config else { return }
        if payload.success {
            let fileState = SyncFileState(
                relativePath: payload.relativePath,
                peerID: peerID,
                syncVersion: payload.syncVersion
            )
            try? await stateDB.upsertFileState(fileState)
        }
    }

    private func handleFileDeletion(from peerID: SyncPeerID, payload: FileDeletionPayload) async {
        guard let syncRootURL, let config else { return }

        let fileURL = syncRootURL.appendingPathComponent(payload.relativePath)

        await changeDetector.addToIgnoreSet(payload.relativePath)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let fileState = SyncFileState(
            relativePath: payload.relativePath,
            peerID: config.localPeerID,
            isDirectory: payload.isDirectory,
            syncVersion: payload.syncVersion,
            isDeleted: true
        )
        try? await stateDB.upsertFileState(fileState)

        Task { await self.changeDetector.removeFromIgnoreSet(payload.relativePath) }
    }

    private func handleStateSnapshotRequest(from peerID: SyncPeerID, payload: StateSnapshotRequestPayload) async {
        guard let config else { return }

        let states = (try? await stateDB.getAllFileStates(for: config.localPeerID)) ?? []
        let currentVersion = (try? await stateDB.getCurrentSyncVersion(for: config.localPeerID)) ?? 0

        let entries = states.map { state in
            StateSnapshotEntry(
                relativePath: state.relativePath,
                isDirectory: state.isDirectory,
                size: state.size,
                contentModificationDate: state.contentModificationDate,
                contentHash: state.contentHash,
                syncVersion: state.syncVersion,
                isDeleted: state.isDeleted
            )
        }

        let snapshot = SyncMessage.stateSnapshot(StateSnapshotPayload(
            entries: entries,
            currentVersion: currentVersion
        ))
        try? await connectionService.send(snapshot, to: peerID)
    }

    private func handleStateSnapshot(from peerID: SyncPeerID, payload: StateSnapshotPayload) async {
        guard let config, let syncRootURL else { return }

        // Compare with local state to find differences
        let localStates = (try? await stateDB.getAllFileStates(for: config.localPeerID)) ?? []
        let localMap = Dictionary(
            localStates.map { ($0.relativePath, $0) },
            uniquingKeysWith: { _, new in new }
        )

        var filesToRequest: [String] = []

        for entry in payload.entries where !entry.isDeleted {
            if let localState = localMap[entry.relativePath] {
                // Compare versions
                if entry.syncVersion > localState.syncVersion {
                    if entry.contentHash != localState.contentHash {
                        filesToRequest.append(entry.relativePath)
                    }
                }
            } else {
                filesToRequest.append(entry.relativePath)
            }
        }

        // Request missing files
        for path in filesToRequest {
            let request = SyncMessage.fileRequest(FileRequestPayload(
                relativePath: path,
                fromOffset: 0
            ))
            try? await connectionService.send(request, to: peerID)
        }

        statusContinuation?.yield(.syncing(itemsRemaining: filesToRequest.count))
    }

    private func handleConflictReport(from peerID: SyncPeerID, payload: ConflictReportPayload) async {
        let peerInfo = SyncPeerInfo(peerID: peerID, isServer: false)
        conflictContinuation?.yield(SyncConflict(
            relativePath: payload.relativePath,
            localMetadata: payload.localMetadata,
            remoteMetadata: payload.remoteMetadata,
            remotePeerInfo: peerInfo
        ))
    }

    private func handleConflictResolution(from peerID: SyncPeerID, payload: ConflictResolutionPayload) async {
        guard let syncRootURL else { return }

        switch payload.resolution {
        case .keepRemote:
            // Request the remote file
            let request = SyncMessage.fileRequest(FileRequestPayload(
                relativePath: payload.relativePath,
                fromOffset: 0
            ))
            try? await connectionService.send(request, to: peerID)

        case .keepLocal:
            // Send our file to the peer
            let fileURL = syncRootURL.appendingPathComponent(payload.relativePath)
            try? await transferService.sendFile(
                at: fileURL,
                relativePath: payload.relativePath,
                to: peerID,
                fromOffset: 0,
                connection: connectionService
            )

        case .keepBoth:
            break
        }
    }

    private func handleSelectiveSyncUpdate(from peerID: SyncPeerID, payload: SelectiveSyncUpdatePayload) async {
        // Store updated rules (in-memory for now; persisted via config save from ViewModel)
        logger.info("Received selective sync update from \(peerID.rawValue.uuidString, privacy: .public)")
    }

    // MARK: - Private: Peer Events

    private func handlePeerEvent(_ event: SyncPeerEvent) async {
        peerEventContinuation?.yield(event)

        switch event {
        case .discovered(let peerInfo):
            guard let config else { return }
            // Auto-connect if this peer is approved
            if config.peers.contains(where: { $0.peerID == peerInfo.peerID && $0.isApproved }) {
                if config.mode == .client, peerInfo.isServer {
                    // Client connects to server
                    guard let syncRootPath = peerInfo.syncRootPath else { return }
                    try? await connectionService.connect(host: peerInfo.displayName, port: 51342)
                }
            }

        case .lost(let peerID):
            await connectionService.disconnect(peerID: peerID)

        case .connectionStateChanged(let peerID, let state):
            if case .connected = state {
                // Request state snapshot for initial sync
                let request = SyncMessage.stateSnapshotRequest(StateSnapshotRequestPayload(sinceVersion: nil))
                try? await connectionService.send(request, to: peerID)
            }
        }
    }
}
