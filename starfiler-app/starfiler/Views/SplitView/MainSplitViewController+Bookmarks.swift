import AppKit

extension MainSplitViewController {

    func presentAddBookmarkAlert() {
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

    func saveBookmark(entry: BookmarkEntry, groupName: String, groupShortcutKey: String? = nil) {
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

    func persistSecurityScopedBookmark(for path: String) {
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

    func normalizeBookmarkEntry(_ entry: BookmarkEntry) -> BookmarkEntry {
        BookmarkEntry(
            displayName: entry.displayName,
            path: normalizedBookmarkPath(entry.path),
            shortcutKey: entry.shortcutKey
        )
    }

    func normalizedBookmarkPath(_ rawPath: String) -> String {
        UserPaths.portableBookmarkPath(rawPath)
    }

    func isSameBookmarkPath(_ lhs: String, _ rhs: String) -> Bool {
        normalizedBookmarkPath(lhs) == normalizedBookmarkPath(rhs)
    }

    func presentSidebarBookmarkEditor(
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

    func deleteSidebarBookmark(
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

    func persistBookmarkConfigAfterSidebarAction(
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

    func propagateBookmarksConfig() {
        leftPaneViewController.updateBookmarksConfig(bookmarksConfig)
        rightPaneViewController.updateBookmarksConfig(bookmarksConfig)
    }

    func presentBookmarkSearchPanel() {
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

    func navigateToSearchResult(_ result: BookmarkSearchViewModel.SearchResult) {
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
}
