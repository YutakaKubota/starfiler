import AppKit

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    enum BookmarkContextAction {
        case editBookmark
        case deleteBookmark
        case unpinPinnedItem
    }

    final class BookmarkTreeNode: NSObject {
        let entry: SidebarViewModel.SidebarEntry
        let children: [BookmarkTreeNode]

        init(entry: SidebarViewModel.SidebarEntry, children: [BookmarkTreeNode]) {
            self.entry = entry
            self.children = children
        }
    }

    private let viewModel: SidebarViewModel
    private let windowControlsContainer = NSView()
    private let windowControlsStackView = NSStackView()
    let scrollView = NSScrollView()
    let outlineView = NSOutlineView()
    let regularContextMenu = NSMenu()
    private let recentSeparatorView = NSView()
    private let recentHeaderLabel = NSTextField(labelWithString: "History")
    private let recentScrollView = NSScrollView()
    let recentOutlineView = NSOutlineView()
    private var scrollViewBottomToRecent: NSLayoutConstraint!
    private var scrollViewBottomToView: NSLayoutConstraint!
    private var windowControlsHeightConstraint: NSLayoutConstraint!
    private var recentScrollViewHeightConstraint: NSLayoutConstraint!

    var regularSections: [SidebarViewModel.SidebarSection] = []
    var bookmarkRootsBySectionTitle: [String: [BookmarkTreeNode]] = [:]
    var recentSection: SidebarViewModel.SidebarSection?
    var contextMenuTarget: (section: SidebarViewModel.SidebarSection, entry: SidebarViewModel.SidebarEntry)?

    let sectionHeaderHeight: CGFloat = 22
    let entryRowHeight: CGFloat = 24
    private let windowControlsTopInset: CGFloat = 6
    private let windowControlsBottomInset: CGFloat = 4
    private let windowControlsLeadingInset: CGFloat = 14
    private let windowControlsSpacing: CGFloat = 8
    private let fallbackWindowControlButtonSize = NSSize(width: 14, height: 14)
    private let maxRecentHeightRatio: CGFloat = 0.45
    private let maxRecentVisibleRows: CGFloat = 12
    private var lastKnownSidebarHeight: CGFloat = 0

    var onNavigateRequested: ((URL) -> Void)?
    var onNavigateAndRevealRequested: ((URL, URL) -> Void)?
    var onNavigationFailed: ((String) -> Void)?
    var onHistoryJumpRequested: ((Int) -> Void)?
    var onBookmarkContextActionRequested: ((BookmarkContextAction, SidebarViewModel.SectionKind, SidebarViewModel.SidebarEntry) -> Void)?

    init(viewModel: SidebarViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureOutlineViews()
        configureLayout()
        bindViewModel()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let height = floor(view.bounds.height)
        guard abs(height - lastKnownSidebarHeight) >= 1 else {
            return
        }
        lastKnownSidebarHeight = height
        updateRecentSectionLayout()
    }

    var currentTheme: FilerTheme = .system

    func reloadData() {
        viewModel.reloadSections()
    }

    func embedWindowControlButtons(_ buttons: [NSButton]) {
        guard !buttons.isEmpty else {
            return
        }

        loadViewIfNeeded()

        for existing in windowControlsStackView.arrangedSubviews {
            windowControlsStackView.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }

        var maximumButtonHeight: CGFloat = 0

        for button in buttons {
            button.removeFromSuperview()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            let buttonSize = resolvedWindowControlButtonSize(for: button)
            maximumButtonHeight = max(maximumButtonHeight, buttonSize.height)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: buttonSize.width),
                button.heightAnchor.constraint(equalToConstant: buttonSize.height)
            ])
            windowControlsStackView.addArrangedSubview(button)
        }

        windowControlsHeightConstraint.constant = maximumButtonHeight + windowControlsTopInset + windowControlsBottomInset
    }

    func applyTheme(_ theme: FilerTheme, backgroundOpacity: CGFloat = 1.0) {
        currentTheme = theme
        let palette = theme.palette
        let backgroundColor = palette.sidebarBackgroundColor.applyingBackgroundOpacity(backgroundOpacity)

        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor
        windowControlsContainer.wantsLayer = true
        windowControlsContainer.layer?.backgroundColor = backgroundColor.cgColor
        recentSeparatorView.wantsLayer = true
        recentSeparatorView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        recentHeaderLabel.textColor = palette.sidebarSectionHeaderColor

        outlineView.backgroundColor = backgroundColor
        scrollView.backgroundColor = backgroundColor
        recentOutlineView.backgroundColor = backgroundColor
        recentScrollView.backgroundColor = backgroundColor

        outlineView.reloadData()
        recentOutlineView.reloadData()
    }

    private func configureOutlineViews() {
        configureRegularOutlineView()
        configureRecentOutlineView()
    }

    private func configureRegularOutlineView() {
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.headerView = nil
        outlineView.rowHeight = entryRowHeight
        outlineView.indentationPerLevel = 14
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.allowsTypeSelect = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.target = self
        outlineView.action = #selector(handleSingleClick(_:))
        regularContextMenu.delegate = self
        outlineView.menu = regularContextMenu

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.title = ""
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
    }

    private func configureRecentOutlineView() {
        recentSeparatorView.translatesAutoresizingMaskIntoConstraints = false
        recentSeparatorView.wantsLayer = true

        recentHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        recentHeaderLabel.font = .systemFont(ofSize: 11, weight: .bold)

        recentOutlineView.translatesAutoresizingMaskIntoConstraints = false
        recentOutlineView.delegate = self
        recentOutlineView.dataSource = self
        recentOutlineView.headerView = nil
        recentOutlineView.rowHeight = entryRowHeight
        recentOutlineView.intercellSpacing = .zero
        recentOutlineView.indentationPerLevel = 0
        recentOutlineView.selectionHighlightStyle = .sourceList
        recentOutlineView.allowsTypeSelect = false
        recentOutlineView.usesAlternatingRowBackgroundColors = false
        recentOutlineView.target = self
        recentOutlineView.action = #selector(handleSingleClick(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recentSidebar"))
        column.title = ""
        recentOutlineView.addTableColumn(column)
        recentOutlineView.outlineTableColumn = column

        recentScrollView.translatesAutoresizingMaskIntoConstraints = false
        recentScrollView.documentView = recentOutlineView
        recentScrollView.hasVerticalScroller = true
        recentScrollView.hasHorizontalScroller = false
        recentScrollView.autohidesScrollers = true
        recentScrollView.borderType = .noBorder
        recentScrollView.drawsBackground = true
    }

    private var recentConstraints: [NSLayoutConstraint] = []

    private func configureLayout() {
        windowControlsContainer.translatesAutoresizingMaskIntoConstraints = false
        windowControlsStackView.translatesAutoresizingMaskIntoConstraints = false
        windowControlsStackView.orientation = .horizontal
        windowControlsStackView.alignment = .centerY
        windowControlsStackView.spacing = windowControlsSpacing

        windowControlsContainer.addSubview(windowControlsStackView)
        view.addSubview(scrollView)
        view.addSubview(windowControlsContainer)
        view.addSubview(recentSeparatorView)
        view.addSubview(recentHeaderLabel)
        view.addSubview(recentScrollView)

        windowControlsHeightConstraint = windowControlsContainer.heightAnchor.constraint(equalToConstant: 0)
        scrollViewBottomToRecent = scrollView.bottomAnchor.constraint(equalTo: recentSeparatorView.topAnchor)
        scrollViewBottomToView = scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        recentScrollViewHeightConstraint = recentScrollView.heightAnchor.constraint(equalToConstant: 0)
        recentScrollViewHeightConstraint.priority = .defaultHigh

        recentConstraints = [
            recentSeparatorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            recentSeparatorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            recentSeparatorView.heightAnchor.constraint(equalToConstant: 1),

            recentHeaderLabel.topAnchor.constraint(equalTo: recentSeparatorView.bottomAnchor, constant: 4),
            recentHeaderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            recentHeaderLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),

            recentScrollView.topAnchor.constraint(equalTo: recentHeaderLabel.bottomAnchor, constant: 8),
            recentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            recentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            recentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            recentScrollViewHeightConstraint,
        ]

        NSLayoutConstraint.activate([
            windowControlsContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            windowControlsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            windowControlsContainer.topAnchor.constraint(equalTo: view.topAnchor),
            windowControlsHeightConstraint,

            windowControlsStackView.leadingAnchor.constraint(equalTo: windowControlsContainer.leadingAnchor, constant: windowControlsLeadingInset),
            windowControlsStackView.centerYAnchor.constraint(equalTo: windowControlsContainer.centerYAnchor),
            windowControlsStackView.topAnchor.constraint(greaterThanOrEqualTo: windowControlsContainer.topAnchor, constant: windowControlsTopInset),
            windowControlsStackView.bottomAnchor.constraint(lessThanOrEqualTo: windowControlsContainer.bottomAnchor, constant: -windowControlsBottomInset),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: windowControlsContainer.bottomAnchor),
        ])

        setRecentSectionVisible(false)
    }

    private func setRecentSectionVisible(_ visible: Bool) {
        recentSeparatorView.isHidden = !visible
        recentHeaderLabel.isHidden = !visible
        recentScrollView.isHidden = !visible

        if visible {
            scrollViewBottomToView.isActive = false
            NSLayoutConstraint.activate(recentConstraints)
            scrollViewBottomToRecent.isActive = true
        } else {
            scrollViewBottomToRecent.isActive = false
            NSLayoutConstraint.deactivate(recentConstraints)
            scrollViewBottomToView.isActive = true
        }
    }

    private func resolvedWindowControlButtonSize(for button: NSButton) -> NSSize {
        let fittingSize = button.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            return fittingSize
        }

        let frameSize = button.frame.size
        if frameSize.width > 0, frameSize.height > 0 {
            return frameSize
        }

        return fallbackWindowControlButtonSize
    }

    private func bindViewModel() {
        viewModel.onSectionsChanged = { [weak self] _ in
            self?.syncSections()
        }
        syncSections()
    }

    private func syncSections() {
        regularSections = viewModel.sections.filter { !isRecentSection($0) }
        rebuildBookmarkTrees()
        recentSection = viewModel.sections.first(where: { isRecentSection($0) })

        outlineView.reloadData()
        expandAllSections()
        recentOutlineView.reloadData()
        updateRecentSectionLayout()
    }

    private func isRecentSection(_ section: SidebarViewModel.SidebarSection) -> Bool {
        if case .recent = section.kind {
            return true
        }
        return false
    }

    private func expandAllSections() {
        for section in regularSections {
            outlineView.expandItem(section.title, expandChildren: true)
        }
    }

    private func rebuildBookmarkTrees() {
        bookmarkRootsBySectionTitle.removeAll()

        for section in regularSections {
            guard supportsHierarchicalDisplay(for: section.kind) else {
                continue
            }
            bookmarkRootsBySectionTitle[section.title] = buildBookmarkTree(for: section.items)
        }
    }

    func supportsHierarchicalDisplay(for sectionKind: SidebarViewModel.SectionKind) -> Bool {
        switch sectionKind {
        case .favorites, .bookmarkGroup:
            return true
        case .pinned, .recent:
            return false
        }
    }

    private func buildBookmarkTree(for entries: [SidebarViewModel.SidebarEntry]) -> [BookmarkTreeNode] {
        guard !entries.isEmpty else {
            return []
        }

        let normalizedPaths = entries.map { normalizePath($0.path) }
        let shortcutSequences = entries.map(shortcutSequenceTokens(for:))
        var parentIndexByChildIndex: [Int: Int] = [:]

        for childIndex in entries.indices {
            let childPath = normalizedPaths[childIndex]
            let childShortcut = shortcutSequences[childIndex]
            var bestParentIndex: Int?
            var bestParentPathLength: Int = -1
            var bestParentShortcutDepth: Int = -1

            for candidateIndex in entries.indices where candidateIndex != childIndex {
                let candidatePath = normalizedPaths[candidateIndex]
                let candidateShortcut = shortcutSequences[candidateIndex]
                guard isDescendantPath(childPath, of: candidatePath) else {
                    continue
                }
                guard isShortcutDescendant(childShortcut, of: candidateShortcut) else {
                    continue
                }

                if
                    candidateShortcut.count > bestParentShortcutDepth ||
                    (candidateShortcut.count == bestParentShortcutDepth && candidatePath.count > bestParentPathLength)
                {
                    bestParentIndex = candidateIndex
                    bestParentPathLength = candidatePath.count
                    bestParentShortcutDepth = candidateShortcut.count
                }
            }

            if let bestParentIndex {
                parentIndexByChildIndex[childIndex] = bestParentIndex
            }
        }

        var childIndicesByParentIndex: [Int: [Int]] = [:]
        for entryIndex in entries.indices {
            if let parentIndex = parentIndexByChildIndex[entryIndex] {
                childIndicesByParentIndex[parentIndex, default: []].append(entryIndex)
            }
        }

        func makeNode(entryIndex: Int) -> BookmarkTreeNode {
            let childIndices = childIndicesByParentIndex[entryIndex] ?? []
            let childNodes = childIndices.map { makeNode(entryIndex: $0) }
            return BookmarkTreeNode(entry: entries[entryIndex], children: childNodes)
        }

        return entries.indices
            .filter { parentIndexByChildIndex[$0] == nil }
            .map { makeNode(entryIndex: $0) }
    }

    private func shortcutSequenceTokens(for entry: SidebarViewModel.SidebarEntry) -> [String] {
        guard let shortcutHint = entry.shortcutHint else {
            return []
        }

        let trimmedHint = shortcutHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmedHint.first == "'" {
            body = String(trimmedHint.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = trimmedHint
        }

        return BookmarkShortcut.tokens(from: body)
    }

    private func isShortcutDescendant(_ child: [String], of parent: [String]) -> Bool {
        guard !parent.isEmpty, child.count > parent.count else {
            return false
        }
        return Array(child.prefix(parent.count)) == parent
    }

    private func normalizePath(_ rawPath: String) -> String {
        PathNormalizer.normalizeForComparison(UserPaths.resolveBookmarkPath(rawPath))
    }

    private func isDescendantPath(_ childPath: String, of parentPath: String) -> Bool {
        guard PathNormalizer.normalizeForComparison(childPath) != PathNormalizer.normalizeForComparison(parentPath) else {
            return false
        }
        return PathNormalizer.isSameOrDescendant(childPath, of: parentPath)
    }

    private func updateRecentSectionLayout() {
        let recentCount = recentSection?.items.count ?? 0
        let hasRecent = recentCount > 0
        setRecentSectionVisible(hasRecent)

        guard hasRecent else {
            return
        }

        recentHeaderLabel.stringValue = recentSection?.title ?? "History"

        let contentHeight = recentContentHeight(for: recentCount)
        let maxHeight = maximumRecentHeight()
        let targetHeight = min(contentHeight, maxHeight)
        recentScrollViewHeightConstraint.constant = targetHeight
        recentScrollView.hasVerticalScroller = contentHeight > maxHeight

        scrollToCurrentPosition()
    }

    private func scrollToCurrentPosition() {
        guard let items = recentSection?.items else {
            return
        }
        guard let currentIndex = items.firstIndex(where: { $0.isCurrentPosition }),
              recentOutlineView.numberOfRows > currentIndex else {
            return
        }
        let shouldAlignTop = items[currentIndex].isLatestPosition
        scrollRecentRow(currentIndex, alignTop: shouldAlignTop)
    }

    private func recentContentHeight(for rowCount: Int) -> CGFloat {
        guard rowCount > 0 else {
            return 0
        }
        let rowPitch = recentOutlineView.rowHeight + recentOutlineView.intercellSpacing.height
        return CGFloat(rowCount) * rowPitch
    }

    private func maximumRecentHeight() -> CGFloat {
        let rowPitch = recentOutlineView.rowHeight + recentOutlineView.intercellSpacing.height
        let maxByRows = rowPitch * maxRecentVisibleRows
        guard view.bounds.height > 0 else {
            return maxByRows
        }
        let maxBySidebarHeight = floor(view.bounds.height * maxRecentHeightRatio)
        return max(rowPitch, min(maxByRows, maxBySidebarHeight))
    }

    private func scrollRecentRow(_ row: Int, alignTop: Bool) {
        guard row >= 0 else {
            return
        }
        let rowRect = recentOutlineView.rect(ofRow: row)
        guard rowRect.height > 0 else {
            recentOutlineView.scrollRowToVisible(row)
            return
        }

        let clipView = recentScrollView.contentView
        let documentHeight = recentOutlineView.bounds.height
        let visibleHeight = clipView.bounds.height
        guard documentHeight > visibleHeight, visibleHeight > 0 else {
            recentOutlineView.scrollRowToVisible(row)
            return
        }

        let desiredOriginY = alignTop
            ? rowRect.minY
            : rowRect.midY - (visibleHeight / 2)
        let maxOriginY = max(0, documentHeight - visibleHeight)
        let clampedOriginY = min(max(0, desiredOriginY), maxOriginY)
        clipView.scroll(to: NSPoint(x: 0, y: clampedOriginY))
        recentScrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Actions

    @objc
    private func handleSingleClick(_ sender: Any?) {
        guard let sourceOutlineView = sender as? NSOutlineView else {
            return
        }

        let clickedRow = sourceOutlineView.clickedRow
        guard clickedRow >= 0 else {
            return
        }

        let item = sourceOutlineView.item(atRow: clickedRow)
        guard let entry = sidebarEntry(from: item) else {
            return
        }

        if sourceOutlineView === recentOutlineView, let position = entry.timelinePosition {
            if !entry.isCurrentPosition {
                onHistoryJumpRequested?(position)
            }
            return
        }

        if sourceOutlineView !== recentOutlineView,
           let section = regularSection(for: item, in: sourceOutlineView),
           section.kind == .pinned {
            let resolvedPath = UserPaths.resolveBookmarkPath(entry.path)
            let itemURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL
            let parentURL = itemURL.deletingLastPathComponent().standardizedFileURL
            guard FileManager.default.fileExists(atPath: itemURL.path) else {
                onNavigationFailed?("Path not found:\n\(resolvedPath)")
                return
            }
            onNavigateAndRevealRequested?(parentURL, itemURL)
            return
        }

        guard let url = viewModel.urlForEntry(entry) else {
            let resolvedPath = UserPaths.resolveBookmarkPath(entry.path)
            onNavigationFailed?("Path not found:\n\(resolvedPath)")
            return
        }

        onNavigateRequested?(url)
    }

    func sidebarEntry(from item: Any?) -> SidebarViewModel.SidebarEntry? {
        if let entry = item as? SidebarViewModel.SidebarEntry {
            return entry
        }

        if let node = item as? BookmarkTreeNode {
            return node.entry
        }

        return nil
    }

    func regularSection(for item: Any?, in outlineView: NSOutlineView) -> SidebarViewModel.SidebarSection? {
        guard let item, let sectionTitle = sectionTitle(for: item, in: outlineView) else {
            return nil
        }
        return regularSections.first(where: { $0.title == sectionTitle })
    }

    private func sectionTitle(for item: Any, in outlineView: NSOutlineView) -> String? {
        var currentItem: Any? = item

        while let unwrappedItem = currentItem {
            if let sectionTitle = unwrappedItem as? String {
                return sectionTitle
            }
            currentItem = outlineView.parent(forItem: unwrappedItem)
        }

        return nil
    }
}
