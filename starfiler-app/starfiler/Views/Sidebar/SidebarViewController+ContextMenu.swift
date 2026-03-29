import AppKit

// MARK: - Context Menu

extension SidebarViewController {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === regularContextMenu else {
            return
        }

        menu.removeAllItems()
        contextMenuTarget = nil

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0 else {
            return
        }

        let item = outlineView.item(atRow: clickedRow)
        guard let entry = sidebarEntry(from: item),
              let section = regularSection(for: item, in: outlineView),
              supportsContextMenu(for: section.kind) else {
            return
        }

        outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        contextMenuTarget = (section, entry)

        switch section.kind {
        case .favorites, .bookmarkGroup:
            let editItem = NSMenuItem(title: "Edit Bookmark\u{2026}", action: #selector(handleEditBookmarkFromContextMenu(_:)), keyEquivalent: "")
            editItem.target = self
            menu.addItem(editItem)

            let deleteItem = NSMenuItem(title: "Delete Bookmark", action: #selector(handleDeleteBookmarkFromContextMenu(_:)), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
        case .pinned:
            let unpinItem = NSMenuItem(title: "Unpin", action: #selector(handleUnpinPinnedItemFromContextMenu(_:)), keyEquivalent: "")
            unpinItem.target = self
            menu.addItem(unpinItem)
        case .recent:
            return
        }
    }

    func supportsContextMenu(for sectionKind: SidebarViewModel.SectionKind) -> Bool {
        switch sectionKind {
        case .favorites, .bookmarkGroup, .pinned:
            return true
        case .recent:
            return false
        }
    }

    @objc
    func handleEditBookmarkFromContextMenu(_ sender: Any?) {
        guard let contextMenuTarget else {
            return
        }

        onBookmarkContextActionRequested?(.editBookmark, contextMenuTarget.section.kind, contextMenuTarget.entry)
    }

    @objc
    func handleDeleteBookmarkFromContextMenu(_ sender: Any?) {
        guard let contextMenuTarget else {
            return
        }

        onBookmarkContextActionRequested?(.deleteBookmark, contextMenuTarget.section.kind, contextMenuTarget.entry)
    }

    @objc
    func handleUnpinPinnedItemFromContextMenu(_ sender: Any?) {
        guard let contextMenuTarget else {
            return
        }

        onBookmarkContextActionRequested?(.unpinPinnedItem, contextMenuTarget.section.kind, contextMenuTarget.entry)
    }
}
