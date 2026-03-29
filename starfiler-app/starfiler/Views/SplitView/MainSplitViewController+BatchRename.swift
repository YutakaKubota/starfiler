import AppKit

extension MainSplitViewController {

    // MARK: - Batch Rename

    func presentBatchRenameWindow() {
        let urls = viewModel.activePane.markedOrSelectedURLs()
        guard !urls.isEmpty else { return }

        let urlSet = Set(urls)
        let items = viewModel.activePane.directoryContents.displayedItems
            .filter { urlSet.contains($0.url) }
        guard !items.isEmpty else { return }

        let allItems = viewModel.activePane.directoryContents.displayedItems

        let batchVM = BatchRenameViewModel(
            sourceFiles: items,
            allDirectoryFiles: allItems,
            configManager: configManager
        )

        batchVM.onApplyRequested = { [weak self] changes in
            self?.viewModel.executeBatchRename(renames: changes)
            self?.batchRenameWindowController?.close()
            self?.batchRenameWindowController = nil
        }

        batchVM.onDismissRequested = { [weak self] in
            self?.batchRenameWindowController?.close()
            self?.batchRenameWindowController = nil
        }

        let vc = BatchRenameViewController(viewModel: batchVM)
        let window = NSWindow(contentViewController: vc)
        window.title = "Batch Rename (\(items.count) files)"
        window.setContentSize(NSSize(width: 720, height: 600))
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 600, height: 400)
        window.center()

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        batchRenameWindowController = wc
    }

    // MARK: - Markdown Preview

    func presentMarkdownPreviews(for fileURLs: [URL]) {
        guard let window = view.window else {
            return
        }

        let palette = currentFilerTheme.palette
        let normalizedURLs = Array(Set(fileURLs.map(\.standardizedFileURL)))
        for fileURL in normalizedURLs {
            if let panel = markdownPreviewPanelControllers[fileURL] {
                panel.focus()
                continue
            }

            let panel = MarkdownPreviewPanelController()
            panel.onDismiss = { [weak self] in
                self?.markdownPreviewPanelControllers.removeValue(forKey: fileURL)
                self?.focusActivePane()
            }

            panel.showRelativeTo(window: window, fileURL: fileURL, palette: palette)
            markdownPreviewPanelControllers[fileURL] = panel
        }
    }
}
