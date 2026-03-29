import Foundation

@MainActor
final class FilePaneViewModel {
    private static let defaultPageStep = 10
    private enum RefreshTrigger {
        case explicit
        case directoryMonitor
    }

    private struct SelectionSnapshot {
        let cursorURL: URL?
        let markedURLs: Set<URL>
        let visualAnchorURL: URL?
    }

    struct LoadingContext: Equatable, Sendable {
        let directory: URL
        let mode: PaneDisplayMode
        let isRecursive: Bool
        var foundCount: Int?

        var statusText: String {
            let base: String
            switch mode {
            case .browser:
                base = isRecursive ? "Loading files recursively..." : "Loading files..."
            case .media:
                base = isRecursive ? "Loading media recursively..." : "Loading media..."
            }
            if let count = foundCount, count > 0 {
                return "\(base) (\(count) found)"
            }
            return base
        }
    }

    private(set) var directoryContents: DirectoryContents {
        didSet {
            onItemsChanged?(directoryContents.displayedItems)
        }
    }

    private(set) var paneState: PaneState {
        didSet {
            if oldValue.cursorIndex != paneState.cursorIndex {
                onCursorChanged?(paneState.cursorIndex)
            }
            if oldValue.markedIndices != paneState.markedIndices {
                onMarkedIndicesChanged?(paneState.markedIndices)
            }
        }
    }

    private(set) var navigationHistory = NavigationHistory()

    var onItemsChanged: (([FileItem]) -> Void)?
    var onCursorChanged: ((Int) -> Void)?
    var onMarkedIndicesChanged: ((IndexSet) -> Void)?
    var onDirectoryChanged: ((URL) -> Void)?
    var onDirectoryLoadFailed: ((URL, Error) -> Void)?
    var onLoadingStateChanged: ((LoadingContext?) -> Void)?
    var onDisplayModeChanged: ((PaneDisplayMode) -> Void)?
    var onFilesRecursiveChanged: ((Bool) -> Void)?
    var onMediaRecursiveChanged: ((Bool) -> Void)?

