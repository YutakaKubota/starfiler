import CoreServices
import CryptoKit
import AppKit
import Foundation
import Network

@MainActor
protocol NetworkSyncControlling: AnyObject {
    var onSnapshot: ((NetworkSyncRuntimeSnapshot) -> Void)? { get set }
    func start()
    func stop()
    func reload(config: NetworkSyncConfig)
    func requestRefresh()
}

@MainActor
final class NetworkSyncService: NetworkSyncControlling {
    var onSnapshot: ((NetworkSyncRuntimeSnapshot) -> Void)?

    private final class ConnectionContext {
        let id: String
        let connection: NWConnection
        var receiveBuffer = Data()
        var hello: NetworkSyncHelloPayload?
        var incomingTransfers: [UUID: IncomingTransfer] = [:]

        init(id: String, connection: NWConnection) {
            self.id = id
            self.connection = connection
        }
    }

    private struct IncomingTransfer {
        var start: NetworkSyncFileTransferStartPayload
        var data: Data
    }

    private let serviceType = "_starfiler-sync._tcp"
    private let chunkSize = 64 * 1024
    private let fileHashThresholdBytes: Int64 = 10 * 1024 * 1024
    private let role: SyncNodeMode
    private let configManager: ConfigManager
    private let securityScopedBookmarkService: any SecurityScopedBookmarkProviding
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let deviceID: UUID

