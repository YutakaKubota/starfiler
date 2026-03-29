import AppKit

// MARK: - Context Menu

extension FilePaneViewController {
    struct ContextMenuContext {
        let contextItem: FileItem?
        let hasContextItem: Bool
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard isPaneContextMenu(menu) else {
            return
        }

        activeContextMenu = menu
        focusContextMenuFilterField(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard isPaneContextMenu(menu) else {
            return
        }

        activeContextMenu = nil
        contextMenuFilterText = ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard isPaneContextMenu(menu) else {
            return
        }

        activeContextMenu = menu
        contextMenuFilterText = ""
        rebuildContextMenu(menu, filterText: contextMenuFilterText)
        focusContextMenuFilterField(in: menu)
    }

    func makeContextMenuFilterField() -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.controlSize = .small
        field.placeholderString = "Filter actions..."
        field.font = .systemFont(ofSize: 12)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(handleContextMenuFilterChanged(_:))
        field.delegate = self
        return field
    }

    @objc
    func handleContextMenuFilterChanged(_ sender: NSSearchField) {
        guard sender === contextMenuFilterField else {
            return
        }

        contextMenuFilterText = sender.stringValue
        guard let menu = activeContextMenu else {
            return
        }

        updateContextMenuActionItems(in: menu, filterText: contextMenuFilterText)
    }
}

// MARK: - Context Menu Private Helpers

private extension FilePaneViewController {
    func isPaneContextMenu(_ menu: NSMenu) -> Bool {
        menu === tableView.menu || menu === mediaCollectionView.menu
    }

    func rebuildContextMenu(_ menu: NSMenu, filterText: String) {
        menu.removeAllItems()
        menu.addItem(makeContextMenuFilterMenuItem())
        menu.addItem(NSMenuItem.separator())
        contextMenuFilterField.stringValue = filterText
        updateContextMenuActionItems(in: menu, filterText: filterText)
    }

