import AppKit

@MainActor
final class NetworkSyncSettingsViewController: NSViewController {
    private let viewModel: NetworkSyncViewModel

    private let titleLabel = NSTextField(labelWithString: "Network Sync")
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: "Run one Mac as the server on the external drive. Clients browse that server tree and download checked items into a local sync folder."
    )
    private let enabledCheckBox = NSButton(checkboxWithTitle: "Enable network sync", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(
        labels: SyncNodeMode.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let displayNameField = NSTextField()
    private let rootPathField = NSTextField()
    private let rootPathHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let chooseRootButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let syncEntireRootCheckBox = NSButton(checkboxWithTitle: "Sync Entire Root", target: nil, action: nil)
    private let refreshTreeButton = NSButton(title: "Refresh Tree", target: nil, action: nil)
    private let selectiveSyncSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let selectiveSyncHintLabel = NSTextField(wrappingLabelWithString: "")
    private let conflictPolicyPopup = NSPopUpButton()
    private let heartbeatField = NSTextField()
    private let debounceField = NSTextField()
    private let peersTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)

    private let selectiveSyncOutlineView = NSOutlineView()
    private let selectiveSyncScrollView = NSScrollView()
    private var selectiveSyncObserverToken: UUID?

    init(viewModel: NetworkSyncViewModel? = nil) {
        self.viewModel = viewModel ?? NetworkSyncViewModel()
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
        descriptionLabel.maximumNumberOfLines = 3

        enabledCheckBox.translatesAutoresizingMaskIntoConstraints = false
        enabledCheckBox.target = self
        enabledCheckBox.action = #selector(toggleEnabled(_:))

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))

        displayNameField.translatesAutoresizingMaskIntoConstraints = false
        displayNameField.placeholderString = "Display name shown to other Macs"

        rootPathField.translatesAutoresizingMaskIntoConstraints = false
        rootPathField.placeholderString = "/Volumes/HD-AD6U3/Shared"

        rootPathHelpLabel.translatesAutoresizingMaskIntoConstraints = false
        rootPathHelpLabel.font = .systemFont(ofSize: 11)
        rootPathHelpLabel.textColor = .secondaryLabelColor
        rootPathHelpLabel.maximumNumberOfLines = 3

        chooseRootButton.translatesAutoresizingMaskIntoConstraints = false
        chooseRootButton.bezelStyle = .rounded
        chooseRootButton.target = self
        chooseRootButton.action = #selector(chooseRootPath(_:))

        syncEntireRootCheckBox.translatesAutoresizingMaskIntoConstraints = false
        syncEntireRootCheckBox.target = self
        syncEntireRootCheckBox.action = #selector(toggleSyncEntireRoot(_:))

        refreshTreeButton.translatesAutoresizingMaskIntoConstraints = false
        refreshTreeButton.bezelStyle = .rounded
        refreshTreeButton.target = self
        refreshTreeButton.action = #selector(refreshSelectiveSyncTree(_:))

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
        statusColumn.title = "Status on This Mac"
        statusColumn.resizingMask = [.autoresizingMask]
        statusColumn.width = 220

        selectiveSyncOutlineView.translatesAutoresizingMaskIntoConstraints = false
        selectiveSyncOutlineView.addTableColumn(nameColumn)
        selectiveSyncOutlineView.addTableColumn(statusColumn)
        selectiveSyncOutlineView.outlineTableColumn = nameColumn
        selectiveSyncOutlineView.headerView = NSTableHeaderView()
        selectiveSyncOutlineView.delegate = self
        selectiveSyncOutlineView.dataSource = self
        selectiveSyncOutlineView.rowHeight = 28
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

        let rootPathStack = NSStackView(views: [rootPathField, chooseRootButton])
        rootPathStack.orientation = .horizontal
        rootPathStack.spacing = 8
        rootPathStack.alignment = .centerY
        rootPathStack.translatesAutoresizingMaskIntoConstraints = false

        let selectiveControls = NSStackView(views: [syncEntireRootCheckBox, refreshTreeButton])
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

        selectiveSyncScrollView.heightAnchor.constraint(equalToConstant: 220).isActive = true

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
            enabledCheckBox,
            labeledRow(title: "Mode", field: modeControl),
            labeledRow(title: "Display Name", field: displayNameField),
            labeledRow(title: "Root Path", field: rootPathStack),
            rootPathHelpLabel,
            labeledSection(
                title: "Selective Sync",
                detail: "Turn off whole-root sync to choose folders or files from the latest server snapshot. Unchecked paths stay on the server and are removed from this Mac after Save.",
                body: selectiveSyncBody
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

        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            selectiveSyncBody.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    private func bindViewModel() {
        selectiveSyncObserverToken = viewModel.addDidChangeObserver { [weak self] in
            self?.refreshFromViewModel()
        }
    }

    private func refreshFromViewModel() {
        descriptionLabel.stringValue = viewModel.mode == .server
            ? "Server mode turns this Mac into the authoritative sync host. Other Macs discover it on the LAN and mirror from this root."
            : "Client mode mirrors checked folders from the server onto this Mac. The local sync destination defaults to ~/StarFilerSync."
        enabledCheckBox.state = viewModel.isEnabled ? .on : .off
        modeControl.selectedSegment = SyncNodeMode.allCases.firstIndex(of: viewModel.mode) ?? 0
        displayNameField.stringValue = viewModel.displayName
        rootPathField.stringValue = viewModel.rootPath
        rootPathField.placeholderString = viewModel.mode == .server
            ? "/Volumes/HD-AD6U3/Shared"
            : NetworkSyncConfig.defaultClientRootPath
        chooseRootButton.title = viewModel.mode == .server ? "Choose Server Root…" : "Choose Local Sync Folder…"
        rootPathHelpLabel.stringValue = rootPathHelpText()
        syncEntireRootCheckBox.state = viewModel.syncEntireRoot ? .on : .off
        selectiveSyncSummaryLabel.stringValue = "Selection: \(viewModel.selectiveSyncSummary)"
        selectiveSyncHintLabel.stringValue = viewModel.selectiveSyncHint
        conflictPolicyPopup.selectItem(withTitle: viewModel.conflictPolicy.displayName)
        heartbeatField.doubleValue = viewModel.heartbeatIntervalSeconds
        debounceField.doubleValue = viewModel.syncDebounceSeconds
        peersTextView.string = peerSummaryText()
        statusLabel.stringValue = viewModel.statusMessage

        selectiveSyncOutlineView.reloadData()
        expandSelectiveSyncTree()
        refreshSelectiveSyncControls()
    }

    private func refreshSelectiveSyncControls() {
        let isClient = viewModel.mode == .client
        refreshTreeButton.isEnabled = true
        syncEntireRootCheckBox.isEnabled = isClient
        selectiveSyncOutlineView.alphaValue = isClient ? 1 : 0.82
    }

    private func expandSelectiveSyncTree() {
        for node in viewModel.selectiveSyncNodes {
            expandRecursively(node)
        }
    }

    private func expandRecursively(_ node: SelectiveSyncBrowserNode) {
        selectiveSyncOutlineView.expandItem(node, expandChildren: false)
        for child in node.children where child.isDirectory {
            expandRecursively(child)
        }
    }

    @objc
    private func toggleEnabled(_ sender: NSButton) {
        viewModel.isEnabled = sender.state == .on
    }

    @objc
    private func changeMode(_ sender: NSSegmentedControl) {
        let selectedIndex = max(sender.selectedSegment, 0)
        viewModel.setMode(SyncNodeMode.allCases[selectedIndex])
    }

    @objc
    private func chooseRootPath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Root"
        if !rootPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: UserPaths.expandHomeVariables(in: rootPathField.stringValue))
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            return
        }

        rootPathField.stringValue = selectedURL.path
        viewModel.rootPath = selectedURL.path
        viewModel.refreshSelectiveSyncPreview()
    }

    @objc
    private func toggleSyncEntireRoot(_ sender: NSButton) {
        viewModel.setSyncEntireRoot(sender.state == .on)
    }

    @objc
    private func refreshSelectiveSyncTree(_ sender: NSButton) {
        viewModel.rootPath = rootPathField.stringValue
        viewModel.refreshSelectiveSyncPreview()
        viewModel.requestRefresh()
    }

    @objc
    private func saveChanges(_ sender: NSButton) {
        viewModel.displayName = displayNameField.stringValue
        viewModel.rootPath = rootPathField.stringValue
        if let rawValue = conflictPolicyPopup.selectedItem?.representedObject as? String,
           let policy = NetworkSyncConflictPolicy(rawValue: rawValue) {
            viewModel.conflictPolicy = policy
        }
        viewModel.heartbeatIntervalSeconds = heartbeatField.doubleValue
        viewModel.syncDebounceSeconds = debounceField.doubleValue
        viewModel.save()
    }

    @objc
    private func reloadFromDisk(_ sender: NSButton) {
        viewModel.reload()
    }

    @objc
    private func toggleSelectiveSyncItem(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              let node = node(for: path, in: viewModel.selectiveSyncNodes)
        else {
            return
        }

        let shouldSelect = node.selectionState == .off
        viewModel.toggleSelectiveNode(path: path, isSelected: shouldSelect)
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

    private func rootPathHelpText() -> String {
        switch viewModel.mode {
        case .server:
            return "Server mode: this folder is the authoritative shared root. Put it on HD-AD6U3 or another always-mounted volume."
        case .client:
            return "Client mode: checked folders and files are downloaded into this local folder. Default is \(NetworkSyncConfig.defaultClientRootPath)."
        }
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
        detailLabel.maximumNumberOfLines = 3

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
            cell.textField?.stringValue = node.statusText
            cell.textField?.textColor = node.isLocalAvailable ? .labelColor : .secondaryLabelColor
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
            cell.checkboxButton.isEnabled = viewModel.mode == .client && !viewModel.syncEntireRoot
            cell.checkboxButton.identifier = NSUserInterfaceItemIdentifier(node.path)
            return cell
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

    private func makeStatusCell(for outlineView: NSOutlineView) -> NSTableCellView {
        if let existing = outlineView.makeView(withIdentifier: .selectiveSyncStatusCell, owner: self) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = .selectiveSyncStatusCell

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
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

private extension NSUserInterfaceItemIdentifier {
    static let selectiveSyncNameColumn = NSUserInterfaceItemIdentifier("SelectiveSyncNameColumn")
    static let selectiveSyncStatusColumn = NSUserInterfaceItemIdentifier("SelectiveSyncStatusColumn")
    static let selectiveSyncNameCell = NSUserInterfaceItemIdentifier("SelectiveSyncNameCell")
    static let selectiveSyncStatusCell = NSUserInterfaceItemIdentifier("SelectiveSyncStatusCell")
}
