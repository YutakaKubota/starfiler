import AppKit
import AVFoundation
import ImageIO

private final class CenteredSearchFieldCell: NSSearchFieldCell {
    // Keep search text and placeholder vertically centered in compact header height.
    private func verticallyCenteredRect(_ rect: NSRect) -> NSRect {
        let activeFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        let textHeight = ceil(activeFont.ascender - activeFont.descender)
        guard rect.height > textHeight else {
            return rect
        }

        var centeredRect = rect
        centeredRect.origin.y = rect.origin.y + floor((rect.height - textHeight) / 2)
        centeredRect.size.height = textHeight
        return centeredRect
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(super.searchTextRect(forBounds: rect))
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(super.drawingRect(forBounds: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(super.titleRect(forBounds: rect))
    }

    override func select(
        withFrame frame: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate anObject: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: searchTextRect(forBounds: frame),
            in: controlView,
            editor: textObj,
            delegate: anObject,
            start: selStart,
            length: selLength
        )
    }

    override func edit(
        withFrame frame: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate anObject: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: searchTextRect(forBounds: frame),
            in: controlView,
            editor: textObj,
            delegate: anObject,
            event: event
        )
    }
}

private final class ShortcutGuidePopupView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let columnsStackView = NSStackView()
    private var columnLabels: [NSTextField] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func update(title: String, subtitle: String, columns: [[String]]) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty

        for label in columnLabels {
            columnsStackView.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        columnLabels.removeAll(keepingCapacity: true)

        for column in columns where !column.isEmpty {
            let label = NSTextField(labelWithString: column.joined(separator: "\n"))
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byClipping
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            columnsStackView.addArrangedSubview(label)
            columnLabels.append(label)
        }
    }

    func applyPalette(_ palette: FilerThemePalette, backgroundOpacity: CGFloat) {
        let alpha = min(max(0.55 + (backgroundOpacity * 0.2), 0.45), 0.85)
        layer?.backgroundColor = palette.windowBackgroundColor.withAlphaComponent(alpha).cgColor
        layer?.borderColor = palette.starAccentColor.withAlphaComponent(0.45).cgColor
        titleLabel.textColor = palette.primaryTextColor
        subtitleLabel.textColor = palette.secondaryTextColor
        for label in columnLabels {
            label.textColor = palette.primaryTextColor
        }
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.lineBreakMode = .byTruncatingTail

        columnsStackView.translatesAutoresizingMaskIntoConstraints = false
        columnsStackView.orientation = .horizontal
        columnsStackView.alignment = .top
        columnsStackView.distribution = .fillProportionally
        columnsStackView.spacing = 18

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(columnsStackView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            columnsStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            columnsStackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            columnsStackView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            columnsStackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
}

final class FilePaneViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout, NSMenuDelegate, KeyActionDelegate, MediaKeyActionDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    private static let pixelmatorProAppURL = URL(
        fileURLWithPath: "/Applications/Pixelmator Pro.app",
        isDirectory: true
    )

    private enum SearchMode: Int {
        case filter = 0
        case spotlight = 1

        var menuTitle: String {
            switch self {
            case .filter:
                return "Filter (Current Folder)"
            case .spotlight:
                return "Spotlight Search"
            }
        }

        var iconSymbolName: String {
            switch self {
            case .filter:
                return "line.3.horizontal.decrease.circle"
            case .spotlight:
                return "sparkle.magnifyingglass"
            }
        }

        var iconAccessibilityLabel: String {
            switch self {
            case .filter:
                return "Filter mode"
            case .spotlight:
                return "Spotlight mode"
            }
        }
    }

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let modified = NSUserInterfaceItemIdentifier("modified")
    }

    private enum Cell {
        static let name = NSUserInterfaceItemIdentifier("nameCell")
        static let text = NSUserInterfaceItemIdentifier("textCell")
    }

    private enum TreeDisclosureMetrics {
        static let leading = CGFloat(4)
        static let indentWidth = CGFloat(16)
        static let disclosureWidth = CGFloat(14)
    }

    private enum ContextMenuMetrics {
        static let staticHeaderItemCount = 2
        static let filterWidth = CGFloat(280)
        static let filterHeight = CGFloat(30)
        static let filterFieldInset = CGFloat(8)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let browserModeIconSize: CGFloat = 16
    private static let browserModeRowHeight: CGFloat = max(24, browserModeIconSize + 8)
    private static let browserNameColumnDefaultWidth: CGFloat = 440
    private static let browserSizeColumnDefaultWidth: CGFloat = 120
    private static let browserModifiedColumnDefaultWidth: CGFloat = 180
    private static let browserNameColumnMinimumWidth: CGFloat = 120
    private static let browserSizeColumnMinimumWidth: CGFloat = 52
    private static let browserModifiedColumnMinimumWidth: CGFloat = 84

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    private let viewModel: FilePaneViewModel
    private var keybindingManager = KeybindingManager()
    private let headerView = NSView()
    private let navigationStackView = NSStackView()
    private let breadcrumbContainerView = NSView()
    private let breadcrumbStackView = NSStackView()
    private let searchControlsStackView = NSStackView()
    private let filesModeButton = NSButton(title: "Files", target: nil, action: nil)
    private let mediaModeButton = NSButton(title: "Media", target: nil, action: nil)
    private let filesRecursiveButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let mediaRecursiveButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let mediaIconSizeSlider = NSSlider(value: 16, minValue: 12, maxValue: 40, target: nil, action: nil)
    private let mediaIconSizeValueLabel = NSTextField(labelWithString: "16 px")
    private let searchField = NSSearchField()
    private lazy var contextMenuFilterField: NSSearchField = makeContextMenuFilterField()
    private let scrollView = NSScrollView()
    private let bookmarkJumpOverlayView = BookmarkJumpOverlayView()
    private let shortcutGuidePopupView = ShortcutGuidePopupView()
    private let loadingOverlayView = NSVisualEffectView()
    private let loadingIndicator = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")
    private let tableView = FileTableView()
    private let mediaCollectionLayout = NSCollectionViewFlowLayout()
    private let mediaCollectionView = MediaCollectionView()
    private let fileDragSource = FileDragSource()

    private lazy var fileDropTarget = FileDropTarget(
        destinationDirectoryProvider: { [weak self] in
            self?.viewModel.paneState.currentDirectory ?? UserPaths.homeDirectoryURL
        },
        dropDestinationDirectoryProvider: { [weak self] draggingInfo in
            self?.dropDestinationDirectory(for: draggingInfo)
        }
    )

    private var isPaneActive = false
    private var isDropTargetHighlighted = false
    private var vimModeState = VimModeState()
    private var filerTheme: FilerTheme = .system
    private var backgroundOpacity: CGFloat = 1.0
    private var fileIconSize: CGFloat = 16
    private let iconCache = NSCache<NSString, NSImage>()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var thumbnailTasks: [NSString: Task<Void, Never>] = [:]
    private var currentSearchMode: SearchMode = .filter
    private var searchMenuModeItems: [SearchMode: NSMenuItem] = [:]
    private var searchMenuScopeItems: [SpotlightSearchScope: NSMenuItem] = [:]
    private weak var activeContextMenu: NSMenu?
    private var contextMenuFilterText = ""
    private var currentDisplayMode: PaneDisplayMode = .browser
    private var isLoadingOverlayVisible = false
    private var starEffectsEnabled = true
    private var animationEffectSettings = AnimationEffectSettings.allEnabled
    private var shortcutGuideEnabled = false
    private let disableAnimationsForUITest = ProcessInfo.processInfo.arguments.contains("--disable-animations")
    private weak var lastCursorRippleLayer: CALayer?
    private var isSearchFieldFocused = false
    private var pendingBreadcrumbDirectoryURL: URL?
    private var lastAppliedBreadcrumbDirectoryURL: URL?
    private var isBreadcrumbUpdateScheduled = false
    private var rangeSelectionAnchorIndex: Int?
    private var isMouseMultiSelectionActive = false
    private var isApplyingSelectionFromViewModel = false

    var onStatusChanged: ((String, Int, Int) -> Void)?
    var onSelectionChanged: ((FileItem?) -> Void)?
    var onDisplayedItemsChanged: (() -> Void)?
    var onStatusContextTextChanged: ((String?) -> Void)?
    var onTabPressed: (() -> Bool)?
    var onDidRequestActivate: (() -> Void)?
    var onFileOperationRequested: ((KeyAction) -> Bool)?
    var onBookmarkJump: ((String) -> Void)?
    var onDropOperationCompleted: ((NSDragOperation, Int) -> Void)?
    var onDropFileOperationRequested: ((FileOperation) async throws -> Void)? {
        didSet {
            fileDropTarget.performFileOperation = onDropFileOperationRequested
        }
    }
    var onSpotlightSearchScopeChanged: ((SpotlightSearchScope) -> Void)?
    var onFileIconSizeChanged: ((CGFloat) -> Void)?
    var onMarkdownPreviewRequested: (([URL]) -> Void)?
    var onDirectoryLoadFailed: ((URL, Error) -> Void)?

    init(viewModel: FilePaneViewModel) {
        self.viewModel = viewModel
        self.currentDisplayMode = viewModel.displayMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let containerView = AppearanceTrackingView()
        containerView.onAppearanceChanged = { [weak self] in
            self?.updateActiveAppearance()
        }
        containerView.setAccessibilityIdentifier("filePane.container")
        view = containerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if disableAnimationsForUITest {
            starEffectsEnabled = false
            animationEffectSettings = .allDisabled
        }
        configureContainerAppearance()
        configureTableView()
        configureCollectionView()
        configureLayout()
        configureSearchControls()
        configureDragAndDrop()
        configureContextMenu()
        bindViewModel()
        setActive(false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        adjustBrowserColumnWidthsIfNeeded()
    }

    deinit {
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
    }

    func focusTable() {
        restoreNormalModeIfNeededAfterSearch()
        isSearchFieldFocused = false
        if currentDisplayMode == .media {
            view.window?.makeFirstResponder(mediaCollectionView)
        } else {
            view.window?.makeFirstResponder(tableView)
        }
        updateSearchFieldAppearance()
    }

    func openSelectedItem() {
        openSelectedFile()
    }

    func setActive(_ active: Bool) {
        let wasInactive = !isPaneActive
        isPaneActive = active
        updateActiveAppearance()

        if active && wasInactive && starEffectsEnabled && animationEffectSettings.activePanePulse {
            let palette = filerTheme.palette
            let glowLayer = CALayer()
            glowLayer.frame = headerView.bounds
            glowLayer.backgroundColor = palette.starGlowColor.withAlphaComponent(0.3).cgColor
            headerView.layer?.addSublayer(glowLayer)

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1.0
            fadeOut.toValue = 0.0
            fadeOut.duration = 0.25
            fadeOut.isRemovedOnCompletion = false
            fadeOut.fillMode = .forwards
            fadeOut.delegate = StarSparkleAnimator.makeRemovalDelegate(for: glowLayer)
            glowLayer.add(fadeOut, forKey: "activePulse")
        }
    }

    func updateBookmarksConfig(_ config: BookmarksConfig) {
        let handleJump: (String) -> Void = { [weak self] path in
            self?.hideBookmarkJumpHint()
            self?.onBookmarkJump?(path)
        }
        let handlePending: (BookmarkJumpHint) -> Void = { [weak self] hint in
            self?.showBookmarkJumpHint(hint)
        }
        let handleEnded: () -> Void = { [weak self] in
            self?.hideBookmarkJumpHint()
        }

        tableView.setBookmarkJumpConfig(config)
        tableView.onBookmarkJump = handleJump
        tableView.onBookmarkJumpPending = handlePending
        tableView.onBookmarkJumpEnded = handleEnded

        mediaCollectionView.setBookmarkJumpConfig(config)
        mediaCollectionView.onBookmarkJump = handleJump
        mediaCollectionView.onBookmarkJumpPending = handlePending
        mediaCollectionView.onBookmarkJumpEnded = handleEnded
    }

    func reloadKeybindings() {
        keybindingManager = KeybindingManager()
        tableView.reloadKeybindings()
        mediaCollectionView.reloadKeybindings()
        hideShortcutGuide()
    }

    func setStarEffectsEnabled(_ enabled: Bool) {
        starEffectsEnabled = disableAnimationsForUITest ? false : enabled
        tableView.reloadData()
        mediaCollectionView.reloadData()
        updateActiveAppearance()
    }

    func setAnimationEffectSettings(_ settings: AnimationEffectSettings) {
        animationEffectSettings = disableAnimationsForUITest ? .allDisabled : settings
    }

    func setShortcutGuideEnabled(_ enabled: Bool) {
        shortcutGuideEnabled = enabled
        guard isViewLoaded else {
            return
        }

        tableView.shortcutGuideEnabled = enabled
        mediaCollectionView.shortcutGuideEnabled = enabled
        if !enabled {
            hideShortcutGuide()
        }
    }

    func setSpotlightSearchScope(_ scope: SpotlightSearchScope) {
        viewModel.setSpotlightSearchScope(scope)
        guard isViewLoaded else {
            return
        }
        updateSearchMenuSelectionStates()

        let trimmed = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedSearchMode == .spotlight, !trimmed.isEmpty {
            applySearchFromHeader()
        }
    }

    private func showBookmarkJumpHint(_ hint: BookmarkJumpHint) {
        hideShortcutGuide()
        bookmarkJumpOverlayView.update(with: hint)
        bookmarkJumpOverlayView.isHidden = false

        if starEffectsEnabled, animationEffectSettings.bookmarkJumpAnimation {
            bookmarkJumpOverlayView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.bookmarkJumpOverlayView.animator().alphaValue = 1
            }
            if let layer = bookmarkJumpOverlayView.layer {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.92
                scale.toValue = 1.0
                scale.duration = 0.12
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(scale, forKey: "scaleIn")
            }
        }

        onStatusChanged?(hint.statusText, viewModel.directoryContents.displayedItems.count, viewModel.markedCount)
    }

    private func hideBookmarkJumpHint() {
        if starEffectsEnabled, animationEffectSettings.bookmarkJumpAnimation, !bookmarkJumpOverlayView.isHidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                self.bookmarkJumpOverlayView.animator().alphaValue = 0
            }, completionHandler: {
                self.bookmarkJumpOverlayView.isHidden = true
                self.bookmarkJumpOverlayView.alphaValue = 1
            })
        } else {
            bookmarkJumpOverlayView.isHidden = true
        }
    }

    private func showShortcutGuide(
        candidates: [KeybindingHintCandidate],
        typedSequence: [KeyEvent],
        initialModifiers: KeyModifiers
    ) {
        guard shortcutGuideEnabled, !candidates.isEmpty else {
            hideShortcutGuide()
            return
        }

        let rows = candidates.map { candidate -> String in
            let remaining = remainingSequence(of: candidate.sequence, after: typedSequence)
            let sequenceToRender = remaining.isEmpty ? candidate.sequence : remaining
            let renderedSequence = renderShortcutSequence(sequenceToRender)
            return "\(renderedSequence)  \(candidate.action.displayName)"
        }

        let columns = makeShortcutGuideColumns(rows, maximumRowsPerColumn: 18)

        let subtitle: String
        if typedSequence.isEmpty, !initialModifiers.isEmpty {
            subtitle = "Modifier: \(renderModifierSymbols(initialModifiers))"
        } else if !typedSequence.isEmpty {
            subtitle = "Input: \(renderShortcutSequence(typedSequence))"
        } else {
            subtitle = ""
        }

        let title = candidates.count == 1 ? "Shortcut Candidate" : "Shortcut Candidates (\(candidates.count))"
        shortcutGuidePopupView.update(title: title, subtitle: subtitle, columns: columns)
        shortcutGuidePopupView.isHidden = false
    }

    private func hideShortcutGuide() {
        guard !shortcutGuidePopupView.isHidden else {
            return
        }
        shortcutGuidePopupView.isHidden = true
    }

    private func updateLoadingOverlay(with context: FilePaneViewModel.LoadingContext?) {
        guard let context else {
            guard isLoadingOverlayVisible else {
                return
            }
            isLoadingOverlayVisible = false
            loadingIndicator.stopAnimation(nil)
            loadingOverlayView.isHidden = true
            loadingOverlayView.alphaValue = 0
            return
        }

        loadingLabel.stringValue = context.statusText
        loadingOverlayView.toolTip = context.directory.path
        if !isLoadingOverlayVisible {
            isLoadingOverlayVisible = true
            loadingOverlayView.isHidden = false
            loadingOverlayView.alphaValue = 1
            loadingIndicator.startAnimation(nil)
        }
    }

    private func remainingSequence(of sequence: [KeyEvent], after prefix: [KeyEvent]) -> [KeyEvent] {
        guard !prefix.isEmpty, sequence.count >= prefix.count else {
            return sequence
        }

        for (index, event) in prefix.enumerated() where sequence[index] != event {
            return sequence
        }

        return Array(sequence.dropFirst(prefix.count))
    }

    private func renderShortcutSequence(_ sequence: [KeyEvent]) -> String {
        sequence.map(renderShortcutToken).joined(separator: " ")
    }

    private func renderShortcutToken(_ event: KeyEvent) -> String {
        let modifierSymbols = renderModifierSymbols(event.modifiers)
        return modifierSymbols + renderKeySymbol(event.key)
    }

    private func renderModifierSymbols(_ modifiers: KeyModifiers) -> String {
        var symbols = ""
        if modifiers.contains(.control) {
            symbols += "\u{2303}"
        }
        if modifiers.contains(.option) {
            symbols += "\u{2325}"
        }
        if modifiers.contains(.shift) {
            symbols += "\u{21E7}"
        }
        if modifiers.contains(.command) {
            symbols += "\u{2318}"
        }
        return symbols
    }

    private func renderKeySymbol(_ key: String) -> String {
        switch key {
        case "Return":
            return "\u{21A9}"
        case "Tab":
            return "\u{21E5}"
        case "Space":
            return "\u{2420}"
        case "Escape":
            return "\u{238B}"
        case "Backspace":
            return "\u{232B}"
        case "Delete":
            return "\u{2326}"
        case "PageUp":
            return "\u{21DE}"
        case "PageDown":
            return "\u{21DF}"
        case "Home":
            return "\u{2196}"
        case "End":
            return "\u{2198}"
        case "ArrowLeft":
            return "\u{2190}"
        case "ArrowRight":
            return "\u{2192}"
        case "ArrowUp":
            return "\u{2191}"
        case "ArrowDown":
            return "\u{2193}"
        default:
            if key.count == 1 {
                return key.uppercased()
            }
            return key
        }
    }

    private func makeShortcutGuideColumns(_ rows: [String], maximumRowsPerColumn: Int) -> [[String]] {
        guard !rows.isEmpty else {
            return []
        }

        let rowLimit = max(1, maximumRowsPerColumn)
        let columnCount = max(1, Int(ceil(Double(rows.count) / Double(rowLimit))))
        let rowsPerColumn = max(1, Int(ceil(Double(rows.count) / Double(columnCount))))

        var columns: [[String]] = []
        columns.reserveCapacity(columnCount)

        var currentIndex = 0
        while currentIndex < rows.count {
            let end = min(currentIndex + rowsPerColumn, rows.count)
            columns.append(Array(rows[currentIndex ..< end]))
            currentIndex = end
        }

        return columns
    }

    func applyTheme(_ theme: FilerTheme, backgroundOpacity: CGFloat = 1.0) {
        filerTheme = theme
        self.backgroundOpacity = backgroundOpacity
        tableView.reloadData()
        mediaCollectionView.reloadData()
        updateActiveAppearance()
    }

    func setFileIconSize(_ size: CGFloat) {
        let clampedSize = min(max(size, 12), 40)
        guard abs(fileIconSize - clampedSize) > 0.001 else {
            return
        }

        fileIconSize = clampedSize
        mediaIconSizeSlider.doubleValue = Double(clampedSize)
        mediaIconSizeValueLabel.stringValue = "\(Int(clampedSize.rounded())) px"
        iconCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        tableView.rowHeight = Self.browserModeRowHeight
        if currentDisplayMode == .media {
            mediaCollectionLayout.invalidateLayout()
            mediaCollectionView.reloadData()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.directoryContents.displayedItems.count
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        let urls = dragURLsForTableView(rowIndexes: rowIndexes)
            .map(\.standardizedFileURL)
        guard !urls.isEmpty else {
            return false
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects(urls as [NSURL])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard viewModel.directoryContents.displayedItems.indices.contains(row) else {
            return nil
        }

        let item = viewModel.directoryContents.displayedItems[row]

        switch tableColumn?.identifier {
        case Column.name:
            let treeItem = viewModel.directoryContents.displayedTreeItems.indices.contains(row)
                ? viewModel.directoryContents.displayedTreeItems[row]
                : nil
            return makeNameCell(for: item, row: row, treeItem: treeItem)
        case Column.size:
            return makeTextCell(text: sizeText(for: item), alignment: .right)
        case Column.modified:
            return makeTextCell(text: modifiedText(for: item), alignment: .left)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let palette = filerTheme.palette
        let rowView = MarkedRowView()
        rowView.isMarkedRow = row == viewModel.paneState.cursorIndex
        rowView.isVisualMode = vimModeState.mode == .visual
        rowView.markedColor = palette.markedColor
        rowView.visualMarkedColor = palette.visualMarkedColor
        return rowView
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard viewModel.directoryContents.displayedItems.indices.contains(row) else {
            return nil
        }
        return viewModel.directoryContents.displayedItems[row].name
    }

    func tableView(
        _ tableView: NSTableView,
        nextTypeSelectMatchFromRow startRow: Int,
        toRow endRow: Int,
        for searchString: String
    ) -> Int {
        let normalizedSearch = searchString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSearch.isEmpty else {
            return -1
        }

        for (index, item) in viewModel.directoryContents.displayedItems.enumerated() {
            let matchedRange = item.name.range(
                of: normalizedSearch,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: .current
            )
            if matchedRange != nil {
                return index
            }
        }

        return -1
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelectionFromViewModel else {
            return
        }

        let selectedRow = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard selectedRow >= 0 else {
            return
        }

        isMouseMultiSelectionActive = false
        viewModel.clearMarks()
        rangeSelectionAnchorIndex = selectedRow
        viewModel.setCursor(index: selectedRow)
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let targetSortColumn: DirectoryContents.SortDescriptor.Column
        switch tableColumn.identifier {
        case Column.name:
            targetSortColumn = .name
        case Column.size:
            targetSortColumn = .size
        case Column.modified:
            targetSortColumn = .date
        default:
            return
        }

        let currentSortDescriptor = viewModel.directoryContents.sortDescriptor
        let nextAscending: Bool
        if currentSortDescriptor.column == targetSortColumn {
            nextAscending = !currentSortDescriptor.ascending
        } else {
            nextAscending = true
        }

        if starEffectsEnabled, animationEffectSettings.sortRowAnimation {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.layer?.add(transition, forKey: "sortTransition")
        }

        viewModel.setSortDescriptor(.init(column: targetSortColumn, ascending: nextAscending))
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewModel.directoryContents.displayedItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: MediaCollectionItem.identifier, for: indexPath)
        guard
            let mediaItem = item as? MediaCollectionItem,
            viewModel.directoryContents.displayedItems.indices.contains(indexPath.item)
        else {
            return item
        }

        let fileItem = viewModel.directoryContents.displayedItems[indexPath.item]
        let isMarked = indexPath.item == viewModel.paneState.cursorIndex
        mediaItem.configure(
            name: fileItem.name,
            thumbnail: icon(for: fileItem, row: indexPath.item),
            isMarked: isMarked,
            isVideo: fileItem.url.isVideoFile,
            palette: filerTheme.palette
        )
        return mediaItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingSelectionFromViewModel else {
            return
        }

        guard let indexPath = indexPaths.first else {
            return
        }

        isMouseMultiSelectionActive = false
        viewModel.clearMarks()
        rangeSelectionAnchorIndex = indexPath.item
        viewModel.setCursor(index: indexPath.item)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
        return
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let insets = mediaCollectionLayout.sectionInset
        let interitemSpacing = mediaCollectionLayout.minimumInteritemSpacing
        let availableWidth = max(120, collectionView.bounds.width - insets.left - insets.right)
        let targetWidth = preferredMediaTileWidth()
        let columns = max(Int((availableWidth + interitemSpacing) / (targetWidth + interitemSpacing)), 1)
        let totalSpacing = CGFloat(max(columns - 1, 0)) * interitemSpacing
        let width = floor((availableWidth - totalSpacing) / CGFloat(columns))
        return NSSize(width: width, height: width * 0.78 + 34)
    }

    func fileTableView(_ tableView: FileTableView, didTrigger action: KeyAction) -> Bool {
        handleKeyAction(action)
    }

    func mediaCollectionView(_ collectionView: MediaCollectionView, didTrigger action: KeyAction) -> Bool {
        handleKeyAction(action)
    }

    private func configureContainerAppearance() {
        view.wantsLayer = true

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true

        navigationStackView.translatesAutoresizingMaskIntoConstraints = false
        navigationStackView.orientation = .horizontal
        navigationStackView.alignment = .centerY
        navigationStackView.spacing = 3
        navigationStackView.distribution = .fill

        breadcrumbContainerView.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbContainerView.wantsLayer = false
        breadcrumbContainerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbContainerView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        breadcrumbStackView.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbStackView.orientation = .horizontal
        breadcrumbStackView.alignment = .centerY
        breadcrumbStackView.spacing = 5
        breadcrumbStackView.distribution = .fillProportionally

        searchControlsStackView.translatesAutoresizingMaskIntoConstraints = false
        searchControlsStackView.orientation = .horizontal
        searchControlsStackView.alignment = .centerY
        searchControlsStackView.spacing = 0
        searchControlsStackView.setContentHuggingPriority(.required, for: .horizontal)
        searchControlsStackView.setContentCompressionResistancePriority(.required, for: .horizontal)

        filesModeButton.translatesAutoresizingMaskIntoConstraints = false
        filesModeButton.isBordered = false
        filesModeButton.wantsLayer = true
        filesModeButton.font = .systemFont(ofSize: 11, weight: .medium)
        filesModeButton.alignment = .center
        filesModeButton.target = self
        filesModeButton.action = #selector(handleDisplayModeChanged(_:))
        filesModeButton.tag = 0
        filesModeButton.setContentHuggingPriority(.required, for: .horizontal)
        filesModeButton.layer?.borderWidth = 0.5
        filesModeButton.layer?.borderColor = NSColor.separatorColor.cgColor

        mediaModeButton.translatesAutoresizingMaskIntoConstraints = false
        mediaModeButton.isBordered = false
        mediaModeButton.wantsLayer = true
        mediaModeButton.font = .systemFont(ofSize: 11, weight: .medium)
        mediaModeButton.alignment = .center
        mediaModeButton.target = self
        mediaModeButton.action = #selector(handleDisplayModeChanged(_:))
        mediaModeButton.tag = 1
        mediaModeButton.setContentHuggingPriority(.required, for: .horizontal)
        mediaModeButton.layer?.borderWidth = 0.5
        mediaModeButton.layer?.borderColor = NSColor.separatorColor.cgColor

        filesRecursiveButton.translatesAutoresizingMaskIntoConstraints = false
        filesRecursiveButton.target = self
        filesRecursiveButton.action = #selector(handleFilesRecursiveToggle(_:))
        filesRecursiveButton.isHidden = true
        filesRecursiveButton.toolTip = "Recursive"
        filesRecursiveButton.setContentHuggingPriority(.required, for: .horizontal)

        mediaRecursiveButton.translatesAutoresizingMaskIntoConstraints = false
        mediaRecursiveButton.target = self
        mediaRecursiveButton.action = #selector(handleMediaRecursiveToggle(_:))
        mediaRecursiveButton.isHidden = true
        mediaRecursiveButton.toolTip = "Recursive"
        mediaRecursiveButton.setContentHuggingPriority(.required, for: .horizontal)

        mediaIconSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        mediaIconSizeSlider.target = self
        mediaIconSizeSlider.action = #selector(handleMediaIconSizeChanged(_:))
        mediaIconSizeSlider.doubleValue = Double(fileIconSize)
        mediaIconSizeSlider.controlSize = .small
        mediaIconSizeSlider.isContinuous = true
        mediaIconSizeSlider.isHidden = true

        mediaIconSizeValueLabel.translatesAutoresizingMaskIntoConstraints = false
        mediaIconSizeValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        mediaIconSizeValueLabel.textColor = .secondaryLabelColor
        mediaIconSizeValueLabel.alignment = .right
        mediaIconSizeValueLabel.stringValue = "\(Int(fileIconSize.rounded())) px"
        mediaIconSizeValueLabel.isHidden = true
        mediaIconSizeValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        mediaIconSizeValueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        if !(searchField.cell is CenteredSearchFieldCell) {
            searchField.cell = CenteredSearchFieldCell(textCell: "")
        }
        // Re-enable text editing after replacing the default search cell.
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.controlSize = .small
        searchField.isBezeled = false
        searchField.drawsBackground = true
        searchField.focusRingType = .none
        searchField.wantsLayer = true
        searchField.layer?.borderWidth = 0.5
        searchField.layer?.borderColor = NSColor.separatorColor.cgColor
        searchField.placeholderString = nil
        searchField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = true
        searchField.setAccessibilityIdentifier("filePane.searchField")
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureSearchFieldMenuTemplate()
        configureSearchFieldButtonAction()

        bookmarkJumpOverlayView.isHidden = true
        shortcutGuidePopupView.isHidden = true

        loadingOverlayView.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlayView.material = .hudWindow
        loadingOverlayView.blendingMode = .withinWindow
        loadingOverlayView.state = .active
        loadingOverlayView.wantsLayer = true
        loadingOverlayView.layer?.cornerRadius = 10
        loadingOverlayView.layer?.borderWidth = 1
        loadingOverlayView.isHidden = true
        loadingOverlayView.alphaValue = 0

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isDisplayedWhenStopped = false

        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        loadingLabel.alignment = .left
        loadingLabel.maximumNumberOfLines = 1
        loadingLabel.lineBreakMode = .byTruncatingTail

        loadingOverlayView.addSubview(loadingIndicator)
        loadingOverlayView.addSubview(loadingLabel)
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.setAccessibilityIdentifier("filePane.tableView")
        tableView.headerView = NSTableHeaderView()
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.keyActionDelegate = self
        tableView.setVimMode(vimModeState.mode)
        tableView.shortcutGuideEnabled = shortcutGuideEnabled
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))
        tableView.shouldHandleMouseDown = { [weak self] event, point in
            self?.handleTreeDisclosureMouseDown(event: event, at: point) ?? false
        }
        tableView.onShortcutGuideUpdated = { [weak self] candidates, typedSequence, modifiers in
            self?.showShortcutGuide(candidates: candidates, typedSequence: typedSequence, initialModifiers: modifiers)
        }
        tableView.onShortcutGuideEnded = { [weak self] in
            self?.hideShortcutGuide()
        }
        tableView.backgroundColor = filerTheme.palette.tableBackgroundColor
        tableView.rowHeight = Self.browserModeRowHeight

        let nameColumn = NSTableColumn(identifier: Column.name)
        nameColumn.title = "Name"
        nameColumn.width = Self.browserNameColumnDefaultWidth
        nameColumn.minWidth = Self.browserNameColumnMinimumWidth

        let sizeColumn = NSTableColumn(identifier: Column.size)
        sizeColumn.title = "Size"
        sizeColumn.width = Self.browserSizeColumnDefaultWidth
        sizeColumn.minWidth = Self.browserSizeColumnMinimumWidth

        let modifiedColumn = NSTableColumn(identifier: Column.modified)
        modifiedColumn.title = "Modified"
        modifiedColumn.width = Self.browserModifiedColumnDefaultWidth
        modifiedColumn.minWidth = Self.browserModifiedColumnMinimumWidth

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(modifiedColumn)
        updateColumnHeaderTitles()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        tableView.didBecomeFirstResponderHandler = { [weak self] in
            self?.restoreNormalModeIfNeededAfterSearch()
            self?.isSearchFieldFocused = false
            self?.updateSearchFieldAppearance()
            self?.onDidRequestActivate?()
        }
    }

    private func adjustBrowserColumnWidthsIfNeeded() {
        guard currentDisplayMode == .browser else {
            return
        }

        let availableWidth = scrollView.contentView.bounds.width
        guard availableWidth > 0 else {
            return
        }

        let targetWidths = Self.browserColumnWidths(
            availableWidth: availableWidth,
            intercellSpacing: tableView.intercellSpacing.width
        )

        applyColumnWidth(targetWidths.name, identifier: Column.name)
        applyColumnWidth(targetWidths.size, identifier: Column.size)
        applyColumnWidth(targetWidths.modified, identifier: Column.modified)
    }

    private func applyColumnWidth(_ width: CGFloat, identifier: NSUserInterfaceItemIdentifier) {
        guard let column = tableView.tableColumns.first(where: { $0.identifier == identifier }) else {
            return
        }

        let clampedWidth = max(width, 1)
        guard abs(column.width - clampedWidth) >= 1 else {
            return
        }

        column.width = clampedWidth
    }

    static func browserColumnWidths(
        availableWidth: CGFloat,
        intercellSpacing: CGFloat
    ) -> (name: CGFloat, size: CGFloat, modified: CGFloat) {
        let columnCount = CGFloat(3)
        let totalSpacing = intercellSpacing * (columnCount - 1)
        let availableColumnsWidth = max(availableWidth - totalSpacing, 0)

        var nameWidth = browserNameColumnDefaultWidth
        var sizeWidth = browserSizeColumnDefaultWidth
        var modifiedWidth = browserModifiedColumnDefaultWidth
        let desiredTotalWidth = nameWidth + sizeWidth + modifiedWidth

        if availableColumnsWidth >= desiredTotalWidth {
            nameWidth += availableColumnsWidth - desiredTotalWidth
            return (nameWidth, sizeWidth, modifiedWidth)
        }

        var overflow = desiredTotalWidth - availableColumnsWidth

        let modifiedReduction = min(overflow, modifiedWidth - browserModifiedColumnMinimumWidth)
        modifiedWidth -= modifiedReduction
        overflow -= modifiedReduction

        let sizeReduction = min(overflow, sizeWidth - browserSizeColumnMinimumWidth)
        sizeWidth -= sizeReduction
        overflow -= sizeReduction

        let nameReduction = min(overflow, nameWidth - browserNameColumnMinimumWidth)
        nameWidth -= nameReduction
        overflow -= nameReduction

        if overflow > 0 {
            let scale = availableColumnsWidth / max(nameWidth + sizeWidth + modifiedWidth, 1)
            nameWidth = floor(nameWidth * scale)
            sizeWidth = floor(sizeWidth * scale)
            modifiedWidth = max(availableColumnsWidth - nameWidth - sizeWidth, 1)
        }

        return (nameWidth, sizeWidth, modifiedWidth)
    }

    private func configureCollectionView() {
        mediaCollectionLayout.minimumInteritemSpacing = 0
        mediaCollectionLayout.minimumLineSpacing = 0
        mediaCollectionLayout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        mediaCollectionView.translatesAutoresizingMaskIntoConstraints = false
        mediaCollectionView.collectionViewLayout = mediaCollectionLayout
        mediaCollectionView.delegate = self
        mediaCollectionView.dataSource = self
        mediaCollectionView.setAccessibilityIdentifier("filePane.mediaCollectionView")
        mediaCollectionView.isSelectable = true
        mediaCollectionView.allowsMultipleSelection = true
        mediaCollectionView.backgroundColors = [filerTheme.palette.tableBackgroundColor]
        mediaCollectionView.register(MediaCollectionItem.self, forItemWithIdentifier: MediaCollectionItem.identifier)
        mediaCollectionView.keyActionDelegate = self
        mediaCollectionView.setVimMode(vimModeState.mode)
        mediaCollectionView.shortcutGuideEnabled = shortcutGuideEnabled
        mediaCollectionView.onShortcutGuideUpdated = { [weak self] candidates, typedSequence, modifiers in
            self?.showShortcutGuide(candidates: candidates, typedSequence: typedSequence, initialModifiers: modifiers)
        }
        mediaCollectionView.onShortcutGuideEnded = { [weak self] in
            self?.hideShortcutGuide()
        }
        mediaCollectionView.didBecomeFirstResponderHandler = { [weak self] in
            self?.restoreNormalModeIfNeededAfterSearch()
            self?.isSearchFieldFocused = false
            self?.updateSearchFieldAppearance()
            self?.onDidRequestActivate?()
        }

        let doubleClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleMediaDoubleClick(_:)))
        doubleClickGesture.numberOfClicksRequired = 2
        doubleClickGesture.delaysPrimaryMouseButtonEvents = false
        mediaCollectionView.addGestureRecognizer(doubleClickGesture)
    }

    private func configureLayout() {
        view.addSubview(headerView)
        view.addSubview(scrollView)
        view.addSubview(bookmarkJumpOverlayView)
        view.addSubview(shortcutGuidePopupView)
        view.addSubview(loadingOverlayView)
        scrollView.setAccessibilityIdentifier("filePane.scrollView")

        navigationStackView.addArrangedSubview(breadcrumbContainerView)
        breadcrumbContainerView.addSubview(breadcrumbStackView)

        headerView.addSubview(navigationStackView)
        headerView.addSubview(searchControlsStackView)
        searchControlsStackView.addArrangedSubview(filesModeButton)
        searchControlsStackView.addArrangedSubview(mediaModeButton)
        searchControlsStackView.addArrangedSubview(filesRecursiveButton)
        searchControlsStackView.addArrangedSubview(mediaRecursiveButton)
        searchControlsStackView.addArrangedSubview(mediaIconSizeSlider)
        searchControlsStackView.addArrangedSubview(mediaIconSizeValueLabel)
        searchControlsStackView.addArrangedSubview(searchField)
        searchControlsStackView.setCustomSpacing(8, after: mediaModeButton)
        searchControlsStackView.setCustomSpacing(8, after: filesRecursiveButton)
        searchControlsStackView.setCustomSpacing(8, after: mediaRecursiveButton)
        searchControlsStackView.setCustomSpacing(4, after: mediaIconSizeSlider)
        searchControlsStackView.setCustomSpacing(12, after: mediaIconSizeValueLabel)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 28),

            navigationStackView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 8),
            navigationStackView.trailingAnchor.constraint(lessThanOrEqualTo: searchControlsStackView.leadingAnchor, constant: -12),
            navigationStackView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            searchControlsStackView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            searchControlsStackView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            searchControlsStackView.leadingAnchor.constraint(greaterThanOrEqualTo: headerView.leadingAnchor, constant: 280),
            breadcrumbContainerView.topAnchor.constraint(equalTo: headerView.topAnchor),
            breadcrumbContainerView.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            filesModeButton.heightAnchor.constraint(equalToConstant: 22),
            filesModeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
            mediaModeButton.heightAnchor.constraint(equalToConstant: 22),
            mediaModeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 50),
            searchField.heightAnchor.constraint(equalToConstant: 22),
            mediaIconSizeSlider.widthAnchor.constraint(equalToConstant: 110),
            mediaIconSizeValueLabel.widthAnchor.constraint(equalToConstant: 44),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            bookmarkJumpOverlayView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bookmarkJumpOverlayView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            bookmarkJumpOverlayView.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            bookmarkJumpOverlayView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),

            shortcutGuidePopupView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shortcutGuidePopupView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -8),
            shortcutGuidePopupView.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            shortcutGuidePopupView.widthAnchor.constraint(lessThanOrEqualToConstant: 980),
            shortcutGuidePopupView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            shortcutGuidePopupView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),

            loadingOverlayView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingOverlayView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            loadingOverlayView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            loadingOverlayView.widthAnchor.constraint(lessThanOrEqualToConstant: 380)
        ])

        NSLayoutConstraint.activate([
            breadcrumbStackView.leadingAnchor.constraint(equalTo: breadcrumbContainerView.leadingAnchor),
            breadcrumbStackView.trailingAnchor.constraint(lessThanOrEqualTo: breadcrumbContainerView.trailingAnchor),
            breadcrumbStackView.centerYAnchor.constraint(equalTo: breadcrumbContainerView.centerYAnchor),

            loadingIndicator.leadingAnchor.constraint(equalTo: loadingOverlayView.leadingAnchor, constant: 14),
            loadingIndicator.topAnchor.constraint(equalTo: loadingOverlayView.topAnchor, constant: 10),
            loadingIndicator.bottomAnchor.constraint(equalTo: loadingOverlayView.bottomAnchor, constant: -10),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 16),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 16),

            loadingLabel.leadingAnchor.constraint(equalTo: loadingIndicator.trailingAnchor, constant: 10),
            loadingLabel.trailingAnchor.constraint(equalTo: loadingOverlayView.trailingAnchor, constant: -14),
            loadingLabel.centerYAnchor.constraint(equalTo: loadingIndicator.centerYAnchor)
        ])
    }

    private func configureSearchControls() {
        updateSearchModeUI()
        updateSearchMenuSelectionStates()
        updateDisplayModeControls()
    }

    private func applyDisplayMode(_ mode: PaneDisplayMode) {
        currentDisplayMode = mode
        hideShortcutGuide()
        updateDisplayModeControls()

        if mode == .media {
            scrollView.documentView = mediaCollectionView
            mediaCollectionView.reloadData()
        } else {
            scrollView.documentView = tableView
        }

        syncSelectionFromViewModel()
        focusTable()
    }

    private func updateDisplayModeControls() {
        let isMediaMode = currentDisplayMode == .media
        let selectedBg = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        let unselectedBg = CGColor.clear
        filesModeButton.layer?.backgroundColor = isMediaMode ? unselectedBg : selectedBg
        mediaModeButton.layer?.backgroundColor = isMediaMode ? selectedBg : unselectedBg
        filesModeButton.contentTintColor = isMediaMode ? .secondaryLabelColor : .labelColor
        mediaModeButton.contentTintColor = isMediaMode ? .labelColor : .secondaryLabelColor
        filesRecursiveButton.state = viewModel.filesRecursiveEnabled ? .on : .off
        filesRecursiveButton.isHidden = isMediaMode
        mediaRecursiveButton.state = viewModel.mediaRecursiveEnabled ? .on : .off
        mediaRecursiveButton.isHidden = !isMediaMode
        mediaIconSizeSlider.isHidden = !isMediaMode
        mediaIconSizeValueLabel.isHidden = !isMediaMode
    }

    private func configureContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        mediaCollectionView.menu = menu
    }

    private func configureDragAndDrop() {
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.dragSourceHandler = fileDragSource
        tableView.dragURLsProvider = { [weak self] in
            self?.dragURLsForTableView() ?? []
        }
        tableView.dropTargetHandler = fileDropTarget

        mediaCollectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        mediaCollectionView.setDraggingSourceOperationMask([.copy], forLocal: false)
        mediaCollectionView.dragSourceHandler = fileDragSource
        mediaCollectionView.dragURLsProvider = { [weak self] in
            self?.viewModel.markedOrSelectedURLs() ?? []
        }

        fileDropTarget.onHighlightChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            self.isDropTargetHighlighted = highlighted
            self.updateActiveAppearance()
            if highlighted {
                self.startDropPulse()
            } else {
                self.stopDropPulse()
            }
        }

        fileDropTarget.onDropCompleted = { [weak self] operation, itemCount in
            guard let self else { return }
            self.stopDropPulse()
            if self.starEffectsEnabled, self.animationEffectSettings.dropZonePulse, let layer = self.view.layer {
                let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
                StarSparkleAnimator.burst(count: 6, in: layer, at: center,
                    color: self.filerTheme.palette.starGlowColor, size: 8, duration: 0.4)
            }
            self.viewModel.refreshCurrentDirectory()
            self.onDropOperationCompleted?(operation, itemCount)
        }

        fileDropTarget.onDropFailed = { [weak self] message in
            self?.presentDropError(message)
        }
    }

    private func dragURLsForTableView(rowIndexes: IndexSet? = nil) -> [URL] {
        if let rowIndexes, !rowIndexes.isEmpty {
            let displayedItems = viewModel.directoryContents.displayedItems
            let rowURLs = rowIndexes.compactMap { row -> URL? in
                guard displayedItems.indices.contains(row) else {
                    return nil
                }
                return displayedItems[row].url
            }
            if !rowURLs.isEmpty {
                return rowURLs
            }
        }

        if !viewModel.paneState.markedIndices.isEmpty {
            return viewModel.markedOrSelectedURLs()
        }

        let displayedItems = viewModel.directoryContents.displayedItems
        let selectedURLs = tableView.selectedRowIndexes.compactMap { row -> URL? in
            guard displayedItems.indices.contains(row) else {
                return nil
            }
            return displayedItems[row].url
        }
        if !selectedURLs.isEmpty {
            return selectedURLs
        }

        let clickedRow = tableView.clickedRow
        if displayedItems.indices.contains(clickedRow) {
            return [displayedItems[clickedRow].url]
        }

        return viewModel.markedOrSelectedURLs()
    }

    private func dropDestinationDirectory(for draggingInfo: NSDraggingInfo) -> URL? {
        let row = dropDestinationRow(for: draggingInfo)
        guard viewModel.directoryContents.displayedItems.indices.contains(row) else {
            return nil
        }

        let item = viewModel.directoryContents.displayedItems[row]
        guard item.isDirectory, !item.isPackage else {
            return nil
        }

        return item.url.standardizedFileURL
    }

    private func dropDestinationRow(for draggingInfo: NSDraggingInfo) -> Int {
        let draggingPoint = draggingInfo.draggingLocation
        var candidatePoints: [NSPoint] = []

        // Most destinations receive draggingLocation in window coordinates.
        candidatePoints.append(tableView.convert(draggingPoint, from: nil))

        // Some environments can report screen coordinates.
        if let window = tableView.window {
            let windowPoint = window.convertPoint(fromScreen: draggingPoint)
            candidatePoints.append(tableView.convert(windowPoint, from: nil))
        }

        // Fallback for cases where draggingLocation is already local coordinates.
        candidatePoints.append(draggingPoint)

        for point in candidatePoints {
            let row = dropDestinationRow(at: point)
            if row >= 0 {
                return row
            }
        }

        return -1
    }

    private func dropDestinationRow(at point: NSPoint) -> Int {
        let directRow = tableView.row(at: point)
        if directRow >= 0 {
            return directRow
        }

        let probeRect = NSRect(
            x: tableView.bounds.minX,
            y: point.y,
            width: max(tableView.bounds.width, 1),
            height: 1
        )
        let intersectingRows = tableView.rows(in: probeRect)
        return intersectingRows.location == NSNotFound ? -1 : intersectingRows.location
    }

    private func bindViewModel() {
        viewModel.onItemsChanged = { [weak self] _ in
            guard let self else {
                return
            }

            self.thumbnailTasks.values.forEach { $0.cancel() }
            self.thumbnailTasks.removeAll()
            self.thumbnailCache.removeAllObjects()

            // Sync search field from filter text only while in filter mode.
            // In spotlight mode, keep the typed query visible.
            if self.selectedSearchMode == .filter {
                let modelFilter = self.viewModel.directoryContents.filterText
                if self.searchField.stringValue != modelFilter {
                    self.searchField.stringValue = modelFilter
                    if modelFilter.isEmpty {
                        self.searchField.layer?.removeAnimation(forKey: "searchGlow")
                        self.searchField.layer?.shadowOpacity = 0
                    }
                }
            }

            self.tableView.reloadData()
            self.mediaCollectionView.reloadData()
            self.updateColumnHeaderTitles()
            self.syncSelectionFromViewModel()
            self.publishStatus()
            self.publishSelection()
            self.onDisplayedItemsChanged?()
        }

        viewModel.onCursorChanged = { [weak self] _ in
            guard let self else { return }
            self.syncSelectionFromViewModel()
            self.publishSelection()

            if self.starEffectsEnabled, self.animationEffectSettings.cursorRipple, self.currentDisplayMode == .browser {
                self.animateCursorRipple(at: self.viewModel.paneState.cursorIndex)
            }
        }

        viewModel.onMarkedIndicesChanged = { [weak self] _ in
            guard let self else {
                return
            }

            self.tableView.reloadData()
            self.mediaCollectionView.reloadData()
            self.syncSelectionFromViewModel()
            self.publishStatus()
        }

        viewModel.onDisplayModeChanged = { [weak self] mode in
            self?.applyDisplayMode(mode)
            self?.publishStatus()
            self?.publishSelection()
        }

        viewModel.onFilesRecursiveChanged = { [weak self] _ in
            self?.updateDisplayModeControls()
            self?.publishSelection()
        }

        viewModel.onMediaRecursiveChanged = { [weak self] _ in
            self?.updateDisplayModeControls()
            self?.publishSelection()
        }

        viewModel.onDirectoryLoadFailed = { [weak self] directory, error in
            self?.onDirectoryLoadFailed?(directory, error)
        }

        viewModel.onLoadingStateChanged = { [weak self] context in
            self?.updateLoadingOverlay(with: context)
        }

        publishStatus()
        publishSelection()
        updateColumnHeaderTitles()
        applyDisplayMode(viewModel.displayMode)
    }

    private func restoreNormalModeIfNeededAfterSearch() {
        guard vimModeState.mode == .filter else {
            return
        }

        vimModeState.enterNormalMode()
        tableView.setVimMode(vimModeState.mode)
        mediaCollectionView.setVimMode(vimModeState.mode)
    }

    private func syncSelectionFromViewModel() {
        let row = viewModel.paneState.cursorIndex
        let rowCount = viewModel.directoryContents.displayedItems.count

        guard rowCount > 0 else {
            isMouseMultiSelectionActive = false
            tableView.deselectAll(nil)
            mediaCollectionView.deselectAll(nil)
            return
        }

        let clampedRow = min(max(row, 0), rowCount - 1)
        isApplyingSelectionFromViewModel = true
        defer {
            isApplyingSelectionFromViewModel = false
        }

        if currentDisplayMode == .media {
            let cursorIndexPath = IndexPath(item: clampedRow, section: 0)
            mediaCollectionView.selectionIndexPaths = [cursorIndexPath]
            if shouldAutoScrollMediaSelection() {
                mediaCollectionView.scrollToItems(at: [cursorIndexPath], scrollPosition: .centeredVertically)
            }
        } else {
            tableView.selectRowIndexes(IndexSet(integer: clampedRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(clampedRow)
        }
    }

    private func shouldAutoScrollMediaSelection() -> Bool {
        guard let event = NSApp.currentEvent else {
            return true
        }

        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return false
        default:
            return true
        }
    }

    private func publishStatus() {
        let directoryURL = viewModel.paneState.currentDirectory.standardizedFileURL
        scheduleBreadcrumbUpdate(for: directoryURL)
        onStatusChanged?(directoryURL.path, viewModel.directoryContents.displayedItems.count, viewModel.markedCount)
    }

    private func scheduleBreadcrumbUpdate(for directoryURL: URL) {
        pendingBreadcrumbDirectoryURL = directoryURL
        guard !isBreadcrumbUpdateScheduled else {
            return
        }

        isBreadcrumbUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingBreadcrumbUpdate()
        }
    }

    private func applyPendingBreadcrumbUpdate() {
        isBreadcrumbUpdateScheduled = false
        guard let directoryURL = pendingBreadcrumbDirectoryURL else {
            return
        }

        pendingBreadcrumbDirectoryURL = nil

        // Avoid tearing down and recreating arranged subviews when the path is unchanged.
        guard directoryURL != lastAppliedBreadcrumbDirectoryURL else {
            updateBreadcrumbAppearance()
            return
        }

        updateBreadcrumbs(for: directoryURL)
        lastAppliedBreadcrumbDirectoryURL = directoryURL
    }

    private func updateBreadcrumbs(for directoryURL: URL) {
        let pathComponents = directoryURL.pathComponents
        guard !pathComponents.isEmpty else {
            breadcrumbStackView.setViews([], in: .leading)
            return
        }

        var breadcrumbViews: [NSView] = []
        var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in pathComponents.enumerated() {
            let title: String
            let targetURL: URL
            if index == 0 {
                title = "/"
                targetURL = currentURL
            } else {
                currentURL.appendPathComponent(component, isDirectory: true)
                title = component
                targetURL = currentURL
            }

            let button = NSButton(title: title, target: self, action: #selector(handleBreadcrumbClick(_:)))
            button.isBordered = false
            button.bezelStyle = .inline
            button.setButtonType(.momentaryChange)
            button.font = .systemFont(ofSize: 11, weight: index == pathComponents.count - 1 ? .semibold : .regular)
            button.lineBreakMode = .byTruncatingMiddle
            button.alignment = .left
            button.imagePosition = .noImage
            button.focusRingType = .none
            button.toolTip = targetURL.path
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            breadcrumbViews.append(button)

            if index < pathComponents.count - 1 {
                let separator = NSTextField(labelWithString: ">")
                separator.font = .systemFont(ofSize: 10, weight: .semibold)
                separator.alignment = .center
                separator.setContentHuggingPriority(.required, for: .horizontal)
                separator.setContentCompressionResistancePriority(.required, for: .horizontal)
                breadcrumbViews.append(separator)
            }
        }

        breadcrumbStackView.setViews(breadcrumbViews, in: .leading)
        updateBreadcrumbAppearance()
    }

    private func publishSelection() {
        let selectedItem = viewModel.selectedItem
        onSelectionChanged?(selectedItem)
        onStatusContextTextChanged?(statusContextText(for: selectedItem))
    }

    private func statusContextText(for selectedItem: FileItem?) -> String? {
        return selectedItem?.url.standardizedFileURL.path
    }

    private func updateActiveAppearance() {
        let palette = filerTheme.palette
        let headerColor: NSColor
        if isDropTargetHighlighted {
            headerColor = palette.dropTargetBorderColor
        } else {
            headerColor = isPaneActive ? palette.activeHeaderColor : palette.inactiveHeaderColor
        }

        view.layer?.backgroundColor = palette.paneBackgroundColor.applyingBackgroundOpacity(backgroundOpacity).cgColor
        headerView.layer?.backgroundColor = headerColor.cgColor
        breadcrumbContainerView.alphaValue = isPaneActive ? 1.0 : 0.82
        let borderColor = NSColor.separatorColor.cgColor
        filesModeButton.layer?.borderColor = borderColor
        mediaModeButton.layer?.borderColor = borderColor
        searchField.textColor = palette.primaryTextColor
        searchField.backgroundColor = palette.filterBarBackgroundColor.applyingBackgroundOpacity(backgroundOpacity)
        updateSearchFieldAppearance()
        updateBreadcrumbAppearance()
        updateDisplayModeControls()
        tableView.backgroundColor = palette.tableBackgroundColor.applyingBackgroundOpacity(backgroundOpacity)
        mediaCollectionView.backgroundColors = [palette.tableBackgroundColor.applyingBackgroundOpacity(backgroundOpacity)]
        scrollView.backgroundColor = palette.tableBackgroundColor.applyingBackgroundOpacity(backgroundOpacity)
        scrollView.alphaValue = isPaneActive ? palette.activePaneAlpha : palette.inactivePaneAlpha
        bookmarkJumpOverlayView.applyPalette(palette, backgroundOpacity: backgroundOpacity)
        shortcutGuidePopupView.applyPalette(palette, backgroundOpacity: backgroundOpacity)
        loadingLabel.textColor = palette.primaryTextColor
        loadingOverlayView.layer?.backgroundColor = palette.windowBackgroundColor.withAlphaComponent(0.72).cgColor
        loadingOverlayView.layer?.borderColor = palette.starAccentColor.withAlphaComponent(0.35).cgColor
    }

    @objc
    private func handleBreadcrumbClick(_ sender: NSButton) {
        guard let path = sender.toolTip, !path.isEmpty else {
            return
        }

        let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard !targetURL.path.isEmpty else {
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        viewModel.navigate(to: targetURL)
    }

    private func updateBreadcrumbAppearance() {
        let palette = filerTheme.palette
        for view in breadcrumbStackView.arrangedSubviews {
            if let button = view as? NSButton {
                button.contentTintColor = isPaneActive ? palette.activePathTextColor : palette.inactivePathTextColor
            } else if let separator = view as? NSTextField {
                separator.textColor = isPaneActive
                    ? palette.activePathTextColor.withAlphaComponent(0.7)
                    : palette.inactivePathTextColor.withAlphaComponent(0.7)
            }
        }
    }

    @objc
    private func handleDisplayModeChanged(_ sender: NSButton) {
        let mode: PaneDisplayMode = sender.tag == 1 ? .media : .browser
        viewModel.setDisplayMode(mode)
    }

    @objc
    private func handleFilesRecursiveToggle(_ sender: NSButton) {
        viewModel.setFilesRecursiveEnabled(sender.state == .on)
    }

    @objc
    private func handleMediaRecursiveToggle(_ sender: NSButton) {
        viewModel.setMediaRecursiveEnabled(sender.state == .on)
    }

    @objc
    private func handleMediaIconSizeChanged(_ sender: NSSlider) {
        let clampedSize = min(max(CGFloat(sender.doubleValue), 12), 40)
        setFileIconSize(clampedSize)
        onFileIconSizeChanged?(clampedSize)
    }

    @objc
    private func handleMediaDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: mediaCollectionView)
        guard let indexPath = mediaCollectionView.indexPathForItem(at: point) else {
            return
        }

        viewModel.setCursor(index: indexPath.item)
        openSelectedFile()
    }

    private func makeNameCell(for item: FileItem, row: Int, treeItem: TreeDisplayItem? = nil) -> NSTableCellView {
        let cell = tableView.makeView(withIdentifier: Cell.name, owner: self) as? FileNameCellView ?? createNameCellView()

        let isMarked = row == viewModel.paneState.cursorIndex
        let palette = filerTheme.palette

        if starEffectsEnabled {
            cell.setMarkStar(visible: isMarked, color: palette.starAccentColor)
            cell.setName(item.name, textColor: palette.primaryTextColor)
        } else {
            cell.setMarkStar(visible: false, color: palette.starAccentColor)
            cell.setName(isMarked ? "* \(item.name)" : item.name, textColor: palette.primaryTextColor)
        }

        cell.setIcon(icon(for: item, row: row), size: Self.browserModeIconSize)

        if let treeItem {
            cell.setTreeIndentation(depth: treeItem.depth, isExpandable: treeItem.isExpandable, isExpanded: treeItem.isExpanded)
        } else {
            cell.setTreeIndentation(depth: 0, isExpandable: false, isExpanded: false)
        }

        return cell
    }

    private func makeTextCell(text: String, alignment: NSTextAlignment) -> NSTableCellView {
        let cell = tableView.makeView(withIdentifier: Cell.text, owner: self) as? NSTableCellView ?? createTextCellView()
        cell.textField?.stringValue = text
        cell.textField?.alignment = alignment
        cell.textField?.textColor = filerTheme.palette.primaryTextColor
        return cell
    }

    private func createNameCellView() -> FileNameCellView {
        let cell = FileNameCellView()
        cell.identifier = Cell.name
        cell.setIcon(nil, size: Self.browserModeIconSize)
        return cell
    }

    private func createTextCellView() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Cell.text

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail

        cell.textField = textField
        cell.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func icon(for item: FileItem, row: Int) -> NSImage {
        if !item.isDirectory && item.url.isMediaFile {
            let thumbnailKey = thumbnailCacheKey(for: item)

            if let thumbnail = thumbnailCache.object(forKey: thumbnailKey) {
                return thumbnail
            }

            scheduleThumbnailLoadIfNeeded(for: item, row: row, key: thumbnailKey)
        }

        return fallbackIcon(for: item)
    }

    private func fallbackIcon(for item: FileItem) -> NSImage {
        let iconSize = currentDisplayMode == .media ? fileIconSize : Self.browserModeIconSize
        let pixelSize = Int(iconSize.rounded())
        let cacheKey = "\(item.url.path)#\(pixelSize)" as NSString

        if let cached = iconCache.object(forKey: cacheKey) {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.isTemplate = false
        icon.size = NSSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize))
        iconCache.setObject(icon, forKey: cacheKey)
        return icon
    }

    private func thumbnailCacheKey(for item: FileItem) -> NSString {
        let pixelSize = thumbnailPixelSizeForCurrentDisplayMode()
        return "thumb#\(item.url.path)#\(pixelSize)" as NSString
    }

    private func scheduleThumbnailLoadIfNeeded(for item: FileItem, row: Int, key: NSString) {
        guard thumbnailTasks[key] == nil else {
            return
        }

        let targetURL = item.url.standardizedFileURL
        let size = thumbnailPixelSizeForCurrentDisplayMode()

        thumbnailTasks[key] = Task { [weak self] in
            guard let self else {
                return
            }

            let thumbnail = await Self.generateThumbnail(for: targetURL, maxPixelSize: size)
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.thumbnailTasks.removeValue(forKey: key)
                }
                return
            }

            await MainActor.run {
                self.thumbnailTasks.removeValue(forKey: key)
                guard let thumbnail else {
                    return
                }

                self.thumbnailCache.setObject(thumbnail, forKey: key)

                guard self.viewModel.directoryContents.displayedItems.indices.contains(row) else {
                    return
                }

                if self.viewModel.directoryContents.displayedItems[row].url.standardizedFileURL != targetURL {
                    return
                }

                let rowIndexes = IndexSet(integer: row)
                let columnIndexes = IndexSet(integersIn: 0 ..< self.tableView.numberOfColumns)
                self.tableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
                self.mediaCollectionView.reloadItems(at: [IndexPath(item: row, section: 0)])
            }
        }
    }

    private func preferredMediaTileWidth() -> CGFloat {
        min(max(fileIconSize * 5.5, 120), 260)
    }

    private func thumbnailPixelSizeForCurrentDisplayMode() -> Int {
        if currentDisplayMode == .media {
            return max(128, Int((preferredMediaTileWidth() * 2).rounded()))
        }

        return max(16, Int((Self.browserModeIconSize * 2).rounded()))
    }

    private static func generateThumbnail(for url: URL, maxPixelSize: Int) async -> NSImage? {
        await Task.detached(priority: .utility) {
            if url.isImageFile {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    return nil
                }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: false,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]

                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }

                let size = NSSize(width: cgImage.width, height: cgImage.height)
                return NSImage(cgImage: cgImage, size: size)
            }

            if url.isVideoFile {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 1)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 1)

                let time = CMTime(seconds: 1, preferredTimescale: 600)
                if let result = try? await generator.image(at: time) {
                    let size = NSSize(width: result.image.width, height: result.image.height)
                    return NSImage(cgImage: result.image, size: size)
                }
                return nil
            }

            return nil
        }.value
    }

    private func sizeText(for item: FileItem) -> String {
        guard !item.isDirectory || item.isPackage, let size = item.size else {
            return ""
        }
        return Self.byteFormatter.string(fromByteCount: size)
    }

    private func modifiedText(for item: FileItem) -> String {
        guard let date = item.dateModified else {
            return ""
        }
        return Self.dateFormatter.string(from: date)
    }

    private func handleTabPressed() -> Bool {
        onTabPressed?() ?? false
    }

    private var selectedSearchMode: SearchMode {
        currentSearchMode
    }

    private func focusSearch(mode: SearchMode) {
        if selectedSearchMode != mode {
            currentSearchMode = mode
            updateSearchModeUI()
        }

        onDidRequestActivate?()
        vimModeState.enterFilterMode()
        tableView.setVimMode(vimModeState.mode)
        mediaCollectionView.setVimMode(vimModeState.mode)

        isSearchFieldFocused = true
        view.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        updateSearchFieldAppearance()

        if starEffectsEnabled, animationEffectSettings.filterBarGlow {
            let palette = filerTheme.palette
            searchField.wantsLayer = true
            searchField.layer?.shadowColor = palette.starAccentColor.cgColor
            searchField.layer?.shadowRadius = 6
            searchField.layer?.shadowOffset = .zero
            searchField.layer?.shadowOpacity = 0

            let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
            glow.values = [0.0, 0.6, 0.2]
            glow.keyTimes = [0, 0.5, 1.0]
            glow.duration = 0.3
            glow.isRemovedOnCompletion = false
            glow.fillMode = .forwards
            searchField.layer?.shadowOpacity = 0.2
            searchField.layer?.add(glow, forKey: "searchGlow")
        }
    }

    private func clearSearchAndReturnToTable() {
        searchField.stringValue = ""
        currentSearchMode = .filter
        updateSearchModeUI()
        viewModel.clearFilter()
        viewModel.exitSpotlightSearchMode()

        searchField.layer?.removeAnimation(forKey: "searchGlow")
        searchField.layer?.shadowOpacity = 0

        switchToNormalModeAndFocusTable()
    }

    private func switchToNormalModeAndFocusTable() {
        vimModeState.enterNormalMode()
        tableView.setVimMode(vimModeState.mode)
        mediaCollectionView.setVimMode(vimModeState.mode)
        focusTable()
    }

    private func updateSearchModeUI() {
        let mode = selectedSearchMode
        updateSearchFieldButtonIcon(
            symbolName: mode.iconSymbolName,
            accessibilityLabel: mode.iconAccessibilityLabel
        )
        updateSearchMenuSelectionStates()
        updateSearchFieldAppearance()
    }

    private func updateSearchFieldAppearance() {
        guard isViewLoaded else {
            return
        }

        let palette = filerTheme.palette
        let borderColor = isSearchFieldFocused ? palette.activeBorderColor : NSColor.separatorColor
        searchField.layer?.borderColor = borderColor.cgColor
        searchField.layer?.borderWidth = isSearchFieldFocused ? 1.0 : 0.5
    }

    private func updateSearchMenuSelectionStates() {
        for (mode, item) in searchMenuModeItems {
            item.state = selectedSearchMode == mode ? .on : .off
        }

        for (scope, item) in searchMenuScopeItems {
            item.state = viewModel.spotlightSearchScope == scope ? .on : .off
        }
    }

    private func applySearchFromHeader() {
        let query = searchField.stringValue

        switch selectedSearchMode {
        case .filter:
            viewModel.exitSpotlightSearchMode()
            viewModel.setFilterText(query)
        case .spotlight:
            viewModel.clearFilter()
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                viewModel.exitSpotlightSearchMode()
            } else {
                viewModel.enterSpotlightSearchMode()
                viewModel.updateSpotlightSearchQuery(trimmed)
            }
        }
    }

    @discardableResult
    private func handleKeyAction(_ action: KeyAction) -> Bool {
        let handled: Bool

        switch action {
        case .cursorUp:
            viewModel.moveCursorUp()
            handled = true
        case .cursorDown:
            viewModel.moveCursorDown()
            handled = true
        case .cursorLeft:
            addSlideTransition(direction: .fromLeft)
            viewModel.goToParent()
            handled = true
        case .cursorRight:
            addSlideTransition(direction: .fromRight)
            viewModel.enterSelected()
            handled = true
        case .pageUp:
            viewModel.moveCursorPageUp()
            handled = true
        case .pageDown:
            viewModel.moveCursorPageDown()
            handled = true
        case .goToTop:
            viewModel.moveCursorToTop()
            handled = true
        case .goToBottom:
            viewModel.moveCursorToBottom()
            handled = true
        case .goBack:
            viewModel.goBack()
            handled = true
        case .goForward:
            viewModel.goForward()
            handled = true
        case .goToParent:
            viewModel.goToParent()
            handled = true
        case .goHome:
            viewModel.navigate(to: UserPaths.homeDirectoryURL)
            handled = true
        case .goDesktop:
            viewModel.navigate(to: UserPaths.desktopDirectoryURL)
            handled = true
        case .goDocuments:
            viewModel.navigate(to: UserPaths.documentsDirectoryURL)
            handled = true
        case .goDownloads:
            viewModel.navigate(to: UserPaths.downloadsDirectoryURL)
            handled = true
        case .goApplications:
            viewModel.navigate(to: URL(fileURLWithPath: "/Applications", isDirectory: true))
            handled = true
        case .enterDirectory:
            handleEnterKeyAction()
            handled = true
        case .switchPane:
            handled = handleTabPressed()
        case .toggleMark:
            performToggleMarkAction()
            handled = true
        case .markAll:
            viewModel.markAll()
            if starEffectsEnabled, animationEffectSettings.markCascade {
                animateMarkCascade(topToBottom: true)
            }
            handled = true
        case .clearMarks:
            if starEffectsEnabled, animationEffectSettings.markCascade {
                animateMarkCascade(topToBottom: false)
            }
            viewModel.clearMarks()
            handled = true
        case .enterVisualMode:
            if vimModeState.mode != .visual {
                vimModeState.enterVisualMode(anchorIndex: viewModel.paneState.cursorIndex)
                tableView.setVimMode(vimModeState.mode)
                mediaCollectionView.setVimMode(vimModeState.mode)
                viewModel.enterVisualMode()

                if starEffectsEnabled, animationEffectSettings.visualModeWave {
                    flashRow(at: viewModel.paneState.cursorIndex,
                        color: filerTheme.palette.starAccentColor.withAlphaComponent(0.4), duration: 0.3)
                }
            }
            handled = true
        case .exitVisualMode:
            vimModeState.exitVisualMode()
            tableView.setVimMode(vimModeState.mode)
            mediaCollectionView.setVimMode(vimModeState.mode)
            viewModel.exitVisualMode()
            handled = true
        case .openFile:
            openSelectedFile()
            handled = true
        case .openFileInFinder:
            revealSelectedInFinder()
            handled = true
        case .copySelectedItemPath:
            copySelectedItemPathToPasteboard()
            handled = true
        case .toggleMediaMode:
            viewModel.toggleDisplayMode()
            handled = true
        case .toggleRecursive:
            viewModel.toggleRecursive()
            handled = true
        case .treeExpand:
            viewModel.expandSelectedFolder()
            handled = true
        case .treeCollapse:
            viewModel.collapseSelectedFolder()
            handled = true
        case .copy, .copyToClipboard, .paste, .pasteFromClipboard, .move, .cutToClipboard, .delete, .rename, .createDirectory, .undo, .togglePreview, .toggleSidebar, .toggleLeftPane, .toggleRightPane, .toggleSinglePane, .equalizePaneWidths, .matchOtherPaneDirectory, .goToOtherPaneDirectory, .openBookmarkSearch, .openHistory, .addBookmark, .batchRename, .syncPanesLeftToRight, .syncPanesRightToLeft, .togglePin, .toggleTerminalPanel, .launchClaude, .launchCodex:
            handled = onFileOperationRequested?(action) ?? false
        case .enterFilterMode:
            focusSearch(mode: .filter)
            handled = true
        case .enterSpotlightSearch:
            focusSearch(mode: .spotlight)
            handled = true
        case .clearFilter:
            clearSearchAndReturnToTable()
            handled = true
        case .toggleHiddenFiles:
            viewModel.toggleHiddenFiles()
            handled = true
        case .sortByName:
            viewModel.sortByName()
            handled = true
        case .sortBySize:
            viewModel.sortBySize()
            handled = true
        case .sortByDate:
            viewModel.sortByDate()
            handled = true
        case .sortBySelectionOrder:
            viewModel.sortBySelectionOrder()
            handled = true
        case .reverseSortOrder:
            viewModel.reverseSortOrder()
            handled = true
        case .refresh:
            viewModel.refresh()
            handled = true
        case .cancelLoading:
            handled = viewModel.cancelLoading()
        case .quit:
            NSApp.terminate(nil)
            handled = true
        }

        return handled
    }

    private func performToggleMarkAction() {
        let itemCount = viewModel.directoryContents.displayedItems.count
        let cursorIndexBeforeToggle = viewModel.paneState.cursorIndex
        viewModel.toggleMark()

        guard let destinationCursorIndex = destinationCursorIndexAfterSpaceMark(
            itemCount: itemCount,
            cursorIndexBeforeToggle: cursorIndexBeforeToggle
        ) else {
            return
        }

        viewModel.setCursor(index: destinationCursorIndex)
    }

    private func destinationCursorIndexAfterSpaceMark(itemCount: Int, cursorIndexBeforeToggle: Int) -> Int? {
        guard itemCount > 0 else {
            return nil
        }

        guard let keyEvent = NSApp.currentEvent?.keyEvent else {
            return nil
        }

        guard keyEvent.key == "Space" else {
            return nil
        }

        if keyEvent.modifiers.isEmpty {
            let nextIndex = cursorIndexBeforeToggle + 1
            return nextIndex < itemCount ? nextIndex : nil
        }

        if keyEvent.modifiers == [.shift] {
            let previousIndex = cursorIndexBeforeToggle - 1
            return previousIndex >= 0 ? previousIndex : nil
        }

        return nil
    }

    @objc
    private func handleDoubleClick(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else {
            return
        }
        openSelectedFile()
    }

    private func handleTreeDisclosureMouseDown(event: NSEvent, at point: NSPoint) -> Bool {
        guard currentDisplayMode == .browser else {
            return false
        }

        guard event.type == .leftMouseDown, event.clickCount == 1 else {
            return false
        }

        let row = tableView.row(at: point)
        guard row >= 0 else {
            return false
        }

        let column = tableView.column(at: point)
        guard column >= 0 else {
            return false
        }

        let tableColumn = tableView.tableColumns[column]
        guard tableColumn.identifier == Column.name else {
            return false
        }

        guard viewModel.directoryContents.displayedTreeItems.indices.contains(row) else {
            return false
        }

        let treeItem = viewModel.directoryContents.displayedTreeItems[row]
        guard treeItem.isExpandable else {
            return false
        }

        let cellFrame = tableView.frameOfCell(atColumn: column, row: row)
        let xInCell = point.x - cellFrame.minX
        let disclosureMinX = TreeDisclosureMetrics.leading + CGFloat(treeItem.depth) * TreeDisclosureMetrics.indentWidth
        let disclosureMaxX = disclosureMinX + TreeDisclosureMetrics.disclosureWidth
        guard xInCell >= disclosureMinX, xInCell <= disclosureMaxX else {
            return false
        }

        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        viewModel.setCursor(index: row)

        if treeItem.isExpanded {
            viewModel.collapseSelectedFolder()
        } else {
            viewModel.expandSelectedFolder()
        }
        return true
    }

    private func openSelectedFile() {
        guard let item = viewModel.selectedItem else {
            return
        }

        if item.isDirectory && !item.isPackage {
            viewModel.enterSelected()
        } else if item.url.isMarkdownFile {
            let markdownURLs = viewModel.markedOrSelectedURLs()
                .filter(\.isMarkdownFile)
            if markdownURLs.isEmpty {
                onMarkdownPreviewRequested?([item.url])
            } else {
                onMarkdownPreviewRequested?(markdownURLs)
            }
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func handleEnterKeyAction() {
        openSelectedFile()
    }

    private func revealSelectedInFinder() {
        guard let item = viewModel.selectedItem else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func copySelectedItemPathToPasteboard() {
        let paths = viewModel.markedOrSelectedPaths()
        guard !paths.isEmpty else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private func presentDropError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Drop Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSControl) === searchField else {
            return
        }

        onDidRequestActivate?()
        isSearchFieldFocused = true
        vimModeState.enterFilterMode()
        tableView.setVimMode(vimModeState.mode)
        mediaCollectionView.setVimMode(vimModeState.mode)
        updateSearchFieldAppearance()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let control = obj.object as? NSControl else {
            return
        }

        if control === contextMenuFilterField {
            handleContextMenuFilterChanged(contextMenuFilterField)
            return
        }

        guard control === searchField else {
            return
        }

        applySearchFromHeader()
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard sender === searchField else {
            return
        }

        // NSSearchField's clear (x) button does not always emit controlTextDidChange.
        // Ensure filter/spotlight state is synced when the field is cleared from the chrome.
        applySearchFromHeader()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSControl) === searchField else {
            return
        }

        restoreNormalModeIfNeededAfterSearch()
        isSearchFieldFocused = false
        updateSearchFieldAppearance()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else {
            return false
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            clearSearchAndReturnToTable()
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if selectedSearchMode == .spotlight {
                viewModel.enterSelected()
                viewModel.exitSpotlightSearchMode()
                searchField.stringValue = ""
                currentSearchMode = .filter
                updateSearchModeUI()

                switchToNormalModeAndFocusTable()
                return true
            }

            applySearchFromHeader()
            let trimmedFilterQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFilterQuery.isEmpty else {
                switchToNormalModeAndFocusTable()
                return true
            }

            viewModel.focusFirstBrowsableDirectoryInFilteredResults()
            if let selectedItem = viewModel.selectedItem, selectedItem.isDirectory, !selectedItem.isPackage {
                addSlideTransition(direction: .fromRight)
                viewModel.enterSelected()
                switchToNormalModeAndFocusTable()
            }
            return true
        }

        return false
    }

    private func configureSearchFieldMenuTemplate() {
        let menu = NSMenu(title: "Search Options")
        searchMenuModeItems.removeAll(keepingCapacity: true)
        searchMenuScopeItems.removeAll(keepingCapacity: true)

        let modeHeader = NSMenuItem(title: "Search Mode", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        for mode in [SearchMode.filter, .spotlight] {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(handleSearchModeMenuSelection(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            menu.addItem(item)
            searchMenuModeItems[mode] = item
        }

        menu.addItem(NSMenuItem.separator())

        let scopeHeader = NSMenuItem(title: "Spotlight Scope", action: nil, keyEquivalent: "")
        scopeHeader.isEnabled = false
        menu.addItem(scopeHeader)

        for scope in SpotlightSearchScope.allCases {
            let item = NSMenuItem(title: scope.displayName, action: #selector(handleSpotlightScopeMenuSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scope.rawValue
            menu.addItem(item)
            searchMenuScopeItems[scope] = item
        }

        searchField.searchMenuTemplate = menu
        updateSearchMenuSelectionStates()
    }

    private func configureSearchFieldButtonAction() {
        guard let cell = searchField.cell as? NSSearchFieldCell else {
            return
        }
        cell.searchButtonCell?.target = self
        cell.searchButtonCell?.action = #selector(handleSearchFieldButtonClick(_:))
    }

    private func updateSearchFieldButtonIcon(symbolName: String, accessibilityLabel: String) {
        guard let cell = searchField.cell as? NSSearchFieldCell,
              let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) else {
            return
        }

        let configuredImage = symbolImage.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        ) ?? symbolImage
        configuredImage.isTemplate = true

        cell.searchButtonCell?.image = configuredImage
        cell.searchButtonCell?.alternateImage = configuredImage
        searchField.toolTip = accessibilityLabel
    }

    @objc
    private func handleSearchFieldButtonClick(_ sender: Any?) {
        guard let menu = searchField.searchMenuTemplate else {
            return
        }

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: searchField)
            return
        }

        menu.popUp(positioning: nil, at: .zero, in: searchField)
    }

    @objc
    private func handleSearchModeMenuSelection(_ sender: NSMenuItem) {
        guard let mode = SearchMode(rawValue: sender.tag), selectedSearchMode != mode else {
            return
        }

        currentSearchMode = mode
        updateSearchModeUI()
        applySearchFromHeader()
    }

    @objc
    private func handleSpotlightScopeMenuSelection(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let scope = SpotlightSearchScope(rawValue: rawValue) else {
            return
        }

        viewModel.setSpotlightSearchScope(scope)
        onSpotlightSearchScopeChanged?(scope)
        updateSearchMenuSelectionStates()
        applySearchFromHeader()
    }

    // MARK: - Context Menu

    private struct ContextMenuContext {
        let contextItem: FileItem?
        let hasContextItem: Bool
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard isPaneContextMenu(menu) else {
            return
        }

        activeContextMenu = menu
        focusContextMenuFilterField(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard isPaneContextMenu(menu) else {
            return
        }

        activeContextMenu = nil
        contextMenuFilterText = ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard isPaneContextMenu(menu) else {
            return
        }

        activeContextMenu = menu
        contextMenuFilterText = ""
        rebuildContextMenu(menu, filterText: contextMenuFilterText)
        focusContextMenuFilterField(in: menu)
    }

    private func isPaneContextMenu(_ menu: NSMenu) -> Bool {
        menu === tableView.menu || menu === mediaCollectionView.menu
    }

    private func makeContextMenuFilterField() -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.controlSize = .small
        field.placeholderString = "Filter actions..."
        field.font = .systemFont(ofSize: 12)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(handleContextMenuFilterChanged(_:))
        field.delegate = self
        return field
    }

    private func rebuildContextMenu(_ menu: NSMenu, filterText: String) {
        menu.removeAllItems()
        menu.addItem(makeContextMenuFilterMenuItem())
        menu.addItem(NSMenuItem.separator())
        contextMenuFilterField.stringValue = filterText
        updateContextMenuActionItems(in: menu, filterText: filterText)
    }

    private func makeContextMenuFilterMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: ContextMenuMetrics.filterWidth,
                height: ContextMenuMetrics.filterHeight
            )
        )

        contextMenuFilterField.removeFromSuperview()
        contextMenuFilterField.frame = NSRect(
            x: ContextMenuMetrics.filterFieldInset,
            y: (ContextMenuMetrics.filterHeight - 22) / 2,
            width: ContextMenuMetrics.filterWidth - (ContextMenuMetrics.filterFieldInset * 2),
            height: 22
        )
        contextMenuFilterField.autoresizingMask = [.width]
        container.addSubview(contextMenuFilterField)
        item.view = container
        return item
    }

    private func updateContextMenuActionItems(in menu: NSMenu, filterText: String) {
        while menu.items.count > ContextMenuMetrics.staticHeaderItemCount {
            menu.removeItem(at: ContextMenuMetrics.staticHeaderItemCount)
        }

        let allItems = makeContextMenuActionItems()
        let visibleItems = filterContextMenuItems(allItems, query: filterText)
        if visibleItems.isEmpty {
            let emptyItem = NSMenuItem(title: "No matching actions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        visibleItems.forEach { menu.addItem($0) }
    }

    @objc
    private func handleContextMenuFilterChanged(_ sender: NSSearchField) {
        guard sender === contextMenuFilterField else {
            return
        }

        contextMenuFilterText = sender.stringValue
        guard let menu = activeContextMenu else {
            return
        }

        updateContextMenuActionItems(in: menu, filterText: contextMenuFilterText)
    }

    private func makeContextMenuActionItems() -> [NSMenuItem] {
        let context = currentContextMenuContext()
        let contextItem = context.contextItem
        let hasContextItem = context.hasContextItem

        var items: [NSMenuItem] = []

        let openTitle: String
        if let contextItem, contextItem.isDirectory && !contextItem.isPackage {
            openTitle = "Open"
        } else {
            openTitle = "Open with Default App"
        }

        items.append(makeContextMenuItem(
            title: openTitle,
            action: .openFile,
            shortcutActions: [.enterDirectory, .openFile],
            requiresContextItem: true,
            enabled: hasContextItem
        ))

        if let contextItem, contextItem.url.isImageFile {
            let openInPixelmatorItem = NSMenuItem(
                title: "Open in Pixelmator Pro",
                action: #selector(handleOpenInPixelmatorFromContextMenu(_:)),
                keyEquivalent: ""
            )
            openInPixelmatorItem.target = self
            openInPixelmatorItem.tag = 1
            items.append(openInPixelmatorItem)
        }

        items.append(makeContextMenuItem(
            title: "Show in Finder",
            action: .openFileInFinder,
            requiresContextItem: true,
            enabled: hasContextItem
        ))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(
            title: "Toggle Mark",
            action: .toggleMark,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(
            title: "Mark All",
            action: .markAll,
            enabled: !viewModel.directoryContents.displayedItems.isEmpty
        ))
        items.append(makeContextMenuItem(
            title: "Clear Marks",
            action: .clearMarks,
            enabled: viewModel.markedCount > 0
        ))

        if vimModeState.mode == .visual {
            items.append(makeContextMenuItem(title: "End Visual Selection", action: .exitVisualMode))
        } else {
            items.append(makeContextMenuItem(
                title: "Start Visual Selection",
                action: .enterVisualMode,
                requiresContextItem: true,
                enabled: hasContextItem
            ))
        }

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(
            title: "Copy",
            action: .copyToClipboard,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(
            title: "Copy File/Folder Path",
            action: .copySelectedItemPath,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(
            title: "Cut",
            action: .cutToClipboard,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(title: "Paste", action: .pasteFromClipboard))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(
            title: "Rename...",
            action: .rename,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(
            title: "Move to Trash",
            action: .delete,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(title: "New Folder", action: .createDirectory))
        items.append(makeContextMenuItem(
            title: "Batch Rename...",
            action: .batchRename,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(title: "Sync: Left → Right", action: .syncPanesLeftToRight))
        items.append(makeContextMenuItem(title: "Sync: Right → Left", action: .syncPanesRightToLeft))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(title: "Filter...", action: .enterFilterMode))
        items.append(makeContextMenuItem(title: "Spotlight Search...", action: .enterSpotlightSearch))
        items.append(makeContextMenuItem(title: "Clear Filter", action: .clearFilter))
        items.append(makeContextMenuItem(title: "Bookmark Search...", action: .openBookmarkSearch))
        items.append(makeContextMenuItem(title: "History...", action: .openHistory))
        items.append(makeContextMenuItem(title: "Add Bookmark...", action: .addBookmark))
        items.append(makeContextMenuItem(title: "Toggle Pin", action: .togglePin))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(title: "Back", action: .goBack))
        items.append(makeContextMenuItem(title: "Forward", action: .goForward))
        items.append(makeContextMenuItem(title: "Enclosing Folder", action: .goToParent))
        items.append(makeContextMenuItem(title: "Home", action: .goHome))
        items.append(makeContextMenuItem(title: "Desktop", action: .goDesktop))
        items.append(makeContextMenuItem(title: "Documents", action: .goDocuments))
        items.append(makeContextMenuItem(title: "Downloads", action: .goDownloads))
        items.append(makeContextMenuItem(title: "Applications", action: .goApplications))
        items.append(makeContextMenuItem(title: "Refresh", action: .refresh))
        items.append(makeContextMenuItem(title: "Toggle Hidden Files", action: .toggleHiddenFiles))
        items.append(makeSortMenuItem())
        items.append(makeContextMenuItem(title: "Toggle Media Mode", action: .toggleMediaMode))
        items.append(makeContextMenuItem(title: "Toggle Recursive Mode", action: .toggleRecursive))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(title: "Toggle Sidebar", action: .toggleSidebar))
        items.append(makeContextMenuItem(title: "Toggle Left Pane", action: .toggleLeftPane))
        items.append(makeContextMenuItem(title: "Toggle Right Pane", action: .toggleRightPane))
        items.append(makeContextMenuItem(title: "Equalize Pane Widths", action: .equalizePaneWidths))
        items.append(makeContextMenuItem(title: "Set Other Pane to Current Folder", action: .matchOtherPaneDirectory))
        items.append(makeContextMenuItem(title: "Go to Other Pane Folder", action: .goToOtherPaneDirectory))
        items.append(makeContextMenuItem(title: "Switch Pane", action: .switchPane))

        return normalizeContextMenuItems(items)
    }

    private func currentContextMenuContext() -> ContextMenuContext {
        let clickedRow = contextMenuClickedRow()
        let hasClickedItem = viewModel.directoryContents.displayedItems.indices.contains(clickedRow)
        let clickedItem = hasClickedItem ? viewModel.directoryContents.displayedItems[clickedRow] : nil
        let contextItem = clickedItem ?? viewModel.selectedItem
        return ContextMenuContext(contextItem: contextItem, hasContextItem: contextItem != nil)
    }

    private func contextMenuClickedRow() -> Int {
        if currentDisplayMode == .media {
            return mediaCollectionView.selectionIndexPaths.first?.item ?? -1
        }

        return tableView.clickedRow
    }

    private func filterContextMenuItems(_ items: [NSMenuItem], query: String) -> [NSMenuItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return items
        }

        var filtered: [NSMenuItem] = []
        var shouldInsertSeparator = false

        for item in items {
            if item.isSeparatorItem {
                shouldInsertSeparator = !filtered.isEmpty
                continue
            }

            guard contextMenuItemMatchesQuery(item, query: trimmedQuery) else {
                continue
            }

            if shouldInsertSeparator, !filtered.isEmpty {
                filtered.append(NSMenuItem.separator())
            }
            filtered.append(item)
            shouldInsertSeparator = false
        }

        return normalizeContextMenuItems(filtered)
    }

    private func contextMenuItemMatchesQuery(_ item: NSMenuItem, query: String) -> Bool {
        if item.title.localizedCaseInsensitiveContains(query) {
            return true
        }

        guard let submenu = item.submenu else {
            return false
        }

        let filteredSubItems = filterContextMenuItems(submenu.items, query: query)
        guard !filteredSubItems.isEmpty else {
            return false
        }

        submenu.removeAllItems()
        filteredSubItems.forEach { submenu.addItem($0) }
        return true
    }

    private func normalizeContextMenuItems(_ items: [NSMenuItem]) -> [NSMenuItem] {
        var normalized: [NSMenuItem] = []
        var previousWasSeparator = true

        for item in items {
            if item.isSeparatorItem {
                guard !previousWasSeparator else {
                    continue
                }
                normalized.append(item)
                previousWasSeparator = true
                continue
            }

            normalized.append(item)
            previousWasSeparator = false
        }

        if normalized.last?.isSeparatorItem == true {
            normalized.removeLast()
        }

        return normalized
    }

    private func focusContextMenuFilterField(in menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.activeContextMenu === menu,
                  let window = self.contextMenuFilterField.window else {
                return
            }

            window.makeFirstResponder(self.contextMenuFilterField)
        }
    }

    private func makeSortMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Sort", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Sort")

        submenu.addItem(makeContextMenuItem(title: "By Name", action: .sortByName))
        submenu.addItem(makeContextMenuItem(title: "By Size", action: .sortBySize))
        submenu.addItem(makeContextMenuItem(title: "By Date", action: .sortByDate))
        submenu.addItem(makeContextMenuItem(title: "By Selection Order", action: .sortBySelectionOrder))
        submenu.addItem(makeContextMenuItem(title: "Reverse Sort Order", action: .reverseSortOrder))

        item.submenu = submenu
        return item
    }

    private func updateColumnHeaderTitles() {
        let currentSort = viewModel.directoryContents.sortDescriptor

        for column in tableView.tableColumns {
            let baseTitle: String
            let mappedSortColumn: DirectoryContents.SortDescriptor.Column?

            switch column.identifier {
            case Column.name:
                baseTitle = "Name"
                mappedSortColumn = .name
            case Column.size:
                baseTitle = "Size"
                mappedSortColumn = .size
            case Column.modified:
                baseTitle = "Modified"
                mappedSortColumn = .date
            default:
                continue
            }

            if let mappedSortColumn, mappedSortColumn == currentSort.column {
                column.title = "\(baseTitle) \(currentSort.ascending ? "↑" : "↓")"
            } else {
                column.title = baseTitle
            }
        }
    }

    private func makeContextMenuItem(
        title: String,
        action keyAction: KeyAction,
        shortcutActions: [KeyAction]? = nil,
        requiresContextItem: Bool = false,
        enabled: Bool = true
    ) -> NSMenuItem {
        let actionsForShortcut = shortcutActions ?? [keyAction]
        let item = NSMenuItem(
            title: contextMenuTitle(title, actions: actionsForShortcut),
            action: #selector(contextMenuPerformAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = keyAction
        item.tag = requiresContextItem ? 1 : 0
        item.isEnabled = enabled
        return item
    }

    private func contextMenuTitle(_ title: String, actions: [KeyAction]) -> String {
        var seen = Set<String>()
        var shortcuts: [String] = []

        for action in actions {
            for shortcut in preferredShortcuts(for: action) where !seen.contains(shortcut) {
                seen.insert(shortcut)
                shortcuts.append(shortcut)
            }
        }

        guard !shortcuts.isEmpty else {
            return title
        }

        return "\(title) (\(shortcuts.joined(separator: " / ")))"
    }

    private func preferredShortcuts(for action: KeyAction) -> [String] {
        let normal = keybindingManager.shortcuts(for: action, mode: .normal)
        if !normal.isEmpty {
            return normal
        }

        let visual = keybindingManager.shortcuts(for: action, mode: .visual)
        if !visual.isEmpty {
            return visual
        }

        return keybindingManager.shortcuts(for: action, mode: .filter)
    }

    @objc
    private func contextMenuPerformAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? KeyAction else {
            return
        }

        let requiresContextItem = sender.tag == 1
        guard resolveContextSelectionIfNeeded(requiresContextItem: requiresContextItem) else {
            return
        }

        _ = handleKeyAction(action)
    }

    private func resolveContextSelectionIfNeeded(requiresContextItem: Bool) -> Bool {
        guard requiresContextItem else {
            return true
        }

        let clickedRow = contextMenuClickedRow()
        if viewModel.directoryContents.displayedItems.indices.contains(clickedRow) {
            viewModel.setCursor(index: clickedRow)
            return true
        }

        return viewModel.selectedItem != nil
    }

    @objc
    private func handleOpenInPixelmatorFromContextMenu(_ sender: NSMenuItem) {
        let requiresContextItem = sender.tag == 1
        guard resolveContextSelectionIfNeeded(requiresContextItem: requiresContextItem),
              let selectedItem = viewModel.selectedItem,
              selectedItem.url.isImageFile else {
            NSSound.beep()
            return
        }

        let appURL = Self.pixelmatorProAppURL
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.open(
            [selectedItem.url],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if error != nil {
                NSSound.beep()
            }
        }
    }

    // MARK: - Animation Helpers

    private func addSlideTransition(direction: CATransitionSubtype) {
        guard starEffectsEnabled, animationEffectSettings.directoryTransitionSlide else { return }
        let transition = CATransition()
        transition.type = .push
        transition.subtype = direction
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollView.layer?.add(transition, forKey: "directoryTransition")
    }

    private func flashRow(at row: Int, color: NSColor, duration: CFTimeInterval) {
        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return }
        rowView.wantsLayer = true
        let flash = CALayer()
        flash.frame = rowView.bounds
        flash.backgroundColor = color.cgColor
        flash.cornerRadius = 2
        rowView.layer?.addSublayer(flash)

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.duration = duration
        fadeOut.isRemovedOnCompletion = false
        fadeOut.fillMode = .forwards
        fadeOut.delegate = StarSparkleAnimator.makeRemovalDelegate(for: flash)
        flash.add(fadeOut, forKey: "rowFlash")
    }

    private func animateCursorRipple(at row: Int) {
        lastCursorRippleLayer?.removeFromSuperlayer()
        lastCursorRippleLayer = nil

        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return }
        rowView.wantsLayer = true

        let palette = filerTheme.palette
        let alpha: CGFloat = vimModeState.mode == .visual ? 0.3 : 0.15
        let duration: CFTimeInterval = vimModeState.mode == .visual ? 0.25 : 0.2

        let ripple = CALayer()
        ripple.frame = rowView.bounds
        ripple.backgroundColor = palette.starAccentColor.withAlphaComponent(alpha).cgColor
        ripple.cornerRadius = 2
        rowView.layer?.addSublayer(ripple)
        lastCursorRippleLayer = ripple

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.duration = duration
        fadeOut.isRemovedOnCompletion = false
        fadeOut.fillMode = .forwards
        fadeOut.delegate = StarSparkleAnimator.makeRemovalDelegate(for: ripple)
        ripple.add(fadeOut, forKey: "cursorRipple")
    }

    private func animateMarkCascade(topToBottom: Bool) {
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }

        let rows = Array(visibleRange.location ..< NSMaxRange(visibleRange))
        let orderedRows = topToBottom ? rows : rows.reversed()
        let palette = filerTheme.palette

        for (i, row) in orderedRows.enumerated() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(i) * 20))
                guard let self else { return }
                self.flashRow(at: row, color: palette.starGlowColor.withAlphaComponent(0.25), duration: 0.3)
            }
        }
    }

    private func startDropPulse() {
        guard starEffectsEnabled, animationEffectSettings.dropZonePulse else { return }
        let pulse = CABasicAnimation(keyPath: "borderWidth")
        pulse.fromValue = 1.0
        pulse.toValue = 2.5
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        view.layer?.add(pulse, forKey: "dropPulse")
    }

    private func stopDropPulse() {
        view.layer?.removeAnimation(forKey: "dropPulse")
    }
}
