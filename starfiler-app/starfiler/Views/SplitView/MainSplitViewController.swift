import AppKit

private enum PreviewSelectionStep {
    case previous
    case next
}

private final class PreviewPopupPanelController {
    private let previewViewController: PreviewPaneViewController
    private var panel: NSPanel?
    private var keyEventMonitor: Any?

    var onDismiss: (() -> Void)?
    var onSelectionStepRequested: ((PreviewSelectionStep) -> Bool)?

    var isVisible: Bool {
        panel != nil
    }

    init(previewViewController: PreviewPaneViewController) {
        self.previewViewController = previewViewController
    }

    deinit {
        stopKeyMonitor()
    }

    func show(relativeTo window: NSWindow, preferredAnchorFrame: NSRect?) {
        let panel = panel ?? makePanel()
        updateFrame(of: panel, relativeTo: window, preferredAnchorFrame: preferredAnchorFrame)

        if panel.parent !== window {
            if let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            window.addChildWindow(panel, ordered: .above)
        }

        panel.orderFront(nil)
        previewViewController.refreshFitIfNeeded()
        startKeyMonitor()
    }

    func dismiss() {
        guard let panel else {
            return
        }

        stopKeyMonitor()
        panel.orderOut(nil)
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        self.panel = nil
        onDismiss?()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let containerView = NSVisualEffectView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 14
        containerView.layer?.masksToBounds = true
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        let rootView = NSView()
        rootView.addSubview(containerView)

        let previewView = previewViewController.view
        previewView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(previewView)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: rootView.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            previewView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: containerView.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        panel.contentView = rootView
        self.panel = panel
        return panel
    }

    private func updateFrame(of panel: NSPanel, relativeTo window: NSWindow, preferredAnchorFrame: NSRect?) {
        let displayFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let anchorFrame = preferredAnchorFrame ?? window.frame
        let width = min(max(anchorFrame.width * 0.9, 600), min(displayFrame.width * 0.78, 1400))
        let height = min(max(displayFrame.height * 0.72, 420), 1000)
        let margin = CGFloat(24)

        let proposedX = anchorFrame.midX - (width / 2)
        let proposedY = anchorFrame.midY - (height / 2)
        let minX = displayFrame.minX + margin
        let maxX = displayFrame.maxX - width - margin
        let minY = displayFrame.minY + margin
        let maxY = displayFrame.maxY - height - margin

        let frame = NSRect(
            x: min(max(proposedX, minX), maxX),
            y: min(max(proposedY, minY), maxY),
            width: width,
            height: height
        )

        panel.setFrame(frame, display: true)
        previewViewController.setPreferredFitViewportSize(
            width: width,
            height: max(height - 68, 1)
        )
    }

    private func startKeyMonitor() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else {
                return event
            }

            guard let keyEvent = event.keyEvent else {
                return event
            }

            guard keyEvent.modifiers.isEmpty else {
                return event
            }

            if keyEvent.key == "Escape" {
                self.dismiss()
                return nil
            }

            let step: PreviewSelectionStep?
            switch keyEvent.key {
            case "ArrowUp", "ArrowLeft":
                step = .previous
            case "ArrowDown", "ArrowRight":
                step = .next
            default:
                step = nil
            }

            guard let step else {
                return event
            }

            if self.onSelectionStepRequested?(step) == true {
                return nil
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        guard let keyEventMonitor else {
            return
        }

        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }
}

final class MainSplitViewController: NSSplitViewController, NSPopoverDelegate {
    private static let defaultSidebarWidth = CGFloat(AppConfig.defaultSidebarWidth)
    static let sidebarWidthRange: ClosedRange<CGFloat> = CGFloat(AppConfig.sidebarWidthRange.lowerBound) ... CGFloat(AppConfig.sidebarWidthRange.upperBound)
    static var lastSelectedBookmarkGroupIndex: Int = 0

    private struct PaneStatus {
        var path: String
        var itemCount: Int
        var markedCount: Int
    }

    struct SidebarBookmarkEditResult {
        let groupName: String
        let displayName: String
        let path: String
        let shortcutKey: String?
    }

    let viewModel: MainViewModel
    let configManager: ConfigManager
    let sidebarViewModel: SidebarViewModel
    let sidebarViewController: SidebarViewController
    let sidebarSplitItem: NSSplitViewItem
    let leftPaneViewController: FilePaneViewController
    let rightPaneViewController: FilePaneViewController
    let leftSplitItem: NSSplitViewItem
    let rightSplitItem: NSSplitViewItem
    private let previewPopupPaneViewController: PreviewPaneViewController

    var bookmarksConfig: BookmarksConfig
    var bookmarkSearchPanelController: BookmarkSearchPanelController?
    var markdownPreviewPanelControllers: [URL: MarkdownPreviewPanelController] = [:]
    var batchRenameWindowController: NSWindowController?


