import Foundation
import Observation

enum SelectiveSyncSelectionState: Sendable {
    case off
    case on
    case mixed
}

enum SelectiveSyncRuntimeState: Sendable {
    case synced
    case selectedPendingDownload
    case syncingUpload
    case syncingDownload
    case pendingRemoval
    case serverOnly
    case partiallySelected
    case conflict
}

struct SelectiveSyncBrowserNode: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let isDirectory: Bool
    let selectionState: SelectiveSyncSelectionState
    let runtimeState: SelectiveSyncRuntimeState
    let statusText: String
    let sizeText: String
    let isLocalAvailable: Bool
    let isRemoteAvailable: Bool
    let children: [SelectiveSyncBrowserNode]
}

@MainActor
@Observable
final class NetworkSyncViewModel: SyncStatusBarPresenting {
    var serverEnabled: Bool
    var clientEnabled: Bool
    var displayName: String
    var serverRootPath: String
    var clientRootPath: String
    var conflictPolicy: NetworkSyncConflictPolicy
    var heartbeatIntervalSeconds: Double
    var syncDebounceSeconds: Double
    var peerSummaries: [NetworkSyncPeerSummary]
    var statusMessage: String

    var statusLevel: SyncStatusLevel = .offline
    var statusTitle: String = "Network Sync"
    var statusDetail: String?
    var peers: [SyncPeerSummary] = []
    var conflicts: [SyncConflictSummary] = []
    var recentTransfers: [SyncTransferSummary] = []
    var onDidChange: (() -> Void)?

    var clientSyncEntireRoot: Bool
    var selectiveSyncNodes: [SelectiveSyncBrowserNode] = []
    var selectiveSyncSummary: String = "Client syncs the whole root."
    var selectiveSyncHint: String = "Enable the client role to browse the latest server snapshot."

    private let configManager: ConfigManager
    private let peerSummaryDateFormatter: DateFormatter
    private let fileManager: FileManager
    private let service: any NetworkSyncControlling
    private var config: NetworkSyncConfig
    private var activeTransfers: [String: NetworkSyncTransferActivity] = [:]
    private let byteCountFormatter: ByteCountFormatter
    private var changeObservers: [UUID: @MainActor () -> Void] = [:]

    var isEnabled: Bool {
        serverEnabled || clientEnabled
    }