    func makeContextMenuFilterMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: ContextMenuMetrics.filterWidth,
                height: ContextMenuMetrics.filterHeight
            )
        )

        contextMenuFilterField.removeFromSuperview()
        contextMenuFilterField.frame = NSRect(
            x: ContextMenuMetrics.filterFieldInset,
            y: (ContextMenuMetrics.filterHeight - 22) / 2,
            width: ContextMenuMetrics.filterWidth - (ContextMenuMetrics.filterFieldInset * 2),
            height: 22
        )
        contextMenuFilterField.autoresizingMask = [.width]
        container.addSubview(contextMenuFilterField)
        item.view = container
        return item
    }

    func updateContextMenuActionItems(in menu: NSMenu, filterText: String) {
        while menu.items.count > ContextMenuMetrics.staticHeaderItemCount {
            menu.removeItem(at: ContextMenuMetrics.staticHeaderItemCount)
        }

        let allItems = makeContextMenuActionItems()
        let visibleItems = filterContextMenuItems(allItems, query: filterText)
        if visibleItems.isEmpty {
            let emptyItem = NSMenuItem(title: "No matching actions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        visibleItems.forEach { menu.addItem($0) }
    }

    func makeContextMenuActionItems() -> [NSMenuItem] {
        let context = currentContextMenuContext()
        let contextItem = context.contextItem
        let hasContextItem = context.hasContextItem

        var items: [NSMenuItem] = []

        let openTitle: String
        if let contextItem, contextItem.isDirectory && !contextItem.isPackage {
            openTitle = "Open"
        } else {
            openTitle = "Open with Default App"
        }

        items.append(makeContextMenuItem(
            title: openTitle,
            action: .openFile,
            shortcutActions: [.enterDirectory, .openFile],
            requiresContextItem: true,
            enabled: hasContextItem
        ))

        if let contextItem, contextItem.url.isImageFile {
            let openInPixelmatorItem = NSMenuItem(
                title: "Open in Pixelmator Pro",
                action: #selector(handleOpenInPixelmatorFromContextMenu(_:)),
                keyEquivalent: ""
            )
            openInPixelmatorItem.target = self
            openInPixelmatorItem.tag = 1
            items.append(openInPixelmatorItem)
        }

        items.append(makeContextMenuItem(
            title: "Show in Finder",
            action: .openFileInFinder,
            requiresContextItem: true,
            enabled: hasContextItem
        ))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(
            title: "Toggle Mark",
            action: .toggleMark,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(
            title: "Mark All",
            action: .markAll,
            enabled: !viewModel.directoryContents.displayedItems.isEmpty
        ))
        items.append(makeContextMenuItem(
            title: "Clear Marks",
            action: .clearMarks,
            enabled: viewModel.markedCount > 0
        ))

        if vimModeState.mode == .visual {
            items.append(makeContextMenuItem(title: "End Visual Selection", action: .exitVisualMode))
        } else {
            items.append(makeContextMenuItem(
                title: "Start Visual Selection",
                action: .enterVisualMode,
                requiresContextItem: true,
                enabled: hasContextItem
            ))
        }

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(
            title: "Copy",
            action: .copyToClipboard,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(
            title: "Copy File/Folder Path",
            action: .copySelectedItemPath,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(
            title: "Cut",
            action: .cutToClipboard,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(title: "Paste", action: .pasteFromClipboard))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(
            title: "Rename...",
            action: .rename,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(
            title: "Move to Trash",
            action: .delete,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(title: "New Folder", action: .createDirectory))
        items.append(makeContextMenuItem(
            title: "Batch Rename...",
            action: .batchRename,
            requiresContextItem: true,
            enabled: hasContextItem
        ))
        items.append(makeContextMenuItem(title: "Sync: Left → Right", action: .syncPanesLeftToRight))
        items.append(makeContextMenuItem(title: "Sync: Right → Left", action: .syncPanesRightToLeft))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(title: "Filter...", action: .enterFilterMode))
        items.append(makeContextMenuItem(title: "Spotlight Search...", action: .enterSpotlightSearch))
        items.append(makeContextMenuItem(title: "Clear Filter", action: .clearFilter))
        items.append(makeContextMenuItem(title: "Bookmark Search...", action: .openBookmarkSearch))
        items.append(makeContextMenuItem(title: "History...", action: .openHistory))
        items.append(makeContextMenuItem(title: "Add Bookmark...", action: .addBookmark))
        items.append(makeContextMenuItem(title: "Toggle Pin", action: .togglePin))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(title: "Back", action: .goBack))
        items.append(makeContextMenuItem(title: "Forward", action: .goForward))
        items.append(makeContextMenuItem(title: "Enclosing Folder", action: .goToParent))
        items.append(makeContextMenuItem(title: "Home", action: .goHome))
        items.append(makeContextMenuItem(title: "Desktop", action: .goDesktop))
        items.append(makeContextMenuItem(title: "Documents", action: .goDocuments))
        items.append(makeContextMenuItem(title: "Downloads", action: .goDownloads))
        items.append(makeContextMenuItem(title: "Applications", action: .goApplications))
        items.append(makeContextMenuItem(title: "Refresh", action: .refresh))
        items.append(makeContextMenuItem(title: "Toggle Hidden Files", action: .toggleHiddenFiles))
        items.append(makeSortMenuItem())
        items.append(makeContextMenuItem(title: "Toggle Media Mode", action: .toggleMediaMode))
        items.append(makeContextMenuItem(title: "Toggle Recursive Mode", action: .toggleRecursive))

        items.append(NSMenuItem.separator())

        items.append(makeContextMenuItem(title: "Toggle Sidebar", action: .toggleSidebar))
        items.append(makeContextMenuItem(title: "Toggle Left Pane", action: .toggleLeftPane))
        items.append(makeContextMenuItem(title: "Toggle Right Pane", action: .toggleRightPane))
        items.append(makeContextMenuItem(title: "Equalize Pane Widths", action: .equalizePaneWidths))
        items.append(makeContextMenuItem(title: "Set Other Pane to Current Folder", action: .matchOtherPaneDirectory))
        items.append(makeContextMenuItem(title: "Go to Other Pane Folder", action: .goToOtherPaneDirectory))
        items.append(makeContextMenuItem(title: "Switch Pane", action: .switchPane))

        return normalizeContextMenuItems(items)
    }

    func currentContextMenuContext() -> ContextMenuContext {
        let clickedRow = contextMenuClickedRow()
        let hasClickedItem = viewModel.directoryContents.displayedItems.indices.contains(clickedRow)
        let clickedItem = hasClickedItem ? viewModel.directoryContents.displayedItems[clickedRow] : nil
        let contextItem = clickedItem ?? viewModel.selectedItem
        return ContextMenuContext(contextItem: contextItem, hasContextItem: contextItem != nil)
    }

    func contextMenuClickedRow() -> Int {
        if currentDisplayMode == .media {
            return mediaCollectionView.selectionIndexPaths.first?.item ?? -1
        }

        return tableView.clickedRow
    }

    func filterContextMenuItems(_ items: [NSMenuItem], query: String) -> [NSMenuItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return items
        }

        var filtered: [NSMenuItem] = []
        var shouldInsertSeparator = false

        for item in items {
            if item.isSeparatorItem {
                shouldInsertSeparator = !filtered.isEmpty
                continue
            }

            guard contextMenuItemMatchesQuery(item, query: trimmedQuery) else {
                continue
            }

            if shouldInsertSeparator, !filtered.isEmpty {
                filtered.append(NSMenuItem.separator())
            }
            filtered.append(item)
            shouldInsertSeparator = false
        }

        return normalizeContextMenuItems(filtered)
    }

    func contextMenuItemMatchesQuery(_ item: NSMenuItem, query: String) -> Bool {
        if item.title.localizedCaseInsensitiveContains(query) {
            return true
        }

        guard let submenu = item.submenu else {
            return false
        }

        let filteredSubItems = filterContextMenuItems(submenu.items, query: query)
        guard !filteredSubItems.isEmpty else {
            return false
        }

        submenu.removeAllItems()
        filteredSubItems.forEach { submenu.addItem($0) }
        return true
    }

    func normalizeContextMenuItems(_ items: [NSMenuItem]) -> [NSMenuItem] {
        var normalized: [NSMenuItem] = []
        var previousWasSeparator = true

        for item in items {
            if item.isSeparatorItem {
                guard !previousWasSeparator else {
                    continue
                }
                normalized.append(item)
                previousWasSeparator = true
                continue
            }

            normalized.append(item)
            previousWasSeparator = false
        }

        if normalized.last?.isSeparatorItem == true {
            normalized.removeLast()
        }

        return normalized
    }

    func focusContextMenuFilterField(in menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.activeContextMenu === menu,
                  let window = self.contextMenuFilterField.window else {
                return
            }

            window.makeFirstResponder(self.contextMenuFilterField)
        }
    }

    func makeSortMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Sort", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Sort")

        submenu.addItem(makeContextMenuItem(title: "By Name", action: .sortByName))
        submenu.addItem(makeContextMenuItem(title: "By Size", action: .sortBySize))
        submenu.addItem(makeContextMenuItem(title: "By Date", action: .sortByDate))
        submenu.addItem(makeContextMenuItem(title: "By Selection Order", action: .sortBySelectionOrder))
        submenu.addItem(makeContextMenuItem(title: "Reverse Sort Order", action: .reverseSortOrder))

        item.submenu = submenu
        return item
    }

    func makeContextMenuItem(
        title: String,
        action keyAction: KeyAction,
        shortcutActions: [KeyAction]? = nil,
        requiresContextItem: Bool = false,
        enabled: Bool = true
    ) -> NSMenuItem {
        let actionsForShortcut = shortcutActions ?? [keyAction]
        let item = NSMenuItem(
            title: contextMenuTitle(title, actions: actionsForShortcut),
            action: #selector(contextMenuPerformAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = keyAction
        item.tag = requiresContextItem ? 1 : 0
        item.isEnabled = enabled
        return item
    }

    func contextMenuTitle(_ title: String, actions: [KeyAction]) -> String {
        var seen = Set<String>()
        var shortcuts: [String] = []

        for action in actions {
            for shortcut in preferredShortcuts(for: action) where !seen.contains(shortcut) {
                seen.insert(shortcut)
                shortcuts.append(shortcut)
            }
        }

        guard !shortcuts.isEmpty else {
            return title
        }

        return "\(title) (\(shortcuts.joined(separator: " / ")))"
    }

    func preferredShortcuts(for action: KeyAction) -> [String] {
        let normal = keybindingManager.shortcuts(for: action, mode: .normal)
        if !normal.isEmpty {
            return normal
        }

        let visual = keybindingManager.shortcuts(for: action, mode: .visual)
        if !visual.isEmpty {
            return visual
        }

        return keybindingManager.shortcuts(for: action, mode: .filter)
    }

    @objc
    func contextMenuPerformAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? KeyAction else {
            return
        }

        let requiresContextItem = sender.tag == 1
        guard resolveContextSelectionIfNeeded(requiresContextItem: requiresContextItem) else {
            return
        }

        _ = handleKeyAction(action)
    }

    func resolveContextSelectionIfNeeded(requiresContextItem: Bool) -> Bool {
        guard requiresContextItem else {
            return true
        }

        let clickedRow = contextMenuClickedRow()
        if viewModel.directoryContents.displayedItems.indices.contains(clickedRow) {
            viewModel.setCursor(index: clickedRow)
            return true
        }

        return viewModel.selectedItem != nil
    }

    @objc
    func handleOpenInPixelmatorFromContextMenu(_ sender: NSMenuItem) {
        let requiresContextItem = sender.tag == 1
        guard resolveContextSelectionIfNeeded(requiresContextItem: requiresContextItem),
              let selectedItem = viewModel.selectedItem,
              selectedItem.url.isImageFile else {
            NSSound.beep()
            return
        }

        let appURL = Self.pixelmatorProAppURL
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.open(
            [selectedItem.url],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if error != nil {
                NSSound.beep()
            }
        }
    }
}