    private var leftPaneStatus: PaneStatus
    private var rightPaneStatus: PaneStatus
    private var leftPaneStatusContextText: String?
    private var rightPaneStatusContextText: String?
    private var actionFeedbackEnabled: Bool
    private var leftPaneFileIconSize: CGFloat
    private var rightPaneFileIconSize: CGFloat
    private var starEffectsEnabled = true
    var currentFilerTheme: FilerTheme = .system
    private var animationEffectSettings = AnimationEffectSettings.allEnabled
    let initialSidebarWidth: CGFloat
    var hasAppliedInitialSidebarWidth = false
    var lastReportedSidebarWidth: CGFloat
    var isAdjustingSplitLayout = false
    private let toastPresenter = ActionToastPresenter()
    private let globalActionRouter = GlobalActionRouter()
    private let applicationRelatedItemLocator: any ApplicationRelatedItemLocating = ApplicationRelatedItemLocatorService()
    var goToPathPopover: NSPopover?
    weak var goToPathHighlightView: NSView?
    var shouldRefocusAfterGoToPathDismiss = true
    private lazy var previewPopupPanelController: PreviewPopupPanelController = {
        let controller = PreviewPopupPanelController(previewViewController: previewPopupPaneViewController)
        controller.onDismiss = { [weak self] in
            guard let self else {
                return
            }
            self.viewModel.previewVisible = false
            self.focusActivePane()
        }
        controller.onSelectionStepRequested = { [weak self] step in
            self?.handlePreviewSelectionStep(step) ?? false
        }
        return controller
    }()

    var onStatusChanged: ((String, Int, Int) -> Void)?
    var onStatusContextTextChanged: ((String?) -> Void)?
    var onSpotlightSearchScopeChanged: ((SpotlightSearchScope) -> Void)?
    var onPaneVisibilityChanged: ((Bool, Bool) -> Void)?
    var onSidebarWidthChanged: ((CGFloat) -> Void)?
    var onFileIconSizeChanged: ((PaneSide, CGFloat) -> Void)?
    var onTerminalAction: ((KeyAction) -> Void)?

    init(
        viewModel: MainViewModel,
        configManager: ConfigManager,
        actionFeedbackEnabled: Bool,
        leftPaneFileIconSize: CGFloat,
        rightPaneFileIconSize: CGFloat,
        initialSidebarWidth: CGFloat = MainSplitViewController.defaultSidebarWidth,
        initialLeftPaneVisible: Bool = true,
        initialRightPaneVisible: Bool = true
    ) {
        let clampedSidebarWidth = Self.clampedSidebarWidth(initialSidebarWidth)
        self.viewModel = viewModel
        self.configManager = configManager
        self.actionFeedbackEnabled = actionFeedbackEnabled
        self.leftPaneFileIconSize = min(max(leftPaneFileIconSize, 12), 40)
        self.rightPaneFileIconSize = min(max(rightPaneFileIconSize, 12), 40)
        self.initialSidebarWidth = clampedSidebarWidth
        self.lastReportedSidebarWidth = clampedSidebarWidth

        self.sidebarViewModel = SidebarViewModel(
            configManager: configManager,
            visitHistoryService: viewModel.visitHistoryService,
            pinnedItemsService: viewModel.pinnedItemsService
        )
        self.sidebarViewController = SidebarViewController(viewModel: sidebarViewModel)
        self.sidebarSplitItem = NSSplitViewItem(viewController: sidebarViewController)

        self.leftPaneViewController = FilePaneViewController(viewModel: viewModel.leftPane)
        self.rightPaneViewController = FilePaneViewController(viewModel: viewModel.rightPane)
        self.leftSplitItem = NSSplitViewItem(viewController: leftPaneViewController)
        self.rightSplitItem = NSSplitViewItem(viewController: rightPaneViewController)
        self.previewPopupPaneViewController = PreviewPaneViewController(viewModel: viewModel.previewPane)
        self.bookmarksConfig = configManager.loadBookmarksConfig()

        self.leftPaneStatus = PaneStatus(
            path: viewModel.leftPane.paneState.currentDirectory.path,
            itemCount: viewModel.leftPane.directoryContents.displayedItems.count,
            markedCount: viewModel.leftPane.markedCount
        )
        self.rightPaneStatus = PaneStatus(
            path: viewModel.rightPane.paneState.currentDirectory.path,
            itemCount: viewModel.rightPane.directoryContents.displayedItems.count,
            markedCount: viewModel.rightPane.markedCount
        )

        super.init(nibName: nil, bundle: nil)
        splitView = BorderlessSplitView()

        viewModel.requestTextInput = { [weak self] prompt in
            self?.presentTextPrompt(prompt)
        }
        viewModel.onFileOperationCompleted = { [weak self] record, context in
            self?.handleFileOperationCompleted(record, context: context)
        }
        viewModel.onFileOperationFailed = { [weak self] message in
            self?.presentErrorAlert(
                title: "File operation failed",
                informativeText: message
            )
        }
        viewModel.resolveFileOperationFailure = { [weak self] context in
            guard let self else {
                return FileOperationFailureDecision(action: .abort, applyToRemaining: true)
            }
            return self.presentFileOperationFailureDecision(for: context)
        }

        configureSplitView()
        bindPaneControllers()
        bindSidebar()
        bindVisitHistory()
        refreshActivePaneUI(focusActivePane: false)
        viewModel.refreshPreviewForActivePane()
        applySidebarVisibility(animated: false)
        applyPaneVisibility(leftVisible: initialLeftPaneVisible, rightVisible: initialRightPaneVisible, animated: false)
        applyPreviewPaneVisibility(animated: false)

        propagateBookmarksConfig()
        setSpotlightSearchScope(viewModel.leftPane.spotlightSearchScope)
        setFileIconSize(self.leftPaneFileIconSize, for: .left)
        setFileIconSize(self.rightPaneFileIconSize, for: .right)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.setAccessibilityIdentifier("mainSplit.container")
        splitView.setAccessibilityIdentifier("mainSplit.splitView")
        sidebarViewController.view.setAccessibilityIdentifier("mainSplit.sidebar")
        leftPaneViewController.view.setAccessibilityIdentifier("mainSplit.leftPane")
        rightPaneViewController.view.setAccessibilityIdentifier("mainSplit.rightPane")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialSidebarWidthIfNeeded()
        adjustSplitLayoutIfNeeded()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        adjustSplitLayoutIfNeeded()
        reportSidebarWidthIfNeeded(force: false)
    }