    private let fileSystemService: FileSystemProviding
    private let securityScopedBookmarkService: any SecurityScopedBookmarkProviding
    private let directoryMonitor: any DirectoryMonitoring
    private let spotlightSearchService: any SpotlightSearching
    private var loadTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var spotlightSearchTask: Task<Void, Never>?
    private var isSpotlightSearchActive = false
    private(set) var spotlightSearchScope: SpotlightSearchScope
    private(set) var displayMode: PaneDisplayMode
    private(set) var filesRecursiveEnabled: Bool
    private(set) var mediaRecursiveEnabled: Bool
    private var pendingRevealURL: URL?
    private var activeNavigationTaskID: UUID?
    private var activeLoadingTaskID: UUID?
    private var loadingContext: LoadingContext?
    private var lastRefreshFailureSignature: String?
    private var hasActiveFilter: Bool {
        !directoryContents.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var firstBrowsableDirectoryIndex: Int? {
        directoryContents.displayedItems.firstIndex(where: { $0.isDirectory && !$0.isPackage })
    }

    init(
        fileSystemService: FileSystemProviding = FileSystemService(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared,
        directoryMonitor: any DirectoryMonitoring = DirectoryMonitor(),
        spotlightSearchService: (any SpotlightSearching)? = nil,
        initialSpotlightSearchScope: SpotlightSearchScope = .currentDirectory,
        initialDisplayMode: PaneDisplayMode = .browser,
        initialFilesRecursiveEnabled: Bool = false,
        initialMediaRecursiveEnabled: Bool = false,
        initialDirectory: URL = UserPaths.homeDirectoryURL,
        initialNavigationHistory: NavigationHistory = NavigationHistory()
    ) {
        self.fileSystemService = fileSystemService
        self.securityScopedBookmarkService = securityScopedBookmarkService
        self.directoryMonitor = directoryMonitor
        self.spotlightSearchService = spotlightSearchService ?? SpotlightSearchService()
        self.spotlightSearchScope = initialSpotlightSearchScope
        self.displayMode = initialDisplayMode
        self.filesRecursiveEnabled = initialFilesRecursiveEnabled
        self.mediaRecursiveEnabled = initialMediaRecursiveEnabled
        self.navigationHistory = initialNavigationHistory
        let normalizedDirectory = initialDirectory.standardizedFileURL
        self.paneState = PaneState(currentDirectory: normalizedDirectory)
        self.directoryContents = DirectoryContents(contentFilter: initialDisplayMode == .media ? .mediaOnly : .allFiles)
        loadDirectory(at: normalizedDirectory, previousDirectory: nil)
    }

    deinit {
        MainActor.assumeIsolated {
            loadTask?.cancel()
            spotlightSearchTask?.cancel()
            spotlightSearchService.cancel()
            directoryMonitor.stopMonitoring()
        }
    }

    var selectedItem: FileItem? {
        guard directoryContents.displayedItems.indices.contains(paneState.cursorIndex) else {
            return nil
        }
        return directoryContents.displayedItems[paneState.cursorIndex]
    }

    var canGoBack: Bool {
        !navigationHistory.backStack.isEmpty
    }

    var canGoForward: Bool {
        !navigationHistory.forwardStack.isEmpty
    }

    var isVisualMode: Bool {
        paneState.visualAnchorIndex != nil
    }

    var markedCount: Int {
        paneState.markedIndices.count
    }

    var isMediaModeEnabled: Bool {
        displayMode == .media
    }

    var effectiveDirectory: URL {
        loadingContext?.directory ?? paneState.currentDirectory.standardizedFileURL
    }

    func markedOrSelectedURLs() -> [URL] {
        FilePaneSelection.markedOrSelectedURLs(
            displayedItems: directoryContents.displayedItems,
            markedIndices: paneState.markedIndices,
            cursorIndex: paneState.cursorIndex
        )
    }

    func markedOrSelectedPaths() -> [String] {
        markedOrSelectedURLs().map { $0.standardizedFileURL.path }
    }

    func navigate(to directory: URL) {
        if isSpotlightSearchActive {
            endSpotlightSearch(restoringDirectoryContents: false)
        }

        let destination = directory.standardizedFileURL
        guard destination != paneState.currentDirectory else {
            return
        }

        applyNavigationDisplayDefaultsIfNeeded()

        let currentDirectory = paneState.currentDirectory
        navigationHistory.push(currentDirectory)
        loadDirectory(at: destination, previousDirectory: currentDirectory)
    }

    func navigate(to directory: URL, selecting itemURL: URL) {
        let destination = directory.standardizedFileURL
        let normalizedItemURL = itemURL.standardizedFileURL

        if destination == paneState.currentDirectory {
            if let index = directoryContents.displayedItems.firstIndex(where: { $0.url.standardizedFileURL == normalizedItemURL }) {
                paneState.cursorIndex = index
            }
            return
        }

        pendingRevealURL = normalizedItemURL
        navigate(to: destination)
    }

    func goBack() {
        if isSpotlightSearchActive {
            endSpotlightSearch(restoringDirectoryContents: false)
        }

        let currentDirectory = paneState.currentDirectory
        guard let destination = navigationHistory.goBack(from: currentDirectory) else {
            return
        }

        applyNavigationDisplayDefaultsIfNeeded()
        loadDirectory(at: destination, previousDirectory: currentDirectory)
    }

    func goForward() {
        if isSpotlightSearchActive {
            endSpotlightSearch(restoringDirectoryContents: false)
        }

        let currentDirectory = paneState.currentDirectory
        guard let destination = navigationHistory.goForward(from: currentDirectory) else {
            return
        }

        applyNavigationDisplayDefaultsIfNeeded()
        loadDirectory(at: destination, previousDirectory: currentDirectory)
    }

    func jumpToHistoryPosition(_ position: Int) {
        if isSpotlightSearchActive {
            endSpotlightSearch(restoringDirectoryContents: false)
        }

        let currentDirectory = paneState.currentDirectory
        guard let destination = navigationHistory.jumpToTimelinePosition(position, from: currentDirectory) else {
            return
        }

        applyNavigationDisplayDefaultsIfNeeded()
        loadDirectory(at: destination, previousDirectory: currentDirectory)
    }

    func goToParent() {
        if isSpotlightSearchActive {
            endSpotlightSearch(restoringDirectoryContents: false)
        }

        let currentDirectory = paneState.currentDirectory.standardizedFileURL
        let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL
        guard parent.path != currentDirectory.path else {
            return
        }
        navigate(to: parent, selecting: currentDirectory)
    }

    func enterSelected() {
        if isSpotlightSearchActive {
            enterSpotlightSelection()
            return
        }

        guard let item = selectedItem, item.isDirectory, !item.isPackage else {
            return
        }
        navigate(to: item.url)
    }

    func expandSelectedFolder() {
        guard let item = selectedItem, item.isDirectory, !item.isPackage else {
            return
        }

        let url = item.url.standardizedFileURL

        if directoryContents.treeExpansionState.isExpanded(url) {
            return
        }

        let snapshot = captureSelectionSnapshot()

        expandTask?.cancel()
        expandTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let children = try await self.fileSystemService.contentsOfDirectory(at: url)
                guard !Task.isCancelled else {
                    return
                }

                var updatedContents = self.directoryContents
                updatedContents.treeExpansionState.expand(url, children: children)
                updatedContents.recompute()
                self.directoryContents = updatedContents
                self.restoreSelection(from: snapshot)
            } catch {
                // Ignore errors when expanding
            }
        }
    }