    private var config: NetworkSyncRoleRuntimeConfig
    private var snapshot: NetworkSyncRuntimeSnapshot = .disabled
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: ConnectionContext] = [:]
    private var clientConnectionID: String?
    private var pathMonitor: NetworkSyncPathMonitor?
    private var heartbeatTimer: Timer?
    private var rootURL: URL?
    private var activeRootAccessURL: URL?
    private var localSnapshot: [String: NetworkSyncFileEntry] = [:]
    private var serverState = NetworkSyncServerState()
    private var clientState = NetworkSyncClientState()
    private var peerRuntimes: [String: NetworkSyncPeerRuntime] = [:]
    private var conflicts: [NetworkSyncConflictRecord] = []
    private var transfers: [NetworkSyncTransferRecord] = []
    private var activeTransfersByPath: [String: NetworkSyncTransferActivity] = [:]
    private var isApplyingRemoteChange = false

    init(
        role: SyncNodeMode,
        configManager: ConfigManager = ConfigManager(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared,
        fileManager: FileManager = .default
    ) {
        self.role = role
        self.configManager = configManager
        self.securityScopedBookmarkService = securityScopedBookmarkService
        self.fileManager = fileManager
        self.config = configManager.loadNetworkSyncConfig().runtimeConfig(for: role)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.deviceID = Self.resolveDeviceID(configDirectory: configManager.configDirectory)
    }

    func start() {
        stop()
        config = configManager.loadNetworkSyncConfig().runtimeConfig(for: role)

        guard config.isEnabled else {
            snapshot = .disabled
            publishSnapshot()
            return
        }

        let trimmedRoot = config.effectiveRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty else {
            setError("Set a sync root path in Network Sync settings.")
            return
        }

        let rootURL = URL(fileURLWithPath: UserPaths.expandHomeVariables(in: trimmedRoot), isDirectory: true).standardizedFileURL

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.securityScopedBookmarkService.startAccessing(rootURL)
                self.activeRootAccessURL = rootURL
                self.rootURL = rootURL

                if !self.fileManager.fileExists(atPath: rootURL.path) {
                    try self.fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                }

                self.snapshot.status = .starting
                self.snapshot.detail = "Starting \(self.config.role.displayName.lowercased())…"
                self.publishSnapshot()

                switch self.config.role {
                case .server:
                    self.localSnapshot = try self.scanEntries(at: rootURL)
                    self.startPathMonitor(for: rootURL)
                    self.startHeartbeat()
                    try self.loadServerState()
                    try self.reconcileServerStateWithDisk(broadcast: false, originDeviceID: nil)
                    try self.startServerListener()
                    self.updateStatus(.idle, detail: "Server is advertising on the local network.")
                case .client:
                    self.loadClientState()
                    try self.pruneDeselectedLocalEntriesIfNeeded(at: rootURL)
                    self.localSnapshot = try self.scanEntries(at: rootURL)
                    self.clientState.materializedPaths = Set(self.localSnapshot.keys)
                    self.saveClientState()
                    self.startPathMonitor(for: rootURL)
                    self.startHeartbeat()
                    self.refreshClientFinderBadges()
                    self.startClientBrowser()
                    self.updateStatus(.offline, detail: "Searching for a Starfiler sync server…")
                }
            } catch {
                self.setError(error.localizedDescription)
            }
        }
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        pathMonitor?.stop()
        pathMonitor = nil

        browser?.cancel()
        browser = nil

        listener?.cancel()
        listener = nil

        for context in connections.values {
            context.connection.cancel()
        }
        connections.removeAll()
        clientConnectionID = nil
        peerRuntimes.removeAll()

        if let activeRootAccessURL {
            Task { [securityScopedBookmarkService] in
                await securityScopedBookmarkService.stopAccessing(activeRootAccessURL)
            }
            self.activeRootAccessURL = nil
        }

        rootURL = nil
        localSnapshot = [:]
        snapshot = config.isEnabled
            ? NetworkSyncRuntimeSnapshot(status: .offline, detail: "Network sync stopped.", peers: [], conflicts: conflicts, transfers: transfers, activeTransfers: [:])
            : .disabled
        publishSnapshot()
    }

    func reload(config: NetworkSyncConfig) {
        self.config = config.runtimeConfig(for: role)
        start()
    }

    func requestRefresh() {
        if config.isEnabled, let rootURL {
            do {
                localSnapshot = try scanEntries(at: rootURL)
                if config.role == .client {
                    refreshClientFinderBadges()
                }
            } catch {
                setError(error.localizedDescription)
                return
            }
        }
        publishSnapshot()
    }

    private func startPathMonitor(for rootURL: URL) {
        let monitor = NetworkSyncPathMonitor(url: rootURL, debounceInterval: config.syncDebounceSeconds) { [weak self] in
            Task { @MainActor in
                self?.handleLocalRootChange()
            }
        }
        monitor.start()
        pathMonitor = monitor
    }

    private func handleLocalRootChange() {
        guard !isApplyingRemoteChange, let rootURL else {
            return
        }

        do {
            switch config.role {
            case .server:
                localSnapshot = try scanEntries(at: rootURL)
                try reconcileServerStateWithDisk(broadcast: true, originDeviceID: nil)
            case .client:
                let latestSnapshot = try scanEntries(at: rootURL)
                let changes = diff(old: localSnapshot, new: latestSnapshot)
                let deletedPaths = Set(
                    changes.compactMap { change -> String? in
                        guard case .delete(let path) = change else { return nil }
                        return shouldSyncPath(path, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths) ? path : nil
                    }
                )
                let upsertedPaths = Set(
                    changes.compactMap { change -> String? in
                        guard case .upsert(let entry) = change else { return nil }
                        return entry.relativePath
                    }
                )
                localSnapshot = latestSnapshot
                clientState.materializedPaths = Set(latestSnapshot.keys)
                clientState.pendingDeletionPaths.formUnion(deletedPaths)
                clientState.pendingDeletionPaths.subtract(upsertedPaths)
                saveClientState()
                refreshClientFinderBadges()
                try pushClientChanges(changes)
            }
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: max(5, config.heartbeatIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        for context in connections.values {
            try? sendEnvelope(.make(.heartbeat, payload: NetworkSyncStateRequestPayload(syncEntireRoot: true, includedPaths: []), encoder: encoder), over: context.connection)
        }
    }

    private func startServerListener() throws {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: config.advertisedServiceName, type: serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.updateStatus(.idle, detail: "Server is advertising on the local network.")
                case .failed(let error):
                    self.setError(error.localizedDescription)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection: connection)
            }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    private func startClientBrowser() {
        let parameters = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.setError(error.localizedDescription)
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var nextPeers: [String: NetworkSyncPeerRuntime] = [:]
        for result in results {
            let endpoint = result.endpoint
            let id = endpoint.debugDescription
            let advertisedName = endpoint.serviceName ?? endpoint.debugDescription
            guard let name = visiblePeerName(from: advertisedName) else {
                continue
            }
            let state: NetworkSyncPeerState = (clientConnectionID == id && connections[id] != nil) ? .connected : .discovered
            nextPeers[id] = NetworkSyncPeerRuntime(
                id: id,
                name: name,
                role: .server,
                state: state,
                hostname: endpoint.debugDescription,
                isConnected: state == .connected,
                lastSeenAt: Date()
            )
        }
        peerRuntimes = nextPeers
        publishSnapshot()

        let matchingResults = results.filter { result in
            let advertisedName = result.endpoint.serviceName ?? result.endpoint.debugDescription
            return visiblePeerName(from: advertisedName) != nil
        }

        guard clientConnectionID == nil, let result = matchingResults.first else {
            return
        }
        connectToServer(endpoint: result.endpoint)
    }

    private func visiblePeerName(from advertisedName: String) -> String? {
        let prefix = "[\(config.effectiveDiscoveryScope)] "
        guard advertisedName.hasPrefix(prefix) else {
            return nil
        }
        return String(advertisedName.dropFirst(prefix.count))
    }

    private func connectToServer(endpoint: NWEndpoint) {
        let id = endpoint.debugDescription
        let connection = NWConnection(to: endpoint, using: .tcp)
        let context = ConnectionContext(id: id, connection: connection)
        connections[id] = context
        clientConnectionID = id

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state, for: id)
            }
        }
        connection.start(queue: .global(qos: .utility))
        startReceiveLoop(for: id)
    }

    private func accept(connection: NWConnection) {
        let id = UUID().uuidString
        let context = ConnectionContext(id: id, connection: connection)
        connections[id] = context
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state, for: id)
            }
        }
        connection.start(queue: .global(qos: .utility))
        startReceiveLoop(for: id)
    }

    private func handleConnectionState(_ state: NWConnection.State, for id: String) {
        guard let context = connections[id] else {
            return
        }

        switch state {
        case .ready:
            if config.role == .client, clientConnectionID == id {
                peerRuntimes[id]?.state = .connected
                peerRuntimes[id]?.isConnected = true
                updateStatus(.idle, detail: "Connected to \(peerRuntimes[id]?.name ?? "server").")
                sendClientHandshake(over: context.connection)
            }
        case .failed(let error):
            removeConnection(id: id)
            if config.role == .client {
                updateStatus(.offline, detail: "Connection lost: \(error.localizedDescription)")
            }
        case .cancelled:
            removeConnection(id: id)
        default:
            break
        }
    }

    private func removeConnection(id: String) {
        connections[id]?.connection.cancel()
        connections.removeValue(forKey: id)
        if clientConnectionID == id {
            clientConnectionID = nil
        }
        if var peer = peerRuntimes[id] {
            peer.state = .offline
            peer.isConnected = false
            peerRuntimes[id] = peer
        }
        publishSnapshot()
    }

    private func sendClientHandshake(over connection: NWConnection) {
        let hello = NetworkSyncHelloPayload(
            deviceID: deviceID,
            displayName: config.displayName,
            mode: config.role,
            protocolVersion: 1,
            syncEntireRoot: config.syncEntireRoot,
            includedPaths: config.includedPaths
        )
        do {
            try sendEnvelope(.make(.hello, payload: hello, encoder: encoder), over: connection)
            try sendEnvelope(.make(.stateRequest, payload: NetworkSyncStateRequestPayload(syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths), encoder: encoder), over: connection)
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func startReceiveLoop(for id: String) {
        guard let context = connections[id] else {
            return
        }

        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let data, !data.isEmpty, let context = self.connections[id] {
                    context.receiveBuffer.append(data)
                    self.consumeFrames(for: context)
                }

                if let error {
                    self.removeConnection(id: id)
                    if self.config.role == .client {
                        self.updateStatus(.offline, detail: error.localizedDescription)
                    }
                    return
                }

                if isComplete {
                    self.removeConnection(id: id)
                    return
                }

                self.startReceiveLoop(for: id)
            }
        }
    }

    private func consumeFrames(for context: ConnectionContext) {
        while context.receiveBuffer.count >= 4 {
            let length = context.receiveBuffer.prefix(4).withUnsafeBytes { rawBuffer in
                rawBuffer.load(as: UInt32.self).bigEndian
            }
            guard context.receiveBuffer.count >= Int(length) + 4 else {
                return
            }

            let payload = context.receiveBuffer.subdata(in: 4..<(4 + Int(length)))
            context.receiveBuffer.removeSubrange(0..<(4 + Int(length)))

            do {
                let envelope = try decoder.decode(NetworkSyncEnvelope.self, from: payload)
                try handleEnvelope(envelope, from: context)
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    private func handleEnvelope(_ envelope: NetworkSyncEnvelope, from context: ConnectionContext) throws {
        switch envelope.kind {
        case .hello:
            let payload = try envelope.decode(NetworkSyncHelloPayload.self, decoder: decoder)
            context.hello = payload
            peerRuntimes[context.id] = NetworkSyncPeerRuntime(
                id: payload.deviceID.uuidString,
                name: payload.displayName,
                role: payload.mode == .server ? .server : .client,
                state: .connected,
                hostname: payload.displayName,
                isConnected: true,
                lastSeenAt: Date()
            )
            publishSnapshot()
        case .stateRequest:
            guard config.role == .server else { return }
            try sendStateSnapshot(over: context.connection)
        case .stateSnapshot:
            guard config.role == .client else { return }
            let payload = try envelope.decode(NetworkSyncStateSnapshotPayload.self, decoder: decoder)
            try applyServerSnapshot(payload.entries, over: context.connection)
        case .fileRequest:
            guard config.role == .server else { return }
            let request = try envelope.decode(NetworkSyncFileRequestPayload.self, decoder: decoder)
            guard let entry = serverState.entries[request.relativePath], !entry.deleted else { return }
            try sendFile(entry: entry, baseRevision: entry.revision, over: context.connection)
        case .fileTransferStart:
            let payload = try envelope.decode(NetworkSyncFileTransferStartPayload.self, decoder: decoder)
            context.incomingTransfers[payload.transferID] = IncomingTransfer(start: payload, data: Data())
            markTransferActive(relativePath: payload.relativePath, activity: config.role == .server ? .upload : .download)
        case .fileTransferChunk:
            let payload = try envelope.decode(NetworkSyncFileTransferChunkPayload.self, decoder: decoder)
            context.incomingTransfers[payload.transferID]?.data.append(payload.data)
        case .fileTransferEnd:
            let payload = try envelope.decode(NetworkSyncFileTransferEndPayload.self, decoder: decoder)
            guard let incoming = context.incomingTransfers.removeValue(forKey: payload.transferID) else { return }
            defer { finishTransferActivity(relativePath: incoming.start.relativePath) }
            if config.role == .server {
                try applyIncomingClientTransfer(incoming, hash: payload.contentHash, from: context)
            } else {
                try applyIncomingServerTransfer(incoming, hash: payload.contentHash)
            }
        case .delete:
            let payload = try envelope.decode(NetworkSyncDeletePayload.self, decoder: decoder)
            if config.role == .server {
                try applyIncomingClientDeletion(payload, from: context)
            } else {
                try applyIncomingServerDeletion(payload)
            }
        case .conflict:
            let payload = try envelope.decode(NetworkSyncConflictPayload.self, decoder: decoder)
            appendConflict(relativePath: payload.relativePath, detail: payload.detail)
        case .heartbeat:
            if var peer = peerRuntimes[context.hello?.deviceID.uuidString ?? context.id] {
                peer.lastSeenAt = Date()
                peerRuntimes[peer.id] = peer
            }
            publishSnapshot()
        case .error:
            let payload = try envelope.decode(NetworkSyncErrorPayload.self, decoder: decoder)
            setError(payload.detail)
        }
    }

    private func applyServerSnapshot(_ entries: [NetworkSyncFileEntry], over connection: NWConnection) throws {
        let remoteEntries = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0) })
        let currentLocal = try scanEntries(at: rootURL!)
        let trackedKnownEntries = clientState.knownEntries.filter {
            clientState.materializedPaths.contains($0.key) || hasPendingDeletion(for: $0.key, pendingDeletionPaths: clientState.pendingDeletionPaths)
        }
        let localChanges = diffAgainstKnown(known: trackedKnownEntries, local: currentLocal)

        for change in localChanges {
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
                try sendFile(entry: entry, baseRevision: clientState.knownEntries[entry.relativePath]?.revision ?? 0, over: connection)
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

        for entry in remoteEntries.values.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard shouldSyncPath(entry.relativePath, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths) else {
                clientState.knownEntries[entry.relativePath] = entry
                clientState.materializedPaths.remove(entry.relativePath)
                clearPendingDeletion(for: entry.relativePath)
                continue
            }

            if metadataEquivalent(currentLocal[entry.relativePath], entry) {
                clientState.knownEntries[entry.relativePath] = entry
                clearPendingDeletion(for: entry.relativePath)
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
                try applyIncomingServerDeletion(
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
                clearPendingDeletion(for: entry.relativePath)
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
            clearPendingDeletion(for: path)
        }

        localSnapshot = try scanEntries(at: rootURL!)
        clientState.materializedPaths = Set(localSnapshot.keys)
        saveClientState()
        refreshClientFinderBadges()
        updateStatus(.idle, detail: "Connected to \(peerRuntimes.values.first?.name ?? "server").")
    }

    private func applyIncomingServerTransfer(_ incoming: IncomingTransfer, hash: String?) throws {
        guard let rootURL else { return }

        let relativePath = incoming.start.relativePath
        let currentLocal = try scanEntries(at: rootURL)
        if hasUnsyncedLocalChange(
            path: relativePath,
            currentLocal: currentLocal,
            materializedPaths: clientState.materializedPaths,
            pendingDeletionPaths: clientState.pendingDeletionPaths
        ) {
            try createLocalConflictCopy(for: relativePath, currentLocal: currentLocal)
        }

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        try writeTransfer(incoming, hash: hash, under: rootURL)
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
        clearPendingDeletion(for: relativePath)
        localSnapshot = try scanEntries(at: rootURL)
        clientState.materializedPaths = Set(localSnapshot.keys)
        saveClientState()
        refreshClientFinderBadges()
        appendTransfer(relativePath: relativePath, direction: .download, status: "Completed", progress: 1, detail: "Downloaded from server")
    }

    private func applyIncomingServerDeletion(_ payload: NetworkSyncDeletePayload) throws {
        guard let rootURL else { return }

        let currentLocal = try scanEntries(at: rootURL)
        if hasUnsyncedLocalChange(
            path: payload.relativePath,
            currentLocal: currentLocal,
            materializedPaths: clientState.materializedPaths,
            pendingDeletionPaths: clientState.pendingDeletionPaths
        ) {
            try createLocalConflictCopy(for: payload.relativePath, currentLocal: currentLocal)
        }

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        let destinationURL = rootURL.appendingPathComponent(payload.relativePath)
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
        clearPendingDeletion(for: payload.relativePath)
        localSnapshot = try scanEntries(at: rootURL)
        clientState.materializedPaths = Set(localSnapshot.keys)
        saveClientState()
        clearFinderBadge(for: payload.relativePath)
        appendTransfer(relativePath: payload.relativePath, direction: .download, status: "Deleted", progress: nil, detail: "Applied server deletion")
    }

    private func applyIncomingClientTransfer(_ incoming: IncomingTransfer, hash: String?, from context: ConnectionContext) throws {
        guard let rootURL else { return }

        let currentEntry = serverState.entries[incoming.start.relativePath]
        let payloadHash: String? = incoming.start.isDirectory ? nil : (hash ?? sha256Hex(for: incoming.data))
        let hasRevisionConflict = currentEntry.map { $0.revision != incoming.start.baseRevision } ?? (incoming.start.baseRevision != 0)
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
            try writeTransfer(conflictTransfer, hash: payloadHash, under: rootURL)
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
            localSnapshot = try scanEntries(at: rootURL)
        appendConflict(relativePath: incoming.start.relativePath, detail: "Stored conflicting upload as \(conflictPath)")
            try sendEnvelope(.make(.conflict, payload: NetworkSyncConflictPayload(relativePath: incoming.start.relativePath, conflictPath: conflictPath, detail: "Stored as a conflict copy on the server."), encoder: encoder), over: context.connection)
            try broadcast(entry: entry, excluding: incoming.start.originDeviceID)
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

        try writeTransfer(acceptedTransfer, hash: payloadHash, under: rootURL)
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
        try saveServerState()
        localSnapshot = try scanEntries(at: rootURL)
        appendTransfer(relativePath: entry.relativePath, direction: .upload, status: "Accepted", progress: 1, detail: "Uploaded to server")
        try sendStateSnapshot(over: context.connection)
        try broadcast(entry: entry, excluding: incoming.start.originDeviceID)
    }

    private func applyIncomingClientDeletion(_ payload: NetworkSyncDeletePayload, from context: ConnectionContext) throws {
        guard let rootURL else { return }

        let currentEntry = serverState.entries[payload.relativePath]
        let hasRevisionConflict = currentEntry.map { $0.revision != payload.baseRevision } ?? (payload.baseRevision != 0)
        if hasRevisionConflict {
            appendConflict(relativePath: payload.relativePath, detail: "Deletion conflict from \(context.hello?.displayName ?? "client")")
            return
        }

        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }

        let destinationURL = rootURL.appendingPathComponent(payload.relativePath)
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
        try saveServerState()
        localSnapshot = try scanEntries(at: rootURL)
        try sendStateSnapshot(over: context.connection)
        try broadcastDelete(tombstone, excluding: payload.originDeviceID)
    }

    private enum LocalDiff {
        case upsert(NetworkSyncFileEntry)
        case delete(String)
    }

    private func pushClientChanges(_ changes: [LocalDiff]) throws {
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
                try sendFile(entry: entry, baseRevision: clientState.knownEntries[entry.relativePath]?.revision ?? 0, over: connection)
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

    private func pruneDeselectedLocalEntriesIfNeeded(at rootURL: URL) throws {
        guard config.role == .client, !config.syncEntireRoot else {
            return
        }

        let allLocalPaths = try scanAllLocalRelativePaths(at: rootURL)
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
            guard fileManager.fileExists(atPath: targetURL.path) else {
                continue
            }
            try fileManager.removeItem(at: targetURL)
            clearFinderBadge(for: relativePath)
        }

        clientState.materializedPaths.subtract(pathsToRemove)
        saveClientState()
    }

    private func sendFile(entry: NetworkSyncFileEntry, baseRevision: Int, over connection: NWConnection) throws {
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
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            while autoreleasepool(invoking: {
                let data = try? handle.read(upToCount: chunkSize)
                guard let data, !data.isEmpty else {
                    return false
                }
                try? sendEnvelope(.make(.fileTransferChunk, payload: NetworkSyncFileTransferChunkPayload(transferID: start.transferID, data: data), encoder: encoder), over: connection)
                return true
            }) {}
        }

        try sendEnvelope(.make(.fileTransferEnd, payload: NetworkSyncFileTransferEndPayload(transferID: start.transferID, contentHash: entry.contentHash), encoder: encoder), over: connection)
        appendTransfer(relativePath: entry.relativePath, direction: .upload, status: "Sent", progress: 1, detail: "Queued over network")
    }

    private func broadcast(entry: NetworkSyncFileEntry, excluding originDeviceID: UUID?) throws {
        for context in connections.values {
            guard let hello = context.hello, hello.mode == .client else { continue }
            guard hello.deviceID != originDeviceID else { continue }
            guard shouldSyncPath(entry.relativePath, syncEntireRoot: hello.syncEntireRoot, includedPaths: hello.includedPaths) else { continue }
            try sendFile(entry: entry, baseRevision: entry.revision, over: context.connection)
        }
    }

    private func broadcastDelete(_ entry: NetworkSyncFileEntry, excluding originDeviceID: UUID?) throws {
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

    private func reconcileServerStateWithDisk(broadcast: Bool, originDeviceID: UUID?) throws {
        guard let rootURL else { return }

        let diskEntries = try scanEntries(at: rootURL)
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
            try self.broadcast(entry: entry, excluding: originDeviceID)
        }
        for entry in deletedEntries {
            try self.broadcastDelete(entry, excluding: originDeviceID)
        }
    }

    private func scanEntries(at rootURL: URL) throws -> [String: NetworkSyncFileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return [:]
        }

        var results: [String: NetworkSyncFileEntry] = [:]
        for case let fileURL as URL in enumerator {
            if fileURL.path.contains("/.starfiler-sync/") || fileURL.lastPathComponent == ".starfiler-sync" {
                enumerator.skipDescendants()
                continue
            }

            let relativePath = relativePath(from: rootURL, to: fileURL)
            guard shouldSyncPath(relativePath, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths),
                  !matchesExcludeRules(relativePath: relativePath)
            else {
                if isDirectoryURL(fileURL) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
            let isDirectory = resourceValues.isDirectory ?? false
            let size = Int64(resourceValues.fileSize ?? 0)
            let modificationTimestamp = (resourceValues.contentModificationDate ?? Date()).timeIntervalSince1970
            let contentHash = isDirectory ? nil : try fileHashIfNeeded(for: fileURL, size: size)
            results[relativePath] = NetworkSyncFileEntry(
                relativePath: relativePath,
                isDirectory: isDirectory,
                size: size,
                modificationTimestamp: modificationTimestamp,
                contentHash: contentHash,
                revision: 0,
                deleted: false
            )
        }

        return results
    }

    private func scanAllLocalRelativePaths(at rootURL: URL) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            if fileURL.path.contains("/.starfiler-sync/") || fileURL.lastPathComponent == ".starfiler-sync" {
                enumerator.skipDescendants()
                continue
            }

            let relativePath = relativePath(from: rootURL, to: fileURL)
            guard !relativePath.isEmpty else {
                continue
            }
            results.append(relativePath)
        }

        return results
    }

    private func fileHashIfNeeded(for fileURL: URL, size: Int64) throws -> String? {
        guard size <= fileHashThresholdBytes else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return sha256Hex(for: data)
    }

    private func diff(old: [String: NetworkSyncFileEntry], new: [String: NetworkSyncFileEntry]) -> [LocalDiff] {
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

    private func diffAgainstKnown(known: [String: NetworkSyncFileEntry], local: [String: NetworkSyncFileEntry]) -> [LocalDiff] {
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

    private func hasUnsyncedLocalChange(
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

    private func hasPendingDeletion(for path: String, pendingDeletionPaths: Set<String>) -> Bool {
        pendingDeletionPaths.contains { pendingPath in
            path == pendingPath || path.hasPrefix(pendingPath + "/")
        }
    }

    private func clearPendingDeletion(for path: String) {
        clientState.pendingDeletionPaths = clientState.pendingDeletionPaths.filter { pendingPath in
            pendingPath != path && !pendingPath.hasPrefix(path + "/")
        }
    }

    private func metadataEquivalent(_ lhs: NetworkSyncFileEntry?, _ rhs: NetworkSyncFileEntry?) -> Bool {
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

    private func writeTransfer(_ incoming: IncomingTransfer, hash: String?, under rootURL: URL) throws {
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
    }

    private func createLocalConflictCopy(for relativePath: String, currentLocal: [String: NetworkSyncFileEntry]) throws {
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

    private func conflictRelativePath(for relativePath: String, peerName: String) -> String {
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

    private func sendEnvelope(_ envelope: NetworkSyncEnvelope, over connection: NWConnection) throws {
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

    private func sendStateSnapshot(over connection: NWConnection) throws {
        let entries = serverState.entries.values.sorted { $0.relativePath < $1.relativePath }
        try sendEnvelope(.make(.stateSnapshot, payload: NetworkSyncStateSnapshotPayload(entries: entries), encoder: encoder), over: connection)
    }

    private func loadServerState() throws {
        let stateURL = serverStateURL()
        if !fileManager.fileExists(atPath: stateURL.path) {
            try migrateLegacyServerStateIfNeeded(to: stateURL)
        }

        if let data = try? Data(contentsOf: stateURL) {
            serverState = try decoder.decode(NetworkSyncServerState.self, from: data)
        } else {
            serverState = NetworkSyncServerState()
        }
    }

    private func saveServerState() throws {
        let stateURL = serverStateURL()
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(serverState).write(to: stateURL, options: .atomic)
    }

    private func loadClientState() {
        let stateURL = clientStateURL()
        if !fileManager.fileExists(atPath: stateURL.path) {
            migrateLegacyClientStateIfNeeded(to: stateURL)
        }

        if let data = try? Data(contentsOf: stateURL),
           let state = try? decoder.decode(NetworkSyncClientState.self, from: data) {
            clientState = state
        } else {
            clientState = NetworkSyncClientState()
        }
    }

    private func saveClientState() {
        let stateURL = clientStateURL()
        try? fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(clientState).write(to: stateURL, options: .atomic)
    }

    private func serverStateURL() -> URL {
        configManager
            .networkSyncRuntimeDirectory(rootPath: rootURL!.path)
            .appendingPathComponent("server-state.json")
    }

    private func clientStateURL() -> URL {
        configManager
            .networkSyncRuntimeDirectory(rootPath: config.effectiveRootPath)
            .appendingPathComponent("client-state.json")
    }

    private func temporaryDirectoryURL(under rootURL: URL) -> URL {
        configManager
            .networkSyncRuntimeDirectory(rootPath: rootURL.path)
            .appendingPathComponent("tmp", isDirectory: true)
    }

    private func migrateLegacyServerStateIfNeeded(to destinationURL: URL) throws {
        guard let rootURL else {
            return
        }

        let legacyURL = rootURL.appendingPathComponent(".starfiler-sync/state.json")
        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }

        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: legacyURL, to: destinationURL)
    }

    private func migrateLegacyClientStateIfNeeded(to destinationURL: URL) {
        let legacyURL = configManager.configDirectory.appendingPathComponent("NetworkSyncClientState.json")
        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }

        try? fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.copyItem(at: legacyURL, to: destinationURL)
    }

    private func nextServerRevision() -> Int {
        let revision = serverState.nextRevision
        serverState.nextRevision += 1
        return revision
    }

    private func shouldSyncPath(_ relativePath: String, syncEntireRoot: Bool, includedPaths: [String]) -> Bool {
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

    private func matchesExcludeRules(relativePath: String) -> Bool {
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

    private func normalizeRelativePath(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let trimmed = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : filePath
        return normalizeRelativePath(trimmed)
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func appendConflict(relativePath: String, detail: String) {
        conflicts.insert(
            NetworkSyncConflictRecord(id: UUID().uuidString, relativePath: relativePath, detail: detail, timestamp: Date()),
            at: 0
        )
        conflicts = Array(conflicts.prefix(10))
        snapshot.conflicts = conflicts
        snapshot.status = .syncing
        applyFinderBadges(for: [relativePath], status: .attention)
        publishSnapshot()
    }

    private func appendTransfer(relativePath: String, direction: NetworkSyncTransferDirection, status: String, progress: Double?, detail: String) {
        transfers.insert(
            NetworkSyncTransferRecord(
                id: UUID().uuidString,
                relativePath: relativePath,
                direction: direction,
                status: status,
                progress: progress,
                detail: detail,
                timestamp: Date()
            ),
            at: 0
        )
        transfers = Array(transfers.prefix(20))
        snapshot.transfers = transfers
        let badgeStatus: FinderBadgeStatus
        switch status {
        case "Completed":
            badgeStatus = .synced
        default:
            badgeStatus = .syncing
        }
        applyFinderBadges(for: [relativePath], status: badgeStatus)
        publishSnapshot()
    }

    private func markTransferActive(relativePath: String, activity: NetworkSyncTransferActivity) {
        activeTransfersByPath[relativePath] = activity
        if snapshot.status == .idle || snapshot.status == .starting {
            snapshot.status = .syncing
        }
        publishSnapshot()
    }

    private func finishTransferActivity(relativePath: String) {
        activeTransfersByPath.removeValue(forKey: relativePath)
        if activeTransfersByPath.isEmpty, snapshot.status == .syncing {
            snapshot.status = .idle
        }
        publishSnapshot()
    }

    private enum FinderBadgeStatus {
        case synced
        case syncing
        case pending
        case attention
    }

    private func refreshClientFinderBadges() {
        guard config.role == .client else {
            return
        }

        var pendingPaths: Set<String> = []
        var syncingPaths: Set<String> = []
        var conflictPaths: Set<String> = []

        for (path, localEntry) in localSnapshot where isUnsyncedClientEntry(path: path, localEntry: localEntry) {
            markPathAndAncestors(path, into: &pendingPaths)
        }

        for path in activeTransfersByPath.keys {
            markPathAndAncestors(path, into: &syncingPaths)
        }

        for conflict in conflicts {
            markPathAndAncestors(conflict.relativePath, into: &conflictPaths)
        }

        for path in localSnapshot.keys.sorted() {
            let status: FinderBadgeStatus
            if conflictPaths.contains(path) {
                status = .attention
            } else if syncingPaths.contains(path) {
                status = .syncing
            } else if pendingPaths.contains(path) {
                status = .pending
            } else {
                status = .synced
            }
            applyFinderBadges(for: [path], status: status)
        }
    }

    private func isUnsyncedClientEntry(path: String, localEntry: NetworkSyncFileEntry) -> Bool {
        guard config.role == .client else {
            return false
        }

        if hasPendingDeletion(for: path, pendingDeletionPaths: clientState.pendingDeletionPaths) {
            return true
        }

        guard let knownEntry = clientState.knownEntries[path] else {
            return true
        }

        return !metadataEquivalent(knownEntry, localEntry)
    }

    private func markPathAndAncestors(_ relativePath: String, into set: inout Set<String>) {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            return
        }

        var path = normalizedPath
        while !path.isEmpty {
            set.insert(path)
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == "." || parent == path {
                break
            }
            path = parent
        }
    }

    private func applyFinderBadges(for relativePaths: some Sequence<String>, status: FinderBadgeStatus) {
        guard config.role == .client, let rootURL else {
            return
        }

        for relativePath in relativePaths {
            let normalizedPath = normalizeRelativePath(relativePath)
            guard !normalizedPath.isEmpty else {
                continue
            }
            let fileURL = rootURL.appendingPathComponent(normalizedPath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }
            applyFinderBadge(to: fileURL, status: status)
        }
    }

    private func clearFinderBadge(for relativePath: String) {
        guard config.role == .client, let rootURL else {
            return
        }

        let normalizedPath = normalizeRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            return
        }

        let fileURL = rootURL.appendingPathComponent(normalizedPath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        NSWorkspace.shared.setIcon(nil, forFile: fileURL.path, options: [])
    }

    private func applyFinderBadge(to fileURL: URL, status: FinderBadgeStatus) {
        NSWorkspace.shared.setIcon(nil, forFile: fileURL.path, options: [])
        let baseIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
        baseIcon.isTemplate = false

        let symbolName: String
        let tint: NSColor
        switch status {
        case .synced:
            symbolName = "checkmark.circle.fill"
            tint = .systemGreen
        case .syncing:
            symbolName = "arrow.triangle.2.circlepath.circle.fill"
            tint = .systemBlue
        case .pending:
            symbolName = "clock.fill"
            tint = .systemYellow
        case .attention:
            symbolName = "exclamationmark.triangle.fill"
            tint = .systemOrange
        }

        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return
        }

        let iconSize = max(max(baseIcon.size.width, baseIcon.size.height), 32)
        let canvasSize = NSSize(width: iconSize, height: iconSize)
        let badgedIcon = NSImage(size: canvasSize)
        badgedIcon.lockFocus()
        baseIcon.size = canvasSize
        baseIcon.draw(in: NSRect(origin: .zero, size: canvasSize))

        let badgeSide = max(14, canvasSize.width * 0.42)
        let badgeRect = NSRect(
            x: canvasSize.width - badgeSide,
            y: 0,
            width: badgeSide,
            height: badgeSide
        )
        let circlePath = NSBezierPath(ovalIn: badgeRect)
        tint.setFill()
        circlePath.fill()

        let configuredSymbol = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: badgeSide * 0.72, weight: .bold)
        ) ?? symbol
        let tinted = configuredSymbol.copy() as? NSImage ?? configuredSymbol
        tinted.isTemplate = true
        tinted.size = NSSize(width: badgeSide * 0.78, height: badgeSide * 0.78)
        NSColor.white.set()
        let symbolOrigin = NSPoint(
            x: badgeRect.midX - (tinted.size.width / 2),
            y: badgeRect.midY - (tinted.size.height / 2)
        )
        tinted.draw(in: NSRect(origin: symbolOrigin, size: tinted.size), from: .zero, operation: .sourceOver, fraction: 1)
        badgedIcon.unlockFocus()

        NSWorkspace.shared.setIcon(badgedIcon, forFile: fileURL.path, options: [])
    }

    private func updateStatus(_ status: NetworkSyncRuntimeStatus, detail: String) {
        snapshot.status = status
        snapshot.detail = detail
        publishSnapshot()
    }

    private func setError(_ detail: String) {
        snapshot.status = .error
        snapshot.detail = detail
        publishSnapshot()
    }

    private func publishSnapshot() {
        snapshot.peers = Array(peerRuntimes.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        snapshot.conflicts = conflicts
        snapshot.transfers = transfers
        snapshot.activeTransfers = activeTransfersByPath
        onSnapshot?(snapshot)
    }

    private static let legacyDeviceIDDefaultsKey = "NetworkSyncService.deviceID"
    private static let deviceIDFileName = "NetworkSyncDeviceID"
    private static let conflictDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private static func resolveDeviceID(configDirectory: URL) -> UUID {
        let fileURL = configDirectory.appendingPathComponent(deviceIDFileName, isDirectory: false)
        if let data = try? Data(contentsOf: fileURL),
           let rawValue = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let existing = UUID(uuidString: rawValue) {
            return existing
        }

        let shouldMigrateLegacyDefaults = configDirectory.standardizedFileURL == ConfigManager.defaultFallbackConfigDirectory().standardizedFileURL
        if shouldMigrateLegacyDefaults,
           let rawValue = UserDefaults.standard.string(forKey: legacyDeviceIDDefaultsKey),
           let existing = UUID(uuidString: rawValue) {
            persistDeviceID(existing, to: fileURL)
            return existing
        }

        let created = UUID()
        persistDeviceID(created, to: fileURL)
        return created
    }

    private static func persistDeviceID(_ deviceID: UUID, to fileURL: URL) {
        let data = Data(deviceID.uuidString.utf8)
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension NWEndpoint {
    var serviceName: String? {
        if case .service(let name, _, _, _) = self {
            return name
        }
        return nil
    }
}

private final class NetworkSyncPathMonitor {
    private let url: URL
    private let debounceInterval: TimeInterval
    private let callback: () -> Void
    private let queue = DispatchQueue(label: "com.nilone.starfiler.network-sync.fsevents")
    private var stream: FSEventStreamRef?
    private var pendingWorkItem: DispatchWorkItem?

    init(url: URL, debounceInterval: TimeInterval, callback: @escaping () -> Void) {
        self.url = url
        self.debounceInterval = debounceInterval
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        let paths = [url.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<NetworkSyncPathMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.scheduleCallback()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil

        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleCallback() {
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem(block: callback)
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
