import AppKit

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension FilePaneViewController {
    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.directoryContents.displayedItems.count
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        let urls = dragURLsForTableView(rowIndexes: rowIndexes)
            .map(\.standardizedFileURL)
        guard !urls.isEmpty else {
            return false
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects(urls as [NSURL])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard viewModel.directoryContents.displayedItems.indices.contains(row) else {
            return nil
        }

        let item = viewModel.directoryContents.displayedItems[row]

        switch tableColumn?.identifier {
        case Column.name:
            let treeItem = viewModel.directoryContents.displayedTreeItems.indices.contains(row)
                ? viewModel.directoryContents.displayedTreeItems[row]
                : nil
            return makeNameCell(for: item, row: row, treeItem: treeItem)
        case Column.size:
            return makeTextCell(text: sizeText(for: item), alignment: .right)
        case Column.modified:
            return makeTextCell(text: modifiedText(for: item), alignment: .left)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let palette = filerTheme.palette
        let rowView = MarkedRowView()
        rowView.isMarkedRow = row == viewModel.paneState.cursorIndex
        rowView.isVisualMode = vimModeState.mode == .visual
        rowView.markedColor = palette.markedColor
        rowView.visualMarkedColor = palette.visualMarkedColor
        return rowView
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard viewModel.directoryContents.displayedItems.indices.contains(row) else {
            return nil
        }
        return viewModel.directoryContents.displayedItems[row].name
    }

    func tableView(
        _ tableView: NSTableView,
        nextTypeSelectMatchFromRow startRow: Int,
        toRow endRow: Int,
        for searchString: String
    ) -> Int {
        let normalizedSearch = searchString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSearch.isEmpty else {
            return -1
        }

        for (index, item) in viewModel.directoryContents.displayedItems.enumerated() {
            let matchedRange = item.name.range(
                of: normalizedSearch,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: .current
            )
            if matchedRange != nil {
                return index
            }
        }

        return -1
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelectionFromViewModel else {
            return
        }

        let selectedRow = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard selectedRow >= 0 else {
            return
        }

        isMouseMultiSelectionActive = false
        viewModel.clearMarks()
        rangeSelectionAnchorIndex = selectedRow
        viewModel.setCursor(index: selectedRow)
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let targetSortColumn: DirectoryContents.SortDescriptor.Column
        switch tableColumn.identifier {
        case Column.name:
            targetSortColumn = .name
        case Column.size:
            targetSortColumn = .size
        case Column.modified:
            targetSortColumn = .date
        default:
            return
        }

        let currentSortDescriptor = viewModel.directoryContents.sortDescriptor
        let nextAscending: Bool
        if currentSortDescriptor.column == targetSortColumn {
            nextAscending = !currentSortDescriptor.ascending
        } else {
            nextAscending = true
        }

        if starEffectsEnabled, animationEffectSettings.sortRowAnimation {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.layer?.add(transition, forKey: "sortTransition")
        }

        viewModel.setSortDescriptor(.init(column: targetSortColumn, ascending: nextAscending))
    }
}