    func collapseSelectedFolder() {
        let cursorIndex = paneState.cursorIndex
        guard directoryContents.displayedTreeItems.indices.contains(cursorIndex) else {
            return
        }

        let treeItem = directoryContents.displayedTreeItems[cursorIndex]

        if treeItem.isExpanded {
            let snapshot = captureSelectionSnapshot()
            var updatedContents = directoryContents
            updatedContents.treeExpansionState.collapse(treeItem.fileItem.url)
            updatedContents.recompute()
            directoryContents = updatedContents
            restoreSelection(from: snapshot)
            return
        }

        if let parentURL = treeItem.parentURL {
            if let parentIndex = directoryContents.displayedItems.firstIndex(where: { $0.url.standardizedFileURL == parentURL }) {
                setCursor(index: parentIndex)
            }
            return
        }
    }

    func enterSpotlightSearchMode() {
        guard !isSpotlightSearchActive else {
            return
        }

        isSpotlightSearchActive = true
        paneState.markedIndices.removeAll()
        paneState.visualAnchorIndex = nil
        applySpotlightResults([])
    }

    func setSpotlightSearchScope(_ scope: SpotlightSearchScope) {
        guard spotlightSearchScope != scope else {
            return
        }

        spotlightSearchScope = scope
    }

    func setDisplayMode(_ mode: PaneDisplayMode) {
        guard displayMode != mode else {
            return
        }

        displayMode = mode
        onDisplayModeChanged?(mode)

        var updatedContents = directoryContents
        updatedContents.contentFilter = mode == .media ? .mediaOnly : .allFiles
        updatedContents.recompute()
        directoryContents = updatedContents
        refreshCurrentDirectory(preservingSelectionByURL: false)
    }

    func toggleDisplayMode() {
        setDisplayMode(displayMode == .browser ? .media : .browser)
    }

    func setFilesRecursiveEnabled(_ enabled: Bool) {
        guard filesRecursiveEnabled != enabled else {
            return
        }

        filesRecursiveEnabled = enabled
        onFilesRecursiveChanged?(enabled)

        guard displayMode == .browser else {
            return
        }

        if activeNavigationTaskID != nil {
            // Cancel the in-progress navigation and reload the destination with the new setting.
            let targetDir = effectiveDirectory
            loadDirectory(at: targetDir, previousDirectory: paneState.currentDirectory)
        } else {
            refreshCurrentDirectory(preservingSelectionByURL: false)
        }
    }

    func setMediaRecursiveEnabled(_ enabled: Bool) {
        guard mediaRecursiveEnabled != enabled else {
            return
        }

        mediaRecursiveEnabled = enabled
        onMediaRecursiveChanged?(enabled)

        guard displayMode == .media else {
            return
        }

        if activeNavigationTaskID != nil {
            let targetDir = effectiveDirectory
            loadDirectory(at: targetDir, previousDirectory: paneState.currentDirectory)
        } else {
            refreshCurrentDirectory(preservingSelectionByURL: false)
        }
    }

    func toggleRecursive() {
        switch displayMode {
        case .browser:
            setFilesRecursiveEnabled(!filesRecursiveEnabled)
        case .media:
            setMediaRecursiveEnabled(!mediaRecursiveEnabled)
        }
    }

