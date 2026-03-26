import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.nilone.starfiler.sync", category: "Discovery")

protocol SyncDiscovering: Sendable {
    func startAdvertising(peerInfo: SyncPeerInfo, port: UInt16) async throws
    func startBrowsing() async
    func stop() async
    var peerEvents: AsyncStream<SyncPeerEvent> { get }
}

actor SyncDiscoveryService: SyncDiscovering {
    static let serviceType = "_starfiler-sync._tcp"

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var eventContinuation: AsyncStream<SyncPeerEvent>.Continuation?
    private var discoveredEndpoints: [NWEndpoint: SyncPeerInfo] = [:]

    nonisolated let peerEvents: AsyncStream<SyncPeerEvent>
    private let peerEventsStorage: AsyncStream<SyncPeerEvent>

    init() {
        var continuation: AsyncStream<SyncPeerEvent>.Continuation!
        let stream = AsyncStream<SyncPeerEvent> { c in
            continuation = c
        }
        self.peerEventsStorage = stream
        self.peerEvents = stream
        // Store continuation in a Task to avoid actor isolation issues
        Task { await self.storeContinuation(continuation) }
    }

    private func storeContinuation(_ continuation: AsyncStream<SyncPeerEvent>.Continuation) {
        self.eventContinuation = continuation
    }

    func startAdvertising(peerInfo: SyncPeerInfo, port: UInt16) async throws {
        stopAdvertising()

        let txtRecord = makeTXTRecord(from: peerInfo)

        do {
            let nwListener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            nwListener.service = NWListener.Service(
                name: peerInfo.peerID.rawValue.uuidString,
                type: Self.serviceType,
                txtRecord: txtRecord
            )

            nwListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.handleListenerState(state) }
            }

            nwListener.start(queue: .global(qos: .userInitiated))
            self.listener = nwListener
            logger.info("Started advertising as \(peerInfo.displayName, privacy: .public) on port \(port)")
        } catch {
            logger.error("Failed to start advertising: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func startBrowsing() async {
        stopBrowsing()

        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleBrowserState(state) }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            Task { await self.handleBrowseResults(results, changes: changes) }
        }

        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
        logger.info("Started browsing for sync peers")
    }

    func stop() async {
        stopAdvertising()
        stopBrowsing()
        eventContinuation?.finish()
        eventContinuation = nil
        logger.info("Discovery service stopped")
    }

    // MARK: - Private

    private func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discoveredEndpoints.removeAll()
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

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            logger.info("Browser ready")
        case .failed(let error):
            logger.error("Browser failed: \(error.localizedDescription, privacy: .public)")
        default:
            break
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handleEndpointAdded(result)
            case .removed(let result):
                handleEndpointRemoved(result)
            case .changed(old: _, new: let newResult, flags: _):
                handleEndpointAdded(newResult)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func handleEndpointAdded(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }

        if let txtRecord = extractTXTRecord(from: result),
           let peerInfo = parsePeerInfo(from: txtRecord, serviceName: name) {
            discoveredEndpoints[result.endpoint] = peerInfo
            eventContinuation?.yield(.discovered(peerInfo))
            logger.info("Discovered peer: \(peerInfo.displayName, privacy: .public)")
        }
    }

    private func handleEndpointRemoved(_ result: NWBrowser.Result) {
        if let peerInfo = discoveredEndpoints.removeValue(forKey: result.endpoint) {
            eventContinuation?.yield(.lost(peerInfo.peerID))
            logger.info("Lost peer: \(peerInfo.displayName, privacy: .public)")
        }
    }

    // MARK: - TXT Record

    private func makeTXTRecord(from peerInfo: SyncPeerInfo) -> NWTXTRecord {
        var record = NWTXTRecord()
        record["peerID"] = peerInfo.peerID.rawValue.uuidString
        record["displayName"] = peerInfo.displayName
        record["isServer"] = peerInfo.isServer ? "1" : "0"
        record["protocolVersion"] = "\(peerInfo.protocolVersion)"
        if let syncRootPath = peerInfo.syncRootPath {
            record["syncRootPath"] = syncRootPath
        }
        return record
    }

    private func extractTXTRecord(from result: NWBrowser.Result) -> NWTXTRecord? {
        guard case .bonjour(let txtRecord) = result.metadata else {
            return nil
        }
        return txtRecord
    }

    private func parsePeerInfo(from txtRecord: NWTXTRecord, serviceName: String) -> SyncPeerInfo? {
        guard let peerIDString = txtRecord["peerID"],
              let peerUUID = UUID(uuidString: peerIDString),
              let displayName = txtRecord["displayName"],
              let isServerString = txtRecord["isServer"],
              let versionString = txtRecord["protocolVersion"],
              let version = Int(versionString)
        else {
            return nil
        }

        return SyncPeerInfo(
            peerID: SyncPeerID(rawValue: peerUUID),
            displayName: displayName,
            isServer: isServerString == "1",
            protocolVersion: version,
            syncRootPath: txtRecord["syncRootPath"]
        )
    }
}
