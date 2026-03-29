import AppKit

// MARK: - Drag & Drop

extension FilePaneViewController {
    func configureDragAndDrop() {
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.dragSourceHandler = fileDragSource
        tableView.dragURLsProvider = { [weak self] in
            self?.dragURLsForTableView() ?? []
        }
        tableView.dropTargetHandler = fileDropTarget

        mediaCollectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        mediaCollectionView.setDraggingSourceOperationMask([.copy], forLocal: false)
        mediaCollectionView.dragSourceHandler = fileDragSource
        mediaCollectionView.dragURLsProvider = { [weak self] in
            self?.viewModel.markedOrSelectedURLs() ?? []
        }

        fileDropTarget.onHighlightChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            self.isDropTargetHighlighted = highlighted
            self.updateActiveAppearance()
            if highlighted {
                self.startDropPulse()
            } else {
                self.stopDropPulse()
            }
        }

        fileDropTarget.onDropCompleted = { [weak self] operation, itemCount in
            guard let self else { return }
            self.stopDropPulse()
            if self.starEffectsEnabled, self.animationEffectSettings.dropZonePulse, let layer = self.view.layer {
                let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
                StarSparkleAnimator.burst(count: 6, in: layer, at: center,
                    color: self.filerTheme.palette.starGlowColor, size: 8, duration: 0.4)
            }
            self.viewModel.refreshCurrentDirectory()
            self.onDropOperationCompleted?(operation, itemCount)
        }

        fileDropTarget.onDropFailed = { [weak self] message in
            self?.presentDropError(message)
        }
    }

    func dragURLsForTableView(rowIndexes: IndexSet? = nil) -> [URL] {
        if let rowIndexes, !rowIndexes.isEmpty {
            let displayedItems = viewModel.directoryContents.displayedItems
            let rowURLs = rowIndexes.compactMap { row -> URL? in
                guard displayedItems.indices.contains(row) else {
                    return nil
                }
                return displayedItems[row].url
            }
            if !rowURLs.isEmpty {
                return rowURLs
            }
        }

        if !viewModel.paneState.markedIndices.isEmpty {
            return viewModel.markedOrSelectedURLs()
        }

        let displayedItems = viewModel.directoryContents.displayedItems
        let selectedURLs = tableView.selectedRowIndexes.compactMap { row -> URL? in
            guard displayedItems.indices.contains(row) else {
                return nil
            }
            return displayedItems[row].url
        }
        if !selectedURLs.isEmpty {
            return selectedURLs
        }

        let clickedRow = tableView.clickedRow
        if displayedItems.indices.contains(clickedRow) {
            return [displayedItems[clickedRow].url]
        }

        return viewModel.markedOrSelectedURLs()
    }

    func dropDestinationDirectory(for draggingInfo: NSDraggingInfo) -> URL? {
        let row = dropDestinationRow(for: draggingInfo)
        guard viewModel.directoryContents.displayedItems.indices.contains(row) else {
            return nil
        }

        let item = viewModel.directoryContents.displayedItems[row]
        guard item.isDirectory, !item.isPackage else {
            return nil
        }

        return item.url.standardizedFileURL
    }

    func dropDestinationRow(for draggingInfo: NSDraggingInfo) -> Int {
        let draggingPoint = draggingInfo.draggingLocation
        var candidatePoints: [NSPoint] = []

        candidatePoints.append(tableView.convert(draggingPoint, from: nil))

        if let window = tableView.window {
            let windowPoint = window.convertPoint(fromScreen: draggingPoint)
            candidatePoints.append(tableView.convert(windowPoint, from: nil))
        }

        candidatePoints.append(draggingPoint)

        for point in candidatePoints {
            let row = dropDestinationRow(at: point)
            if row >= 0 {
                return row
            }
        }

        return -1
    }

    func dropDestinationRow(at point: NSPoint) -> Int {
        let directRow = tableView.row(at: point)
        if directRow >= 0 {
            return directRow
        }

        let probeRect = NSRect(
            x: tableView.bounds.minX,
            y: point.y,
            width: max(tableView.bounds.width, 1),
            height: 1
        )
        let intersectingRows = tableView.rows(in: probeRect)
        return intersectingRows.location == NSNotFound ? -1 : intersectingRows.location
    }

    func presentDropError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Drop Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
