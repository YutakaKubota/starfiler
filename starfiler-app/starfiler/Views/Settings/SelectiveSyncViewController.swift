import AppKit

final class SelectiveSyncViewController: NSViewController {
    private let viewModel: NetworkSyncViewModel
    private let peerID: SyncPeerID
    private let peerName: String
    private var outlineView: NSOutlineView!
    private var statusLabel: NSTextField!
    private var loadingIndicator: NSProgressIndicator!

    private var flatNodes: [SelectiveSyncDisplayNode] = []

    var onRulesChanged: (() -> Void)?

    init(viewModel: NetworkSyncViewModel, peerID: SyncPeerID, peerName: String) {
        self.viewModel = viewModel
        self.peerID = peerID
        self.peerName = peerName
        super.init(nibName: nil, bundle: nil)
        self.title = "Selective Sync — \(peerName)"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 460))
        self.view = container

        // Header
        let headerLabel = NSTextField(labelWithString: "Select folders and files to sync from \(peerName):")
        headerLabel.font = .systemFont(ofSize: 13)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        // Status / Loading
        statusLabel = NSTextField(labelWithString: "Loading remote file list...")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.startAnimation(nil)
        container.addSubview(loadingIndicator)

        // Outline View in scroll view
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        container.addSubview(scrollView)

        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 20

        let checkColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
        checkColumn.width = 28
        checkColumn.minWidth = 28
        checkColumn.maxWidth = 28
        outlineView.addTableColumn(checkColumn)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 320
        outlineView.addTableColumn(nameColumn)

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 80
        outlineView.addTableColumn(sizeColumn)

        outlineView.outlineTableColumn = nameColumn
        outlineView.delegate = self
        outlineView.dataSource = self

        scrollView.documentView = outlineView

        // Sync All / None buttons
        let syncAllButton = NSButton(title: "Select All", target: self, action: #selector(selectAllItems(_:)))
        syncAllButton.bezelStyle = .rounded
        syncAllButton.controlSize = .small
        syncAllButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(syncAllButton)

        let syncNoneButton = NSButton(title: "Deselect All", target: self, action: #selector(deselectAllItems(_:)))
        syncNoneButton.bezelStyle = .rounded
        syncNoneButton.controlSize = .small
        syncNoneButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(syncNoneButton)

        // Apply button
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applyChanges))
        applyButton.bezelStyle = .rounded
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.keyEquivalent = "\r"
        container.addSubview(applyButton)

        // Summary
        let summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.tag = 100
        container.addSubview(summaryLabel)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            loadingIndicator.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            loadingIndicator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            statusLabel.centerYAnchor.constraint(equalTo: loadingIndicator.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: loadingIndicator.trailingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: syncAllButton.topAnchor, constant: -12),

            syncAllButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            syncAllButton.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -8),

            syncNoneButton.leadingAnchor.constraint(equalTo: syncAllButton.trailingAnchor, constant: 8),
            syncNoneButton.centerYAnchor.constraint(equalTo: syncAllButton.centerYAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            summaryLabel.bottomAnchor.constraint(equalTo: applyButton.topAnchor, constant: -8),

            applyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        viewModel.onRemoteFileTreeUpdated = { [weak self] in
            self?.reloadTree()
        }

        // Request file list
        Task { @MainActor in
            await viewModel.requestRemoteFileTree(from: peerID)
        }
    }

    // MARK: - Actions

    @objc private func selectAllItems(_ sender: Any?) {
        for i in flatNodes.indices {
            flatNodes[i].isSynced = true
        }
        outlineView.reloadData()
        updateSummary()
    }

    @objc private func deselectAllItems(_ sender: Any?) {
        for i in flatNodes.indices {
            flatNodes[i].isSynced = false
        }
        outlineView.reloadData()
        updateSummary()
    }

    @objc private func applyChanges() {
        let includedPaths = flatNodes
            .filter { $0.isSynced }
            .map { $0.relativePath }

        let existingRules = viewModel.getSelectiveSyncRules(for: peerID)
        let rules = SelectiveSyncRules(
            includedPaths: includedPaths,
            excludeRules: existingRules?.excludeRules ?? SyncExcludeRule.defaults,
            maxFileSize: existingRules?.maxFileSize
        )
        viewModel.setSelectiveSyncRules(rules, for: peerID)
        onRulesChanged?()

        view.window?.close()
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard row >= 0 else { return }

        let item = outlineView.item(atRow: row)
        guard let node = item as? SelectiveSyncDisplayNode else { return }

        let isChecked = sender.state == .on
        if let idx = flatNodes.firstIndex(where: { $0.relativePath == node.relativePath }) {
            flatNodes[idx].isSynced = isChecked

            // If directory, toggle all children too
            if node.isDirectory {
                let prefix = node.relativePath + "/"
                for i in flatNodes.indices {
                    if flatNodes[i].relativePath.hasPrefix(prefix) {
                        flatNodes[i].isSynced = isChecked
                    }
                }
            }
        }

        outlineView.reloadData()
        updateSummary()
    }

    // MARK: - Private

    private func reloadTree() {
        let tree = viewModel.remoteFileTree
        flatNodes = buildDisplayNodes(from: tree)

        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true

        if flatNodes.isEmpty {
            statusLabel.stringValue = "No files on remote peer"
        } else {
            statusLabel.stringValue = "\(flatNodes.count) items"
        }

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        updateSummary()
    }

    private func buildDisplayNodes(from nodes: [SyncRemoteFileNode]) -> [SelectiveSyncDisplayNode] {
        var result: [SelectiveSyncDisplayNode] = []
        for node in nodes {
            let displayNode = SelectiveSyncDisplayNode(
                relativePath: node.relativePath,
                name: node.name,
                isDirectory: node.isDirectory,
                size: node.size,
                isSynced: node.isSynced,
                children: buildDisplayNodes(from: node.children),
                depth: (node.relativePath as NSString).pathComponents.count - 1
            )
            result.append(displayNode)
        }
        return result
    }

    private func updateSummary() {
        let syncedCount = flatNodes.filter(\.isSynced).count
        let totalSize = flatNodes.filter { $0.isSynced && !$0.isDirectory }.compactMap(\.size).reduce(0, +)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeStr = formatter.string(fromByteCount: totalSize)

        if let label = view.viewWithTag(100) as? NSTextField {
            label.stringValue = "\(syncedCount) of \(flatNodes.count) items selected (\(sizeStr))"
        }
    }
}

