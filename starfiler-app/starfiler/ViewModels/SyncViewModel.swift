import Foundation
import Observation

@MainActor
@Observable
final class SyncViewModel {
    var leftDirectory: URL
    var rightDirectory: URL
    var direction: SyncDirection {
        didSet {
            if isPreviewReady { compare() }
        }
    }
    var excludeRules: [SyncExcludeRule]

    private(set) var phase: SyncPhase
    private(set) var items: [SyncItem]
    private(set) var scanProgress: Int
    private(set) var syncProgress: Int
    private(set) var syncTotal: Int
    private(set) var currentSyncFile: String

    var showIdentical: Bool {
        didSet { /* filteredItems recomputed automatically */ }
    }
    var showExcluded: Bool {
        didSet { /* filteredItems recomputed automatically */ }
    }

    var filteredItems: [SyncItem] {
        items.filter { item in
            if !showIdentical && item.status == .identical { return false }
            if !showExcluded && item.status == .excluded { return false }
            return true
        }
    }

    var selectedCount: Int { items.filter(\.isSelected).count }
    var actionableCount: Int { items.filter { $0.isSelected && $0.action != .skip }.count }
    var isBusy: Bool {
        if case .comparing = phase { return true }
        if case .syncing = phase { return true }
        return false
    }

    var isPreviewReady: Bool {
        if case .previewReady = phase { return true }
        return false
    }

    var canSync: Bool {
        isPreviewReady && actionableCount > 0
    }

    var statusSummary: String {
        let actionable = actionableCount
        let skipped = items.count - actionable
        if case .completed(let result) = phase {
            var text = "Done: \(result.copiedCount) copied"
            if result.deletedCount > 0 { text += ", \(result.deletedCount) deleted" }
            if !result.errors.isEmpty { text += ", \(result.errors.count) errors" }
            return text
        }
        return "\(actionable) to sync, \(skipped) skipped"
    }

    private(set) var synclets: [Synclet]

    private let comparisonService: any DirectoryComparing
    private let executionService: any SyncExecuting
    private let configManager: ConfigManager
    private let securityScopedBookmarkService: any SecurityScopedBookmarkProviding

    private var compareTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    init(
        leftDirectory: URL,
        rightDirectory: URL,
        comparisonService: any DirectoryComparing = DirectoryComparisonService(),
        executionService: any SyncExecuting = SyncExecutionService(),
        configManager: ConfigManager = ConfigManager(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared
    ) {
        self.leftDirectory = leftDirectory
        self.rightDirectory = rightDirectory
        self.direction = .leftToRight
        self.excludeRules = SyncExcludeRule.defaults
        self.phase = .idle
        self.items = []
        self.scanProgress = 0
        self.syncProgress = 0
        self.syncTotal = 0
        self.currentSyncFile = ""
        self.showIdentical = false
        self.showExcluded = false
        self.comparisonService = comparisonService
        self.executionService = executionService
        self.configManager = configManager
        self.securityScopedBookmarkService = securityScopedBookmarkService
        self.synclets = configManager.loadSyncletsConfig().synclets
    }

    // MARK: - Compare

    func compare() {
        compareTask?.cancel()
        phase = .comparing
        scanProgress = 0
        items = []

        let leftDir = leftDirectory
        let rightDir = rightDirectory
        let service = securityScopedBookmarkService

        compareTask = Task { [weak self] in
            guard let self else { return }
            try? await service.startAccessing(leftDir)
            try? await service.startAccessing(rightDir)
            do {
                let result = try await self.comparisonService.compare(
                    leftDirectory: leftDir,
                    rightDirectory: rightDir,
                    direction: self.direction,
                    excludeRules: self.excludeRules,
                    progress: { [weak self] scanned in
                        Task { @MainActor [weak self] in
                            self?.scanProgress = scanned
                        }
                    }
                )
                self.items = result
                self.phase = .previewReady
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .error(error.localizedDescription)
            }
            await service.stopAccessing(leftDir)
            await service.stopAccessing(rightDir)
        }
    }

    // MARK: - Sync

    func executeSync() {
        guard canSync else { return }

        syncTask?.cancel()
        phase = .syncing
        syncProgress = 0
        syncTotal = actionableCount

        let leftDir = leftDirectory
        let rightDir = rightDirectory
        let service = securityScopedBookmarkService

        syncTask = Task { [weak self] in
            guard let self else { return }
            try? await service.startAccessing(leftDir)
            try? await service.startAccessing(rightDir)
            do {
                let result = try await self.executionService.execute(
                    items: self.items,
                    leftBase: leftDir,
                    rightBase: rightDir,
                    progress: { [weak self] completed, total, currentFile in
                        Task { @MainActor [weak self] in
                            self?.syncProgress = completed
                            self?.syncTotal = total
                            self?.currentSyncFile = currentFile
                        }
                    }
                )
                self.phase = .completed(result)
            } catch is CancellationError {
                self.phase = .previewReady
            } catch {
                self.phase = .error(error.localizedDescription)
            }
            await service.stopAccessing(leftDir)
            await service.stopAccessing(rightDir)
        }
    }

    func cancel() {
        compareTask?.cancel()
        syncTask?.cancel()
        phase = .idle
    }

    // MARK: - Item Selection

    func toggleItemSelection(at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].isSelected.toggle()
    }

    func selectAll() {
        for i in items.indices {
            if items[i].action != .skip {
                items[i].isSelected = true
            }
        }
    }

    func deselectAll() {
        for i in items.indices {
            items[i].isSelected = false
        }
    }

    func setItemAction(_ action: SyncItemAction, at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].action = action
        items[index].isSelected = action != .skip
    }

    // MARK: - Exclude Rules

    func addExcludeRule(_ pattern: String) {
        guard !pattern.isEmpty else { return }
        excludeRules.append(SyncExcludeRule(pattern: pattern))
        if case .previewReady = phase { compare() }
    }

    func removeExcludeRule(at index: Int) {
        guard excludeRules.indices.contains(index) else { return }
        excludeRules.remove(at: index)
        if case .previewReady = phase { compare() }
    }

    func toggleExcludeRule(at index: Int) {
        guard excludeRules.indices.contains(index) else { return }
        excludeRules[index].isEnabled.toggle()
        if case .previewReady = phase { compare() }
    }

    // MARK: - Synclet Management

    func saveSynclet(name: String) {
        guard !name.isEmpty else { return }
        let synclet = Synclet(
            name: name,
            leftPath: leftDirectory.path,
            rightPath: rightDirectory.path,
            direction: direction,
            excludeRules: excludeRules
        )
        synclets.append(synclet)
        persistSynclets()
    }

    func loadSynclet(_ synclet: Synclet) {
        leftDirectory = URL(fileURLWithPath: synclet.leftPath, isDirectory: true)
        rightDirectory = URL(fileURLWithPath: synclet.rightPath, isDirectory: true)
        direction = synclet.direction
        excludeRules = synclet.excludeRules
        phase = .idle
        items = []
    }

    func deleteSynclet(_ synclet: Synclet) {
        synclets.removeAll { $0.id == synclet.id }
        persistSynclets()
    }

    private func persistSynclets() {
        let config = SyncletsConfig(synclets: synclets)
        try? configManager.saveSyncletsConfig(config)
    }
}
