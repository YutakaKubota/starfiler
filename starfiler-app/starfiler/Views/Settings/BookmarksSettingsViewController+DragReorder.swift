import AppKit

// MARK: - Move / Reorder Actions

extension BookmarksSettingsViewController {
    @objc
    func moveGroupUp(_ sender: Any?) {
        moveGroup(by: -1)
    }

    @objc
    func moveGroupDown(_ sender: Any?) {
        moveGroup(by: 1)
    }

    func moveGroup(by delta: Int) {
        guard bookmarksConfig.groups.count > 1 else {
            return
        }

        guard let groupIndex = selectGroupIndex(
            title: delta < 0 ? "Move Group Up" : "Move Group Down",
            informativeText: "Choose a group to move.",
            allowDefault: true,
            preferredGroupName: selectedRow?.groupName
        ) else {
            return
        }

        let destinationIndex = groupIndex + delta
        guard bookmarksConfig.groups.indices.contains(destinationIndex) else {
            NSSound.beep()
            return
        }

        var groups = bookmarksConfig.groups
        groups.swapAt(groupIndex, destinationIndex)

        let movedGroup = groups[destinationIndex]
        let selectionTarget = movedGroup.entries.first.map {
            BookmarkSelectionTarget(groupName: movedGroup.name, displayName: $0.displayName, path: $0.path)
        }
        persist(BookmarksConfig(groups: groups), selecting: selectionTarget)
    }

    @objc
    func addBookmark(_ sender: Any?) {
        guard let result = presentFolderEditor(initialRow: nil) else {
            return
        }
        upsertBookmark(with: result, replacing: nil)
    }

    @objc
    func editBookmark(_ sender: Any?) {
        guard let selectedRow else {
            return
        }
        guard let result = presentFolderEditor(initialRow: selectedRow) else {
            return
        }
        upsertBookmark(with: result, replacing: selectedRow)
    }

    @objc
    func deleteBookmark(_ sender: Any?) {
        let selectedBookmarks = selectedRows
        guard !selectedBookmarks.isEmpty else {
            return
        }

        let selectionCount = selectedBookmarks.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selectionCount == 1 ? "Delete Folder Bookmark" : "Delete Folder Bookmarks"
        if selectionCount == 1, let selectedRow = selectedBookmarks.first {
            alert.informativeText = "Delete \"\(selectedRow.displayName)\" from group \"\(selectedRow.groupName)\"?"
        } else {
            alert.informativeText = "Delete \(selectionCount) selected bookmarks?"
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        var groups = bookmarksConfig.groups
        let selectedKeys = Set(
            selectedBookmarks.map { row in
                BookmarkIdentity(
                    groupName: row.groupName,
                    displayName: row.displayName,
                    path: normalizedBookmarkPath(row.path),
                    shortcutKey: row.shortcutKey
                )
            }
        )
        for groupIndex in groups.indices {
            let groupName = groups[groupIndex].name
            groups[groupIndex].entries.removeAll { entry in
                selectedKeys.contains(
                    BookmarkIdentity(
                        groupName: groupName,
                        displayName: entry.displayName,
                        path: normalizedBookmarkPath(entry.path),
                        shortcutKey: entry.shortcutKey
                    )
                )
            }
        }

        persist(BookmarksConfig(groups: groups))
    }

    @objc
    func moveBookmarkUp(_ sender: Any?) {
        moveSelectedBookmark(by: -1)
    }

    @objc
    func moveBookmarkDown(_ sender: Any?) {
        moveSelectedBookmark(by: 1)
    }

    func moveSelectedBookmark(by delta: Int) {
        guard let selectedRow, let position = position(for: selectedRow) else {
            return
        }

        var groups = bookmarksConfig.groups
        let destinationIndex = position.entryIndex + delta
        guard groups[position.groupIndex].entries.indices.contains(destinationIndex) else {
            NSSound.beep()
            return
        }

        groups[position.groupIndex].entries.swapAt(position.entryIndex, destinationIndex)
        let movedEntry = groups[position.groupIndex].entries[destinationIndex]
        let selectionTarget = BookmarkSelectionTarget(
            groupName: groups[position.groupIndex].name,
            displayName: movedEntry.displayName,
            path: movedEntry.path
        )
        persist(BookmarksConfig(groups: groups), selecting: selectionTarget)
    }

    @objc
    func reloadBookmarks(_ sender: Any?) {
        reloadFromDisk()
    }

    @objc
    func openConfigFile(_ sender: Any?) {
        let url = configManager.bookmarksConfigURL

        if !FileManager.default.fileExists(atPath: url.path) {
            try? configManager.saveBookmarksConfig(bookmarksConfig)
        }

        NSWorkspace.shared.open(url)
    }

    @objc
    func browseFolderBookmarkPath(_ sender: Any?) {
        guard let pathField = folderEditorPathField else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Folder"
        panel.message = "Select a folder to bookmark."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        let rawPath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawPath.isEmpty {
            let currentURL = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                panel.directoryURL = currentURL
            } else {
                let parentURL = currentURL.deletingLastPathComponent().standardizedFileURL
                if FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    panel.directoryURL = parentURL
                }
            }
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        pathField.stringValue = selectedURL.standardizedFileURL.path
    }
}
