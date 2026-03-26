import Foundation
import Observation

enum SelectiveSyncSelectionState: Sendable {
    case off
    case on
    case mixed
}

struct SelectiveSyncBrowserNode: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let isDirectory: Bool
    let selectionState: SelectiveSyncSelectionState
    let statusText: String
    let isLocalAvailable: Bool
    let isRemoteAvailable: Bool
    let children: [SelectiveSyncBrowserNode]
}

@MainActor
@Observable
final class NetworkSyncViewModel: SyncStatusBarPresenting {
    var isEnabled: Bool
    var mode: SyncNodeMode
    var displayName: String
    var rootPath: String
    var includedPathsText: String
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

    var syncEntireRoot: Bool
    var selectiveSyncNodes: [SelectiveSyncBrowserNode] = []
    var selectiveSyncSummary: String = "Syncs the whole root."
    var selectiveSyncHint: String = "Client mode can browse the server snapshot after the first connection."

    private let configManager: ConfigManager
    private let peerSummaryDateFormatter: DateFormatter
    private let fileManager: FileManager
    private let service: any NetworkSyncControlling
    private var config: NetworkSyncConfig
    private var changeObservers: [UUID: @MainActor () -> Void] = [:]

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

        let loadedConfig = configManager.loadNetworkSyncConfig()
        self.config = loadedConfig
        self.isEnabled = loadedConfig.isEnabled
        self.mode = loadedConfig.mode
        self.displayName = loadedConfig.displayName
        self.rootPath = loadedConfig.effectiveRootPath
        self.includedPathsText = loadedConfig.includedPaths.joined(separator: "\n")
        self.conflictPolicy = loadedConfig.conflictPolicy
        self.heartbeatIntervalSeconds = loadedConfig.heartbeatIntervalSeconds
        self.syncDebounceSeconds = loadedConfig.syncDebounceSeconds
        self.peerSummaries = []
        self.statusMessage = loadedConfig.isEnabled ? "Sync is enabled" : "Sync is disabled"
        self.syncEntireRoot = loadedConfig.includedPaths.isEmpty
        self.service = service ?? NetworkSyncService(
            configManager: configManager,
            securityScopedBookmarkService: securityScopedBookmarkService
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
        isEnabled = config.isEnabled
        mode = config.mode
        displayName = config.displayName
        rootPath = config.effectiveRootPath
        includedPathsText = config.includedPaths.joined(separator: "\n")
        conflictPolicy = config.conflictPolicy
        heartbeatIntervalSeconds = config.heartbeatIntervalSeconds
        syncDebounceSeconds = config.syncDebounceSeconds
        syncEntireRoot = config.includedPaths.isEmpty
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
        let sanitizedRootPath = sanitized(rootPath, fallback: mode == .client ? NetworkSyncConfig.defaultClientRootPath : "")
        let sanitizedIncludedPaths = currentIncludedPaths()

        let nextConfig = NetworkSyncConfig(
            isEnabled: isEnabled,
            mode: mode,
            displayName: sanitizedDisplayName,
            rootPath: sanitizedRootPath,
            includedPaths: sanitizedIncludedPaths,
            conflictPolicy: conflictPolicy,
            heartbeatIntervalSeconds: heartbeatIntervalSeconds,
            syncDebounceSeconds: syncDebounceSeconds,
            peers: config.peers
        )

        do {
            try configManager.saveNetworkSyncConfig(nextConfig)
            config = nextConfig
            displayName = nextConfig.displayName
            rootPath = nextConfig.effectiveRootPath
            syncEntireRoot = nextConfig.includedPaths.isEmpty
            includedPathsText = nextConfig.includedPaths.joined(separator: "\n")
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

    func setMode(_ nextMode: SyncNodeMode) {
        mode = nextMode
        applyModeDefaultsIfNeeded()
        statusMessage = nextMode == .server
            ? "Server mode publishes a shared root."
            : "Client mode mirrors selected folders into \(rootPath)."
        notifyDidChange()
    }

    func setSyncEntireRoot(_ enabled: Bool) {
        syncEntireRoot = enabled
        if enabled {
            config.includedPaths = []
        } else if config.includedPaths.isEmpty {
            config.includedPaths = selectiveSyncNodes.map(\.path)
        }
        syncIncludedPathsText()
        refreshSelectiveSyncBrowser()
        statusMessage = enabled ? "Syncs the whole root. Save to apply." : "Using explicit selective sync paths. Save to apply."
        notifyDidChange()
    }

    func applyModeDefaultsIfNeeded() {
        if mode == .client && sanitized(rootPath).isEmpty {
            rootPath = NetworkSyncConfig.defaultClientRootPath
        }
        refreshSelectiveSyncPreview()
    }

    func toggleSelectiveNode(path: String, isSelected: Bool) {
        if syncEntireRoot && !isSelected {
            setSyncEntireRoot(false)
        }

        var selectedPaths = Set(config.includedPaths.map(normalizeRelativePath).filter { !$0.isEmpty })
        if syncEntireRoot && isSelected {
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

        config.includedPaths = selectedPaths.sorted()
        syncEntireRoot = config.includedPaths.isEmpty
        syncIncludedPathsText()
        refreshSelectiveSyncBrowser()
        statusMessage = "Selective sync updated. Save to apply."
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
        config.includedPaths = currentIncludedPaths()
        syncIncludedPathsText()
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
        selectiveSyncNodes = roots.map { materializeNode($0) }

        if mode == .server {
            selectiveSyncHint = "Server mode shows the exported root inventory. Clients choose their own sync selection."
        } else if selectiveSyncNodes.isEmpty {
            selectiveSyncHint = "Connect once as a client to fetch the server tree, then pick folders or files to keep on this Mac."
        } else if syncEntireRoot {
            selectiveSyncHint = "Everything under the server root is selected. Turn this off to choose folders individually."
        } else {
            selectiveSyncHint = "Selections are inclusive. Unchecked paths are removed from this Mac after Save."
        }

        if syncEntireRoot {
            selectiveSyncSummary = selectiveSyncNodes.isEmpty
                ? "Syncs the whole root when a server snapshot becomes available."
                : "Syncs the whole root."
        } else if config.includedPaths.isEmpty {
            selectiveSyncSummary = "No explicit paths selected."
        } else {
            selectiveSyncSummary = config.includedPaths.joined(separator: ", ")
        }
    }

    private func currentIncludedPaths() -> [String] {
        if syncEntireRoot {
            return []
        }
        return config.includedPaths
            .map(normalizeRelativePath)
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func syncIncludedPathsText() {
        includedPathsText = currentIncludedPaths().joined(separator: "\n")
    }

    private func loadAvailableEntries() -> [NetworkSyncFileEntry] {
        switch mode {
        case .client:
            let stateURL = configManager.configDirectory.appendingPathComponent("NetworkSyncClientState.json")
            guard let data = try? Data(contentsOf: stateURL),
                  let state = try? JSONDecoder().decode(NetworkSyncClientState.self, from: data)
            else {
                return []
            }
            return state.knownEntries.values.filter { !$0.deleted }
        case .server:
            let effectiveRootPath = mode == .client ? config.effectiveRootPath : rootPath
            let trimmedRootPath = normalizeRelativePath(effectiveRootPath)
            guard !trimmedRootPath.isEmpty else {
                return []
            }
            let rootURL = URL(fileURLWithPath: UserPaths.expandHomeVariables(in: effectiveRootPath), isDirectory: true).standardizedFileURL
            let stateURL = rootURL.appendingPathComponent(".starfiler-sync/state.json")
            guard let data = try? Data(contentsOf: stateURL),
                  let state = try? JSONDecoder().decode(NetworkSyncServerState.self, from: data)
            else {
                return []
            }
            return state.entries.values.filter { !$0.deleted }
        }
    }

    private func loadLocalAvailability() -> Set<String> {
        let effectiveRootPath = mode == .client ? sanitized(rootPath, fallback: NetworkSyncConfig.defaultClientRootPath) : rootPath
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
                isRemoteAvailable: isLeaf,
                isLocalAvailable: localAvailability.contains(currentPath),
                children: [:]
            )

            let updatedNode = TreeNode(
                path: node.path,
                name: node.name,
                isDirectory: node.isDirectory || isDirectory,
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
            isRemoteAvailable: isLeaf,
            isLocalAvailable: localAvailability.contains(nextPath),
            children: [:]
        )

        var updatedNode = TreeNode(
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory || !isLeaf || entry.isDirectory,
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
                isRemoteAvailable: updatedNode.isRemoteAvailable,
                isLocalAvailable: updatedNode.isLocalAvailable,
                children: nestedChildren
            )
        }

        children[nextPath] = updatedNode
    }

    private func materializeNode(_ node: TreeNode) -> SelectiveSyncBrowserNode {
        let children = node.children.values.sorted(by: Self.sortTreeNodes).map(materializeNode)
        let selectionState = selectionState(for: node.path, children: children)
        let statusText = statusText(for: node, selectionState: selectionState, children: children)

        return SelectiveSyncBrowserNode(
            id: node.path,
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory,
            selectionState: selectionState,
            statusText: statusText,
            isLocalAvailable: node.isLocalAvailable,
            isRemoteAvailable: node.isRemoteAvailable,
            children: children
        )
    }

    private func selectionState(for path: String, children: [SelectiveSyncBrowserNode]) -> SelectiveSyncSelectionState {
        if syncEntireRoot || pathIsSelected(path) {
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

    private func statusText(for node: TreeNode, selectionState: SelectiveSyncSelectionState, children: [SelectiveSyncBrowserNode]) -> String {
        switch selectionState {
        case .on:
            return node.isLocalAvailable ? "Synced locally" : "Selected on this Mac"
        case .mixed:
            return "Some children selected"
        case .off:
            if node.isLocalAvailable {
                return "Will be removed on Save"
            }
            if node.isDirectory, !children.isEmpty {
                return "Server subtree only"
            }
            return "Server only"
        }
    }

    private func pathIsSelected(_ path: String) -> Bool {
        let normalizedPath = normalizeRelativePath(path)
        return currentIncludedPaths().contains(where: { normalizedPath == $0 || normalizedPath.hasPrefix($0 + "/") })
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
            if selectedPaths.isEmpty && !syncEntireRoot {
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
    let isRemoteAvailable: Bool
    let isLocalAvailable: Bool
    let children: [String: TreeNode]

    func settingChildrenRecursively(path targetPath: String, children newChildren: [String: TreeNode]) -> TreeNode {
        if path == targetPath {
            return TreeNode(
                path: path,
                name: name,
                isDirectory: isDirectory,
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
            isRemoteAvailable: isRemoteAvailable,
            isLocalAvailable: isLocalAvailable,
            children: updatedChildren
        )
    }
}
