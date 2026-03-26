import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.nilone.starfiler.sync", category: "Connection")

// MARK: - Protocols

protocol SyncConnectionManaging: Sendable {
    func startListening(port: UInt16) async throws
    func connect(to endpoint: NWEndpoint) async throws
    func connect(host: String, port: UInt16) async throws
    func disconnect(peerID: SyncPeerID) async
    func disconnectAll() async
    func stop() async
    func send(_ message: SyncMessage, to peerID: SyncPeerID) async throws
    var incomingMessages: AsyncStream<(SyncPeerID, SyncMessage)> { get }
    var connectionEvents: AsyncStream<SyncPeerEvent> { get }
}

// MARK: - Connection Service

actor SyncConnectionService: SyncConnectionManaging {
    private struct PeerConnection: Sendable {
        let connection: NWConnection
        let peerID: SyncPeerID
        var state: SyncPeerConnectionState
    }

    private var listener: NWListener?
    private var connections: [SyncPeerID: PeerConnection] = [:]
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]
    private let codec = SyncMessageCodec()
    private let localPeerInfo: SyncPeerInfo
    private let heartbeatInterval: TimeInterval

    private var messageContinuation: AsyncStream<(SyncPeerID, SyncMessage)>.Continuation?
    private var eventContinuation: AsyncStream<SyncPeerEvent>.Continuation?

    nonisolated let incomingMessages: AsyncStream<(SyncPeerID, SyncMessage)>
    nonisolated let connectionEvents: AsyncStream<SyncPeerEvent>

    private var heartbeatTasks: [SyncPeerID: Task<Void, Never>] = [:]
    private var receiveTasks: [SyncPeerID: Task<Void, Never>] = [:]
    private var reconnectTasks: [SyncPeerID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [SyncPeerID: Int] = [:]

    init(localPeerInfo: SyncPeerInfo, heartbeatInterval: TimeInterval = 30) {
        self.localPeerInfo = localPeerInfo
        self.heartbeatInterval = heartbeatInterval

        var msgCont: AsyncStream<(SyncPeerID, SyncMessage)>.Continuation!
        self.incomingMessages = AsyncStream { c in msgCont = c }

        var evtCont: AsyncStream<SyncPeerEvent>.Continuation!
        self.connectionEvents = AsyncStream { c in evtCont = c }

        Task {
            await self.storeContinuations(msgCont, evtCont)
        }
    }

    private func storeContinuations(
        _ msg: AsyncStream<(SyncPeerID, SyncMessage)>.Continuation,
        _ evt: AsyncStream<SyncPeerEvent>.Continuation
    ) {
        self.messageContinuation = msg
        self.eventContinuation = evt
    }

    // MARK: - Listening (Server)

    func startListening(port: UInt16) async throws {
        stopListening()

        let nwListener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)

        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleListenerState(state) }
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleNewConnection(connection) }
        }

        nwListener.start(queue: .global(qos: .userInitiated))
        self.listener = nwListener
        logger.info("Listening on port \(port)")
    }

    // MARK: - Connecting (Client)

    func connect(to endpoint: NWEndpoint) async throws {
        let connection = NWConnection(to: endpoint, using: .tcp)
        setupNewConnection(connection)
    }

    func connect(host: String, port: UInt16) async throws {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)
        setupNewConnection(connection)
    }

    // MARK: - Disconnect

    func disconnect(peerID: SyncPeerID) async {
        cleanupPeer(peerID)
    }

    func disconnectAll() async {
        let allPeerIDs = Array(connections.keys)
        for peerID in allPeerIDs {
            cleanupPeer(peerID)
        }
        for (_, connection) in pendingConnections {
            connection.cancel()
        }
        pendingConnections.removeAll()
    }

    func stop() async {
        await disconnectAll()
        stopListening()
        messageContinuation?.finish()
        eventContinuation?.finish()
        messageContinuation = nil
        eventContinuation = nil
        logger.info("Connection service stopped")
    }

    // MARK: - Send

    func send(_ message: SyncMessage, to peerID: SyncPeerID) async throws {
        guard let peerConn = connections[peerID],
              peerConn.state == .connected else {
            throw SyncConnectionError.peerNotConnected(peerID)
        }

        let frameData = try codec.encode(message)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConn.connection.send(
                content: frameData,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    // MARK: - Private: Connection Setup

    private func setupNewConnection(_ connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        pendingConnections[connID] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handlePendingConnectionState(connID: connID, state: state) }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func handlePendingConnectionState(connID: ObjectIdentifier, state: NWConnection.State) {
        guard let connection = pendingConnections[connID] else { return }

        switch state {
        case .ready:
            logger.info("Pending connection ready, sending handshake")
            sendHandshake(on: connection, connID: connID)
        case .failed(let error):
            logger.error("Pending connection failed: \(error.localizedDescription, privacy: .public)")
            pendingConnections.removeValue(forKey: connID)
            connection.cancel()
        case .cancelled:
            pendingConnections.removeValue(forKey: connID)
        default:
            break
        }
    }

    private func sendHandshake(on connection: NWConnection, connID: ObjectIdentifier) {
        let handshake = SyncMessage.handshake(HandshakePayload(
            peerInfo: localPeerInfo,
            requestedSyncRoot: localPeerInfo.syncRootPath
        ))

        do {
            let frameData = try codec.encode(handshake)
            connection.send(content: frameData, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    logger.error("Failed to send handshake: \(error.localizedDescription, privacy: .public)")
                    Task { await self.removePendingConnection(connID) }
                } else {
                    Task { await self.waitForHandshakeResponse(on: connection, connID: connID) }
                }
            })
        } catch {
            logger.error("Failed to encode handshake: \(error.localizedDescription, privacy: .public)")
            pendingConnections.removeValue(forKey: connID)
            connection.cancel()
        }
    }

    private func removePendingConnection(_ connID: ObjectIdentifier) {
        if let conn = pendingConnections.removeValue(forKey: connID) {
            conn.cancel()
        }
    }

    private func waitForHandshakeResponse(on connection: NWConnection, connID: ObjectIdentifier) {
        receiveFrame(on: connection) { [weak self] result in
            guard let self else { return }
            Task {
                await self.handleHandshakeResponse(result: result, connection: connection, connID: connID)
            }
        }
    }

    private func handleHandshakeResponse(result: Result<SyncMessage, Error>, connection: NWConnection, connID: ObjectIdentifier) {
        pendingConnections.removeValue(forKey: connID)

        switch result {
        case .success(let message):
            switch message {
            case .handshakeAck(let ack):
                if ack.accepted {
                    promoteConnection(connection, peerInfo: ack.peerInfo)
                } else {
                    logger.warning("Handshake rejected: \(ack.reason ?? "unknown", privacy: .public)")
                    connection.cancel()
                }
            case .handshake(let handshake):
                // Server received handshake from client
                let ack = SyncMessage.handshakeAck(HandshakeAckPayload(
                    peerInfo: localPeerInfo,
                    accepted: true,
                    reason: nil,
                    syncRootPath: localPeerInfo.syncRootPath
                ))
                do {
                    let frameData = try codec.encode(ack)
                    connection.send(content: frameData, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error == nil {
                            Task { await self.promoteConnection(connection, peerInfo: handshake.peerInfo) }
                        }
                    })
                } catch {
                    connection.cancel()
                }
            default:
                logger.warning("Unexpected message during handshake")
                connection.cancel()
            }

        case .failure(let error):
            logger.error("Handshake failed: \(error.localizedDescription, privacy: .public)")
            connection.cancel()
        }
    }

    private func promoteConnection(_ connection: NWConnection, peerInfo: SyncPeerInfo) {
        let peerID = peerInfo.peerID
        cleanupPeer(peerID)

        let peerConn = PeerConnection(connection: connection, peerID: peerID, state: .connected)
        connections[peerID] = peerConn
        reconnectAttempts[peerID] = 0

        eventContinuation?.yield(.connectionStateChanged(peerID, .connected))
        logger.info("Connected to peer: \(peerInfo.displayName, privacy: .public)")

        // Monitor connection state
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleEstablishedConnectionState(peerID: peerID, state: state) }
        }

        startReceiving(peerID: peerID, connection: connection)
        startHeartbeat(peerID: peerID)
    }

    // MARK: - Private: Server Incoming

    private func handleNewConnection(_ connection: NWConnection) {
        let connID = ObjectIdentifier(connection)
        pendingConnections[connID] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handlePendingConnectionState(connID: connID, state: state) }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("Listener ready")
        case .failed(let error):
            logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            logger.info("Listener cancelled")
        default:
            break
        }
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Private: Receive Loop

    private func startReceiving(peerID: SyncPeerID, connection: NWConnection) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.receiveFrame(on: connection) { [weak self] result in
                        guard let self else {
                            continuation.resume()
                            return
                        }
                        Task {
                            switch result {
                            case .success(let message):
                                await self.handleIncomingMessage(peerID: peerID, message: message)
                            case .failure:
                                await self.handlePeerDisconnected(peerID: peerID, reason: "receive error")
                            }
                            continuation.resume()
                        }
                    }
                }

                // Check if still connected
                let isConnected = await self.isPeerConnected(peerID)
                if !isConnected { break }
            }
        }
        receiveTasks[peerID] = task
    }

    private func isPeerConnected(_ peerID: SyncPeerID) -> Bool {
        connections[peerID]?.state == .connected
    }

    private func handleIncomingMessage(peerID: SyncPeerID, message: SyncMessage) {
        switch message {
        case .heartbeat:
            connections[peerID]?.state = .connected
        case .disconnect(let payload):
            handlePeerDisconnected(peerID: peerID, reason: payload.reason)
        default:
            messageContinuation?.yield((peerID, message))
        }
    }

    // MARK: - Private: Heartbeat

    private func startHeartbeat(peerID: SyncPeerID) {
        let interval = heartbeatInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }

                let heartbeat = SyncMessage.heartbeat(HeartbeatPayload(
                    timestamp: Date(),
                    syncVersion: 0
                ))
                do {
                    try await self.send(heartbeat, to: peerID)
                } catch {
                    await self.handlePeerDisconnected(peerID: peerID, reason: "heartbeat failed")
                    return
                }
            }
        }
        heartbeatTasks[peerID] = task
    }

    // MARK: - Private: Disconnection & Reconnect

    private func handleEstablishedConnectionState(peerID: SyncPeerID, state: NWConnection.State) {
        switch state {
        case .failed(let error):
            handlePeerDisconnected(peerID: peerID, reason: error.localizedDescription)
        case .cancelled:
            handlePeerDisconnected(peerID: peerID, reason: "cancelled")
        default:
            break
        }
    }

    private func handlePeerDisconnected(peerID: SyncPeerID, reason: String?) {
        guard connections[peerID] != nil else { return }

        cleanupPeer(peerID)
        eventContinuation?.yield(.connectionStateChanged(peerID, .disconnected(reason: reason)))
        logger.info("Peer disconnected: \(peerID.rawValue.uuidString, privacy: .public), reason: \(reason ?? "unknown", privacy: .public)")

        scheduleReconnect(peerID: peerID)
    }

    private func scheduleReconnect(peerID: SyncPeerID) {
        let attempt = (reconnectAttempts[peerID] ?? 0) + 1
        reconnectAttempts[peerID] = attempt

        let delay = min(Double(1 << min(attempt, 6)), 60.0) // 1, 2, 4, 8, 16, 32, 60
        logger.info("Scheduling reconnect for \(peerID.rawValue.uuidString, privacy: .public) in \(delay)s (attempt \(attempt))")

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }

            await self.eventContinuation?.yield(.connectionStateChanged(peerID, .connecting))
        }
        reconnectTasks[peerID] = task
    }

    // MARK: - Private: Cleanup

    private func cleanupPeer(_ peerID: SyncPeerID) {
        heartbeatTasks[peerID]?.cancel()
        heartbeatTasks.removeValue(forKey: peerID)
        receiveTasks[peerID]?.cancel()
        receiveTasks.removeValue(forKey: peerID)
        reconnectTasks[peerID]?.cancel()
        reconnectTasks.removeValue(forKey: peerID)

        if let conn = connections.removeValue(forKey: peerID) {
            conn.connection.cancel()
        }
    }

    // MARK: - Private: Frame I/O

    nonisolated private func receiveFrame(on connection: NWConnection, completion: @escaping @Sendable (Result<SyncMessage, Error>) -> Void) {
        // First read header
        connection.receive(minimumIncompleteLength: SyncMessageCodec.headerSize, maximumLength: SyncMessageCodec.headerSize) { [weak self] headerData, _, _, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }

            guard let headerData, headerData.count >= SyncMessageCodec.headerSize else {
                completion(.failure(SyncConnectionError.connectionClosed))
                return
            }

            guard let frameLength = self.codec.extractFrameLength(from: headerData) else {
                completion(.failure(SyncMessageCodecError.insufficientData))
                return
            }

            let remainingLength = frameLength - SyncMessageCodec.headerSize
            if remainingLength == 0 {
                do {
                    let message = try self.codec.decode(from: headerData)
                    completion(.success(message))
                } catch {
                    completion(.failure(error))
                }
                return
            }

            // Read payload
            connection.receive(minimumIncompleteLength: remainingLength, maximumLength: remainingLength) { payloadData, _, _, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                guard let payloadData else {
                    completion(.failure(SyncConnectionError.connectionClosed))
                    return
                }

                var fullFrame = headerData
                fullFrame.append(payloadData)

                do {
                    let message = try self.codec.decode(from: fullFrame)
                    completion(.success(message))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }
}

// MARK: - Errors

enum SyncConnectionError: Error, Sendable, LocalizedError {
    case peerNotConnected(SyncPeerID)
    case connectionClosed
    case handshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .peerNotConnected(let peerID):
            return "Peer \(peerID.rawValue.uuidString) is not connected"
        case .connectionClosed:
            return "Connection was closed"
        case .handshakeFailed(let reason):
            return "Handshake failed: \(reason)"
        }
    }
}
