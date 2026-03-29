import AppKit

// MARK: - NSOutlineViewDataSource / NSOutlineViewDelegate

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

    func statusSymbolName(for runtimeState: SelectiveSyncRuntimeState) -> String {
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

    func statusColor(for runtimeState: SelectiveSyncRuntimeState) -> NSColor {
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

    func checkboxState(for selectionState: SelectiveSyncSelectionState) -> NSControl.StateValue {
        switch selectionState {
        case .off:
            return .off
        case .on:
            return .on
        case .mixed:
            return .mixed
        }
    }

    func makeNameCell(for outlineView: NSOutlineView) -> SelectiveSyncNameCellView {
        if let existing = outlineView.makeView(withIdentifier: .selectiveSyncNameCell, owner: self) as? SelectiveSyncNameCellView {
            return existing
        }

        let cell = SelectiveSyncNameCellView()
        cell.identifier = .selectiveSyncNameCell
        cell.checkboxButton.target = self
        cell.checkboxButton.action = #selector(toggleSelectiveSyncItem(_:))
        return cell
    }

    func makeStatusCell(for outlineView: NSOutlineView) -> SelectiveSyncStatusCellView {
        if let existing = outlineView.makeView(withIdentifier: .selectiveSyncStatusCell, owner: self) as? SelectiveSyncStatusCellView {
            return existing
        }

        let cell = SelectiveSyncStatusCellView()
        cell.identifier = .selectiveSyncStatusCell
        return cell
    }

    func makeSizeCell(for outlineView: NSOutlineView) -> NSTableCellView {
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

final class SelectiveSyncNameCellView: NSTableCellView {
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

final class SelectiveSyncStatusCellView: NSTableCellView {
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

extension NSUserInterfaceItemIdentifier {
    static let selectiveSyncNameColumn = NSUserInterfaceItemIdentifier("SelectiveSyncNameColumn")
    static let selectiveSyncStatusColumn = NSUserInterfaceItemIdentifier("SelectiveSyncStatusColumn")
    static let selectiveSyncSizeColumn = NSUserInterfaceItemIdentifier("SelectiveSyncSizeColumn")
    static let selectiveSyncNameCell = NSUserInterfaceItemIdentifier("SelectiveSyncNameCell")
    static let selectiveSyncStatusCell = NSUserInterfaceItemIdentifier("SelectiveSyncStatusCell")
    static let selectiveSyncSizeCell = NSUserInterfaceItemIdentifier("SelectiveSyncSizeCell")
}