    init(
        configManager: ConfigManager = ConfigManager(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared,
        fileManager: FileManager = .default,
        service: (any NetworkSyncControlling)? = nil
    ) {
        self.configManager = configManager
        self.fileManager = fileManager
        self.peerSummaryDateFormatter = DateFormatter()
        peerSummaryDateFormatter.dateStyle = .short
        peerSummaryDateFormatter.timeStyle = .short
        self.byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.countStyle = .file
        byteCountFormatter.includesUnit = true

        let loadedConfig = configManager.loadNetworkSyncConfig()
        self.config = loadedConfig
        self.serverEnabled = loadedConfig.serverEnabled
        self.clientEnabled = loadedConfig.clientEnabled
        self.displayName = loadedConfig.displayName
        self.serverRootPath = loadedConfig.serverEffectiveRootPath
        self.clientRootPath = loadedConfig.clientEffectiveRootPath
        self.conflictPolicy = loadedConfig.conflictPolicy
        self.heartbeatIntervalSeconds = loadedConfig.heartbeatIntervalSeconds
        self.syncDebounceSeconds = loadedConfig.syncDebounceSeconds
        self.peerSummaries = []
        self.statusMessage = loadedConfig.isEnabled ? "Network Sync roles are enabled." : "Network Sync is disabled."
        self.clientSyncEntireRoot = loadedConfig.clientSyncEntireRoot
        self.service = service ?? NetworkSyncCoordinator(
            configManager: configManager,
            securityScopedBookmarkService: securityScopedBookmarkService,
            fileManager: fileManager
        )

        refreshPeerSummaries()
        refreshSelectiveSyncBrowser()
        bindService()
        if loadedConfig.isEnabled {
            self.service.start()
        } else {
            applySnapshot(.disabled)
        }
    }

    func reload() {
        config = configManager.loadNetworkSyncConfig()
        serverEnabled = config.serverEnabled
        clientEnabled = config.clientEnabled
        displayName = config.displayName
        serverRootPath = config.serverEffectiveRootPath
        clientRootPath = config.clientEffectiveRootPath
        conflictPolicy = config.conflictPolicy
        heartbeatIntervalSeconds = config.heartbeatIntervalSeconds
        syncDebounceSeconds = config.syncDebounceSeconds
        clientSyncEntireRoot = config.clientSyncEntireRoot
        refreshPeerSummaries()
        refreshSelectiveSyncBrowser()
        statusMessage = "Reloaded from disk"
        if config.isEnabled {
            service.reload(config: config)
        } else {
            service.stop()
            applySnapshot(.disabled)
        }
    }

    func save() {
        let sanitizedDisplayName = sanitized(displayName, fallback: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        let sanitizedServerRootPath = sanitized(serverRootPath)
        let sanitizedClientRootPath = sanitized(clientRootPath, fallback: NetworkSyncConfig.defaultClientRootPath)
        let sanitizedIncludedPaths = currentIncludedPaths()

        if let validationError = validateRolePaths(
            serverEnabled: serverEnabled,
            serverRootPath: sanitizedServerRootPath,
            clientEnabled: clientEnabled,
            clientRootPath: sanitizedClientRootPath
        ) {
            statusMessage = validationError
            statusDetail = validationError
            notifyDidChange()
            return
        }

        let nextConfig = NetworkSyncConfig(
            displayName: sanitizedDisplayName,
            discoveryScope: config.discoveryScope,
            serverEnabled: serverEnabled,
            serverRootPath: sanitizedServerRootPath,
            clientEnabled: clientEnabled,
            clientRootPath: sanitizedClientRootPath,
            clientSyncEntireRoot: clientSyncEntireRoot,
            clientIncludedPaths: sanitizedIncludedPaths,
            conflictPolicy: conflictPolicy,
            heartbeatIntervalSeconds: heartbeatIntervalSeconds,
            syncDebounceSeconds: syncDebounceSeconds,
            peers: config.peers
        )

        do {
            try configManager.saveNetworkSyncConfig(nextConfig)
            config = nextConfig
            displayName = nextConfig.displayName
            serverRootPath = nextConfig.serverEffectiveRootPath
            clientRootPath = nextConfig.clientEffectiveRootPath
            clientSyncEntireRoot = nextConfig.clientSyncEntireRoot
            refreshPeerSummaries()
            refreshSelectiveSyncBrowser()
            statusMessage = "Saved"
            if nextConfig.isEnabled {
                service.reload(config: nextConfig)
            } else {
                service.stop()
                applySnapshot(.disabled)
            }
        } catch {
            statusMessage = error.localizedDescription
            statusDetail = error.localizedDescription
            notifyDidChange()
        }
    }

    func updatePeerSummaries(with peers: [NetworkSyncPeerConfig]) {
        config.peers = peers
        refreshPeerSummaries()
    }

    func requestRefresh() {
        service.requestRefresh()
        refreshSelectiveSyncBrowser()
        notifyDidChange()
    }

    func stop() {
        service.stop()
    }

    func setServerEnabled(_ enabled: Bool) {
        serverEnabled = enabled
        statusMessage = enabled
            ? "Server role will publish \(sanitized(serverRootPath, fallback: "its configured root"))."
            : "Server role will stop publishing after Save."
        notifyDidChange()
    }

    func setClientEnabled(_ enabled: Bool) {
        clientEnabled = enabled
        applyClientDefaultsIfNeeded()
        statusMessage = enabled
            ? "Client role will mirror into \(sanitized(clientRootPath, fallback: NetworkSyncConfig.defaultClientRootPath))."
            : "Client role will stop mirroring after Save."
        refreshSelectiveSyncBrowser()
        notifyDidChange()
    }

    func setClientSyncEntireRoot(_ enabled: Bool) {
        clientSyncEntireRoot = enabled
        config.clientSyncEntireRoot = enabled
        refreshSelectiveSyncBrowser()
        statusMessage = enabled
            ? "Whole-root sync is enabled. Previous explicit selection is preserved."
            : "Using explicit selective sync paths. Save to apply."
        notifyDidChange()
    }

    func applyClientDefaultsIfNeeded() {
        if sanitized(clientRootPath).isEmpty {
            clientRootPath = NetworkSyncConfig.defaultClientRootPath
        }
        refreshSelectiveSyncPreview()
    }

    func toggleSelectiveNode(path: String, isSelected: Bool) {
        if clientSyncEntireRoot && !isSelected {
            setClientSyncEntireRoot(false)
        }

        var selectedPaths = Set(config.clientIncludedPaths.map(normalizeRelativePath).filter { !$0.isEmpty })
        if clientSyncEntireRoot && isSelected {
            return
        }

        if isSelected {
            if selectedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return
            }
            selectedPaths = selectedPaths.filter { !($0 == path || $0.hasPrefix(path + "/")) }
            selectedPaths.insert(path)
        } else {
            deselect(path: path, selectedPaths: &selectedPaths, roots: selectiveSyncNodes)
        }

        config.clientIncludedPaths = selectedPaths.sorted()
        config.clientSyncEntireRoot = clientSyncEntireRoot
        refreshSelectiveSyncBrowser()
        statusMessage = "Selective sync updated. Save to apply."
        notifyDidChange()
    }

    func selectAllSelectiveSyncItems() {
        clientSyncEntireRoot = false
        config.clientSyncEntireRoot = false
        config.clientIncludedPaths = selectiveSyncNodes.map(\.path)
        refreshSelectiveSyncBrowser()
        statusMessage = "Selected all visible folders and files. Save to apply."
        notifyDidChange()
    }

    func clearAllSelectiveSyncItems() {
        clientSyncEntireRoot = false
        config.clientSyncEntireRoot = false
        config.clientIncludedPaths = []
        refreshSelectiveSyncBrowser()
        statusMessage = "Cleared all explicit selections. Save to apply."
        notifyDidChange()
    }

    @discardableResult
    func addDidChangeObserver(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = observer
        return token
    }

    func removeDidChangeObserver(_ token: UUID) {
        changeObservers.removeValue(forKey: token)
    }

    func refreshSelectiveSyncPreview() {
        config.clientIncludedPaths = currentIncludedPaths()
        refreshSelectiveSyncBrowser()
        notifyDidChange()
    }

    private func bindService() {
        service.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.applySnapshot(snapshot)
            }
        }
    }

    private func applySnapshot(_ snapshot: NetworkSyncRuntimeSnapshot) {
        statusLevel = Self.statusLevel(for: snapshot.status)
        statusTitle = snapshot.status == .disabled ? "Network Sync Disabled" : "Network Sync"
        statusDetail = snapshot.detail
        statusMessage = snapshot.detail
        activeTransfers = snapshot.activeTransfers
        peers = snapshot.peers.map { peer in
            SyncPeerSummary(
                id: peer.id,
                name: peer.name,
                role: peer.role.displayName,
                status: peer.state.displayName,
                isConnected: peer.isConnected,
                isServer: peer.role == .server
            )
        }
        conflicts = snapshot.conflicts.map { conflict in
            SyncConflictSummary(
                id: conflict.id,
                relativePath: conflict.relativePath,
                detail: conflict.detail,
                timestamp: conflict.timestamp
            )
        }
        recentTransfers = snapshot.transfers.map { transfer in
            SyncTransferSummary(
                id: transfer.id,
                relativePath: transfer.relativePath,
                direction: transfer.direction == .upload ? "Upload" : "Download",
                status: transfer.status,
                progress: transfer.progress,
                detail: transfer.detail
            )
        }
        refreshSelectiveSyncBrowser()
        notifyDidChange()
    }

    private func refreshPeerSummaries() {
        peerSummaries = config.peers.map { peer in
            NetworkSyncPeerSummary(peer: peer, formatter: peerSummaryDateFormatter)
        }
    }

    private func refreshSelectiveSyncBrowser() {
        let entries = loadAvailableEntries()
        let localAvailability = loadLocalAvailability()
        let roots = buildTree(entries: entries, localAvailability: localAvailability)
        selectiveSyncNodes = roots.map { materializeNode($0).node }

        if !clientEnabled {
            selectiveSyncHint = "Enable the client role to mirror selected folders onto this Mac."
        } else if selectiveSyncNodes.isEmpty {
            selectiveSyncHint = "Connect once as a client to fetch the server tree, then pick folders or files to keep on this Mac."
        } else if clientSyncEntireRoot {
            selectiveSyncHint = "Everything under the server root is selected. Turn this off to restore explicit folder picks without losing them."
        } else {
            selectiveSyncHint = "Folder checkboxes apply recursively. Unchecked paths are removed from this Mac after Save."
        }

        if clientSyncEntireRoot {
            selectiveSyncSummary = selectiveSyncNodes.isEmpty
                ? "Client syncs the whole root when a server snapshot becomes available."
                : "Client syncs the whole root."
        } else if currentIncludedPaths().isEmpty {
            selectiveSyncSummary = "Nothing selected. This Mac keeps no local synced copy until you pick folders."
        } else {
            selectiveSyncSummary = currentIncludedPaths().joined(separator: ", ")
        }
    }

    private func currentIncludedPaths() -> [String] {
        return config.clientIncludedPaths
            .map(normalizeRelativePath)
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func loadAvailableEntries() -> [NetworkSyncFileEntry] {
        let stateURL = configManager
            .networkSyncRuntimeDirectory(rootPath: config.clientEffectiveRootPath)
            .appendingPathComponent("client-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(NetworkSyncClientState.self, from: data)
        else {
            return []
        }
        return state.knownEntries.values.filter { !$0.deleted }
    }

    private func loadLocalAvailability() -> Set<String> {
        let effectiveRootPath = sanitized(clientRootPath, fallback: NetworkSyncConfig.defaultClientRootPath)
        let trimmedRootPath = effectiveRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRootPath.isEmpty else {
            return []
        }

        let rootURL = URL(fileURLWithPath: UserPaths.expandHomeVariables(in: trimmedRootPath), isDirectory: true).standardizedFileURL
        var localPaths: Set<String> = []

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return localPaths
        }

        for case let fileURL as URL in enumerator {
            let relative = normalizeRelativePath(fileURL.path.replacingOccurrences(of: rootURL.path, with: ""))
            guard !relative.isEmpty else {
                continue
            }
            localPaths.insert(relative)
        }

        return localPaths
    }

    private func buildTree(entries: [NetworkSyncFileEntry], localAvailability: Set<String>) -> [TreeNode] {
        var roots: [String: TreeNode] = [:]

        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            insert(entry: entry, into: &roots, localAvailability: localAvailability)
        }

        return roots.values.sorted(by: Self.sortTreeNodes)
    }

    private func insert(entry: NetworkSyncFileEntry, into roots: inout [String: TreeNode], localAvailability: Set<String>) {
        let normalizedPath = normalizeRelativePath(entry.relativePath)
        guard !normalizedPath.isEmpty else {
            return
        }

        let components = normalizedPath.split(separator: "/").map(String.init)
        var currentPath = ""
        var currentRoots = roots

        for (index, component) in components.enumerated() {
            currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
            let isLeaf = index == components.count - 1
            let isDirectory = isLeaf ? entry.isDirectory : true
            let node = currentRoots[currentPath] ?? TreeNode(
                path: currentPath,
                name: component,
                isDirectory: isDirectory,
                directBytes: isLeaf ? entry.size : 0,
                isRemoteAvailable: isLeaf,
                isLocalAvailable: localAvailability.contains(currentPath),
                children: [:]
            )

            let updatedNode = TreeNode(
                path: node.path,
                name: node.name,
                isDirectory: node.isDirectory || isDirectory,
                directBytes: isLeaf ? entry.size : node.directBytes,
                isRemoteAvailable: node.isRemoteAvailable || isLeaf,
                isLocalAvailable: node.isLocalAvailable || localAvailability.contains(currentPath),
                children: node.children
            )

            currentRoots[currentPath] = updatedNode

            if index == 0 {
                roots[currentPath] = updatedNode
            }

            if index < components.count - 1 {
                var children = currentRoots[currentPath]?.children ?? [:]
                insertChild(pathComponents: Array(components[(index + 1)...]), fullPath: currentPath, entry: entry, localAvailability: localAvailability, into: &children)
                if var rootNode = roots[components[0]] {
                    rootNode = rootNode.settingChildrenRecursively(path: currentPath, children: children)
                    roots[components[0]] = rootNode
                }
                break
            }
        }
    }

    private func insertChild(pathComponents: [String], fullPath: String, entry: NetworkSyncFileEntry, localAvailability: Set<String>, into children: inout [String: TreeNode]) {
        guard let component = pathComponents.first else {
            return
        }

        let nextPath = fullPath + "/" + component
        let isLeaf = pathComponents.count == 1
        let node = children[nextPath] ?? TreeNode(
            path: nextPath,
            name: component,
            isDirectory: isLeaf ? entry.isDirectory : true,
            directBytes: isLeaf ? entry.size : 0,
            isRemoteAvailable: isLeaf,
            isLocalAvailable: localAvailability.contains(nextPath),
            children: [:]
        )

        var updatedNode = TreeNode(
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory || !isLeaf || entry.isDirectory,
            directBytes: isLeaf ? entry.size : node.directBytes,
            isRemoteAvailable: node.isRemoteAvailable || isLeaf,
            isLocalAvailable: node.isLocalAvailable || localAvailability.contains(nextPath),
            children: node.children
        )

        if !isLeaf {
            var nestedChildren = updatedNode.children
            insertChild(pathComponents: Array(pathComponents.dropFirst()), fullPath: nextPath, entry: entry, localAvailability: localAvailability, into: &nestedChildren)
            updatedNode = TreeNode(
                path: updatedNode.path,
                name: updatedNode.name,
                isDirectory: updatedNode.isDirectory,
                directBytes: updatedNode.directBytes,
                isRemoteAvailable: updatedNode.isRemoteAvailable,
                isLocalAvailable: updatedNode.isLocalAvailable,
                children: nestedChildren
            )
        }

        children[nextPath] = updatedNode
    }

    private func materializeNode(_ node: TreeNode) -> MaterializedNode {
        let materializedChildren = node.children.values.sorted(by: Self.sortTreeNodes).map(materializeNode)
        let children = materializedChildren.map(\.node)
        let aggregatedBytes = node.directBytes + materializedChildren.reduce(into: Int64(0)) { partial, element in
            partial += element.aggregateBytes
        }
        let selectionState = selectionState(for: node.path, children: children)
        let runtimeState = runtimeState(for: node, selectionState: selectionState, children: children)
        let statusText = statusText(for: runtimeState, node: node)

        let materializedNode = SelectiveSyncBrowserNode(
            id: node.path,
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory,
            selectionState: selectionState,
            runtimeState: runtimeState,
            statusText: statusText,
            sizeText: byteCountFormatter.string(fromByteCount: aggregatedBytes),
            isLocalAvailable: node.isLocalAvailable,
            isRemoteAvailable: node.isRemoteAvailable,
            children: children
        )
        return MaterializedNode(node: materializedNode, aggregateBytes: aggregatedBytes)
    }

    private func selectionState(for path: String, children: [SelectiveSyncBrowserNode]) -> SelectiveSyncSelectionState {
        if clientSyncEntireRoot || pathIsSelected(path) {
            return .on
        }
        guard !children.isEmpty else {
            return .off
        }
        let childStates = children.map(\.selectionState)
        if childStates.allSatisfy({ $0 == .on }) {
            return .on
        }
        if childStates.allSatisfy({ $0 == .off }) {
            return .off
        }
        return .mixed
    }

    private func runtimeState(for node: TreeNode, selectionState: SelectiveSyncSelectionState, children: [SelectiveSyncBrowserNode]) -> SelectiveSyncRuntimeState {
        if hasConflict(for: node.path) {
            return .conflict
        }
        if let activity = activeTransfer(for: node.path) {
            return activity == .upload ? .syncingUpload : .syncingDownload
        }

        switch selectionState {
        case .mixed:
            return .partiallySelected
        case .on:
            return node.isLocalAvailable ? .synced : .selectedPendingDownload
        case .off:
            if node.isLocalAvailable {
                return .pendingRemoval
            }
            return .serverOnly
        }
    }

    private func pathIsSelected(_ path: String) -> Bool {
        let normalizedPath = normalizeRelativePath(path)
        if clientSyncEntireRoot {
            return true
        }
        return currentIncludedPaths().contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") })
    }

    private func statusText(for runtimeState: SelectiveSyncRuntimeState, node: TreeNode) -> String {
        switch runtimeState {
        case .synced:
            return "Synced locally"
        case .selectedPendingDownload:
            return "Selected, waiting for sync"
        case .syncingUpload:
            return "Uploading now"
        case .syncingDownload:
            return "Downloading now"
        case .pendingRemoval:
            return "Will be removed on Save"
        case .serverOnly:
            return node.isDirectory ? "Server subtree only" : "Server only"
        case .partiallySelected:
            return "Partially selected"
        case .conflict:
            return "Needs attention"
        }
    }

    private func hasConflict(for path: String) -> Bool {
        conflicts.contains { conflict in
            let candidate = normalizeRelativePath(conflict.relativePath)
            return candidate == path || candidate.hasPrefix(path + "/")
        }
    }

    private func activeTransfer(for path: String) -> NetworkSyncTransferActivity? {
        activeTransfers.first { candidatePath, _ in
            let normalized = normalizeRelativePath(candidatePath)
            return normalized == path || normalized.hasPrefix(path + "/")
        }?.value
    }

    private func deselect(path: String, selectedPaths: inout Set<String>, roots: [SelectiveSyncBrowserNode]) {
        let normalizedPath = normalizeRelativePath(path)
        selectedPaths = selectedPaths.filter { !($0 == normalizedPath || $0.hasPrefix(normalizedPath + "/")) }

        if let selectedAncestor = selectedPaths
            .filter({ normalizedPath.hasPrefix($0 + "/") })
            .sorted(by: { $0.count > $1.count })
            .first,
           let ancestorNode = findNode(path: selectedAncestor, in: roots)
        {
            selectedPaths.remove(selectedAncestor)
            expandSelectionExcluding(targetPath: normalizedPath, from: ancestorNode, into: &selectedPaths)
        } else if let exactNode = findNode(path: normalizedPath, in: roots), exactNode.selectionState == .on {
            selectedPaths.remove(normalizedPath)
            if selectedPaths.isEmpty && !clientSyncEntireRoot {
                selectedPaths = Set(roots.filter { $0.path != normalizedPath }.map(\.path))
            }
            if let exactParent = parentPath(of: normalizedPath), let parentNode = findNode(path: exactParent, in: roots), currentIncludedPaths().contains(exactParent) {
                selectedPaths.remove(exactParent)
                expandSelectionExcluding(targetPath: normalizedPath, from: parentNode, into: &selectedPaths)
            }
        }
    }

    private func expandSelectionExcluding(targetPath: String, from node: SelectiveSyncBrowserNode, into selectedPaths: inout Set<String>) {
        for child in node.children {
            if child.path == targetPath || targetPath.hasPrefix(child.path + "/") {
                if targetPath != child.path {
                    expandSelectionExcluding(targetPath: targetPath, from: child, into: &selectedPaths)
                }
            } else {
                selectedPaths.insert(child.path)
            }
        }
    }

    private func findNode(path: String, in roots: [SelectiveSyncBrowserNode]) -> SelectiveSyncBrowserNode? {
        for node in roots {
            if node.path == path {
                return node
            }
            if let found = findNode(path: path, in: node.children) {
                return found
            }
        }
        return nil
    }

    private func parentPath(of path: String) -> String? {
        let components = normalizeRelativePath(path).split(separator: "/").map(String.init)
        guard components.count > 1 else {
            return nil
        }
        return components.dropLast().joined(separator: "/")
    }

    private func validateRolePaths(
        serverEnabled: Bool,
        serverRootPath: String,
        clientEnabled: Bool,
        clientRootPath: String
    ) -> String? {
        guard serverEnabled, clientEnabled else {
            return nil
        }

        let serverURL = URL(
            fileURLWithPath: UserPaths.expandHomeVariables(in: serverRootPath),
            isDirectory: true
        ).standardizedFileURL
        let clientURL = URL(
            fileURLWithPath: UserPaths.expandHomeVariables(in: clientRootPath),
            isDirectory: true
        ).standardizedFileURL

        let serverPath = serverURL.path
        let clientPath = clientURL.path
        if serverPath == clientPath {
            return "Server root and client sync folder must be different."
        }
        if clientPath.hasPrefix(serverPath + "/") || serverPath.hasPrefix(clientPath + "/") {
            return "Server root and client sync folder must not be nested inside each other."
        }
        return nil
    }

    private func sanitized(_ value: String, fallback: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizeRelativePath(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private static func sortTreeNodes(_ lhs: TreeNode, _ rhs: TreeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func statusLevel(for status: NetworkSyncRuntimeStatus) -> SyncStatusLevel {
        switch status {
        case .disabled, .offline:
            return .offline
        case .starting, .syncing:
            return .syncing
        case .idle:
            return .idle
        case .error:
            return .attention
        }
    }

    private func notifyDidChange() {
        onDidChange?()
        for observer in changeObservers.values {
            observer()
        }
    }
}

private struct TreeNode: Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let directBytes: Int64
    let isRemoteAvailable: Bool
    let isLocalAvailable: Bool
    let children: [String: TreeNode]

    func settingChildrenRecursively(path targetPath: String, children newChildren: [String: TreeNode]) -> TreeNode {
        if path == targetPath {
            return TreeNode(
                path: path,
                name: name,
                isDirectory: isDirectory,
                directBytes: directBytes,
                isRemoteAvailable: isRemoteAvailable,
                isLocalAvailable: isLocalAvailable,
                children: newChildren
            )
        }

        var updatedChildren = children
        for (childPath, childNode) in children {
            if targetPath.hasPrefix(childPath) {
                updatedChildren[childPath] = childNode.settingChildrenRecursively(path: targetPath, children: newChildren)
            }
        }

        return TreeNode(
            path: path,
            name: name,
            isDirectory: isDirectory,
            directBytes: directBytes,
            isRemoteAvailable: isRemoteAvailable,
            isLocalAvailable: isLocalAvailable,
            children: updatedChildren
        )
    }
}

private struct MaterializedNode: Sendable {
    let node: SelectiveSyncBrowserNode
    let aggregateBytes: Int64
}
