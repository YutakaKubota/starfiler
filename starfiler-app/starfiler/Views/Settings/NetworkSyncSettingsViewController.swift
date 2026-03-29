import AppKit

@MainActor
final class NetworkSyncSettingsViewController: NSViewController {
    private let viewModel: NetworkSyncViewModel

    private let titleLabel = NSTextField(labelWithString: "Network Sync")
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: "Enable the server role to publish a shared root, the client role to mirror selected folders locally, or both at once. When both roles run on one Mac, the two roots must stay different and not be nested."
    )
    private let serverEnabledCheckBox = NSButton(checkboxWithTitle: "Run Server Role", target: nil, action: nil)
    private let clientEnabledCheckBox = NSButton(checkboxWithTitle: "Run Client Role", target: nil, action: nil)
    private let displayNameField = NSTextField()
    private let serverRootPathField = NSTextField()
    private let clientRootPathField = NSTextField()
    private let serverRootPathHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let clientRootPathHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let chooseServerRootButton = NSButton(title: "Choose Server Root…", target: nil, action: nil)
    private let chooseClientRootButton = NSButton(title: "Choose Client Folder…", target: nil, action: nil)
    private let syncEntireRootCheckBox = NSButton(checkboxWithTitle: "Sync Entire Root", target: nil, action: nil)
    private let refreshTreeButton = NSButton(title: "Refresh Tree", target: nil, action: nil)
    private let selectAllButton = NSButton(title: "Select All", target: nil, action: nil)
    private let clearSelectionButton = NSButton(title: "Clear All", target: nil, action: nil)
    private let expandAllButton = NSButton(title: "Expand All", target: nil, action: nil)
    private let collapseAllButton = NSButton(title: "Collapse All", target: nil, action: nil)
    private let selectiveSyncSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let selectiveSyncHintLabel = NSTextField(wrappingLabelWithString: "")
    private let conflictPolicyPopup = NSPopUpButton()
    private let heartbeatField = NSTextField()
    private let debounceField = NSTextField()
    private let peersTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let formScrollView = NSScrollView()

    private let selectiveSyncOutlineView = NSOutlineView()
    private let selectiveSyncScrollView = NSScrollView()
    private var selectiveSyncObserverToken: UUID?
    private var suppressViewModelRefresh = false
    private var lastRenderedSelectiveSyncNodes: [SelectiveSyncBrowserNode] = []
    private var hasPerformedInitialSelectiveSyncExpansion = false
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

        let sizeColumn = NSTableColumn(identifier: .selectiveSyncSizeColumn)
        sizeColumn.title = "Size"
        sizeColumn.resizingMask = [.autoresizingMask]
        sizeColumn.width = 120

        selectiveSyncOutlineView.translatesAutoresizingMaskIntoConstraints = false
        selectiveSyncOutlineView.addTableColumn(nameColumn)
        selectiveSyncOutlineView.addTableColumn(statusColumn)
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
        formScrollView.documentView = content
        view.addSubview(formScrollView)

        NSLayoutConstraint.activate([
            formScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            formScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            content.topAnchor.constraint(equalTo: formScrollView.contentView.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: formScrollView.contentView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: formScrollView.contentView.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: formScrollView.contentView.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: formScrollView.contentView.widthAnchor, constant: -40),
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

    private func refreshFromViewModel() {
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
        conflictPolicyPopup.selectItem(withTitle: viewModel.conflictPolicy.displayName)
        setDoubleValue(heartbeatField, viewModel.heartbeatIntervalSeconds)
        setDoubleValue(debounceField, viewModel.syncDebounceSeconds)
        let peerSummary = peerSummaryText()
        if peersTextView.string != peerSummary {
            peersTextView.string = peerSummary
        }
        setStringValue(statusLabel, viewModel.statusMessage)

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
        refreshTreeButton.isEnabled = isClient
        syncEntireRootCheckBox.isEnabled = isClient
        selectAllButton.isEnabled = isClient && !viewModel.clientSyncEntireRoot && !viewModel.selectiveSyncNodes.isEmpty
        clearSelectionButton.isEnabled = isClient && !viewModel.clientSyncEntireRoot
        expandAllButton.isEnabled = !viewModel.selectiveSyncNodes.isEmpty
        collapseAllButton.isEnabled = !viewModel.selectiveSyncNodes.isEmpty
        selectiveSyncOutlineView.alphaValue = isClient ? 1 : 0.82
    }

    private func expandSelectiveSyncTree() {
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

    @objc
    private func toggleServerEnabled(_ sender: NSButton) {
        viewModel.setServerEnabled(sender.state == .on)
    }

    @objc
    private func toggleClientEnabled(_ sender: NSButton) {
        viewModel.setClientEnabled(sender.state == .on)
    }

    @objc
    private func chooseServerRootPath(_ sender: NSButton) {
        guard let selectedURL = chooseDirectory(initialPath: serverRootPathField.stringValue, prompt: "Choose Server Root") else {
            return
        }
        serverRootPathField.stringValue = selectedURL.path
    }

    @objc
    private func chooseClientRootPath(_ sender: NSButton) {
        guard let selectedURL = chooseDirectory(initialPath: clientRootPathField.stringValue, prompt: "Choose Client Folder") else {
            return
        }
        clientRootPathField.stringValue = selectedURL.path
        withSuppressedViewModelRefresh {
            viewModel.clientRootPath = selectedURL.path
            viewModel.applyClientDefaultsIfNeeded()
            viewModel.refreshSelectiveSyncPreview()
        }
        refreshFromViewModel()
    }

    @objc
    private func toggleSyncEntireRoot(_ sender: NSButton) {
        viewModel.setClientSyncEntireRoot(sender.state == .on)
    }

    @objc
    private func refreshSelectiveSyncTree(_ sender: NSButton) {
        withSuppressedViewModelRefresh {
            viewModel.clientRootPath = clientRootPathField.stringValue
            viewModel.refreshSelectiveSyncPreview()
            viewModel.requestRefresh()
        }
        refreshFromViewModel()
    }

    @objc
    private func selectAllSelectiveSyncItems(_ sender: NSButton) {
        viewModel.selectAllSelectiveSyncItems()
    }

    @objc
    private func clearSelectiveSyncItems(_ sender: NSButton) {
        viewModel.clearAllSelectiveSyncItems()
    }

    @objc
    private func expandAllSelectiveSyncItems(_ sender: NSButton) {
        expandSelectiveSyncTree()
        hasPerformedInitialSelectiveSyncExpansion = true
    }

    @objc
    private func collapseAllSelectiveSyncItems(_ sender: NSButton) {
        for node in viewModel.selectiveSyncNodes {
            collapseRecursively(node)
        }
        hasPerformedInitialSelectiveSyncExpansion = true
    }

    @objc
    private func saveChanges(_ sender: NSButton) {
        withSuppressedViewModelRefresh {
            viewModel.displayName = displayNameField.stringValue
            viewModel.serverRootPath = serverRootPathField.stringValue
            viewModel.clientRootPath = clientRootPathField.stringValue
            if let rawValue = conflictPolicyPopup.selectedItem?.representedObject as? String,
               let policy = NetworkSyncConflictPolicy(rawValue: rawValue) {
                viewModel.conflictPolicy = policy
            }
            viewModel.heartbeatIntervalSeconds = heartbeatField.doubleValue
            viewModel.syncDebounceSeconds = debounceField.doubleValue
            viewModel.save()
        }
        refreshFromViewModel()
    }

    @objc
    private func reloadFromDisk(_ sender: NSButton) {
        viewModel.reload()
    }

    private func withSuppressedViewModelRefresh(_ updates: () -> Void) {
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

    @objc
    private func toggleSelectiveSyncItem(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              node(for: path, in: viewModel.selectiveSyncNodes) != nil else {
            return
        }

        let shouldSelect = sender.state != .off
        viewModel.toggleSelectiveNode(path: path, isSelected: shouldSelect)
    }

    private func collapseRecursively(_ node: SelectiveSyncBrowserNode) {
        for child in node.children where child.isDirectory {
            collapseRecursively(child)
        }
        selectiveSyncOutlineView.collapseItem(node)
    }

    private func node(for path: String, in roots: [SelectiveSyncBrowserNode]) -> SelectiveSyncBrowserNode? {
        for candidate in roots {
            if candidate.path == path {
                return candidate
            }
            if let found = node(for: path, in: candidate.children) {
                return found
            }
        }
        return nil
    }

    private func peerSummaryText() -> String {
        if viewModel.peerSummaries.isEmpty {
            return "No peers configured yet."
        }

        return viewModel.peerSummaries
            .map { summary in
                [summary.title, summary.subtitle, summary.detail]
                    .joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    private func rolesDescription() -> String {
        switch (viewModel.serverEnabled, viewModel.clientEnabled) {
        case (true, true):
            return "This Mac is publishing a shared root and mirroring checked folders locally. Keep the server root and client folder separate so changes do not loop back into each other."
        case (true, false):
            return "This Mac is acting as the authoritative server. Other Macs can discover it on the LAN and sync from the published shared root."
        case (false, true):
            return "This Mac is acting as a client. Checked folders are mirrored from the server into the local sync folder."
        case (false, false):
            return "Enable the server role to publish a shared root, the client role to mirror selected folders locally, or both at once."
        }
    }

    private func serverRootHelpText() -> String {
        "Server role: this folder is the authoritative shared root. Put it on HD-ADU3 or another always-mounted volume."
    }

    private func clientRootHelpText() -> String {
        "Client role: checked folders and files are downloaded into this local folder. Default is \(NetworkSyncConfig.defaultClientRootPath)."
    }

    private func chooseDirectory(initialPath: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        if !initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: UserPaths.expandHomeVariables(in: initialPath))
        }
        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            return nil
        }
        return selectedURL
    }

    private func labeledRow(title: String, field: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [titleLabel, field])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return row
    }

    private func labeledSection(title: String, detail: String, body: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4

        let stack = NSStackView(views: [titleLabel, detailLabel, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private var decimalFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }
}

extension NetworkSyncSettingsViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let nodes = (item as? SelectiveSyncBrowserNode)?.children ?? viewModel.selectiveSyncNodes
        return nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let nodes = (item as? SelectiveSyncBrowserNode)?.children ?? viewModel.selectiveSyncNodes
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SelectiveSyncBrowserNode else {
            return false
        }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SelectiveSyncBrowserNode else {
            return nil
        }

        switch tableColumn?.identifier {
        case .selectiveSyncStatusColumn:
            let cell = makeStatusCell(for: outlineView)
            cell.symbolImageView.image = NSImage(systemSymbolName: statusSymbolName(for: node.runtimeState), accessibilityDescription: nil)
            cell.symbolImageView.contentTintColor = statusColor(for: node.runtimeState)
            cell.textField?.stringValue = node.statusText
            cell.textField?.textColor = statusColor(for: node.runtimeState)
            return cell
        case .selectiveSyncSizeColumn:
            let cell = makeSizeCell(for: outlineView)
            cell.textField?.stringValue = node.sizeText
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        default:
            let cell = makeNameCell(for: outlineView)
            cell.symbolImageView.image = NSImage(
                systemSymbolName: node.isDirectory ? "folder" : "doc",
                accessibilityDescription: node.isDirectory ? "Folder" : "File"
            )
            cell.checkboxButton.title = node.name
            cell.checkboxButton.state = checkboxState(for: node.selectionState)
            cell.checkboxButton.allowsMixedState = true
            cell.checkboxButton.isEnabled = viewModel.clientEnabled && !viewModel.clientSyncEntireRoot
            cell.checkboxButton.identifier = NSUserInterfaceItemIdentifier(node.path)
            return cell
        }
    }

    private func statusSymbolName(for runtimeState: SelectiveSyncRuntimeState) -> String {
        switch runtimeState {
        case .synced:
            return "checkmark.circle.fill"
        case .selectedPendingDownload:
            return "clock.badge.checkmark"
        case .syncingUpload:
            return "arrow.up.circle.fill"
        case .syncingDownload:
            return "arrow.down.circle.fill"
        case .pendingRemoval:
            return "trash.circle"
        case .serverOnly:
            return "externaldrive.badge.icloud"
        case .partiallySelected:
            return "circle.lefthalf.filled"
        case .conflict:
            return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for runtimeState: SelectiveSyncRuntimeState) -> NSColor {
        switch runtimeState {
        case .synced:
            return .systemGreen
        case .selectedPendingDownload:
            return .systemOrange
        case .syncingUpload, .syncingDownload:
            return .systemBlue
        case .pendingRemoval:
            return .systemRed
        case .serverOnly, .partiallySelected:
            return .secondaryLabelColor
        case .conflict:
            return .systemOrange
        }
    }

    private func checkboxState(for selectionState: SelectiveSyncSelectionState) -> NSControl.StateValue {
        switch selectionState {
        case .off:
            return .off
        case .on:
            return .on
        case .mixed:
            return .mixed
        }
    }

    private func makeNameCell(for outlineView: NSOutlineView) -> SelectiveSyncNameCellView {
        if let existing = outlineView.makeView(withIdentifier: .selectiveSyncNameCell, owner: self) as? SelectiveSyncNameCellView {
            return existing
        }

        let cell = SelectiveSyncNameCellView()
        cell.identifier = .selectiveSyncNameCell
        cell.checkboxButton.target = self
        cell.checkboxButton.action = #selector(toggleSelectiveSyncItem(_:))
        return cell
    }

    private func makeStatusCell(for outlineView: NSOutlineView) -> SelectiveSyncStatusCellView {
        if let existing = outlineView.makeView(withIdentifier: .selectiveSyncStatusCell, owner: self) as? SelectiveSyncStatusCellView {
            return existing
        }

        let cell = SelectiveSyncStatusCellView()
        cell.identifier = .selectiveSyncStatusCell
        return cell
    }

    private func makeSizeCell(for outlineView: NSOutlineView) -> NSTableCellView {
        if let existing = outlineView.makeView(withIdentifier: .selectiveSyncSizeCell, owner: self) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = .selectiveSyncSizeCell

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingHead
        cell.textField = label
        cell.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

private final class SelectiveSyncNameCellView: NSTableCellView {
    let symbolImageView = NSImageView()
    let checkboxButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        symbolImageView.translatesAutoresizingMaskIntoConstraints = false
        symbolImageView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        symbolImageView.contentTintColor = .secondaryLabelColor

        checkboxButton.translatesAutoresizingMaskIntoConstraints = false
        checkboxButton.font = .systemFont(ofSize: 12)
        checkboxButton.lineBreakMode = .byTruncatingTail
        checkboxButton.imagePosition = .imageLeading

        addSubview(symbolImageView)
        addSubview(checkboxButton)

        NSLayoutConstraint.activate([
            symbolImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbolImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolImageView.widthAnchor.constraint(equalToConstant: 14),
            symbolImageView.heightAnchor.constraint(equalToConstant: 14),

            checkboxButton.leadingAnchor.constraint(equalTo: symbolImageView.trailingAnchor, constant: 6),
            checkboxButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            checkboxButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class SelectiveSyncStatusCellView: NSTableCellView {
    let symbolImageView = NSImageView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        symbolImageView.translatesAutoresizingMaskIntoConstraints = false
        symbolImageView.symbolConfiguration = .init(pointSize: 12, weight: .semibold)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        self.textField = label

        addSubview(symbolImageView)
        addSubview(label)

        NSLayoutConstraint.activate([
            symbolImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbolImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolImageView.widthAnchor.constraint(equalToConstant: 14),
            symbolImageView.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: symbolImageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let selectiveSyncNameColumn = NSUserInterfaceItemIdentifier("SelectiveSyncNameColumn")
    static let selectiveSyncStatusColumn = NSUserInterfaceItemIdentifier("SelectiveSyncStatusColumn")
    static let selectiveSyncSizeColumn = NSUserInterfaceItemIdentifier("SelectiveSyncSizeColumn")
    static let selectiveSyncNameCell = NSUserInterfaceItemIdentifier("SelectiveSyncNameCell")
    static let selectiveSyncStatusCell = NSUserInterfaceItemIdentifier("SelectiveSyncStatusCell")
    static let selectiveSyncSizeCell = NSUserInterfaceItemIdentifier("SelectiveSyncSizeCell")
}
