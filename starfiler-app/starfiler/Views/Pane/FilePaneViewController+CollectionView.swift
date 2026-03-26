import AppKit

// MARK: - NSCollectionViewDataSource, NSCollectionViewDelegate & FlowLayout

extension FilePaneViewController {
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewModel.directoryContents.displayedItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: MediaCollectionItem.identifier, for: indexPath)
        guard
            let mediaItem = item as? MediaCollectionItem,
            viewModel.directoryContents.displayedItems.indices.contains(indexPath.item)
        else {
            return item
        }

        let fileItem = viewModel.directoryContents.displayedItems[indexPath.item]
        let isMarked = indexPath.item == viewModel.paneState.cursorIndex
        mediaItem.configure(
            name: fileItem.name,
            thumbnail: icon(for: fileItem, row: indexPath.item),
            isMarked: isMarked,
            isVideo: fileItem.url.isVideoFile,
            palette: filerTheme.palette
        )
        return mediaItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingSelectionFromViewModel else {
            return
        }

        guard let indexPath = indexPaths.first else {
            return
        }

        isMouseMultiSelectionActive = false
        viewModel.clearMarks()
        rangeSelectionAnchorIndex = indexPath.item
        viewModel.setCursor(index: indexPath.item)

        if
            currentDisplayMode == .media,
            viewModel.directoryContents.displayedItems.indices.contains(indexPath.item),
            viewModel.directoryContents.displayedItems[indexPath.item].url.isAudioFile
        {
            onInlineMediaPlaybackRequested?()
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
        return
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let insets = mediaCollectionLayout.sectionInset
        let interitemSpacing = mediaCollectionLayout.minimumInteritemSpacing
        let availableWidth = max(120, collectionView.bounds.width - insets.left - insets.right)
        let targetWidth = preferredMediaTileWidth()
        let columns = max(Int((availableWidth + interitemSpacing) / (targetWidth + interitemSpacing)), 1)
        let totalSpacing = CGFloat(max(columns - 1, 0)) * interitemSpacing
        let width = floor((availableWidth - totalSpacing) / CGFloat(columns))
        return NSSize(width: width, height: width * 0.78 + 34)
    }

    func fileTableView(_ tableView: FileTableView, didTrigger action: KeyAction) -> Bool {
        handleKeyAction(action)
    }

    func mediaCollectionView(_ collectionView: MediaCollectionView, didTrigger action: KeyAction) -> Bool {
        handleKeyAction(action)
    }
}
