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
    private static let sidebarWidthRange: ClosedRange<CGFloat> = CGFloat(AppConfig.sidebarWidthRange.lowerBound) ... CGFloat(AppConfig.sidebarWidthRange.upperBound)
    private static var lastSelectedBookmarkGroupIndex: Int = 0

    private struct PaneStatus {
        var path: String
        var itemCount: Int
        var markedCount: Int
    }

    private struct SidebarBookmarkEditResult {
        let groupName: String
        let displayName: String
        let path: String
        let shortcutKey: String?
    }

    private let viewModel: MainViewModel
    private let configManager: ConfigManager
    private let sidebarViewModel: SidebarViewModel
    private let sidebarViewController: SidebarViewController
    private let sidebarSplitItem: NSSplitViewItem
    private let leftPaneViewController: FilePaneViewController
    private let rightPaneViewController: FilePaneViewController
    private let leftSplitItem: NSSplitViewItem
    private let rightSplitItem: NSSplitViewItem
    private let previewPopupPaneViewController: PreviewPaneViewController

    private var bookmarksConfig: BookmarksConfig
    private var bookmarkSearchPanelController: BookmarkSearchPanelController?
    private var markdownPreviewPanelControllers: [URL: MarkdownPreviewPanelController] = [:]
    private var batchRenameWindowController: NSWindowController?


    private var leftPaneStatus: PaneStatus
    private var rightPaneStatus: PaneStatus
    private var leftPaneStatusContextText: String?
    private var rightPaneStatusContextText: String?
    private var actionFeedbackEnabled: Bool
    private var leftPaneFileIconSize: CGFloat
    private var rightPaneFileIconSize: CGFloat
    private var starEffectsEnabled = true
    private var currentFilerTheme: FilerTheme = .system
    private var animationEffectSettings = AnimationEffectSettings.allEnabled
    private let initialSidebarWidth: CGFloat
    private var hasAppliedInitialSidebarWidth = false
    private var lastReportedSidebarWidth: CGFloat
    private var isAdjustingSplitLayout = false
    private let toastPresenter = ActionToastPresenter()
    private let globalActionRouter = GlobalActionRouter()
    private let applicationRelatedItemLocator: any ApplicationRelatedItemLocating = ApplicationRelatedItemLocatorService()
    private var goToPathPopover: NSPopover?
    private weak var goToPathHighlightView: NSView?
    private var shouldRefocusAfterGoToPathDismiss = true
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

    private func arrangedSubviewIndex(for paneView: NSView, in arrangedSubviews: [NSView]) -> Int? {
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

    func presentGoToPathPrompt() {
        let activePaneSide = viewModel.activePaneSide
        let currentPath = viewModel.activePane.paneState.currentDirectory.path
        let paneView = paneViewController(for: activePaneSide).view
        let accentColor = goToPathAccentColor(for: activePaneSide)

        dismissGoToPathPopover(refocusActivePane: false)

        var popoverContentController: GoToPathPopoverViewController?
        let contentController = GoToPathPopoverViewController(
            currentPath: currentPath,
            accentColor: accentColor,
            onSubmit: { [weak self] rawInput in
                guard let self else {
                    return
                }

                let trimmedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedInput.isEmpty else {
                    popoverContentController?.showValidationError("Enter a path")
                    return
                }

                guard let destination = self.resolveNavigationDestination(from: trimmedInput) else {
                    popoverContentController?.showValidationError("Path not found")
                    return
                }

                self.dismissGoToPathPopover(refocusActivePane: true)
                self.navigateActivePane(to: destination)
            },
            onCancel: { [weak self] in
                self?.dismissGoToPathPopover(refocusActivePane: true)
            }
        )
        popoverContentController = contentController

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = contentController

        showGoToPathHighlight(on: paneView, accentColor: accentColor)

        let anchorRect = NSRect(x: paneView.bounds.midX - 1, y: paneView.bounds.height - 28, width: 2, height: 2)
        popover.show(relativeTo: anchorRect, of: paneView, preferredEdge: .minY)
        contentController.focusInputField()
        goToPathPopover = popover
    }

    func popoverDidClose(_ notification: Notification) {
        clearGoToPathPresentation(refocusActivePane: shouldRefocusAfterGoToPathDismiss)
        shouldRefocusAfterGoToPathDismiss = true
    }

    private func dismissGoToPathPopover(refocusActivePane: Bool) {
        shouldRefocusAfterGoToPathDismiss = refocusActivePane

        guard let popover = goToPathPopover else {
            clearGoToPathPresentation(refocusActivePane: refocusActivePane)
            return
        }

        popover.performClose(nil)
    }

    private func clearGoToPathPresentation(refocusActivePane: Bool) {
        goToPathPopover?.delegate = nil
        goToPathPopover = nil
        goToPathHighlightView?.removeFromSuperview()
        goToPathHighlightView = nil

        if refocusActivePane {
            focusActivePane()
        }
    }

    private func goToPathAccentColor(for side: PaneSide) -> NSColor {
        switch side {
        case .left:
            return .systemBlue
        case .right:
            return .systemOrange
        }
    }

    private func showGoToPathHighlight(on paneView: NSView, accentColor: NSColor) {
        goToPathHighlightView?.removeFromSuperview()

        let overlay = PaneHighlightOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.borderWidth = 3
        overlay.layer?.cornerRadius = 8
        overlay.layer?.borderColor = accentColor.withAlphaComponent(0.85).cgColor
        overlay.layer?.backgroundColor = accentColor.withAlphaComponent(0.08).cgColor

        paneView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: paneView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: paneView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: paneView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: paneView.bottomAnchor)
        ])

        goToPathHighlightView = overlay
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

    private func setActivePane(_ side: PaneSide) {
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

    private func showActionToast(_ message: String) {
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

    private func applySidebarVisibility(animated: Bool) {
        let shouldCollapse = !viewModel.sidebarVisible
        guard sidebarSplitItem.isCollapsed != shouldCollapse else {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                sidebarSplitItem.animator().isCollapsed = shouldCollapse
            }, completionHandler: { [weak self] in
                self?.restoreSidebarWidthIfNeeded()
                self?.reportSidebarWidthIfNeeded(force: true)
            })
        } else {
            sidebarSplitItem.isCollapsed = shouldCollapse
            restoreSidebarWidthIfNeeded()
            reportSidebarWidthIfNeeded(force: true)
        }
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

    private func applyPaneVisibility(leftVisible: Bool, rightVisible: Bool, animated: Bool) {
        let normalizedLeftVisible: Bool
        let normalizedRightVisible: Bool
        if !leftVisible, !rightVisible {
            normalizedLeftVisible = true
            normalizedRightVisible = false
        } else {
            normalizedLeftVisible = leftVisible
            normalizedRightVisible = rightVisible
        }

        setPaneVisibility(splitItem: leftSplitItem, visible: normalizedLeftVisible, animated: animated)
        setPaneVisibility(splitItem: rightSplitItem, visible: normalizedRightVisible, animated: animated)

        if !normalizedLeftVisible, viewModel.activePaneSide == .left {
            setActivePane(.right)
        } else if !normalizedRightVisible, viewModel.activePaneSide == .right {
            setActivePane(.left)
        }

        onPaneVisibilityChanged?(normalizedLeftVisible, normalizedRightVisible)
    }

    private func togglePaneVisibility(side: PaneSide, animated: Bool) {
        let leftVisible = !leftSplitItem.isCollapsed
        let rightVisible = !rightSplitItem.isCollapsed
        switch side {
        case .left:
            if leftVisible, !rightVisible {
                return
            }
            applyPaneVisibility(leftVisible: !leftVisible, rightVisible: rightVisible, animated: animated)
        case .right:
            if rightVisible, !leftVisible {
                return
            }
            applyPaneVisibility(leftVisible: leftVisible, rightVisible: !rightVisible, animated: animated)
        }
    }

    private func setPaneVisibility(splitItem: NSSplitViewItem, visible: Bool, animated: Bool) {
        let shouldCollapse = !visible
        guard splitItem.isCollapsed != shouldCollapse else {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                splitItem.animator().isCollapsed = shouldCollapse
            }
        } else {
            splitItem.isCollapsed = shouldCollapse
        }
    }

    private func paneViewController(for side: PaneSide) -> FilePaneViewController {
        switch side {
        case .left:
            return leftPaneViewController
        case .right:
            return rightPaneViewController
        }
    }

    private func applyInitialSidebarWidthIfNeeded() {
        guard !hasAppliedInitialSidebarWidth else {
            return
        }

        hasAppliedInitialSidebarWidth = true
        if !sidebarSplitItem.isCollapsed, splitView.arrangedSubviews.count > 1 {
            splitView.setPosition(initialSidebarWidth, ofDividerAt: 0)
        }

        reportSidebarWidthIfNeeded(force: true)
    }

    private func adjustSplitLayoutIfNeeded() {
        guard !isAdjustingSplitLayout else {
            return
        }

        let arrangedSubviews = splitView.arrangedSubviews
        guard !arrangedSubviews.isEmpty else {
            return
        }

        isAdjustingSplitLayout = true
        defer { isAdjustingSplitLayout = false }

        if !sidebarSplitItem.isCollapsed,
           let sidebarIndex = arrangedSubviewIndex(for: sidebarViewController.view, in: arrangedSubviews),
           sidebarIndex < arrangedSubviews.count - 1 {
            let currentSidebarWidth = arrangedSubviews[sidebarIndex].frame.width
            let maximumSidebarWidth = maximumAllowedSidebarWidth(for: arrangedSubviews)
            let clampedSidebarWidth = min(currentSidebarWidth, maximumSidebarWidth)
            if abs(clampedSidebarWidth - currentSidebarWidth) >= 1 {
                splitView.setPosition(clampedSidebarWidth, ofDividerAt: sidebarIndex)
            }
        }

        guard !leftSplitItem.isCollapsed,
              !rightSplitItem.isCollapsed else {
            return
        }

        let updatedSubviews = splitView.arrangedSubviews
        guard let leftIndex = arrangedSubviewIndex(for: leftPaneViewController.view, in: updatedSubviews),
              let rightIndex = arrangedSubviewIndex(for: rightPaneViewController.view, in: updatedSubviews),
              rightIndex == leftIndex + 1 else {
            return
        }

        let leftMinX = updatedSubviews[leftIndex].frame.minX
        let rightMaxX = updatedSubviews[rightIndex].frame.maxX
        let currentDividerPosition = updatedSubviews[leftIndex].frame.maxX
        let minimumDividerPosition = leftMinX + leftSplitItem.minimumThickness
        let maximumDividerPosition = rightMaxX - splitView.dividerThickness - rightSplitItem.minimumThickness

        guard maximumDividerPosition >= minimumDividerPosition else {
            return
        }

        let clampedDividerPosition = min(max(currentDividerPosition, minimumDividerPosition), maximumDividerPosition)
        if abs(clampedDividerPosition - currentDividerPosition) >= 1 {
            splitView.setPosition(clampedDividerPosition, ofDividerAt: leftIndex)
        }
    }

    private func restoreSidebarWidthIfNeeded() {
        guard !sidebarSplitItem.isCollapsed, splitView.arrangedSubviews.count > 1 else {
            return
        }

        splitView.setPosition(lastReportedSidebarWidth, ofDividerAt: 0)
    }

    private func reportSidebarWidthIfNeeded(force: Bool) {
        guard !sidebarSplitItem.isCollapsed else {
            return
        }

        let width = Self.clampedSidebarWidth(sidebarViewController.view.frame.width)
        guard force || abs(width - lastReportedSidebarWidth) >= 1 else {
            return
        }

        lastReportedSidebarWidth = width
        onSidebarWidthChanged?(width)
    }

    private static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    private func maximumAllowedSidebarWidth(for arrangedSubviews: [NSView]) -> CGFloat {
        let dividerCount = max(arrangedSubviews.count - 1, 0)
        let visiblePaneMinimumWidths =
            (!leftSplitItem.isCollapsed ? leftSplitItem.minimumThickness : 0) +
            (!rightSplitItem.isCollapsed ? rightSplitItem.minimumThickness : 0)
        let availableSidebarWidth = splitView.bounds.width
            - (CGFloat(dividerCount) * splitView.dividerThickness)
            - visiblePaneMinimumWidths

        return min(
            Self.sidebarWidthRange.upperBound,
            max(Self.sidebarWidthRange.lowerBound, availableSidebarWidth)
        )
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

    private func propagateBookmarksConfig() {
        leftPaneViewController.updateBookmarksConfig(bookmarksConfig)
        rightPaneViewController.updateBookmarksConfig(bookmarksConfig)
    }

    private func presentBookmarkSearchPanel() {
        bookmarkSearchPanelController?.dismiss()

        let searchVM = BookmarkSearchViewModel()
        searchVM.load(
            from: bookmarksConfig,
            history: viewModel.visitHistoryService.recentEntries(limit: 20)
        )

        let panel = BookmarkSearchPanelController(viewModel: searchVM)
        panel.onSelectEntry = { [weak self] result in
            self?.navigateToSearchResult(result)
        }
        panel.onDismiss = { [weak self] in
            self?.bookmarkSearchPanelController = nil
            self?.focusActivePane()
        }

        guard let window = view.window else {
            return
        }

        panel.showRelativeTo(window: window)
        bookmarkSearchPanelController = panel
    }

    private func navigateToSearchResult(_ result: BookmarkSearchViewModel.SearchResult) {
        let path = PathNormalizer.resolveExistingPath(UserPaths.resolveBookmarkPath(result.path))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            presentPathNotFoundAlert(path: path)
            return
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        let destination = isDirectory.boolValue
            ? url
            : url.deletingLastPathComponent().standardizedFileURL

        if viewModel.activePane.displayMode == .media {
            viewModel.activePane.setDisplayMode(.browser)
        }

        navigateActivePane(to: destination)
    }

    private func resolveNavigationDestination(from rawInput: String) -> URL? {
        let sanitizedInput = stripSurroundingQuotes(from: rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !sanitizedInput.isEmpty else {
            return nil
        }

        let homeAliasNormalizedInput = normalizedHomeAliasPath(from: sanitizedInput)
        let expandedPath = (homeAliasNormalizedInput as NSString).expandingTildeInPath
        let currentDirectory = viewModel.activePane.paneState.currentDirectory
        let rawURL: URL
        if expandedPath.hasPrefix("/") {
            rawURL = URL(fileURLWithPath: expandedPath)
        } else {
            rawURL = URL(fileURLWithPath: expandedPath, relativeTo: currentDirectory)
        }

        let normalizedURL = rawURL.standardizedFileURL
        let resolvedPath = PathNormalizer.resolveExistingPath(normalizedURL.path)
        let resolvedURL = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return resolvedURL
        }

        return resolvedURL.deletingLastPathComponent().standardizedFileURL
    }

    private func normalizedHomeAliasPath(from path: String) -> String {
        let lowercasedPath = path.lowercased()
        if lowercasedPath == "home" {
            return "~"
        }

        let prefix = "home/"
        guard lowercasedPath.hasPrefix(prefix) else {
            return path
        }

        let suffixStart = path.index(path.startIndex, offsetBy: prefix.count)
        return "~/" + String(path[suffixStart...])
    }

    private func stripSurroundingQuotes(from value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }

        return value
    }

    private func navigateActivePane(to destination: URL, selecting itemURL: URL? = nil) {
        let normalizedDestination = destination.standardizedFileURL
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.viewModel.securityScopedBookmarkService.startAccessing(normalizedDestination)
                await self.viewModel.securityScopedBookmarkService.stopAccessing(normalizedDestination)
                await MainActor.run {
                    if let itemURL {
                        self.viewModel.activePane.navigate(to: normalizedDestination, selecting: itemURL)
                        self.focusActivePane()
                    } else {
                        self.viewModel.activePane.navigate(to: normalizedDestination)
                    }
                }
            } catch let bookmarkError as SecurityScopedBookmarkError {
                switch bookmarkError {
                case .bookmarkNotFound:
                    await MainActor.run {
                        self.presentAccessGrantPrompt(for: normalizedDestination)
                    }
                default:
                    await MainActor.run {
                        self.presentNavigationErrorAlert(for: normalizedDestination, error: bookmarkError)
                    }
                }
            } catch {
                await MainActor.run {
                    self.presentNavigationErrorAlert(for: normalizedDestination, error: error)
                }
            }
        }
    }

    private func presentPathNotFoundAlert(path: String) {
        presentErrorAlert(title: "Path not found", informativeText: path)
    }

    private func presentAccessGrantPrompt(for destination: URL) {
        let panel = NSOpenPanel()
        panel.title = "Grant Folder Access"
        panel.message = "Select the bookmark folder (or one of its parent folders) to allow navigation."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = destination

        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            return
        }

        guard isSameOrDescendant(destination, of: selectedURL) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Selected folder does not contain bookmark"
            alert.informativeText = "Choose \(destination.path) or one of its parent folders."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.viewModel.securityScopedBookmarkService.saveBookmark(for: selectedURL)
                await MainActor.run {
                    self.viewModel.activePane.navigate(to: destination)
                }
            } catch {
                await MainActor.run {
                    self.presentNavigationErrorAlert(for: selectedURL, error: error)
                }
            }
        }
    }

    private func presentNavigationErrorAlert(for destination: URL, error: Error) {
        presentErrorAlert(
            title: "Failed to open path",
            informativeText: "\(destination.path)\n\n\(error.localizedDescription)"
        )
    }

    private func presentBookmarkPermissionSaveError(for destination: URL, error: Error) {
        presentErrorAlert(
            title: "Bookmark saved without access permission",
            informativeText:
                "\(destination.path)\n\n" +
                "You can keep this bookmark, but navigation may fail until access is granted.\n\n" +
                error.localizedDescription
        )
    }

    private func presentErrorAlert(title: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func isSameOrDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return PathNormalizer.isSameOrDescendant(childPath, of: parentPath)
    }

    private func presentAddBookmarkAlert() {
        let targetURL: URL
        if let selectedItem = viewModel.activePane.selectedItem, selectedItem.isDirectory {
            targetURL = selectedItem.url.standardizedFileURL
        } else {
            targetURL = viewModel.activePane.paneState.currentDirectory.standardizedFileURL
        }
        let defaultDisplayName = targetURL.lastPathComponent.isEmpty
            ? targetURL.path
            : targetURL.lastPathComponent

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Add Bookmark"
        alert.informativeText = targetURL.path
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let groupNames = bookmarksConfig.groups.map(\.name)
        let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 108))

        let groupPopup = NSPopUpButton(frame: NSRect(x: 0, y: 82, width: 340, height: 26), pullsDown: false)
        groupPopup.addItems(withTitles: groupNames)
        groupPopup.addItem(withTitle: "New…")
        let lastIndex = Self.lastSelectedBookmarkGroupIndex
        if lastIndex >= 0, lastIndex < groupPopup.numberOfItems {
            groupPopup.selectItem(at: lastIndex)
        }

        let displayNameField = NSTextField(frame: NSRect(x: 0, y: 52, width: 340, height: 24))
        displayNameField.stringValue = defaultDisplayName

        let shortcutLabel = NSTextField(labelWithString: "Shortcut sequence (optional):")
        shortcutLabel.frame = NSRect(x: 0, y: 26, width: 260, height: 20)
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .secondaryLabelColor

        let shortcutField = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        shortcutField.placeholderString = "e.g. d or d u"

        accessoryContainer.addSubview(groupPopup)
        accessoryContainer.addSubview(displayNameField)
        accessoryContainer.addSubview(shortcutLabel)
        accessoryContainer.addSubview(shortcutField)
        alert.accessoryView = accessoryContainer

        alert.window.initialFirstResponder = shortcutField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let selectedGroupIndex = groupPopup.indexOfSelectedItem
        Self.lastSelectedBookmarkGroupIndex = selectedGroupIndex

        let selectedGroupName: String
        var groupShortcutKey: String?
        if selectedGroupIndex >= 0, selectedGroupIndex < groupNames.count {
            selectedGroupName = groupNames[selectedGroupIndex]
        } else {
            guard let newGroup = presentNewBookmarkGroupAlert() else {
                return
            }
            selectedGroupName = newGroup.name
            groupShortcutKey = newGroup.shortcutKey
        }

        guard !selectedGroupName.isEmpty else {
            return
        }

        let displayName = displayNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName = displayName.isEmpty ? defaultDisplayName : displayName

        let entryShortcutKey = BookmarkShortcut.canonical(from: shortcutField.stringValue)

        saveBookmark(
            entry: BookmarkEntry(
                displayName: resolvedDisplayName,
                path: targetURL.path,
                shortcutKey: entryShortcutKey
            ),
            groupName: selectedGroupName,
            groupShortcutKey: groupShortcutKey
        )
    }

    private func presentNewBookmarkGroupAlert() -> (name: String, shortcutKey: String?)? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Create New Bookmark Group"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 50))

        let groupNameField = NSTextField(frame: NSRect(x: 0, y: 26, width: 210, height: 24))
        groupNameField.placeholderString = "Group name"

        let groupShortcutField = NSTextField(frame: NSRect(x: 220, y: 26, width: 120, height: 24))
        groupShortcutField.placeholderString = "Group key"

        let shortcutHintLabel = NSTextField(labelWithString: "Shortcut sequence (optional)")
        shortcutHintLabel.frame = NSRect(x: 0, y: 2, width: 250, height: 20)
        shortcutHintLabel.font = .systemFont(ofSize: 11)
        shortcutHintLabel.textColor = .secondaryLabelColor

        container.addSubview(groupNameField)
        container.addSubview(groupShortcutField)
        container.addSubview(shortcutHintLabel)
        alert.accessoryView = container
        alert.window.initialFirstResponder = groupNameField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let groupName = groupNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupName.isEmpty else {
            presentErrorAlert(
                title: "Missing Group Name",
                informativeText: "Group name is required when creating a new group."
            )
            return nil
        }

        return (
            name: groupName,
            shortcutKey: BookmarkShortcut.canonical(from: groupShortcutField.stringValue)
        )
    }

    private func saveBookmark(entry: BookmarkEntry, groupName: String, groupShortcutKey: String? = nil) {
        var latestConfig = configManager.loadBookmarksConfig()
        var groups = latestConfig.groups
        let normalizedEntry = normalizeBookmarkEntry(entry)

        if let groupIndex = groups.firstIndex(where: { $0.name == groupName }) {
            if let entryIndex = groups[groupIndex].entries.firstIndex(where: {
                isSameBookmarkPath($0.path, normalizedEntry.path)
            }) {
                groups[groupIndex].entries[entryIndex] = normalizedEntry
            } else {
                groups[groupIndex].entries.append(normalizedEntry)
            }
        } else {
            groups.append(BookmarkGroup(
                name: groupName,
                entries: [normalizedEntry],
                shortcutKey: groupShortcutKey
            ))
        }

        latestConfig.groups = groups

        do {
            try configManager.saveBookmarksConfig(latestConfig)
            bookmarksConfig = latestConfig
            persistSecurityScopedBookmark(for: normalizedEntry.path)
            sidebarViewModel.reloadSections()
            propagateBookmarksConfig()
            showActionToast("Saved bookmark \"\(normalizedEntry.displayName)\"")
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to save bookmark"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func persistSecurityScopedBookmark(for path: String) {
        let resolvedPath = UserPaths.resolveBookmarkPath(path)
        let bookmarkURL = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.viewModel.securityScopedBookmarkService.saveBookmark(for: bookmarkURL)
            } catch {
                await MainActor.run {
                    self.presentBookmarkPermissionSaveError(for: bookmarkURL, error: error)
                }
            }
        }
    }

    private func normalizeBookmarkEntry(_ entry: BookmarkEntry) -> BookmarkEntry {
        BookmarkEntry(
            displayName: entry.displayName,
            path: normalizedBookmarkPath(entry.path),
            shortcutKey: entry.shortcutKey
        )
    }

    private func normalizedBookmarkPath(_ rawPath: String) -> String {
        UserPaths.portableBookmarkPath(rawPath)
    }

    private func isSameBookmarkPath(_ lhs: String, _ rhs: String) -> Bool {
        normalizedBookmarkPath(lhs) == normalizedBookmarkPath(rhs)
    }

    private func presentSidebarBookmarkEditor(
        for entry: SidebarViewModel.SidebarEntry,
        sectionKind: SidebarViewModel.SectionKind
    ) {
        let latestConfig = configManager.loadBookmarksConfig()
        guard let originalGroupName = resolvedBookmarkGroupName(for: sectionKind, in: latestConfig) else {
            NSSound.beep()
            return
        }

        guard let result = presentSidebarBookmarkEditAlert(
            initialEntry: entry,
            initialGroupName: originalGroupName,
            groups: latestConfig.groups
        ) else {
            return
        }

        applySidebarBookmarkEdit(originalEntry: entry, originalGroupName: originalGroupName, result: result)
    }

    private func deleteSidebarBookmark(
        _ entry: SidebarViewModel.SidebarEntry,
        sectionKind: SidebarViewModel.SectionKind
    ) {
        var latestConfig = configManager.loadBookmarksConfig()
        guard let groupName = resolvedBookmarkGroupName(for: sectionKind, in: latestConfig),
              let groupIndex = latestConfig.groups.firstIndex(where: { $0.name == groupName }) else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Bookmark"
        alert.informativeText = "Delete \"\(entry.displayName)\"?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let previousCount = latestConfig.groups[groupIndex].entries.count
        latestConfig.groups[groupIndex].entries.removeAll {
            isSameBookmarkPath($0.path, entry.path)
        }
        guard latestConfig.groups[groupIndex].entries.count != previousCount else {
            NSSound.beep()
            return
        }

        persistBookmarkConfigAfterSidebarAction(
            latestConfig,
            toastMessage: "Deleted bookmark \"\(entry.displayName)\""
        )
    }

    private func resolvedBookmarkGroupName(
        for sectionKind: SidebarViewModel.SectionKind,
        in config: BookmarksConfig
    ) -> String? {
        switch sectionKind {
        case .bookmarkGroup(let groupName):
            return groupName
        case .favorites:
            return config.groups.first(where: { $0.isDefault })?.name
        case .pinned, .recent:
            return nil
        }
    }

    private func presentSidebarBookmarkEditAlert(
        initialEntry: SidebarViewModel.SidebarEntry,
        initialGroupName: String,
        groups: [BookmarkGroup]
    ) -> SidebarBookmarkEditResult? {
        guard !groups.isEmpty else {
            return nil
        }

        let groupNames = groups.map(\.name)
        let initialShortcut = groups
            .first(where: { $0.name == initialGroupName })?
            .entries
            .first(where: { isSameBookmarkPath($0.path, initialEntry.path) })?
            .shortcutKey

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Edit Bookmark"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 186))

        let groupLabel = NSTextField(labelWithString: "Group")
        groupLabel.frame = NSRect(x: 0, y: 160, width: 220, height: 20)
        groupLabel.font = .systemFont(ofSize: 11)
        groupLabel.textColor = .secondaryLabelColor

        let groupPopup = NSPopUpButton(frame: NSRect(x: 0, y: 136, width: 260, height: 24), pullsDown: false)
        groupPopup.addItems(withTitles: groupNames)

        let displayNameLabel = NSTextField(labelWithString: "Display Name")
        displayNameLabel.frame = NSRect(x: 0, y: 108, width: 200, height: 20)
        displayNameLabel.font = .systemFont(ofSize: 11)
        displayNameLabel.textColor = .secondaryLabelColor

        let displayNameField = NSTextField(frame: NSRect(x: 0, y: 84, width: 210, height: 24))
        displayNameField.stringValue = initialEntry.displayName

        let shortcutLabel = NSTextField(labelWithString: "Shortcut sequence (optional)")
        shortcutLabel.frame = NSRect(x: 220, y: 108, width: 240, height: 20)
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .secondaryLabelColor

        let shortcutField = NSTextField(frame: NSRect(x: 220, y: 84, width: 170, height: 24))
        shortcutField.placeholderString = "e.g. d or d u"
        shortcutField.stringValue = initialShortcut ?? ""

        let pathLabel = NSTextField(labelWithString: "Path")
        pathLabel.frame = NSRect(x: 0, y: 56, width: 210, height: 20)
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor

        let pathField = NSTextField(frame: NSRect(x: 0, y: 32, width: 460, height: 24))
        pathField.stringValue = initialEntry.path

        container.addSubview(groupLabel)
        container.addSubview(groupPopup)
        container.addSubview(displayNameLabel)
        container.addSubview(displayNameField)
        container.addSubview(shortcutLabel)
        container.addSubview(shortcutField)
        container.addSubview(pathLabel)
        container.addSubview(pathField)
        alert.accessoryView = container

        if let initialIndex = groupNames.firstIndex(of: initialGroupName) {
            groupPopup.selectItem(at: initialIndex)
        } else {
            groupPopup.selectItem(at: 0)
        }

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let selectedGroupIndex = groupPopup.indexOfSelectedItem
        guard selectedGroupIndex >= 0, groupNames.indices.contains(selectedGroupIndex) else {
            return nil
        }

        let selectedGroupName = groupNames[selectedGroupIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = displayNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !selectedGroupName.isEmpty, !displayName.isEmpty, !path.isEmpty else {
            presentErrorAlert(
                title: "Missing Required Fields",
                informativeText: "Group, display name, and path are required."
            )
            return nil
        }

        return SidebarBookmarkEditResult(
            groupName: selectedGroupName,
            displayName: displayName,
            path: path,
            shortcutKey: BookmarkShortcut.canonical(from: shortcutField.stringValue)
        )
    }

    private func applySidebarBookmarkEdit(
        originalEntry: SidebarViewModel.SidebarEntry,
        originalGroupName: String,
        result: SidebarBookmarkEditResult
    ) {
        var latestConfig = configManager.loadBookmarksConfig()
        guard let originalGroupIndex = latestConfig.groups.firstIndex(where: { $0.name == originalGroupName }),
              let targetGroupIndex = latestConfig.groups.firstIndex(where: { $0.name == result.groupName }) else {
            NSSound.beep()
            return
        }

        latestConfig.groups[originalGroupIndex].entries.removeAll {
            isSameBookmarkPath($0.path, originalEntry.path)
        }
        let updatedEntry = BookmarkEntry(
            displayName: result.displayName,
            path: normalizedBookmarkPath(result.path),
            shortcutKey: result.shortcutKey
        )

        if let existingIndex = latestConfig.groups[targetGroupIndex].entries.firstIndex(where: {
            isSameBookmarkPath($0.path, updatedEntry.path)
        }) {
            latestConfig.groups[targetGroupIndex].entries[existingIndex] = updatedEntry
        } else {
            latestConfig.groups[targetGroupIndex].entries.append(updatedEntry)
        }

        persistBookmarkConfigAfterSidebarAction(
            latestConfig,
            toastMessage: "Updated bookmark \"\(updatedEntry.displayName)\""
        )
        persistSecurityScopedBookmark(for: updatedEntry.path)
    }

    private func persistBookmarkConfigAfterSidebarAction(
        _ config: BookmarksConfig,
        toastMessage: String
    ) {
        do {
            try configManager.saveBookmarksConfig(config)
            bookmarksConfig = config
            propagateBookmarksConfig()
            sidebarViewModel.reloadSections()
            showActionToast(toastMessage)
        } catch {
            presentErrorAlert(
                title: "Failed to save bookmark",
                informativeText: error.localizedDescription
            )
        }
    }

    // MARK: - Batch Rename

    func presentBatchRenameWindow() {
        let urls = viewModel.activePane.markedOrSelectedURLs()
        guard !urls.isEmpty else { return }

        let urlSet = Set(urls)
        let items = viewModel.activePane.directoryContents.displayedItems
            .filter { urlSet.contains($0.url) }
        guard !items.isEmpty else { return }

        let allItems = viewModel.activePane.directoryContents.displayedItems

        let batchVM = BatchRenameViewModel(
            sourceFiles: items,
            allDirectoryFiles: allItems,
            configManager: configManager
        )

        batchVM.onApplyRequested = { [weak self] changes in
            self?.viewModel.executeBatchRename(renames: changes)
            self?.batchRenameWindowController?.close()
            self?.batchRenameWindowController = nil
        }

        batchVM.onDismissRequested = { [weak self] in
            self?.batchRenameWindowController?.close()
            self?.batchRenameWindowController = nil
        }

        let vc = BatchRenameViewController(viewModel: batchVM)
        let window = NSWindow(contentViewController: vc)
        window.title = "Batch Rename (\(items.count) files)"
        window.setContentSize(NSSize(width: 720, height: 600))
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 600, height: 400)
        window.center()

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        batchRenameWindowController = wc
    }

    // MARK: - Markdown Preview

    private func presentMarkdownPreviews(for fileURLs: [URL]) {
        guard let window = view.window else {
            return
        }

        let palette = currentFilerTheme.palette
        let normalizedURLs = Array(Set(fileURLs.map(\.standardizedFileURL)))
        for fileURL in normalizedURLs {
            if let panel = markdownPreviewPanelControllers[fileURL] {
                panel.focus()
                continue
            }

            let panel = MarkdownPreviewPanelController()
            panel.onDismiss = { [weak self] in
                self?.markdownPreviewPanelControllers.removeValue(forKey: fileURL)
                self?.focusActivePane()
            }

            panel.showRelativeTo(window: window, fileURL: fileURL, palette: palette)
            markdownPreviewPanelControllers[fileURL] = panel
        }
    }
}
