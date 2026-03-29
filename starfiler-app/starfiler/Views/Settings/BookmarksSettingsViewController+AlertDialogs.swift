import AppKit

// MARK: - Group / Folder Alert Panels & Persistence

extension BookmarksSettingsViewController {
    @objc
    func addGroup(_ sender: Any?) {
        guard let result = presentGroupEditor(initialGroup: nil) else {
            return
        }

        var groups = bookmarksConfig.groups
        guard !hasGroup(named: result.name, in: groups) else {
            presentWarning(
                title: "Duplicate Group Name",
                informativeText: "A group named \"\(result.name)\" already exists."
            )
            return
        }

        groups.append(
            BookmarkGroup(
                name: result.name,
                entries: [],
                shortcutKey: result.shortcutKey,
                isDefault: false
            )
        )

        guard validateNoShortcutConflict(in: groups) else {
            return
        }
        persist(BookmarksConfig(groups: groups))
    }

    @objc
    func editGroup(_ sender: Any?) {
        guard let groupIndex = selectGroupIndex(
            title: "Edit Group",
            informativeText: "Choose a group to edit.",
            allowDefault: true,
            preferredGroupName: selectedRow?.groupName
        ) else {
            return
        }

        var groups = bookmarksConfig.groups
        let existingGroup = groups[groupIndex]

        guard let result = presentGroupEditor(initialGroup: existingGroup) else {
            return
        }

        guard !hasGroup(named: result.name, in: groups, excludingIndex: groupIndex) else {
            presentWarning(
                title: "Duplicate Group Name",
                informativeText: "A group named \"\(result.name)\" already exists."
            )
            return
        }

        let oldName = groups[groupIndex].name
        groups[groupIndex].name = result.name
        groups[groupIndex].shortcutKey = result.shortcutKey

        guard validateNoShortcutConflict(in: groups) else {
            return
        }

        let selectionTarget: BookmarkSelectionTarget?
        if let selectedRow, selectedRow.groupName == oldName {
            selectionTarget = BookmarkSelectionTarget(
                groupName: result.name,
                displayName: selectedRow.displayName,
                path: selectedRow.path
            )
        } else {
            selectionTarget = nil
        }
        persist(BookmarksConfig(groups: groups), selecting: selectionTarget)
    }