// MARK: - Display Node

final class SelectiveSyncDisplayNode: NSObject {
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let size: Int64?
    var isSynced: Bool
    let children: [SelectiveSyncDisplayNode]
    let depth: Int

    var formattedSize: String {
        guard let size, !isDirectory else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    init(relativePath: String, name: String, isDirectory: Bool, size: Int64?, isSynced: Bool, children: [SelectiveSyncDisplayNode], depth: Int) {
        self.relativePath = relativePath
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.isSynced = isSynced
        self.children = children
        self.depth = depth
    }
}

// MARK: - NSOutlineViewDataSource

extension SelectiveSyncViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return flatNodes.filter { $0.depth == 0 }.count
        }
        guard let node = item as? SelectiveSyncDisplayNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return flatNodes.filter { $0.depth == 0 }[index]
        }
        guard let node = item as? SelectiveSyncDisplayNode else { return NSObject() }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SelectiveSyncDisplayNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }
}

// MARK: - NSOutlineViewDelegate

extension SelectiveSyncViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SelectiveSyncDisplayNode else { return nil }
        let columnID = tableColumn?.identifier.rawValue ?? ""

        switch columnID {
        case "check":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            checkbox.state = node.isSynced ? .on : .off
            return checkbox

        case "name":
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("NameCell")

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let symbolName = node.isDirectory ? "folder.fill" : "doc.fill"
            imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            imageView.contentTintColor = node.isDirectory ? .systemBlue : .secondaryLabelColor
            cell.addSubview(imageView)

            let textField = NSTextField(labelWithString: node.name)
            textField.font = .systemFont(ofSize: 12)
            textField.textColor = node.isSynced ? .labelColor : .tertiaryLabelColor
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            return cell

        case "size":
            let label = NSTextField(labelWithString: node.formattedSize)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label

        default:
            return nil
        }
    }
}
