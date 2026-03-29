import CoreServices
import CryptoKit
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

    final class ConnectionContext {
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

    struct IncomingTransfer {
        var start: NetworkSyncFileTransferStartPayload
        var data: Data
    }

    enum LocalDiff {
        case upsert(NetworkSyncFileEntry)
        case delete(String)
    }

    private let serviceType = "_starfiler-sync._tcp"
    let chunkSize = 64 * 1024
    let fileHashThresholdBytes: Int64 = 10 * 1024 * 1024
    private let role: SyncNodeMode
    let configManager: ConfigManager
    private let securityScopedBookmarkService: any SecurityScopedBookmarkProviding
    let fileManager: FileManager
    let executionContext = NetworkSyncExecutionContext()
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let deviceID: UUID

    var config: NetworkSyncRoleRuntimeConfig
    var snapshot: NetworkSyncRuntimeSnapshot = .disabled
    private var listener: NWListener?
    private var browser: NWBrowser?
    var connections: [String: ConnectionContext] = [:]
    var clientConnectionID: String?
    private var pathMonitor: NetworkSyncPathMonitor?
    private var heartbeatTimer: Timer?
    var rootURL: URL?
    private var activeRootAccessURL: URL?
    var localSnapshot: [String: NetworkSyncFileEntry] = [:]
    var serverState = NetworkSyncServerState()
    var clientState = NetworkSyncClientState()
    var lastSavedClientStateData: Data?
    var acknowledgedClientRevisionsByDevice: [String: [String: Int]] = [:]
    var peerRuntimes: [String: NetworkSyncPeerRuntime] = [:]
    var conflicts: [NetworkSyncConflictRecord] = []
    var transfers: [NetworkSyncTransferRecord] = []
    var activeTransfersByPath: [String: NetworkSyncTransferActivity] = [:]
    var browserStateVersion = 0
    var isApplyingRemoteChange = false
    let finderBadgeManager = NetworkSyncFinderBadgeManager()
    var suppressLocalRootEventsUntil = Date.distantPast
    private var suppressedLocalRootRetryTask: Task<Void, Never>?
    private var pendingLocalRootVerificationTask: Task<Void, Never>?
    private var remainingLocalRootVerificationPasses = 0
    var isProcessingLocalRootChange = false
    var hasPendingLocalRootChange = false
    var needsStateRefreshAfterLocalChange = false

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
                self.finderBadgeManager.configure(
                    rootURL: rootURL,
                    syncDebounceSeconds: self.config.syncDebounceSeconds,
                    suppressLocalRootEvents: { [weak self] duration in
                        self?.suppressLocalRootEvents(for: duration)
                    },
                    logDuration: { [weak self] operation, startedAt in
                        self?.logDuration(operation, startedAt: startedAt)
                    }
                )

                if !self.fileManager.fileExists(atPath: rootURL.path) {
                    try self.fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                }

                self.snapshot.status = .starting
                self.snapshot.detail = "Starting \(self.config.role.displayName.lowercased())…"
                self.publishSnapshot()

                switch self.config.role {
                case .server:
                    self.localSnapshot = try await self.scanEntries(at: rootURL)
                    self.startPathMonitor(for: rootURL)
                    self.startHeartbeat()
                    try self.loadServerState()
                    try await self.reconcileServerStateWithDisk(broadcast: false, originDeviceID: nil)
                    try self.startServerListener()
                    self.updateStatus(.idle, detail: "Server is advertising on the local network.")
                case .client:
                    self.loadClientState()
                    try await self.pruneDeselectedLocalEntriesIfNeeded(at: rootURL)
                    self.localSnapshot = try await self.scanEntries(at: rootURL)
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
        finderBadgeManager.reset()
        suppressedLocalRootRetryTask?.cancel()
        suppressedLocalRootRetryTask = nil
        pendingLocalRootVerificationTask?.cancel()
        pendingLocalRootVerificationTask = nil
        remainingLocalRootVerificationPasses = 0
        suppressLocalRootEventsUntil = .distantPast
        isProcessingLocalRootChange = false
        hasPendingLocalRootChange = false
        needsStateRefreshAfterLocalChange = false

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
            ? NetworkSyncRuntimeSnapshot(
                status: .offline,
                detail: "Network sync stopped.",
                peers: [],
                conflicts: conflicts,
                transfers: transfers,
                activeTransfers: [:],
                browserStateVersion: browserStateVersion
            )
            : .disabled
        publishSnapshot()
    }

    func reload(config: NetworkSyncConfig) {
        self.config = config.runtimeConfig(for: role)
        start()
    }

    func requestRefresh() {
        guard config.isEnabled, let rootURL else {
            publishSnapshot()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.localSnapshot = try await self.scanEntries(at: rootURL)
                if self.config.role == .client {
                    self.refreshClientFinderBadges()
                }
                self.publishSnapshot()
            } catch {
                self.setError(error.localizedDescription)
            }
        }
    }

    // MARK: - Path Monitoring

    private func startPathMonitor(for rootURL: URL) {
        let monitor = NetworkSyncPathMonitor(url: rootURL, debounceInterval: config.syncDebounceSeconds) { [weak self] in
            Task { @MainActor in
                self?.scheduleLocalRootChangeHandling()
            }
        }
        monitor.start()
        pathMonitor = monitor
    }

    func scheduleLocalRootChangeHandling() {
        guard !isProcessingLocalRootChange else {
            hasPendingLocalRootChange = true
            return
        }

        isProcessingLocalRootChange = true
        Task { @MainActor [weak self] in
            await self?.drainLocalRootChanges()
        }
    }

    private func drainLocalRootChanges() async {
        repeat {
            hasPendingLocalRootChange = false
            await handleLocalRootChange()
        } while hasPendingLocalRootChange

        isProcessingLocalRootChange = false

        if needsStateRefreshAfterLocalChange {
            needsStateRefreshAfterLocalChange = false
            requestServerStateSnapshot()
        }
    }

    private func handleLocalRootChange() async {
        guard !isApplyingRemoteChange, let rootURL else {
            return
        }
        guard Date() >= suppressLocalRootEventsUntil else {
            scheduleSuppressedLocalRootRetry()
            return
        }

        do {
            switch config.role {
            case .server:
                localSnapshot = try await scanEntries(at: rootURL)
                try await reconcileServerStateWithDisk(broadcast: true, originDeviceID: nil)
            case .client:
                let latestSnapshot = try await scanEntries(at: rootURL)
                var changes = diff(old: localSnapshot, new: latestSnapshot)
                let updatedMaterializedPaths = Set(latestSnapshot.keys)
                let deletedPaths = Set(
                    clientState.materializedPaths.subtracting(updatedMaterializedPaths).filter {
                        shouldSyncPath($0, syncEntireRoot: config.syncEntireRoot, includedPaths: config.includedPaths)
                    }
                )
                let upsertedPaths = Set(
                    changes.compactMap { change -> String? in
                        guard case .upsert(let entry) = change else { return nil }
                        return entry.relativePath
                    }
                )
                let deletedChanges = Set(
                    changes.compactMap { change -> String? in
                        guard case .delete(let path) = change else { return nil }
                        return path
                    }
                )
                for path in deletedPaths.subtracting(deletedChanges).sorted() {
                    changes.append(.delete(path))
                }
                var updatedPendingDeletionPaths = clientState.pendingDeletionPaths
                updatedPendingDeletionPaths.formUnion(deletedPaths)
                updatedPendingDeletionPaths.subtract(upsertedPaths)

                guard !changes.isEmpty ||
                    updatedMaterializedPaths != clientState.materializedPaths ||
                    updatedPendingDeletionPaths != clientState.pendingDeletionPaths else {
                    return
                }

                localSnapshot = latestSnapshot
                clientState.materializedPaths = updatedMaterializedPaths
                clientState.pendingDeletionPaths = updatedPendingDeletionPaths
                stageClientLocalChanges(changes)
                saveClientState()
                refreshClientFinderBadges()
                try await pushClientChanges(changes)
                scheduleLocalRootVerification()
            }
        } catch {
            setError(error.localizedDescription)
        }
    }

    // MARK: - Heartbeat

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

    // MARK: - Server Listener

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

    // MARK: - Client Browser

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

    // MARK: - Connection Management

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
                scheduleLocalRootChangeHandling()
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

    // MARK: - Receive Loop

    private func startReceiveLoop(for id: String) {
        guard let context = connections[id] else {
            return
        }

        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let data, !data.isEmpty, let context = self.connections[id] {
                    context.receiveBuffer.append(data)
                    await self.consumeFrames(for: context)
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

    private func consumeFrames(for context: ConnectionContext) async {
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
                try await handleEnvelope(envelope, from: context)
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    // MARK: - Envelope Handling

    private func handleEnvelope(_ envelope: NetworkSyncEnvelope, from context: ConnectionContext) async throws {
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
            try await applyServerSnapshot(payload.entries, over: context.connection)
        case .fileRequest:
            guard config.role == .server else { return }
            let request = try envelope.decode(NetworkSyncFileRequestPayload.self, decoder: decoder)
            guard let entry = serverState.entries[request.relativePath], !entry.deleted else { return }
            try await sendFile(entry: entry, baseRevision: entry.revision, over: context.connection)
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
                try await applyIncomingClientTransfer(incoming, hash: payload.contentHash, from: context)
            } else {
                try await applyIncomingServerTransfer(incoming, hash: payload.contentHash)
            }
        case .delete:
            let payload = try envelope.decode(NetworkSyncDeletePayload.self, decoder: decoder)
            if config.role == .server {
                try await applyIncomingClientDeletion(payload, from: context)
            } else {
                try await applyIncomingServerDeletion(payload)
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

    // MARK: - Suppression & Verification

    func suppressLocalRootEvents(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        if deadline > suppressLocalRootEventsUntil {
            suppressLocalRootEventsUntil = deadline
        }
    }

    private func scheduleSuppressedLocalRootRetry() {
        guard suppressedLocalRootRetryTask == nil else {
            return
        }

        let delay = max(suppressLocalRootEventsUntil.timeIntervalSinceNow, 0.1)
        suppressedLocalRootRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.suppressedLocalRootRetryTask = nil
            self.scheduleLocalRootChangeHandling()
        }
    }

    func scheduleLocalRootVerification() {
        remainingLocalRootVerificationPasses = max(remainingLocalRootVerificationPasses, 3)
        guard pendingLocalRootVerificationTask == nil else {
            return
        }

        let delay = max(0.2, config.syncDebounceSeconds)
        pendingLocalRootVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.pendingLocalRootVerificationTask = nil
            guard self.remainingLocalRootVerificationPasses > 0 else {
                return
            }
            self.remainingLocalRootVerificationPasses -= 1
            self.scheduleLocalRootChangeHandling()
            if self.remainingLocalRootVerificationPasses > 0 {
                self.scheduleLocalRootVerification()
            }
        }
    }

    func localRootEventSuppressionWindow() -> TimeInterval {
        max(0.5, config.syncDebounceSeconds * 2)
    }

    // MARK: - Transfer Activity Tracking

    func markTransferActive(relativePath: String, activity: NetworkSyncTransferActivity) {
        activeTransfersByPath[relativePath] = activity
        if snapshot.status == .idle || snapshot.status == .starting {
            snapshot.status = .syncing
        }
        publishSnapshot()
    }

    func finishTransferActivity(relativePath: String) {
        activeTransfersByPath.removeValue(forKey: relativePath)
        if activeTransfersByPath.isEmpty, snapshot.status == .syncing {
            snapshot.status = .idle
        }
        publishSnapshot()
    }

    // MARK: - Conflict & Transfer Logging

    func appendConflict(relativePath: String, detail: String) {
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

    func appendTransfer(relativePath: String, direction: NetworkSyncTransferDirection, status: String, progress: Double?, detail: String) {
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
        let badgeStatus: NetworkSyncFinderBadgeManager.FinderBadgeStatus
        switch status {
        case "Completed":
            badgeStatus = .synced
        default:
            badgeStatus = .syncing
        }
        applyFinderBadges(for: [relativePath], status: badgeStatus)
        publishSnapshot()
    }

    // MARK: - Revision Tracking

    func nextServerRevision() -> Int {
        let revision = serverState.nextRevision
        serverState.nextRevision += 1
        return revision
    }

    func effectiveClientBaseRevision(
        requestedBaseRevision: Int,
        relativePath: String,
        deviceID: UUID
    ) -> Int {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard !normalizedPath.isEmpty,
              let acknowledgedRevision = acknowledgedClientRevisionsByDevice[deviceID.uuidString]?[normalizedPath],
              requestedBaseRevision < acknowledgedRevision
        else {
            return requestedBaseRevision
        }
        return acknowledgedRevision
    }

    func recordAcknowledgedClientRevision(_ revision: Int, for relativePath: String, deviceID: UUID) {
        let normalizedPath = normalizeRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            return
        }

        var revisions = acknowledgedClientRevisionsByDevice[deviceID.uuidString] ?? [:]
        revisions[normalizedPath] = revision
        acknowledgedClientRevisionsByDevice[deviceID.uuidString] = revisions
    }

    // MARK: - Status Helpers

    func updateStatus(_ status: NetworkSyncRuntimeStatus, detail: String) {
        snapshot.status = status
        snapshot.detail = detail
        publishSnapshot()
    }

    func setError(_ detail: String) {
        snapshot.status = .error
        snapshot.detail = detail
        publishSnapshot()
    }

    func logDuration(_ operation: String, startedAt: CFAbsoluteTime) {
        let elapsed = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        NSLog("NetworkSyncService[%@] %@ completed in %.1f ms", role.rawValue, operation, elapsed)
    }

    func publishSnapshot() {
        snapshot.peers = Array(peerRuntimes.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        snapshot.conflicts = conflicts
        snapshot.transfers = transfers
        snapshot.activeTransfers = activeTransfersByPath
        snapshot.browserStateVersion = browserStateVersion
        onSnapshot?(snapshot)
    }

    // MARK: - Device ID

    private static let legacyDeviceIDDefaultsKey = "NetworkSyncService.deviceID"
    private static let deviceIDFileName = "NetworkSyncDeviceID"
    static let conflictDateFormatter: DateFormatter = {
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

extension NetworkSyncClientState {
    mutating func clearPendingDeletion(at path: String) {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        guard !normalizedPath.isEmpty else {
            return
        }

        pendingDeletionPaths.remove(normalizedPath)
    }

    mutating func clearPendingDeletionTree(at path: String) {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        guard !normalizedPath.isEmpty else {
            return
        }

        pendingDeletionPaths = pendingDeletionPaths.filter { pendingPath in
            pendingPath != normalizedPath && !pendingPath.hasPrefix(normalizedPath + "/")
        }
    }
}

actor NetworkSyncExecutionContext {
    private let fileManager = FileManager.default

    func scanEntries(
        at rootURL: URL,
        syncEntireRoot: Bool,
        includedPaths: [String],
        fileHashThresholdBytes: Int64
    ) throws -> [String: NetworkSyncFileEntry] {
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
            if Self.shouldIgnoreLocalArtifact(at: fileURL) {
                if Self.isDirectoryURL(fileURL) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let relativePath = Self.relativePath(from: rootURL, to: fileURL)
            guard Self.shouldSyncPath(relativePath, syncEntireRoot: syncEntireRoot, includedPaths: includedPaths),
                  !Self.matchesExcludeRules(relativePath: relativePath)
            else {
                if Self.isDirectoryURL(fileURL) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
            let isDirectory = resourceValues.isDirectory ?? false
            let size = Int64(resourceValues.fileSize ?? 0)
            let modificationTimestamp = (resourceValues.contentModificationDate ?? Date()).timeIntervalSince1970
            let contentHash = isDirectory ? nil : try fileHashIfNeeded(for: fileURL, size: size, thresholdBytes: fileHashThresholdBytes)
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

    func scanAllLocalRelativePaths(at rootURL: URL) throws -> [String] {
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
            if Self.shouldIgnoreLocalArtifact(at: fileURL) {
                if Self.isDirectoryURL(fileURL) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let relativePath = Self.relativePath(from: rootURL, to: fileURL)
            guard !relativePath.isEmpty else {
                continue
            }
            results.append(relativePath)
        }

        return results
    }

    func readFileChunks(at fileURL: URL, chunkSize: Int) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var chunks: [Data] = []
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            chunks.append(data)
        }
        return chunks
    }

    func writeTransfer(
        relativePath: String,
        isDirectory: Bool,
        modificationTimestamp: TimeInterval,
        data: Data,
        temporaryDirectoryURL: URL,
        rootURL: URL
    ) throws {
        let destinationURL = rootURL.appendingPathComponent(relativePath)
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        if isDirectory {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } else {
            let tempURL = temporaryDirectoryURL.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }

        let modificationDate = Date(timeIntervalSince1970: modificationTimestamp)
        try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: destinationURL.path)
    }

    func removeItemIfExists(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    func replaceItem(at destinationURL: URL, withCopyOf sourceURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func fileHashIfNeeded(for fileURL: URL, size: Int64, thresholdBytes: Int64) throws -> String? {
        guard size <= thresholdBytes else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func shouldSyncPath(_ relativePath: String, syncEntireRoot: Bool, includedPaths: [String]) -> Bool {
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

    private static func matchesExcludeRules(relativePath: String) -> Bool {
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

    private static func normalizeRelativePath(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private static func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let trimmed = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : filePath
        return normalizeRelativePath(trimmed)
    }

    private static func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func shouldIgnoreLocalArtifact(at url: URL) -> Bool {
        url.lastPathComponent == "Icon\r"
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
    private var needsFollowUpCallback = false

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

        let callback: FSEventStreamCallback = { _, info, eventCount, _, eventFlags, _ in
            guard let info else { return }
            let monitor = Unmanaged<NetworkSyncPathMonitor>.fromOpaque(info).takeUnretainedValue()
            let flags = UnsafeBufferPointer(start: eventFlags, count: eventCount)
            guard flags.contains(where: NetworkSyncPathMonitor.isMeaningfulEvent) else {
                return
            }
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
        needsFollowUpCallback = false

        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleCallback() {
        guard pendingWorkItem == nil else {
            needsFollowUpCallback = true
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.pendingWorkItem = nil
            self.callback()
            if self.needsFollowUpCallback {
                self.needsFollowUpCallback = false
                self.scheduleCallback()
            }
        }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private static func isMeaningfulEvent(_ flags: FSEventStreamEventFlags) -> Bool {
        let metadataOnlyFlags = Self.eventFlags([
            kFSEventStreamEventFlagItemInodeMetaMod,
            kFSEventStreamEventFlagItemFinderInfoMod,
            kFSEventStreamEventFlagItemChangeOwner,
            kFSEventStreamEventFlagItemXattrMod,
        ])

        let meaningfulFlags = Self.eventFlags([
            kFSEventStreamEventFlagMustScanSubDirs,
            kFSEventStreamEventFlagRootChanged,
            kFSEventStreamEventFlagMount,
            kFSEventStreamEventFlagUnmount,
            kFSEventStreamEventFlagItemCreated,
            kFSEventStreamEventFlagItemRemoved,
            kFSEventStreamEventFlagItemRenamed,
            kFSEventStreamEventFlagItemModified,
            kFSEventStreamEventFlagItemCloned,
        ])

        if flags & meaningfulFlags != 0 {
            return true
        }

        return flags & ~metadataOnlyFlags != 0
    }

    private static func eventFlags(_ values: [Int]) -> FSEventStreamEventFlags {
        values.reduce(FSEventStreamEventFlags(0)) { partial, value in
            partial | FSEventStreamEventFlags(value)
        }
    }
}