    func focusActivePane() {
        paneViewController(for: viewModel.activePaneSide).focusTable()
    }

    func openSelectedItemInActivePane() {
        paneViewController(for: viewModel.activePaneSide).openSelectedItem()
    }

    func togglePreviewPane() {
        if previewPopupPanelController.isVisible {
            previewPopupPanelController.dismiss()
            return
        }

        guard isPreviewableSelectionAvailableForActivePane() else {
            NSSound.beep()
            return
        }

        viewModel.previewVisible = true
        applyPreviewPaneVisibility(animated: false)
    }

    func toggleSidebarPane() {
        viewModel.toggleSidebar()
        applySidebarVisibility(animated: false)
    }

    func toggleLeftPane() {
        togglePaneVisibility(side: .left, animated: true)
    }

    func toggleRightPane() {
        togglePaneVisibility(side: .right, animated: true)
    }

    func toggleSinglePane() {
        let leftVisible = !leftSplitItem.isCollapsed
        let rightVisible = !rightSplitItem.isCollapsed

        if leftVisible && rightVisible {
            switch viewModel.activePaneSide {
            case .left:
                applyPaneVisibility(leftVisible: true, rightVisible: false, animated: true)
            case .right:
                applyPaneVisibility(leftVisible: false, rightVisible: true, animated: true)
            }
            return
        }

        applyPaneVisibility(leftVisible: true, rightVisible: true, animated: true)
    }

    func equalizePaneWidths() {
        guard !leftSplitItem.isCollapsed, !rightSplitItem.isCollapsed else {
            return
        }

        view.layoutSubtreeIfNeeded()
        let arrangedSubviews = splitView.arrangedSubviews
        guard let leftIndex = arrangedSubviewIndex(for: leftPaneViewController.view, in: arrangedSubviews),
              let rightIndex = arrangedSubviewIndex(for: rightPaneViewController.view, in: arrangedSubviews),
              rightIndex == leftIndex + 1 else {
            return
        }

        let leftMinX = arrangedSubviews[leftIndex].frame.minX
        let rightMaxX = arrangedSubviews[rightIndex].frame.maxX
        let availableWidth = rightMaxX - leftMinX - splitView.dividerThickness
        guard availableWidth > 0 else {
            return
        }

        let targetDividerPosition = leftMinX + (availableWidth / 2)
        splitView.setPosition(targetDividerPosition, ofDividerAt: leftIndex)
    }

    func arrangedSubviewIndex(for paneView: NSView, in arrangedSubviews: [NSView]) -> Int? {
        arrangedSubviews.firstIndex { arrangedSubview in
            paneView === arrangedSubview || paneView.isDescendant(of: arrangedSubview)
        }
    }

