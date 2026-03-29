import AppKit

// MARK: - NSOutlineViewDataSource / NSOutlineViewDelegate

extension SidebarViewController {
    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if outlineView === recentOutlineView {
            if item == nil {
                return recentSection?.items.count ?? 0
            }
            return 0
        }

        if item == nil {
            return regularSections.count
        }

        if let sectionTitle = item as? String,
           let section = regularSections.first(where: { $0.title == sectionTitle }) {
            if supportsHierarchicalDisplay(for: section.kind) {
                return bookmarkRootsBySectionTitle[sectionTitle]?.count ?? 0
            }
            return section.items.count
        }

        if let node = item as? BookmarkTreeNode {
            return node.children.count
        }

        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if outlineView === recentOutlineView {
            return recentSection?.items[index] ?? ""
        }

        if item == nil {
            return regularSections[index].title
        }

        if let sectionTitle = item as? String,
           let section = regularSections.first(where: { $0.title == sectionTitle }) {
            if supportsHierarchicalDisplay(for: section.kind) {
                return bookmarkRootsBySectionTitle[sectionTitle]?[index] ?? ""
            }
            return section.items[index]
        }

        if let node = item as? BookmarkTreeNode {
            return node.children[index]
        }

        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if outlineView === recentOutlineView {
            return false
        }
        if item is String {
            return true
        }
        if let node = item as? BookmarkTreeNode {
            return !node.children.isEmpty
        }
        return false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let sectionTitle = item as? String {
            return makeSectionHeaderView(title: sectionTitle, in: outlineView)
        }

        if let entry = item as? SidebarViewModel.SidebarEntry {
            return makeEntryView(entry: entry, in: outlineView)
        }

        if let node = item as? BookmarkTreeNode {
            return makeEntryView(entry: node.entry, in: outlineView)
        }

        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if outlineView === recentOutlineView {
            return false
        }
        return item is String
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarViewModel.SidebarEntry || item is BookmarkTreeNode
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if outlineView === recentOutlineView {
            return entryRowHeight
        }

        if item is String {
            return sectionHeaderHeight
        }
        return entryRowHeight
    }

    // MARK: - Cell Views

    func makeSectionHeaderView(title: String, in outlineView: NSOutlineView) -> NSView {
        let cellIdentifier = NSUserInterfaceItemIdentifier("sectionHeader")
        let palette = currentTheme.palette
        let isFavorites = isFavoritesSectionTitle(title)

        if let existing = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            existing.textField?.stringValue = title
            existing.textField?.textColor = palette.sidebarSectionHeaderColor
            if let starView = existing.viewWithTag(200) as? NSImageView {
                starView.isHidden = !isFavorites
                starView.contentTintColor = palette.starAccentColor
            }
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = cellIdentifier

        let starImageView = NSImageView()
        starImageView.translatesAutoresizingMaskIntoConstraints = false
        starImageView.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        starImageView.contentTintColor = palette.starAccentColor
        starImageView.tag = 200
        starImageView.isHidden = !isFavorites

        let textField = NSTextField(labelWithString: title)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 11, weight: .bold)
        textField.textColor = palette.sidebarSectionHeaderColor

        cell.textField = textField
        cell.addSubview(starImageView)
        cell.addSubview(textField)

        NSLayoutConstraint.activate([
            starImageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            starImageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            starImageView.widthAnchor.constraint(equalToConstant: 12),
            starImageView.heightAnchor.constraint(equalToConstant: 12),

            textField.leadingAnchor.constraint(equalTo: starImageView.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    func isFavoritesSectionTitle(_ title: String) -> Bool {
        guard let section = regularSections.first(where: { $0.title == title }) else {
            return false
        }
        if case .favorites = section.kind {
            return true
        }
        return false
    }

    func makeEntryView(entry: SidebarViewModel.SidebarEntry, in outlineView: NSOutlineView) -> NSView {
        let cellIdentifier = NSUserInterfaceItemIdentifier("entryCell")
        let cell: NSTableCellView
        let shortcutLabel: NSTextField
        let highlightBar: NSView

        let shortcutIdentifier = NSUserInterfaceItemIdentifier("shortcutLabel")
        let barIdentifier = NSUserInterfaceItemIdentifier("highlightBar")

        if let existing = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView,
           let existingShortcut = existing.subviews.first(where: { $0.identifier == shortcutIdentifier }) as? NSTextField,
           let existingBar = existing.subviews.first(where: { $0.identifier == barIdentifier }) {
            cell = existing
            shortcutLabel = existingShortcut
            highlightBar = existingBar
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

            highlightBar = NSView()
            highlightBar.translatesAutoresizingMaskIntoConstraints = false
            highlightBar.wantsLayer = true
            highlightBar.identifier = barIdentifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .systemFont(ofSize: 13)

            shortcutLabel = NSTextField(labelWithString: "")
            shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
            shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            shortcutLabel.textColor = .tertiaryLabelColor
            shortcutLabel.alignment = .right
            shortcutLabel.identifier = shortcutIdentifier
            shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
            shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            cell.imageView = imageView
            cell.textField = textField
            cell.addSubview(highlightBar)
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.addSubview(shortcutLabel)

            NSLayoutConstraint.activate([
                highlightBar.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                highlightBar.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
                highlightBar.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
                highlightBar.widthAnchor.constraint(equalToConstant: 3),

                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textField.trailingAnchor, constant: 4),
                shortcutLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                shortcutLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let palette = currentTheme.palette
        cell.textField?.stringValue = entry.displayName
        cell.imageView?.image = NSImage(systemSymbolName: entry.iconName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)

        highlightBar.isHidden = true
        if entry.isCurrentPosition {
            cell.textField?.font = .systemFont(ofSize: 13, weight: .semibold)
            cell.textField?.textColor = palette.starAccentColor
            cell.imageView?.contentTintColor = palette.starAccentColor
        } else {
            cell.textField?.font = .systemFont(ofSize: 13)
            cell.textField?.textColor = palette.sidebarEntryTextColor
            cell.imageView?.contentTintColor = palette.sidebarIconTintColor
        }

        shortcutLabel.stringValue = entry.shortcutHint ?? ""
        shortcutLabel.isHidden = entry.shortcutHint == nil
        shortcutLabel.textColor = palette.sidebarShortcutHintColor

        return cell
    }
}
