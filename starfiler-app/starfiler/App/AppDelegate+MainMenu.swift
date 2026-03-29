import AppKit

// MARK: - Main Menu Construction & Menu Actions
extension AppDelegate {
    func buildMainMenu() {
        NSApp.mainMenu = MainMenuBuilder().build()
    }

    // MARK: - Menu Actions

    @objc func menuCreateDirectory(_ sender: Any?) {
        mainWindowController?.performAction { $0.createDirectory() }
    }

    @objc func menuOpenFile(_ sender: Any?) {
        mainWindowController?.openSelectedItemInActivePane()
    }

    @objc func menuRevealInFinder(_ sender: Any?) {
        mainWindowController?.performAction { vm in
            guard let url = vm.activePane.selectedItem?.url.standardizedFileURL else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc func undo(_ sender: Any?) {
        mainWindowController?.performAction { $0.undo() }
    }

    @objc func copy(_ sender: Any?) {
        mainWindowController?.performAction { vm in
            let copiedURLs = vm.copyMarkedToClipboard()
            guard !copiedURLs.isEmpty else {
                NSSound.beep()
                return
            }
            writeFileURLsToPasteboard(copiedURLs, operation: .copy)
        }
    }

    @objc func cut(_ sender: Any?) {
        mainWindowController?.performAction { vm in
            let cutURLs = vm.cutMarkedToClipboard()
            guard !cutURLs.isEmpty else {
                NSSound.beep()
                return
            }
            writeFileURLsToPasteboard(cutURLs, operation: .cut)
        }
    }

    @objc func menuCopySelectedItemPath(_ sender: Any?) {
        mainWindowController?.performAction { vm in
            let paths = vm.activePane.markedOrSelectedPaths()
            guard !paths.isEmpty else {
                NSSound.beep()
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        }
    }

    @objc func paste(_ sender: Any?) {
        syncFileClipboardFromPasteboardIfNeeded()
        mainWindowController?.performAction { $0.pasteToActivePane() }
    }

    @objc func menuPasteAsMove(_ sender: Any?) {
        syncFileClipboardFromPasteboardIfNeeded()
        mainWindowController?.performAction { $0.pasteToActivePaneAsMove() }
    }

    @objc func menuDelete(_ sender: Any?) {
        mainWindowController?.requestDeleteFromActivePane()
    }

    func writeFileURLsToPasteboard(_ urls: [URL], operation: ClipboardOperation) {
        let pasteboard = NSPasteboard.general
        let normalizedURLs = urls.map(\.standardizedFileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects(normalizedURLs as [NSURL])
        pasteboard.setString(
            pasteboardOperationValue(for: operation),
            forType: FileClipboardPasteboard.operationType
        )
        fileClipboardChangeCount = pasteboard.changeCount
    }

    func syncFileClipboardFromPasteboardIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard fileClipboardChangeCount != pasteboard.changeCount else {
            return
        }

        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let pastedURLs = pasteboard.readObjects(forClasses: classes, options: options) as? [URL], !pastedURLs.isEmpty else {
            fileClipboardChangeCount = pasteboard.changeCount
            mainWindowController?.performAction { $0.replaceClipboard(urls: [], operation: .copy) }
            return
        }

        let normalizedURLs = pastedURLs.map(\.standardizedFileURL)
        let operation = pasteboardOperation(from: pasteboard)
        fileClipboardChangeCount = pasteboard.changeCount
        mainWindowController?.performAction { $0.replaceClipboard(urls: normalizedURLs, operation: operation) }
    }

    func pasteboardOperation(from pasteboard: NSPasteboard) -> ClipboardOperation {
        guard let rawValue = pasteboard.string(forType: FileClipboardPasteboard.operationType) else {
            return .copy
        }

        switch rawValue {
        case FileClipboardPasteboard.cutOperationValue:
            return .cut
        default:
            return .copy
        }
    }

    func pasteboardOperationValue(for operation: ClipboardOperation) -> String {
        switch operation {
        case .copy:
            return FileClipboardPasteboard.copyOperationValue
        case .cut:
            return FileClipboardPasteboard.cutOperationValue
        }
    }

    @objc func menuRename(_ sender: Any?) {
        mainWindowController?.performAction { $0.rename() }
    }

    @objc func menuBatchRename(_ sender: Any?) {
        mainWindowController?.presentBatchRename()
    }

    @objc func menuSyncLeftToRight(_ sender: Any?) {
        mainWindowController?.performAction { $0.syncPanesLeftToRight() }
    }

    @objc func menuSyncRightToLeft(_ sender: Any?) {
        mainWindowController?.performAction { $0.syncPanesRightToLeft() }
    }

    @objc func menuSelectAll(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.markAll() }
    }

    @objc func menuShowFilesMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.setDisplayMode(.browser) }
    }