    func setFilerTheme(_ theme: FilerTheme, backgroundOpacity: CGFloat = 1.0) {
        currentFilerTheme = theme
        let palette = theme.palette
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = palette.windowBackgroundColor.applyingBackgroundOpacity(backgroundOpacity).cgColor

        toastPresenter.palette = palette
        leftPaneViewController.applyTheme(theme, backgroundOpacity: backgroundOpacity)
        rightPaneViewController.applyTheme(theme, backgroundOpacity: backgroundOpacity)
        sidebarViewController.applyTheme(theme, backgroundOpacity: backgroundOpacity)
        previewPopupPaneViewController.applyTheme(theme, backgroundOpacity: backgroundOpacity)
    }

    func reloadBookmarksConfig() {
        bookmarksConfig = configManager.loadBookmarksConfig()
        propagateBookmarksConfig()
        sidebarViewModel.reloadSections()
    }

    func reloadSidebarSections() {
        sidebarViewModel.reloadSections()
    }

    func reloadKeybindings() {
        leftPaneViewController.reloadKeybindings()
        rightPaneViewController.reloadKeybindings()
    }

    func requestDeleteFromActivePane() {
        let selectedURLs = viewModel.activePane.markedOrSelectedURLs()
            .map(\.standardizedFileURL)
        guard !selectedURLs.isEmpty else {
            return
        }

        let appBundleURLs = selectedURLs.filter(Self.isApplicationBundleUnderApplications)

        guard !appBundleURLs.isEmpty else {
            viewModel.delete(urls: selectedURLs)
            return
        }

        presentApplicationDeletionDialog(selectedURLs: selectedURLs, appBundleURLs: appBundleURLs)
    }

    func popoverDidClose(_ notification: Notification) {
        handlePopoverDidClose(refocusActivePane: shouldRefocusAfterGoToPathDismiss)
    }

    func embedWindowControlButtons(_ buttons: [NSButton]) {
        sidebarViewController.embedWindowControlButtons(buttons)
    }

    func setActionFeedbackEnabled(_ enabled: Bool) {
        actionFeedbackEnabled = enabled
    }

    func setStarEffectsEnabled(_ enabled: Bool) {
        starEffectsEnabled = enabled
        toastPresenter.starEffectsEnabled = enabled
        leftPaneViewController.setStarEffectsEnabled(enabled)
        rightPaneViewController.setStarEffectsEnabled(enabled)
        previewPopupPaneViewController.setStarEffectsEnabled(enabled)
    }

    func setAnimationEffectSettings(_ settings: AnimationEffectSettings) {
        animationEffectSettings = settings
        leftPaneViewController.setAnimationEffectSettings(settings)
        rightPaneViewController.setAnimationEffectSettings(settings)
        previewPopupPaneViewController.setAnimationEffectSettings(settings)
    }

    func setShortcutGuideEnabled(_ enabled: Bool) {
        leftPaneViewController.setShortcutGuideEnabled(enabled)
        rightPaneViewController.setShortcutGuideEnabled(enabled)
    }

    func setSpotlightSearchScope(_ scope: SpotlightSearchScope) {
        viewModel.setSpotlightSearchScope(scope)
        leftPaneViewController.setSpotlightSearchScope(scope)
        rightPaneViewController.setSpotlightSearchScope(scope)
    }

    func setFileIconSize(_ size: CGFloat) {
        let clampedSize = min(max(size, 12), 40)
        leftPaneFileIconSize = clampedSize
        rightPaneFileIconSize = clampedSize
        leftPaneViewController.setFileIconSize(clampedSize)
        rightPaneViewController.setFileIconSize(clampedSize)
    }

    func setFileIconSize(_ size: CGFloat, for side: PaneSide) {
        let clampedSize = min(max(size, 12), 40)
        switch side {
        case .left:
            leftPaneFileIconSize = clampedSize
            leftPaneViewController.setFileIconSize(clampedSize)
        case .right:
            rightPaneFileIconSize = clampedSize
            rightPaneViewController.setFileIconSize(clampedSize)
        }
    }

    func currentSidebarWidth() -> CGFloat {
        if sidebarSplitItem.isCollapsed {
            return lastReportedSidebarWidth
        }

        return Self.clampedSidebarWidth(sidebarViewController.view.frame.width)
    }

    private func configureSplitView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MainSplitViewV2"
        splitView.delegate = self

        sidebarSplitItem.minimumThickness = Self.sidebarWidthRange.lowerBound
        sidebarSplitItem.maximumThickness = Self.sidebarWidthRange.upperBound
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.titlebarSeparatorStyle = .none
        addSplitViewItem(sidebarSplitItem)

        leftSplitItem.minimumThickness = 280
        leftSplitItem.canCollapse = true
        leftSplitItem.titlebarSeparatorStyle = .none
        addSplitViewItem(leftSplitItem)