    @objc
    func deleteGroup(_ sender: Any?) {
        guard let groupIndex = selectGroupIndex(
            title: "Delete Group",
            informativeText: "Choose a group to delete.",
            allowDefault: false,
            preferredGroupName: selectedRow?.groupName
        ) else {
            return
        }

        let group = bookmarksConfig.groups[groupIndex]
        guard group.entries.isEmpty else {
            presentWarning(
                title: "Group Contains Folders",
                informativeText: "Move or delete all folders in \"\(group.name)\" before deleting the group."
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Group"
        alert.informativeText = "Delete group \"\(group.name)\"?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        var groups = bookmarksConfig.groups
        groups.remove(at: groupIndex)
        persist(BookmarksConfig(groups: groups))
    }

    func selectGroupIndex(
        title: String,
        informativeText: String,
        allowDefault: Bool,
        preferredGroupName: String?
    ) -> Int? {
        let candidates = bookmarksConfig.groups.enumerated().compactMap { index, group -> (Int, BookmarkGroup)? in
            guard allowDefault || !group.isDefault else {
                return nil
            }
            return (index, group)
        }

        guard !candidates.isEmpty else {
            presentWarning(
                title: "No Groups",
                informativeText: allowDefault
                    ? "There are no groups available."
                    : "Only the default group exists. It cannot be deleted."
            )
            return nil
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24), pullsDown: false)
        popup.addItems(withTitles: candidates.map { $0.1.name })
        if let preferredGroupName,
           let preferredIndex = candidates.firstIndex(where: { $0.1.name == preferredGroupName }) {
            popup.selectItem(at: preferredIndex)
        } else {
            popup.selectItem(at: 0)
        }
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let selected = popup.indexOfSelectedItem
        guard selected >= 0, candidates.indices.contains(selected) else {
            return nil
        }
        return candidates[selected].0
    }

    func presentGroupEditor(initialGroup: BookmarkGroup?) -> GroupEditorResult? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = initialGroup == nil ? "Add Group" : "Edit Group"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 112))

        let nameLabel = NSTextField(labelWithString: "Group Name")
        nameLabel.frame = NSRect(x: 0, y: 84, width: 240, height: 20)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor

        let nameField = NSTextField(frame: NSRect(x: 0, y: 60, width: 260, height: 24))
        nameField.placeholderString = "Group name"

        let shortcutLabel = NSTextField(labelWithString: "Group Shortcut Sequence (optional)")
        shortcutLabel.frame = NSRect(x: 0, y: 32, width: 240, height: 20)
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .secondaryLabelColor

        let shortcutField = NSTextField(frame: NSRect(x: 0, y: 8, width: 210, height: 24))
        shortcutField.placeholderString = "e.g. r"

        if let initialGroup {
            nameField.stringValue = initialGroup.name
            shortcutField.stringValue = initialGroup.shortcutKey ?? ""
        }

        container.addSubview(nameLabel)
        container.addSubview(nameField)
        container.addSubview(shortcutLabel)
        container.addSubview(shortcutField)
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presentWarning(
                title: "Missing Required Field",
                informativeText: "Group name is required."
            )
            return nil
        }

        return GroupEditorResult(
            name: name,
            shortcutKey: normalizedShortcutKey(shortcutField.stringValue)
        )
    }

    func presentFolderEditor(initialRow: BookmarkRow?) -> EditorResult? {
        let existingGroups = bookmarksConfig.groups
        guard !existingGroups.isEmpty else {
            presentWarning(
                title: "No Groups",
                informativeText: "Add a group before adding folder bookmarks."
            )
            return nil
        }

        let groupNames = existingGroups.map(\.name)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = initialRow == nil ? "Add Folder Bookmark" : "Edit Folder Bookmark"
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
        displayNameField.placeholderString = "Bookmark name"

        let entryShortcutLabel = NSTextField(labelWithString: "Folder Shortcut Sequence (optional)")
        entryShortcutLabel.frame = NSRect(x: 220, y: 108, width: 240, height: 20)
        entryShortcutLabel.font = .systemFont(ofSize: 11)
        entryShortcutLabel.textColor = .secondaryLabelColor

        let entryShortcutField = NSTextField(frame: NSRect(x: 220, y: 84, width: 170, height: 24))
        entryShortcutField.placeholderString = "e.g. d u"

        let pathLabel = NSTextField(labelWithString: "Path")
        pathLabel.frame = NSRect(x: 0, y: 56, width: 210, height: 20)
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor

        let pathField = NSTextField(frame: NSRect(x: 0, y: 32, width: 348, height: 24))
        pathField.placeholderString = "/path/to/directory"

        let browsePathButton = NSButton(title: "Browse...", target: self, action: #selector(browseFolderBookmarkPath(_:)))
        browsePathButton.frame = NSRect(x: 356, y: 32, width: 104, height: 24)
        browsePathButton.bezelStyle = .rounded

        container.addSubview(groupLabel)
        container.addSubview(groupPopup)
        container.addSubview(displayNameLabel)
        container.addSubview(displayNameField)
        container.addSubview(entryShortcutLabel)
        container.addSubview(entryShortcutField)
        container.addSubview(pathLabel)
        container.addSubview(pathField)
        container.addSubview(browsePathButton)
        alert.accessoryView = container

        if let initialRow {
            if let selectedIndex = groupNames.firstIndex(of: initialRow.groupName) {
                groupPopup.selectItem(at: selectedIndex)
            }
            displayNameField.stringValue = initialRow.displayName
            pathField.stringValue = initialRow.path
            entryShortcutField.stringValue = initialRow.shortcutKey ?? ""
        } else {
            groupPopup.selectItem(at: 0)
        }

        folderEditorPathField = pathField
        defer {
            folderEditorPathField = nil
        }

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let selectedGroupIndex = groupPopup.indexOfSelectedItem
        guard selectedGroupIndex >= 0, groupNames.indices.contains(selectedGroupIndex) else {
            return nil
        }

        let groupName = groupNames[selectedGroupIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = displayNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !groupName.isEmpty, !displayName.isEmpty, !path.isEmpty else {
            presentWarning(
                title: "Missing Required Fields",
                informativeText: "Group, display name, and path are required."
            )
            return nil
        }

        return EditorResult(
            groupName: groupName,
            displayName: displayName,
            path: path,
            shortcutKey: normalizedShortcutKey(entryShortcutField.stringValue)
        )
    }

    func normalizedShortcutKey(_ raw: String) -> String? {
        BookmarkShortcut.canonical(from: raw)
    }

    func upsertBookmark(with result: EditorResult, replacing existingRow: BookmarkRow?) {
        var groups = bookmarksConfig.groups
        let normalizedResultPath = normalizedBookmarkPath(result.path)

        if let existingRow,
           let existingGroupIndex = groups.firstIndex(where: { $0.name == existingRow.groupName }) {
            groups[existingGroupIndex].entries.removeAll { entry in
                isSameBookmarkPath(entry.path, existingRow.path) && entry.displayName == existingRow.displayName
            }
        }

        let newEntry = BookmarkEntry(
            displayName: result.displayName,
            path: normalizedResultPath,
            shortcutKey: result.shortcutKey
        )

        if let targetGroupIndex = groups.firstIndex(where: { $0.name == result.groupName }) {
            if let existingEntryIndex = groups[targetGroupIndex].entries.firstIndex(where: {
                isSameBookmarkPath($0.path, normalizedResultPath)
            }) {
                groups[targetGroupIndex].entries[existingEntryIndex] = newEntry
            } else {
                groups[targetGroupIndex].entries.append(newEntry)
            }
        } else {
            groups.append(
                BookmarkGroup(
                    name: result.groupName,
                    entries: [newEntry],
                    shortcutKey: nil,
                    isDefault: false
                )
            )
        }

        guard validateNoShortcutConflict(in: groups) else {
            return
        }

        persist(BookmarksConfig(groups: groups))
        persistSecurityScopedBookmark(for: result.path)
    }

    func validateNoShortcutConflict(in groups: [BookmarkGroup]) -> Bool {
        let config = BookmarksConfig(groups: groups)
        guard let conflict = config.firstShortcutConflict() else {
            return true
        }

        presentWarning(
            title: "Shortcut Conflict",
            informativeText:
                "Shortcut \"\(conflict.sequenceDisplayText)\" is already used by " +
                "\"\(conflict.existing.entryLabel)\" (group: \(conflict.existing.groupName)).\n\n" +
                "Change the shortcut and try again."
        )
        return false
    }

    func hasGroup(named name: String, in groups: [BookmarkGroup], excludingIndex: Int? = nil) -> Bool {
        groups.enumerated().contains { index, group in
            guard index != excludingIndex else {
                return false
            }
            return group.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    func presentWarning(title: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func persist(_ config: BookmarksConfig, selecting selectionTarget: BookmarkSelectionTarget? = nil) {
        do {
            try configManager.saveBookmarksConfig(config)
            bookmarksConfig = configManager.loadBookmarksConfig()
            rows = flattenRows(from: bookmarksConfig)
            tableView.reloadData()
            if let selectionTarget {
                selectRow(matching: selectionTarget)
            }
            updateButtonState()
            onBookmarksChanged?()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to save bookmarks"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func persistSecurityScopedBookmark(for path: String) {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            return
        }

        let resolvedPath = UserPaths.resolveBookmarkPath(normalizedPath)
        let url = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.securityScopedBookmarkService.saveBookmark(for: url)
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Bookmark saved without access permission"
                    alert.informativeText =
                        "Path: \(url.path)\n\n" +
                        "Open the folder once via Browse and save again to grant sandbox access.\n\n" +
                        error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    func selectRow(matching target: BookmarkSelectionTarget) {
        guard let rowIndex = rows.firstIndex(where: { row in
            row.groupName == target.groupName &&
                row.displayName == target.displayName &&
                isSameBookmarkPath(row.path, target.path)
        }) else {
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(rowIndex)
    }
}