    func updateSpotlightSearchQuery(_ query: String) {
        guard isSpotlightSearchActive else {
            return
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        spotlightSearchTask?.cancel()
        spotlightSearchService.cancel()

        guard !trimmedQuery.isEmpty else {
            applySpotlightResults([])
            return
        }

        let scope = spotlightSearchScope
        let currentDirectory = paneState.currentDirectory

        spotlightSearchTask = Task { [weak self] in
            guard let self else {
                return
            }

            let stream = self.spotlightSearchService.search(
                query: trimmedQuery,
                scope: scope,
                currentDirectory: currentDirectory
            )
            for await items in stream {
                guard !Task.isCancelled, self.isSpotlightSearchActive else {
                    return
                }

                self.applySpotlightResults(items)
            }
        }
    }

    func exitSpotlightSearchMode() {
        guard isSpotlightSearchActive else {
            return
        }

        endSpotlightSearch(restoringDirectoryContents: true)
    }

    func moveCursor(by delta: Int) {
        let itemCount = directoryContents.displayedItems.count
        guard itemCount > 0 else {
            setCursor(index: 0)
            return
        }

        let nextIndex = min(max(0, paneState.cursorIndex + delta), itemCount - 1)
        setCursor(index: nextIndex)
    }

    func setCursor(index: Int) {
        guard !directoryContents.displayedItems.isEmpty else {
            paneState.cursorIndex = 0
            return
        }

        let clampedIndex = min(max(index, 0), directoryContents.displayedItems.count - 1)
        paneState.cursorIndex = clampedIndex
        updateVisualSelectionForCurrentCursorIfNeeded()
    }

    func moveCursorUp() {
        moveCursor(by: -1)
    }

    func moveCursorDown() {
        moveCursor(by: 1)
    }

    func moveCursorToTop() {
        setCursor(index: 0)
    }

    func moveCursorToBottom() {
        let lastIndex = max(directoryContents.displayedItems.count - 1, 0)
        setCursor(index: lastIndex)
    }

    func moveCursorPageUp(pageStep: Int? = nil) {
        let resolvedPageStep = max(1, pageStep ?? Self.defaultPageStep)
        moveCursor(by: -resolvedPageStep)
    }

    func moveCursorPageDown(pageStep: Int? = nil) {
        let resolvedPageStep = max(1, pageStep ?? Self.defaultPageStep)
        moveCursor(by: resolvedPageStep)
    }

    func toggleMark() {
        paneState.visualAnchorIndex = nil
        paneState.markedIndices = FilePaneSelection.toggledMarkedIndices(
            currentMarkedIndices: paneState.markedIndices,
            cursorIndex: paneState.cursorIndex,
            itemCount: directoryContents.displayedItems.count
        )
    }

    func markAll() {
        paneState.visualAnchorIndex = nil
        paneState.markedIndices = FilePaneSelection.allMarkedIndices(
            itemCount: directoryContents.displayedItems.count
        )
    }

    func clearMarks() {
        paneState.visualAnchorIndex = nil
        paneState.markedIndices.removeAll()
    }

    func setMarkedIndices(_ markedIndices: IndexSet) {
        paneState.visualAnchorIndex = nil
        paneState.markedIndices = FilePaneSelection.clampedMarkedIndices(
            markedIndices,
            itemCount: directoryContents.displayedItems.count
        )
    }

    func setMarkedRange(anchorIndex: Int, currentIndex: Int) {
        paneState.visualAnchorIndex = nil
        paneState.markedIndices = FilePaneSelection.rangeMarkedIndices(
            anchorIndex: anchorIndex,
            currentIndex: currentIndex,
            itemCount: directoryContents.displayedItems.count
        )
    }

    func enterVisualMode() {
        guard !directoryContents.displayedItems.isEmpty else {
            paneState.visualAnchorIndex = nil
            paneState.markedIndices.removeAll()
            return
        }

        paneState.visualAnchorIndex = paneState.cursorIndex
        updateVisualSelectionForCurrentCursorIfNeeded()
    }

    func exitVisualMode() {
        paneState.visualAnchorIndex = nil
    }

    func setVisualSelection(anchorIndex: Int, currentIndex: Int) {
        paneState.visualAnchorIndex = anchorIndex
        setCursor(index: currentIndex)
    }

    func toggleMarkAtCursor() {
        toggleMark()
    }

    func markAllDisplayedItems() {
        markAll()
    }

    func clearAllMarks() {
        clearMarks()
    }

    func setFilterText(_ text: String) {
        var updatedContents = directoryContents
        updatedContents.filterText = text
        updatedContents.recompute()
        directoryContents = updatedContents
        clampCursorIndex()
        clampMarkedIndices()
        clampVisualAnchorIndex()
        updateVisualSelectionForCurrentCursorIfNeeded()
    }

    func clearFilter() {
        setFilterText("")
    }

    func focusFirstBrowsableDirectoryInFilteredResults() {
        guard hasActiveFilter else {
            return
        }

        if let firstBrowsableDirectoryIndex {
            paneState.cursorIndex = firstBrowsableDirectoryIndex
        } else if !directoryContents.displayedItems.isEmpty {
            paneState.cursorIndex = 0
        }
    }

    func setShowHiddenFiles(_ enabled: Bool) {
        guard directoryContents.showHiddenFiles != enabled else {
            return
        }

        var updatedContents = directoryContents
        updatedContents.showHiddenFiles = enabled

        // Recursive scan must be reloaded to include/exclude hidden descendants.
        if displayMode == .media || (displayMode == .browser && filesRecursiveEnabled) {
            directoryContents = updatedContents
            refreshCurrentDirectory(preservingSelectionByURL: false)
            return
        }

        updatedContents.recompute()
        directoryContents = updatedContents
        clampCursorIndex()
        clampMarkedIndices()
        clampVisualAnchorIndex()
        updateVisualSelectionForCurrentCursorIfNeeded()
    }

    func toggleHiddenFiles() {
        setShowHiddenFiles(!directoryContents.showHiddenFiles)
    }

    func sortByName() {
        applySortDescriptor(.name(ascending: true))
    }

    func sortBySize() {
        applySortDescriptor(.size(ascending: true))
    }

    func sortByDate() {
        applySortDescriptor(.date(ascending: true))
    }

    func sortBySelectionOrder() {
        applySortDescriptor(.selection(ascending: true))
    }

    func cycleSortMode() {
        let nextSortDescriptor: DirectoryContents.SortDescriptor

        switch directoryContents.sortDescriptor.column {
        case .name:
            nextSortDescriptor = .size(ascending: true)
        case .size:
            nextSortDescriptor = .date(ascending: true)
        case .date:
            nextSortDescriptor = .selection(ascending: true)
        case .selection:
            nextSortDescriptor = .name(ascending: true)
        }

        applySortDescriptor(nextSortDescriptor)
    }

    var sortModeDisplayText: String {
        let title: String
        switch directoryContents.sortDescriptor.column {
        case .name:
            title = "Name"
        case .size:
            title = "Size"
        case .date:
            title = "Date Modified"
        case .selection:
            title = "Selection Order"
        }

        if directoryContents.sortDescriptor.column == .selection {
            return "Sort: \(title)"
        }

        let direction = directoryContents.sortDescriptor.ascending ? "(Asc)" : "(Desc)"
        return "Sort: \(title) \(direction)"
    }

    func setSortDescriptor(_ sortDescriptor: DirectoryContents.SortDescriptor) {
        applySortDescriptor(sortDescriptor)
    }

    func reverseSortOrder() {
        let currentSortDescriptor = directoryContents.sortDescriptor
        let nextSortDescriptor = DirectoryContents.SortDescriptor(
            column: currentSortDescriptor.column,
            ascending: !currentSortDescriptor.ascending
        )

        applySortDescriptor(nextSortDescriptor)
    }

    func refresh() {
        guard !isSpotlightSearchActive else {
            return
        }
        refreshCurrentDirectory(preservingSelectionByURL: true, trigger: .explicit)
    }

    func refreshCurrentDirectory() {
        guard !isSpotlightSearchActive else {
            return
        }
        refreshCurrentDirectory(preservingSelectionByURL: true, trigger: .explicit)
    }

    @discardableResult
    func cancelLoading() -> Bool {
        guard activeLoadingTaskID != nil else {
            return false
        }

        activeNavigationTaskID = nil
        loadTask?.cancel()
        activeLoadingTaskID = nil
        loadingContext = nil
        onLoadingStateChanged?(nil)
        return true
    }

    func suspendDirectoryMonitoring() {
        directoryMonitor.suspend()
    }

    func resumeDirectoryMonitoring() {
        directoryMonitor.resume()
    }

    private func refreshCurrentDirectory(
        preservingSelectionByURL: Bool,
        trigger: RefreshTrigger = .explicit
    ) {
        guard activeNavigationTaskID == nil else {
            return
        }

        // File system notifications may arrive in bursts.
        // Ignore monitor-triggered reload while another load is active to avoid
        // cancel/restart loops that keep showing "Loading...".
        if trigger == .directoryMonitor, activeLoadingTaskID != nil {
            return
        }

        let currentDirectory = paneState.currentDirectory
        let selectionSnapshot = preservingSelectionByURL ? captureSelectionSnapshot() : nil
        let refreshTaskID = UUID()
        let shouldNotifyLoadingState = trigger == .explicit
        beginLoading(taskID: refreshTaskID, directory: currentDirectory, notify: shouldNotifyLoadingState)

        var refreshProgressHandler: (@Sendable (Int) -> Void)?
        if shouldNotifyLoadingState {
            refreshProgressHandler = { [weak self] count in
                Task<Void, Never> { @MainActor [weak self] in
                    guard let self, self.activeLoadingTaskID == refreshTaskID else { return }
                    var ctx = self.loadingContext
                    ctx?.foundCount = count
                    self.loadingContext = ctx
                    self.onLoadingStateChanged?(ctx)
                }
            }
        }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.endLoading(taskID: refreshTaskID, notify: shouldNotifyLoadingState)
            }

            do {
                let items = try await self.loadItemsForCurrentMode(at: currentDirectory, onProgress: refreshProgressHandler)
                guard !Task.isCancelled else {
                    return
                }

                let currentFilterText = self.directoryContents.filterText
                var updatedContents = self.directoryContents
                updatedContents.allItems = items
                // Keep active filter text when refreshing in-place (e.g. recursive toggle).
                updatedContents.filterText = currentFilterText
                updatedContents.contentFilter = self.displayMode == .media ? .mediaOnly : .allFiles

                // Re-load children for expanded directories
                let expandedURLs = updatedContents.treeExpansionState.expandedURLs
                for expandedURL in expandedURLs {
                    if let children = try? await self.fileSystemService.contentsOfDirectory(at: expandedURL) {
                        guard !Task.isCancelled else {
                            return
                        }
                        updatedContents.treeExpansionState.updateChildren(for: expandedURL, children: children)
                    } else {
                        updatedContents.treeExpansionState.collapse(expandedURL)
                    }
                }

                updatedContents.recompute()
                self.directoryContents = updatedContents
                self.lastRefreshFailureSignature = nil

                if self.revealPendingSelectionIfNeeded() {
                    self.clampMarkedIndices()
                    self.clampVisualAnchorIndex()
                    self.updateVisualSelectionForCurrentCursorIfNeeded()
                    return
                }

                if let selectionSnapshot {
                    self.restoreSelection(from: selectionSnapshot)
                } else {
                    self.clampCursorIndex()
                    self.clampMarkedIndices()
                    self.clampVisualAnchorIndex()
                    self.updateVisualSelectionForCurrentCursorIfNeeded()
                }
            } catch {
                if error is CancellationError {
                    return
                }

                let signature = "\(currentDirectory.path)|\(error.localizedDescription)"
                guard self.lastRefreshFailureSignature != signature else {
                    return
                }
                self.lastRefreshFailureSignature = signature
                self.onDirectoryLoadFailed?(currentDirectory, error)
            }
        }
    }

    private func loadDirectory(at directory: URL, previousDirectory: URL?) {
        if isSpotlightSearchActive {
            endSpotlightSearch(restoringDirectoryContents: false)
        }

        if let previousDirectory, previousDirectory != directory {
            directoryMonitor.stopMonitoring()
        }

        let navigationTaskID = UUID()
        activeNavigationTaskID = navigationTaskID
        beginLoading(taskID: navigationTaskID, directory: directory)
        loadTask?.cancel()

        loadTask = Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                if self.activeNavigationTaskID == navigationTaskID {
                    self.activeNavigationTaskID = nil
                }
                self.endLoading(taskID: navigationTaskID)
            }

            var didAcquireDestinationScope = false

            do {
                try await self.securityScopedBookmarkService.startAccessing(directory)
                didAcquireDestinationScope = true

                let progressHandler: @Sendable (Int) -> Void = { [weak self] count in
                    Task<Void, Never> { @MainActor [weak self] in
                        guard let self, self.activeLoadingTaskID == navigationTaskID else { return }
                        var ctx = self.loadingContext
                        ctx?.foundCount = count
                        self.loadingContext = ctx
                        self.onLoadingStateChanged?(ctx)
                    }
                }
                let items = try await self.loadItemsForCurrentMode(at: directory, onProgress: progressHandler)
                guard !Task.isCancelled else {
                    if didAcquireDestinationScope {
                        await self.securityScopedBookmarkService.stopAccessing(directory)
                    }
                    return
                }

                if let previousDirectory, previousDirectory != directory {
                    await self.securityScopedBookmarkService.stopAccessing(previousDirectory)
                }

                self.paneState.currentDirectory = directory
                self.paneState.markedIndices.removeAll()
                self.paneState.visualAnchorIndex = nil

                var updatedContents = self.directoryContents
                updatedContents.allItems = items
                updatedContents.filterText = ""
                updatedContents.contentFilter = self.displayMode == .media ? .mediaOnly : .allFiles
                updatedContents.treeExpansionState.clear()
                updatedContents.recompute()
                self.directoryContents = updatedContents
                self.lastRefreshFailureSignature = nil

                if !self.revealPendingSelectionIfNeeded() {
                    self.clampCursorIndex()
                    self.clampMarkedIndices()
                    self.clampVisualAnchorIndex()
                }

                self.startMonitoringCurrentDirectory(directory)
                self.onDirectoryChanged?(directory)
            } catch {
                let isCancellation = error is CancellationError

                if didAcquireDestinationScope {
                    await self.securityScopedBookmarkService.stopAccessing(directory)
                }

                if let previousDirectory {
                    self.startMonitoringCurrentDirectory(previousDirectory)
                }

                if isCancellation {
                    return
                }

                self.onDirectoryLoadFailed?(directory, error)
            }
        }
    }

    private func loadItemsForCurrentMode(at directory: URL, onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> [FileItem] {
        switch displayMode {
        case .browser:
            if filesRecursiveEnabled {
                return try await fileSystemService.recursiveContentsOfDirectory(
                    at: directory,
                    includeHiddenFiles: directoryContents.showHiddenFiles,
                    onProgress: onProgress
                )
            }
            return try await fileSystemService.contentsOfDirectory(at: directory)
        case .media:
            return try await fileSystemService.mediaItems(
                in: directory,
                recursive: mediaRecursiveEnabled,
                includeHiddenFiles: directoryContents.showHiddenFiles,
                onProgress: onProgress
            )
        }
    }

    private func applyNavigationDisplayDefaultsIfNeeded() {
        var didChangeDisplayMode = false

        if displayMode != .browser {
            displayMode = .browser
            didChangeDisplayMode = true
            onDisplayModeChanged?(.browser)
        }

        if filesRecursiveEnabled {
            filesRecursiveEnabled = false
            onFilesRecursiveChanged?(false)
        }

        if mediaRecursiveEnabled {
            mediaRecursiveEnabled = false
            onMediaRecursiveChanged?(false)
        }

        guard didChangeDisplayMode else {
            return
        }

        var updatedContents = directoryContents
        updatedContents.contentFilter = .allFiles
        updatedContents.recompute()
        directoryContents = updatedContents
    }

    private func beginLoading(taskID: UUID, directory: URL) {
        beginLoading(taskID: taskID, directory: directory, notify: true)
    }

    private func beginLoading(taskID: UUID, directory: URL, notify: Bool) {
        activeLoadingTaskID = taskID
        loadingContext = currentLoadingContext(for: directory)
        guard notify else {
            return
        }
        onLoadingStateChanged?(loadingContext)
    }

    private func endLoading(taskID: UUID) {
        endLoading(taskID: taskID, notify: true)
    }

    private func endLoading(taskID: UUID, notify: Bool) {
        guard activeLoadingTaskID == taskID else {
            return
        }
        activeLoadingTaskID = nil
        loadingContext = nil
        guard notify else {
            return
        }
        onLoadingStateChanged?(nil)
    }

    private func currentLoadingContext(for directory: URL) -> LoadingContext {
        let recursive = displayMode == .media ? mediaRecursiveEnabled : filesRecursiveEnabled
        return LoadingContext(
            directory: directory.standardizedFileURL,
            mode: displayMode,
            isRecursive: recursive
        )
    }

    private func applySortDescriptor(_ sortDescriptor: DirectoryContents.SortDescriptor) {
        var updatedContents = directoryContents
        updatedContents.setSortDescriptor(sortDescriptor)
        directoryContents = updatedContents
        clampCursorIndex()
        clampMarkedIndices()
        clampVisualAnchorIndex()
        updateVisualSelectionForCurrentCursorIfNeeded()
    }

    private func clampCursorIndex() {
        let count = directoryContents.displayedItems.count
        guard count > 0 else {
            paneState.cursorIndex = 0
            return
        }

        if hasActiveFilter {
            if let firstBrowsableDirectoryIndex {
                paneState.cursorIndex = firstBrowsableDirectoryIndex
            } else {
                paneState.cursorIndex = 0
            }
            return
        }

        if paneState.cursorIndex >= count {
            paneState.cursorIndex = count - 1
        }
    }

    private func clampMarkedIndices() {
        paneState.markedIndices = FilePaneSelection.clampedMarkedIndices(
            paneState.markedIndices,
            itemCount: directoryContents.displayedItems.count
        )
    }

    private func clampVisualAnchorIndex() {
        paneState.visualAnchorIndex = FilePaneSelection.clampedVisualAnchorIndex(
            paneState.visualAnchorIndex,
            itemCount: directoryContents.displayedItems.count
        )
    }

    private func updateVisualSelectionForCurrentCursorIfNeeded() {
        guard let markedIndices = FilePaneSelection.visualSelection(
            visualAnchorIndex: paneState.visualAnchorIndex,
            cursorIndex: paneState.cursorIndex,
            itemCount: directoryContents.displayedItems.count
        ) else {
            return
        }

        paneState.markedIndices = markedIndices
    }

    private func startMonitoringCurrentDirectory(_ directory: URL) {
        let monitoredDirectory = directory.standardizedFileURL
        directoryMonitor.startMonitoring(url: monitoredDirectory) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshCurrentDirectory(
                    preservingSelectionByURL: true,
                    trigger: .directoryMonitor
                )
            }
        }
    }

    private func captureSelectionSnapshot() -> SelectionSnapshot {
        let displayedItems = directoryContents.displayedItems

        let cursorURL: URL?
        if displayedItems.indices.contains(paneState.cursorIndex) {
            cursorURL = displayedItems[paneState.cursorIndex].url.standardizedFileURL
        } else {
            cursorURL = nil
        }

        let markedURLs = Set(
            paneState.markedIndices.compactMap { index -> URL? in
                guard displayedItems.indices.contains(index) else {
                    return nil
                }
                return displayedItems[index].url.standardizedFileURL
            }
        )

        let visualAnchorURL: URL?
        if let visualAnchorIndex = paneState.visualAnchorIndex, displayedItems.indices.contains(visualAnchorIndex) {
            visualAnchorURL = displayedItems[visualAnchorIndex].url.standardizedFileURL
        } else {
            visualAnchorURL = nil
        }

        return SelectionSnapshot(
            cursorURL: cursorURL,
            markedURLs: markedURLs,
            visualAnchorURL: visualAnchorURL
        )
    }

    private func restoreSelection(from snapshot: SelectionSnapshot) {
        let displayedItems = directoryContents.displayedItems
        guard !displayedItems.isEmpty else {
            paneState.cursorIndex = 0
            paneState.markedIndices.removeAll()
            paneState.visualAnchorIndex = nil
            return
        }

        var indexByURL: [URL: Int] = [:]
        indexByURL.reserveCapacity(displayedItems.count)
        for (index, item) in displayedItems.enumerated() {
            let normalizedURL = item.url.standardizedFileURL
            if indexByURL[normalizedURL] == nil {
                indexByURL[normalizedURL] = index
            }
        }

        if let cursorURL = snapshot.cursorURL, let restoredCursorIndex = indexByURL[cursorURL] {
            paneState.cursorIndex = restoredCursorIndex
        } else {
            clampCursorIndex()
        }

        paneState.markedIndices = FilePaneSelection.markedIndices(
            for: snapshot.markedURLs,
            indexByURL: indexByURL
        )

        if let visualAnchorURL = snapshot.visualAnchorURL, let restoredVisualAnchorIndex = indexByURL[visualAnchorURL] {
            paneState.visualAnchorIndex = restoredVisualAnchorIndex
        } else {
            paneState.visualAnchorIndex = nil
        }

        updateVisualSelectionForCurrentCursorIfNeeded()
    }

    private func enterSpotlightSelection() {
        guard let selectedItem else {
            return
        }

        let selectedURL = selectedItem.url.standardizedFileURL
        let targetDirectory = selectedURL.deletingLastPathComponent().standardizedFileURL
        pendingRevealURL = selectedURL

        if targetDirectory == paneState.currentDirectory {
            endSpotlightSearch(restoringDirectoryContents: true)
            return
        }

        endSpotlightSearch(restoringDirectoryContents: false)
        navigate(to: targetDirectory)
    }

    private func applySpotlightResults(_ items: [FileItem]) {
        var updatedContents = directoryContents
        updatedContents.allItems = items
        updatedContents.filterText = ""
        updatedContents.recompute()
        directoryContents = updatedContents
        paneState.markedIndices.removeAll()
        paneState.visualAnchorIndex = nil
        clampCursorIndex()
        clampMarkedIndices()
        clampVisualAnchorIndex()
    }

    private func endSpotlightSearch(restoringDirectoryContents: Bool) {
        isSpotlightSearchActive = false
        spotlightSearchTask?.cancel()
        spotlightSearchTask = nil
        spotlightSearchService.cancel()

        if restoringDirectoryContents {
            refreshCurrentDirectory(preservingSelectionByURL: false)
        }
    }

    private func revealPendingSelectionIfNeeded() -> Bool {
        guard let pendingRevealURL else {
            return false
        }

        defer {
            self.pendingRevealURL = nil
        }

        guard let index = directoryContents.displayedItems.firstIndex(where: { $0.url.standardizedFileURL == pendingRevealURL }) else {
            return false
        }

        paneState.cursorIndex = index
        return true
    }
}
