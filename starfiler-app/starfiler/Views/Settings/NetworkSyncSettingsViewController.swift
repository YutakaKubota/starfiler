import AppKit

@MainActor
final class NetworkSyncSettingsViewController: NSViewController {
    let viewModel: NetworkSyncViewModel

    private let titleLabel = NSTextField(labelWithString: "Network Sync")
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: "Enable the server role to publish a shared root, the client role to mirror selected folders locally, or both at once. When both roles run on one Mac, the two roots must stay different and not be nested."
    )
    private let serverEnabledCheckBox = NSButton(checkboxWithTitle: "Run Server Role", target: nil, action: nil)
    private let clientEnabledCheckBox = NSButton(checkboxWithTitle: "Run Client Role", target: nil, action: nil)
    let displayNameField = NSTextField()
    let serverRootPathField = NSTextField()
    let clientRootPathField = NSTextField()
    private let serverRootPathHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let clientRootPathHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let chooseServerRootButton = NSButton(title: "Choose Server Root\u{2026}", target: nil, action: nil)
    private let chooseClientRootButton = NSButton(title: "Choose Client Folder\u{2026}", target: nil, action: nil)
    private let syncEntireRootCheckBox = NSButton(checkboxWithTitle: "Sync Entire Root", target: nil, action: nil)
    private let refreshTreeButton = NSButton(title: "Refresh Tree", target: nil, action: nil)
    private let selectAllButton = NSButton(title: "Select All", target: nil, action: nil)
    private let clearSelectionButton = NSButton(title: "Clear All", target: nil, action: nil)
    private let expandAllButton = NSButton(title: "Expand All", target: nil, action: nil)
    private let collapseAllButton = NSButton(title: "Collapse All", target: nil, action: nil)
    private let selectiveSyncSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let selectiveSyncHintLabel = NSTextField(wrappingLabelWithString: "")
    private let selectiveSyncActivityIndicator = NSProgressIndicator()
    private let selectiveSyncActivityLabel = NSTextField(labelWithString: "")
    let conflictPolicyPopup = NSPopUpButton()
    let heartbeatField = NSTextField()
    let debounceField = NSTextField()
    private let peersTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let formScrollView = NSScrollView()

    let selectiveSyncOutlineView = NSOutlineView()
    private let selectiveSyncScrollView = NSScrollView()
    private var selectiveSyncObserverToken: UUID?
    var suppressViewModelRefresh = false
    private var lastRenderedSelectiveSyncNodes: [SelectiveSyncBrowserNode] = []
    var hasPerformedInitialSelectiveSyncExpansion = false
    private var pendingRefreshTask: Task<Void, Never>?

    init(viewModel: NetworkSyncViewModel? = nil) {
        self.viewModel = viewModel ?? NetworkSyncViewModel()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingRefreshTask?.cancel()
        if let selectiveSyncObserverToken {
            Task { @MainActor [viewModel] in
                viewModel.removeDidChangeObserver(selectiveSyncObserverToken)
            }
        }
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        configureLayout()
        bindViewModel()
        refreshFromViewModel()
    }

    private func configureUI() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 4

        serverEnabledCheckBox.translatesAutoresizingMaskIntoConstraints = false
        serverEnabledCheckBox.target = self
        serverEnabledCheckBox.action = #selector(toggleServerEnabled(_:))

        clientEnabledCheckBox.translatesAutoresizingMaskIntoConstraints = false
        clientEnabledCheckBox.target = self
        clientEnabledCheckBox.action = #selector(toggleClientEnabled(_:))

        displayNameField.translatesAutoresizingMaskIntoConstraints = false
        displayNameField.placeholderString = "Display name shown to other Macs"

        serverRootPathField.translatesAutoresizingMaskIntoConstraints = false
        serverRootPathField.placeholderString = "/Volumes/HD-AD6U3/StarFilerSync"

        clientRootPathField.translatesAutoresizingMaskIntoConstraints = false
        clientRootPathField.placeholderString = NetworkSyncConfig.defaultClientRootPath

        serverRootPathHelpLabel.translatesAutoresizingMaskIntoConstraints = false
        serverRootPathHelpLabel.font = .systemFont(ofSize: 11)
        serverRootPathHelpLabel.textColor = .secondaryLabelColor
        serverRootPathHelpLabel.maximumNumberOfLines = 3

        clientRootPathHelpLabel.translatesAutoresizingMaskIntoConstraints = false
        clientRootPathHelpLabel.font = .systemFont(ofSize: 11)
        clientRootPathHelpLabel.textColor = .secondaryLabelColor
        clientRootPathHelpLabel.maximumNumberOfLines = 3

        chooseServerRootButton.translatesAutoresizingMaskIntoConstraints = false
        chooseServerRootButton.bezelStyle = .rounded
        chooseServerRootButton.target = self
        chooseServerRootButton.action = #selector(chooseServerRootPath(_:))

        chooseClientRootButton.translatesAutoresizingMaskIntoConstraints = false
        chooseClientRootButton.bezelStyle = .rounded
        chooseClientRootButton.target = self
        chooseClientRootButton.action = #selector(chooseClientRootPath(_:))

        syncEntireRootCheckBox.translatesAutoresizingMaskIntoConstraints = false
        syncEntireRootCheckBox.target = self
        syncEntireRootCheckBox.action = #selector(toggleSyncEntireRoot(_:))

        refreshTreeButton.translatesAutoresizingMaskIntoConstraints = false
        refreshTreeButton.bezelStyle = .rounded
        refreshTreeButton.target = self
        refreshTreeButton.action = #selector(refreshSelectiveSyncTree(_:))

        for button in [selectAllButton, clearSelectionButton, expandAllButton, collapseAllButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
        }
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllSelectiveSyncItems(_:))
        clearSelectionButton.target = self
        clearSelectionButton.action = #selector(clearSelectiveSyncItems(_:))
        expandAllButton.target = self
        expandAllButton.action = #selector(expandAllSelectiveSyncItems(_:))
        collapseAllButton.target = self
        collapseAllButton.action = #selector(collapseAllSelectiveSyncItems(_:))

        selectiveSyncSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        selectiveSyncSummaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        selectiveSyncSummaryLabel.maximumNumberOfLines = 2

        selectiveSyncHintLabel.translatesAutoresizingMaskIntoConstraints = false
        selectiveSyncHintLabel.font = .systemFont(ofSize: 11)
        selectiveSyncHintLabel.textColor = .secondaryLabelColor
        selectiveSyncHintLabel.maximumNumberOfLines = 3

        selectiveSyncActivityIndicator.translatesAutoresizingMaskIntoConstraints = false
        selectiveSyncActivityIndicator.style = .spinning
        selectiveSyncActivityIndicator.controlSize = .small
        selectiveSyncActivityIndicator.isDisplayedWhenStopped = false

        selectiveSyncActivityLabel.translatesAutoresizingMaskIntoConstraints = false
        selectiveSyncActivityLabel.font = .systemFont(ofSize: 11)
        selectiveSyncActivityLabel.textColor = .secondaryLabelColor
        selectiveSyncActivityLabel.lineBreakMode = .byTruncatingTail

        conflictPolicyPopup.translatesAutoresizingMaskIntoConstraints = false
        for policy in NetworkSyncConflictPolicy.allCases {
            conflictPolicyPopup.addItem(withTitle: policy.displayName)
            conflictPolicyPopup.lastItem?.representedObject = policy.rawValue
        }

        heartbeatField.translatesAutoresizingMaskIntoConstraints = false
        heartbeatField.formatter = decimalFormatter

        debounceField.translatesAutoresizingMaskIntoConstraints = false
        debounceField.formatter = decimalFormatter

        configureSelectiveSyncOutlineView()

        peersTextView.isEditable = false
        peersTextView.drawsBackground = false
        peersTextView.font = .systemFont(ofSize: 12)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveChanges(_:))

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.bezelStyle = .rounded
        reloadButton.target = self
        reloadButton.action = #selector(reloadFromDisk(_:))
    }

    private func configureSelectiveSyncOutlineView() {
        let nameColumn = NSTableColumn(identifier: .selectiveSyncNameColumn)
        nameColumn.title = "Folders and Files"
        nameColumn.resizingMask = [.autoresizingMask]
        nameColumn.width = 340

        let statusColumn = NSTableColumn(identifier: .selectiveSyncStatusColumn)
        statusColumn.title = "Sync Status"
        statusColumn.resizingMask = [.autoresizingMask]
        statusColumn.width = 240

        let modifiedColumn = NSTableColumn(identifier: .selectiveSyncModifiedColumn)
        modifiedColumn.title = "Modified"
        modifiedColumn.resizingMask = [.autoresizingMask]
        modifiedColumn.width = 160

        let sizeColumn = NSTableColumn(identifier: .selectiveSyncSizeColumn)
        sizeColumn.title = "Size"
        sizeColumn.resizingMask = [.autoresizingMask]
        sizeColumn.width = 120

        selectiveSyncOutlineView.translatesAutoresizingMaskIntoConstraints = false
        selectiveSyncOutlineView.addTableColumn(nameColumn)
        selectiveSyncOutlineView.addTableColumn(statusColumn)
        selectiveSyncOutlineView.addTableColumn(modifiedColumn)
        selectiveSyncOutlineView.addTableColumn(sizeColumn)
        selectiveSyncOutlineView.outlineTableColumn = nameColumn
        selectiveSyncOutlineView.headerView = NSTableHeaderView()
        selectiveSyncOutlineView.delegate = self
        selectiveSyncOutlineView.dataSource = self
        selectiveSyncOutlineView.rowHeight = 30
        selectiveSyncOutlineView.intercellSpacing = NSSize(width: 8, height: 6)
        selectiveSyncOutlineView.selectionHighlightStyle = .none
        selectiveSyncOutlineView.floatsGroupRows = false
        selectiveSyncOutlineView.focusRingType = .none

        selectiveSyncScrollView.translatesAutoresizingMaskIntoConstraints = false
        selectiveSyncScrollView.borderType = .bezelBorder
        selectiveSyncScrollView.hasVerticalScroller = true
        selectiveSyncScrollView.documentView = selectiveSyncOutlineView
    }

    private func configureLayout() {
        let peersScrollView = NSScrollView()
        peersScrollView.translatesAutoresizingMaskIntoConstraints = false
        peersScrollView.borderType = .bezelBorder
        peersScrollView.hasVerticalScroller = true
        peersScrollView.documentView = peersTextView

        let serverRootPathStack = NSStackView(views: [serverRootPathField, chooseServerRootButton])
        serverRootPathStack.orientation = .horizontal
        serverRootPathStack.spacing = 8
        serverRootPathStack.alignment = .centerY
        serverRootPathStack.translatesAutoresizingMaskIntoConstraints = false

        let clientRootPathStack = NSStackView(views: [clientRootPathField, chooseClientRootButton])
        clientRootPathStack.orientation = .horizontal
        clientRootPathStack.spacing = 8
        clientRootPathStack.alignment = .centerY
        clientRootPathStack.translatesAutoresizingMaskIntoConstraints = false

        let selectiveControls = NSStackView(views: [
            syncEntireRootCheckBox,
            selectAllButton,
            clearSelectionButton,
            expandAllButton,
            collapseAllButton,
            refreshTreeButton,
        ])
        selectiveControls.orientation = .horizontal
        selectiveControls.spacing = 8
        selectiveControls.alignment = .centerY
        selectiveControls.translatesAutoresizingMaskIntoConstraints = false

        let selectiveSyncBody = NSStackView(views: [
            selectiveControls,
            selectiveSyncSummaryLabel,
            selectiveSyncHintLabel,
            selectiveSyncActivityRow(),
            selectiveSyncScrollView,
        ])
        selectiveSyncBody.orientation = .vertical
        selectiveSyncBody.alignment = .leading
        selectiveSyncBody.spacing = 8
        selectiveSyncBody.translatesAutoresizingMaskIntoConstraints = false

        selectiveSyncScrollView.heightAnchor.constraint(equalToConstant: 380).isActive = true

        let serverRoleBody = NSStackView(views: [
            serverEnabledCheckBox,
            labeledRow(title: "Shared Root", field: serverRootPathStack),
            serverRootPathHelpLabel,
        ])
        serverRoleBody.orientation = .vertical
        serverRoleBody.alignment = .leading
        serverRoleBody.spacing = 8
        serverRoleBody.translatesAutoresizingMaskIntoConstraints = false

        let clientRoleBody = NSStackView(views: [
            clientEnabledCheckBox,
            labeledRow(title: "Local Sync Folder", field: clientRootPathStack),
            clientRootPathHelpLabel,
            labeledSection(
                title: "Selective Sync",
                detail: "Turn off whole-root sync to choose folders or files from the latest server snapshot. Unchecked paths stay on the server and are removed from this Mac after Save.",
                body: selectiveSyncBody
            ),
        ])
        clientRoleBody.orientation = .vertical
        clientRoleBody.alignment = .leading
        clientRoleBody.spacing = 8
        clientRoleBody.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [saveButton, reloadButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12

        [
            titleLabel,
            descriptionLabel,
            labeledRow(title: "Display Name", field: displayNameField),
            labeledSection(
                title: "Server Role",
                detail: "Publish the authoritative shared root to other Macs on the local network. Use this on the Mac attached to HD-ADU3 or another always-mounted volume.",
                body: serverRoleBody
            ),
            labeledSection(
                title: "Client Role",
                detail: "Mirror selected folders from the server onto this Mac. This can run alongside the server role when the two roots are separate.",
                body: clientRoleBody
            ),
            labeledRow(title: "Conflict Policy", field: conflictPolicyPopup),
            labeledRow(title: "Heartbeat (sec)", field: heartbeatField),
            labeledRow(title: "Debounce (sec)", field: debounceField),
            labeledSection(
                title: "Peers",
                detail: "Peers discovered or remembered by the current config.",
                body: peersScrollView
            ),
            statusLabel,
            buttonStack,
        ].forEach { content.addArrangedSubview($0) }

        formScrollView.translatesAutoresizingMaskIntoConstraints = false
        formScrollView.drawsBackground = false
        formScrollView.hasVerticalScroller = true
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)
        formScrollView.documentView = documentView
        view.addSubview(formScrollView)

        let horizontalInset: CGFloat = 28
        let verticalInset: CGFloat = 28
        let maxContentWidth: CGFloat = 940
        let flexibleWidthConstraint = content.widthAnchor.constraint(
            equalTo: documentView.widthAnchor,
            constant: -(horizontalInset * 2)
        )
        flexibleWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            formScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            formScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: formScrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: formScrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: formScrollView.contentView.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: formScrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: formScrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: formScrollView.contentView.heightAnchor),

            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: verticalInset),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -horizontalInset),
            content.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -verticalInset),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: maxContentWidth),
            flexibleWidthConstraint,
            selectiveSyncBody.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    private func bindViewModel() {
        selectiveSyncObserverToken = viewModel.addDidChangeObserver { [weak self] in
            guard let self, !self.suppressViewModelRefresh else {
                return
            }
            self.scheduleRefreshFromViewModel()
        }
    }

    func refreshFromViewModel() {
        setStringValue(descriptionLabel, rolesDescription())
        setState(serverEnabledCheckBox, viewModel.serverEnabled ? .on : .off)
        setState(clientEnabledCheckBox, viewModel.clientEnabled ? .on : .off)
        setStringValue(displayNameField, viewModel.displayName)
        setStringValue(serverRootPathField, viewModel.serverRootPath)
        setStringValue(clientRootPathField, viewModel.clientRootPath)
        setStringValue(serverRootPathHelpLabel, serverRootHelpText())
        setStringValue(clientRootPathHelpLabel, clientRootHelpText())
        setState(syncEntireRootCheckBox, viewModel.clientSyncEntireRoot ? .on : .off)
        setStringValue(selectiveSyncSummaryLabel, "Selection: \(viewModel.selectiveSyncSummary)")
        setStringValue(selectiveSyncHintLabel, viewModel.selectiveSyncHint)
        setStringValue(selectiveSyncActivityLabel, viewModel.selectiveSyncActivityText)
        conflictPolicyPopup.selectItem(withTitle: viewModel.conflictPolicy.displayName)
        setDoubleValue(heartbeatField, viewModel.heartbeatIntervalSeconds)
        setDoubleValue(debounceField, viewModel.syncDebounceSeconds)
        let peerSummary = peerSummaryText()
        if peersTextView.string != peerSummary {
            peersTextView.string = peerSummary
        }
        setStringValue(statusLabel, viewModel.statusMessage)
        if viewModel.isSelectiveSyncRefreshing {
            selectiveSyncActivityIndicator.startAnimation(nil)
        } else {
            selectiveSyncActivityIndicator.stopAnimation(nil)
        }

        refreshSelectiveSyncOutlineIfNeeded()
        refreshSelectiveSyncControls()
    }

    private func scheduleRefreshFromViewModel() {
        guard pendingRefreshTask == nil else {
            return
        }

        pendingRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            self.pendingRefreshTask = nil
            guard !self.suppressViewModelRefresh else {
                return
            }
            self.refreshFromViewModel()
        }
    }

    private func refreshSelectiveSyncOutlineIfNeeded() {
        let nextNodes = viewModel.selectiveSyncNodes
        let nodesChanged = nextNodes != lastRenderedSelectiveSyncNodes
        guard nodesChanged else {
            return
        }

        let expandedPaths = currentExpandedPaths(in: lastRenderedSelectiveSyncNodes)
        selectiveSyncOutlineView.reloadData()

        if !hasPerformedInitialSelectiveSyncExpansion {
            expandSelectiveSyncTree()
            hasPerformedInitialSelectiveSyncExpansion = true
        } else {
            restoreExpandedPaths(expandedPaths, in: nextNodes)
        }

        lastRenderedSelectiveSyncNodes = nextNodes
    }

    private func refreshSelectiveSyncControls() {
        let isClient = viewModel.clientEnabled
        let isRefreshing = viewModel.isSelectiveSyncRefreshing
        refreshTreeButton.isEnabled = isClient && !isRefreshing
        reloadButton.isEnabled = !isRefreshing
        syncEntireRootCheckBox.isEnabled = isClient && !isRefreshing
        selectAllButton.isEnabled = isClient && !viewModel.clientSyncEntireRoot && !viewModel.selectiveSyncNodes.isEmpty && !isRefreshing
        clearSelectionButton.isEnabled = isClient && !viewModel.clientSyncEntireRoot && !isRefreshing
        expandAllButton.isEnabled = !viewModel.selectiveSyncNodes.isEmpty && !isRefreshing
        collapseAllButton.isEnabled = !viewModel.selectiveSyncNodes.isEmpty && !isRefreshing
        selectiveSyncOutlineView.isEnabled = !isRefreshing
        selectiveSyncOutlineView.alphaValue = isClient ? 1 : 0.82
    }

    func expandSelectiveSyncTree() {
        for node in viewModel.selectiveSyncNodes {
            expandRecursively(node)
        }
    }

    private func currentExpandedPaths(in roots: [SelectiveSyncBrowserNode]) -> Set<String> {
        var paths: Set<String> = []

        func collect(from nodes: [SelectiveSyncBrowserNode]) {
            for node in nodes where node.isDirectory {
                if selectiveSyncOutlineView.isItemExpanded(node) {
                    paths.insert(node.path)
                }
                collect(from: node.children)
            }
        }

        collect(from: roots)
        return paths
    }

    private func restoreExpandedPaths(_ paths: Set<String>, in roots: [SelectiveSyncBrowserNode]) {
        func restore(from nodes: [SelectiveSyncBrowserNode]) {
            for node in nodes where node.isDirectory {
                if paths.contains(node.path) {
                    selectiveSyncOutlineView.expandItem(node, expandChildren: false)
                }
                restore(from: node.children)
            }
        }

        restore(from: roots)
    }

    private func expandRecursively(_ node: SelectiveSyncBrowserNode) {
        selectiveSyncOutlineView.expandItem(node, expandChildren: false)
        for child in node.children where child.isDirectory {
            expandRecursively(child)
        }
    }

    func withSuppressedViewModelRefresh(_ updates: () -> Void) {
        suppressViewModelRefresh = true
        updates()
        suppressViewModelRefresh = false
    }

    private func setStringValue(_ textField: NSTextField, _ value: String) {
        guard textField.stringValue != value else {
            return
        }
        textField.stringValue = value
    }

    private func setState(_ button: NSButton, _ state: NSControl.StateValue) {
        guard button.state != state else {
            return
        }
        button.state = state
    }

    private func setDoubleValue(_ textField: NSTextField, _ value: Double) {
        guard textField.doubleValue != value else {
            return
        }
        textField.doubleValue = value
    }

    private func selectiveSyncActivityRow() -> NSView {
        let row = NSStackView(views: [selectiveSyncActivityIndicator, selectiveSyncActivityLabel])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}