        rightSplitItem.minimumThickness = 280
        rightSplitItem.canCollapse = true
        rightSplitItem.titlebarSeparatorStyle = .none
        addSplitViewItem(rightSplitItem)
    }

    private func bindPaneControllers() {
        bindPaneCallbacks(for: leftPaneViewController, side: .left)
        bindPaneCallbacks(for: rightPaneViewController, side: .right)
        bindPreviewPaneCallbacks(for: previewPopupPaneViewController)
    }

    private func bindPreviewPaneCallbacks(for previewPaneViewController: PreviewPaneViewController) {
        previewPaneViewController.onImageSelectionChanged = { [weak self] selectedURL in
            self?.viewModel.previewPane.setSelectedFileURL(selectedURL)
        }

        previewPaneViewController.onNavigateRequested = { [weak self] destination in
            self?.viewModel.activePane.navigate(to: destination)
        }
    }

    private func bindPaneCallbacks(for pane: FilePaneViewController, side: PaneSide) {
        pane.onTabPressed = { [weak self] in
            self?.handleTabSwitch() ?? false
        }
        pane.onDidRequestActivate = { [weak self] in
            self?.setActivePane(side)
        }
        pane.onSelectionChanged = { [weak self] _ in
            self?.viewModel.updatePreviewSelection(for: side)
        }
        pane.onDisplayedItemsChanged = { [weak self] in
            guard let self, self.viewModel.activePaneSide == side else {
                return
            }
            self.viewModel.refreshPreviewForActivePane()
        }
        pane.onStatusContextTextChanged = { [weak self] text in
            self?.updatePaneStatusContext(side: side, text: text)
        }
        pane.onStatusChanged = { [weak self] path, itemCount, markedCount in
            self?.updatePaneStatus(side: side, path: path, itemCount: itemCount, markedCount: markedCount)
        }
        pane.onFileOperationRequested = { [weak self] action in
            guard let self else {
                return false
            }
            self.setActivePane(side)
            return self.handleGlobalAction(action)
        }
        pane.onBookmarkJump = { [weak self] path in
            self?.navigateToSearchResult(BookmarkSearchViewModel.SearchResult(
                groupName: "", displayName: "", path: path, shortcutHint: nil
            ))
        }
        pane.onDirectoryLoadFailed = { [weak self] directory, error in
            self?.presentNavigationErrorAlert(for: directory, error: error)
        }
        pane.onDropOperationCompleted = { [weak self] operation, itemCount in
            self?.handleDropOperationCompleted(operation: operation, itemCount: itemCount)
        }
        pane.onDropFileOperationRequested = { [weak self] operation in
            guard let self else {
                return
            }

            await MainActor.run {
                self.setActivePane(side)
            }
            _ = try await self.viewModel.executeExternalFileOperation(operation)
        }
        pane.onSpotlightSearchScopeChanged = { [weak self] scope in
            self?.handleSpotlightSearchScopeChanged(scope)
        }
        pane.onFileIconSizeChanged = { [weak self] size in
            self?.handleFileIconSizeChanged(size, side: side)
        }
        pane.onMarkdownPreviewRequested = { [weak self] urls in
            self?.presentMarkdownPreviews(for: urls)
        }
    }

    private func bindSidebar() {
        sidebarViewController.onNavigateRequested = { [weak self] url in
            self?.navigateActivePane(to: url)
        }
        sidebarViewController.onNavigateAndRevealRequested = { [weak self] directory, itemURL in
            self?.navigateActivePane(to: directory, selecting: itemURL)
        }
        sidebarViewController.onNavigationFailed = { [weak self] message in
            self?.presentErrorAlert(
                title: "Failed to open path",
                informativeText: message
            )
        }
        sidebarViewController.onHistoryJumpRequested = { [weak self] position in
            self?.viewModel.activePane.jumpToHistoryPosition(position)
        }
        sidebarViewController.onBookmarkContextActionRequested = { [weak self] action, sectionKind, entry in
            switch action {
            case .editBookmark:
                self?.presentSidebarBookmarkEditor(for: entry, sectionKind: sectionKind)
            case .deleteBookmark:
                self?.deleteSidebarBookmark(entry, sectionKind: sectionKind)
            case .unpinPinnedItem:
                self?.sidebarViewModel.removePinnedEntry(entry)
                self?.showActionToast("Unpinned \"\(entry.displayName)\"")
            }
        }
    }

    private func handleTabSwitch() -> Bool {
        viewModel.switchActivePane()
        refreshActivePaneUI(focusActivePane: true)
        return true
    }

    func setActivePane(_ side: PaneSide) {
        guard viewModel.activePaneSide != side else {
            return
        }

        viewModel.setActivePane(side)
        refreshActivePaneUI(focusActivePane: false)
    }

    private func handleGlobalAction(_ action: KeyAction) -> Bool {
        let handlers = GlobalActionRouter.Handlers(
            copy: { self.viewModel.copyMarked() },
            copyToClipboard: { self.triggerSystemClipboardAction(Selector(("copy:"))) },
            paste: { self.viewModel.paste() },
            pasteFromClipboard: { self.triggerSystemClipboardAction(Selector(("paste:"))) },
            move: { self.viewModel.cutMarked() },
            cutToClipboard: { self.triggerSystemClipboardAction(Selector(("cut:"))) },
            delete: { self.requestDeleteFromActivePane() },
            rename: { self.viewModel.rename() },
            createDirectory: { self.viewModel.createDirectory() },
            undo: { self.viewModel.undo() },
            togglePreview: { self.togglePreviewPane() },
            toggleSidebar: { self.toggleSidebarPane() },
            toggleLeftPane: { self.toggleLeftPane() },
            toggleRightPane: { self.toggleRightPane() },
            toggleSinglePane: { self.toggleSinglePane() },
            equalizePaneWidths: { self.equalizePaneWidths() },
            matchOtherPaneDirectory: { self.viewModel.matchOtherPaneDirectoryToActivePane() },
            goToOtherPaneDirectory: { self.viewModel.moveActivePaneToOtherPaneDirectory() },
            openBookmarkSearch: { self.presentBookmarkSearchPanel() },
            openHistory: { self.presentBookmarkSearchPanel() },
            addBookmark: { self.presentAddBookmarkAlert() },
            batchRename: { self.presentBatchRenameWindow() },
            syncPanesLeftToRight: { self.viewModel.syncPanesLeftToRight() },
            syncPanesRightToLeft: { self.viewModel.syncPanesRightToLeft() },
            togglePin: {
                let wasPinned = self.viewModel.isPinnedActiveItem()
                self.viewModel.togglePinForActivePane()
                self.sidebarViewModel.reloadSections()
                return wasPinned ? "Unpinned" : "Pinned"
            },
            terminalAction: { self.onTerminalAction?($0) }
        )

        switch globalActionRouter.route(action, handlers: handlers) {
        case .handled:
            return true
        case .handledWithToast(let message):
            showActionToast(message)
            return true
        case .unhandled:
            return false
        }
    }

    private struct DeletionChecklistRow {
        let url: URL
        let title: String
    }

    private func presentApplicationDeletionDialog(selectedURLs: [URL], appBundleURLs: [URL]) {
        let relatedItems = applicationRelatedItemLocator.relatedItems(forApplicationsAt: appBundleURLs)

        var rows: [DeletionChecklistRow] = []
        var seenPaths: Set<String> = []

        for url in selectedURLs {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else {
                continue
            }
            let prefix = Self.isApplicationBundleUnderApplications(url) ? "App" : "Selected"
            rows.append(
                DeletionChecklistRow(
                    url: url,
                    title: "[\(prefix)] \(url.lastPathComponent)  (\(path))"
                )
            )
        }

        for related in relatedItems {
            let normalizedURL = related.url.standardizedFileURL
            let path = normalizedURL.path
            guard seenPaths.insert(path).inserted else {
                continue
            }

            let appName = related.appURL.deletingPathExtension().lastPathComponent
            rows.append(
                DeletionChecklistRow(
                    url: normalizedURL,
                    title: "[\(related.category): \(appName)] \(path)"
                )
            )
        }

        guard !rows.isEmpty else {
            viewModel.delete(urls: selectedURLs)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete app and related files?"
        alert.informativeText = "Checked items will be moved to Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let accessory = makeDeletionChecklistAccessory(rows: rows)
        alert.accessoryView = accessory.container

        guard alert.runModal() == .alertFirstButtonReturn else {
            focusActivePane()
            return
        }

        let urlsToDelete = accessory.selections.compactMap { selection in
            selection.checkbox.state == .on ? selection.url : nil
        }

        guard !urlsToDelete.isEmpty else {
            focusActivePane()
            return
        }

        viewModel.delete(urls: urlsToDelete)
    }

    private func makeDeletionChecklistAccessory(
        rows: [DeletionChecklistRow]
    ) -> (container: NSView, selections: [(checkbox: NSButton, url: URL)]) {
        var selections: [(checkbox: NSButton, url: URL)] = []
        let contentWidth = CGFloat(620)
        let rowHeight = CGFloat(24)
        let contentHeight = CGFloat(rows.count) * rowHeight
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: max(contentHeight, rowHeight)))

        var y = documentView.frame.height - rowHeight
        for row in rows {
            let checkbox = NSButton(checkboxWithTitle: row.title, target: nil, action: nil)
            checkbox.state = .on
            checkbox.font = .systemFont(ofSize: 12)
            checkbox.lineBreakMode = .byTruncatingMiddle
            checkbox.frame = NSRect(x: 8, y: y, width: contentWidth - 16, height: rowHeight)
            documentView.addSubview(checkbox)
            selections.append((checkbox: checkbox, url: row.url))
            y -= rowHeight
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.documentView = documentView

        let visibleRowCount = min(max(rows.count, 1), 12)
        let height = CGFloat(visibleRowCount) * rowHeight + 10

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: height))
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: 640),
            scrollView.heightAnchor.constraint(equalToConstant: height)
        ])

        return (container: container, selections: selections)
    }

    private static func isApplicationBundleUnderApplications(_ url: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL
        return normalizedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && normalizedURL.path.hasPrefix("/Applications/")
    }

    private func handleFileOperationCompleted(_ record: FileOperationRecord, context: FileOperationCompletionContext) {
        let message: String?
        switch context {
        case .undo:
            message = "Action undone"
        case .normal:
            message = actionMessage(for: record.result)
        }

        guard let message else {
            return
        }

        showActionToast(message)
    }

    private func handleDropOperationCompleted(operation: NSDragOperation, itemCount: Int) {
        guard itemCount > 0 else {
            return
        }

        let message: String
        switch operation {
        case .move:
            message = "\(itemCount) \(itemLabel(for: itemCount)) moved"
        default:
            message = "\(itemCount) \(itemLabel(for: itemCount)) copied"
        }
        showActionToast(message)
    }

    private func handleSpotlightSearchScopeChanged(_ scope: SpotlightSearchScope) {
        setSpotlightSearchScope(scope)
        onSpotlightSearchScopeChanged?(scope)
    }

    private func handleFileIconSizeChanged(_ size: CGFloat, side: PaneSide) {
        let clampedSize = min(max(size, 12), 40)
        setFileIconSize(clampedSize, for: side)
        onFileIconSizeChanged?(side, clampedSize)
    }

    private func actionMessage(for result: FileOperationResult) -> String? {
        switch result {
        case .copied(let changes):
            guard !changes.isEmpty else { return nil }
            return "\(changes.count) \(itemLabel(for: changes.count)) copied"
        case .moved(let changes):
            guard !changes.isEmpty else { return nil }
            return "\(changes.count) \(itemLabel(for: changes.count)) moved"
        case .trashed(let changes):
            guard !changes.isEmpty else { return nil }
            return "\(changes.count) \(itemLabel(for: changes.count)) moved to Trash"
        case .renamed(let change):
            guard change.source != change.destination else { return nil }
            return "Renamed to \"\(change.destination.lastPathComponent)\""
        case .createdDirectory(let url):
            return "Created folder \"\(url.lastPathComponent)\""
        case .batchRenamed(let changes):
            guard !changes.isEmpty else { return nil }
            return "\(changes.count) \(itemLabel(for: changes.count)) renamed"
        }
    }

    private func itemLabel(for count: Int) -> String {
        count == 1 ? "item" : "items"
    }

    private func triggerSystemClipboardAction(_ selector: Selector) {
        guard NSApp.sendAction(selector, to: nil, from: nil) else {
            NSSound.beep()
            return
        }
    }

    private func presentFileOperationFailureDecision(
        for context: FileOperationFailureContext
    ) -> FileOperationFailureDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = fileOperationFailureTitle(for: context.operationType)

        var lines: [String] = [
            "Source: \(context.sourceURL.path)"
        ]
        if let destinationURL = context.destinationURL {
            lines.append("Destination: \(destinationURL.path)")
        }
        lines.append("")
        lines.append(context.message)
        alert.informativeText = lines.joined(separator: "\n")

        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Abort")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply Skip/Abort to remaining failures"

        let response = alert.runModal()
        let action: FileOperationFailureAction
        switch response {
        case .alertFirstButtonReturn:
            action = .retry
        case .alertSecondButtonReturn:
            action = .skip
        default:
            action = .abort
        }

        let applyToRemaining = (alert.suppressionButton?.state == .on)
            && (action == .skip || action == .abort)
        return FileOperationFailureDecision(
            action: action,
            applyToRemaining: applyToRemaining
        )
    }

    private func fileOperationFailureTitle(for operationType: FileOperationType) -> String {
        switch operationType {
        case .copy:
            return "Copy failed"
        case .move:
            return "Move failed"
        case .trash:
            return "Delete failed"
        case .rename:
            return "Rename failed"
        case .createDirectory:
            return "Create folder failed"
        case .batchRename:
            return "Batch rename failed"
        }
    }

    func showActionToast(_ message: String) {
        guard actionFeedbackEnabled else {
            return
        }

        toastPresenter.show(message: message, in: view)
    }

    private func refreshActivePaneUI(focusActivePane shouldFocus: Bool) {
        leftPaneViewController.setActive(viewModel.activePaneSide == .left)
        rightPaneViewController.setActive(viewModel.activePaneSide == .right)

        if shouldFocus {
            focusActivePane()
        }

        publishActivePaneStatus()
        publishActivePaneStatusContext()
        updateSidebarNavigationHistory()
    }

    private func applyPreviewPaneVisibility(animated: Bool) {
        _ = animated

        guard viewModel.previewVisible else {
            if previewPopupPanelController.isVisible {
                previewPopupPanelController.dismiss()
            }
            return
        }

        guard let window = view.window else {
            return
        }

        previewPopupPanelController.show(
            relativeTo: window,
            preferredAnchorFrame: previewAnchorFrameInScreen(for: viewModel.activePaneSide)
        )
    }

    private func isPreviewableSelectionAvailableForActivePane() -> Bool {
        guard let selectedItem = viewModel.activePane.selectedItem else {
            return false
        }

        if selectedItem.isDirectory && !selectedItem.isPackage {
            return false
        }

        return selectedItem.url.isImageFile
    }

    private func handlePreviewSelectionStep(_ step: PreviewSelectionStep) -> Bool {
        let pane = viewModel.activePane
        guard !pane.directoryContents.displayedItems.isEmpty else {
            return true
        }

        switch step {
        case .previous:
            pane.moveCursorUp()
        case .next:
            pane.moveCursorDown()
        }
        return true
    }

    private func previewAnchorFrameInScreen(for activePaneSide: PaneSide) -> NSRect? {
        guard let window = view.window else {
            return nil
        }

        let oppositeSide: PaneSide = activePaneSide == .left ? .right : .left
        if let frame = paneFrameInScreen(for: oppositeSide, in: window) {
            return frame
        }
        return paneFrameInScreen(for: activePaneSide, in: window)
    }

    private func paneFrameInScreen(for side: PaneSide, in window: NSWindow) -> NSRect? {
        let isVisible: Bool
        switch side {
        case .left:
            isVisible = !leftSplitItem.isCollapsed
        case .right:
            isVisible = !rightSplitItem.isCollapsed
        }

        guard isVisible else {
            return nil
        }

        let paneView = paneViewController(for: side).view
        guard paneView.window === window else {
            return nil
        }

        let paneRectInWindow = paneView.convert(paneView.bounds, to: nil)
        let paneRectInScreen = window.convertToScreen(paneRectInWindow)
        guard paneRectInScreen.width > 1, paneRectInScreen.height > 1 else {
            return nil
        }

        return paneRectInScreen
    }

    private func updatePaneStatus(side: PaneSide, path: String, itemCount: Int, markedCount: Int) {
        let status = PaneStatus(path: path, itemCount: itemCount, markedCount: markedCount)

        switch side {
        case .left:
            leftPaneStatus = status
        case .right:
            rightPaneStatus = status
        }

        if side == viewModel.activePaneSide {
            publishActivePaneStatus()
        }
    }

    private func updatePaneStatusContext(side: PaneSide, text: String?) {
        switch side {
        case .left:
            leftPaneStatusContextText = text
        case .right:
            rightPaneStatusContextText = text
        }

        if side == viewModel.activePaneSide {
            publishActivePaneStatusContext()
        }
    }

    private func publishActivePaneStatus() {
        let status: PaneStatus

        switch viewModel.activePaneSide {
        case .left:
            status = leftPaneStatus
        case .right:
            status = rightPaneStatus
        }

        onStatusChanged?(status.path, status.itemCount, status.markedCount)
    }

    private func publishActivePaneStatusContext() {
        let statusContextText: String?

        switch viewModel.activePaneSide {
        case .left:
            statusContextText = leftPaneStatusContextText
        case .right:
            statusContextText = rightPaneStatusContextText
        }

        onStatusContextTextChanged?(statusContextText)
    }

    func paneViewController(for side: PaneSide) -> FilePaneViewController {
        switch side {
        case .left:
            return leftPaneViewController
        case .right:
            return rightPaneViewController
        }
    }

    private func presentTextPrompt(_ prompt: TextInputPrompt) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(string: prompt.defaultValue ?? "")
        inputField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = inputField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        return inputField.stringValue
    }

    private func bindVisitHistory() {
        viewModel.leftPane.onDirectoryChanged = { [weak self] url in
            self?.viewModel.visitHistoryService.recordVisit(to: url)
            self?.sidebarViewModel.reloadSections()
            self?.updateSidebarNavigationHistory()
        }
        viewModel.rightPane.onDirectoryChanged = { [weak self] url in
            self?.viewModel.visitHistoryService.recordVisit(to: url)
            self?.sidebarViewModel.reloadSections()
            self?.updateSidebarNavigationHistory()
        }
    }

    private func updateSidebarNavigationHistory() {
        let activePane = viewModel.activePane
        let history = activePane.navigationHistory
        sidebarViewModel.updateNavigationHistory(
            backStack: history.backStack,
            currentURL: activePane.paneState.currentDirectory,
            forwardStack: history.forwardStack,
            paneSide: viewModel.activePaneSide
        )
    }

}