    @objc func menuShowMediaMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.setDisplayMode(.media) }
    }

    @objc func menuToggleLeftPane(_ sender: Any?) {
        mainWindowController?.toggleLeftPane()
    }

    @objc func menuToggleRightPane(_ sender: Any?) {
        mainWindowController?.toggleRightPane()
    }

    @objc func menuToggleSinglePane(_ sender: Any?) {
        mainWindowController?.toggleSinglePane()
    }

    @objc func menuEqualizePaneWidths(_ sender: Any?) {
        mainWindowController?.equalizePaneWidths()
    }

    @objc func menuToggleMediaMode(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleDisplayMode() }
    }

    @objc func menuToggleRecursive(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleRecursive() }
    }

    @objc func menuToggleHiddenFiles(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.toggleHiddenFiles() }
    }

    @objc func menuRefresh(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.refresh() }
    }

    @objc func menuGoBack(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goBack() }
    }

    @objc func menuGoForward(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goForward() }
    }

    @objc func menuGoToParent(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.goToParent() }
    }

    @objc func menuGoToPath(_ sender: Any?) {
        mainWindowController?.presentGoToPathPrompt()
    }

    @objc func menuGoHD(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: URL(fileURLWithPath: "/", isDirectory: true))
        }
    }

    @objc func menuGoHome(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.homeDirectoryURL)
        }
    }

    @objc func menuGoDesktop(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.desktopDirectoryURL)
        }
    }

    @objc func menuGoDocuments(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.documentsDirectoryURL)
        }
    }

    @objc func menuGoDownloads(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: UserPaths.downloadsDirectoryURL)
        }
    }

    @objc func menuGoApplications(_ sender: Any?) {
        mainWindowController?.performAction {
            $0.activePane.navigate(to: URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
    }

    @objc func menuSortByName(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortByName() }
    }

    @objc func menuSortBySize(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortBySize() }
    }

    @objc func menuSortByDate(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortByDate() }
    }

    @objc func menuSortBySelectionOrder(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.sortBySelectionOrder() }
    }

    @objc func menuReverseSortOrder(_ sender: Any?) {
        mainWindowController?.performAction { $0.activePane.reverseSortOrder() }
    }

    @objc func menuToggleSidebar(_ sender: Any?) {
        mainWindowController?.toggleSidebarPane()
    }

    @objc func menuSwitchPane(_ sender: Any?) {
        mainWindowController?.performAction { $0.switchActivePane() }
    }

    @objc func menuLaunchClaude(_ sender: Any?) {
        mainWindowController?.launchTerminalSession(command: .claude)
    }

    @objc func menuLaunchCodex(_ sender: Any?) {
        mainWindowController?.launchTerminalSession(command: .codex)
    }

    @objc func menuToggleSessionManager(_ sender: Any?) {
        mainWindowController?.toggleSessionManager()
    }

    @MainActor
    @objc func menuShowSettings(_ sender: Any?) {
        presentSettingsWindow()
    }
}
