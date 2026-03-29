import AppKit

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension BookmarksSettingsViewController {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else {
            return nil
        }

        let item = rows[row]
        let columnID = tableColumn?.identifier.rawValue ?? ""
        let cellIdentifier = NSUserInterfaceItemIdentifier("bookmarkCell-\(columnID)")

        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.textField = textField
            cell.addSubview(textField)

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        switch columnID {
        case "group":
            cell.textField?.stringValue = item.groupName
        case "name":
            cell.textField?.stringValue = item.displayName
        case "path":
            cell.textField?.stringValue = item.path
        case "shortcut":
            cell.textField?.stringValue = shortcutDescription(for: item)
        default:
            cell.textField?.stringValue = ""
        }

        return cell
    }

    func shortcutDescription(for row: BookmarkRow) -> String {
        if let hint = BookmarkShortcut.hint(
            groupShortcut: row.groupShortcutKey,
            entryShortcut: row.shortcutKey,
            isDefaultGroup: row.isDefaultGroup
        ) {
            return hint
        }
        return "-"
    }

    func normalizedBookmarkPath(_ rawPath: String) -> String {
        UserPaths.portableBookmarkPath(rawPath)
    }

    func isSameBookmarkPath(_ lhs: String, _ rhs: String) -> Bool {
        normalizedBookmarkPath(lhs) == normalizedBookmarkPath(rhs)
    }
}
