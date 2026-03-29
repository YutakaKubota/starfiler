import AppKit

// MARK: - Search & Filter

extension FilePaneViewController {
    var selectedSearchMode: SearchMode {
        currentSearchMode
    }

    func focusSearch(mode: SearchMode) {
        if selectedSearchMode != mode {
            currentSearchMode = mode
            updateSearchModeUI()
        }

        onDidRequestActivate?()
        vimModeState.enterFilterMode()
        tableView.setVimMode(vimModeState.mode)
        mediaCollectionView.setVimMode(vimModeState.mode)

        isSearchFieldFocused = true
        view.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
        updateSearchFieldAppearance()

        if starEffectsEnabled, animationEffectSettings.filterBarGlow {
            let palette = filerTheme.palette
            searchField.wantsLayer = true
            searchField.layer?.shadowColor = palette.starAccentColor.cgColor
            searchField.layer?.shadowRadius = 6
            searchField.layer?.shadowOffset = .zero
            searchField.layer?.shadowOpacity = 0

            let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
            glow.values = [0.0, 0.6, 0.2]
            glow.keyTimes = [0, 0.5, 1.0]
            glow.duration = 0.3
            glow.isRemovedOnCompletion = false
            glow.fillMode = .forwards
            searchField.layer?.shadowOpacity = 0.2
            searchField.layer?.add(glow, forKey: "searchGlow")
        }
    }

    func clearSearchAndReturnToTable() {
        searchField.stringValue = ""
        currentSearchMode = .filter
        updateSearchModeUI()
        viewModel.clearFilter()
        viewModel.exitSpotlightSearchMode()

        searchField.layer?.removeAnimation(forKey: "searchGlow")
        searchField.layer?.shadowOpacity = 0

        switchToNormalModeAndFocusTable()
    }

    func switchToNormalModeAndFocusTable() {
        vimModeState.enterNormalMode()
        tableView.setVimMode(vimModeState.mode)
        mediaCollectionView.setVimMode(vimModeState.mode)
        focusTable()
    }

    func updateSearchModeUI() {
        let mode = selectedSearchMode
        updateSearchFieldButtonIcon(
            symbolName: mode.iconSymbolName,
            accessibilityLabel: mode.iconAccessibilityLabel
        )
        updateSearchMenuSelectionStates()
        updateSearchFieldAppearance()
    }

    func updateSearchFieldAppearance() {
        guard isViewLoaded else {
            return
        }

        let palette = filerTheme.palette
        let borderColor = isSearchFieldFocused ? palette.activeBorderColor : NSColor.separatorColor
        searchField.layer?.borderColor = borderColor.cgColor
        searchField.layer?.borderWidth = isSearchFieldFocused ? 1.0 : 0.5
    }

    func updateSearchMenuSelectionStates() {
        for (mode, item) in searchMenuModeItems {
            item.state = selectedSearchMode == mode ? .on : .off
        }

        for (scope, item) in searchMenuScopeItems {
            item.state = viewModel.spotlightSearchScope == scope ? .on : .off
        }
    }

    func applySearchFromHeader() {
        let query = searchField.stringValue

        switch selectedSearchMode {
        case .filter:
            viewModel.exitSpotlightSearchMode()
            viewModel.setFilterText(query)
        case .spotlight:
            viewModel.clearFilter()
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                viewModel.exitSpotlightSearchMode()
            } else {
                viewModel.enterSpotlightSearchMode()
                viewModel.updateSpotlightSearchQuery(trimmed)
            }
        }
    }

    func configureSearchFieldMenuTemplate() {
        let menu = NSMenu(title: "Search Options")
        searchMenuModeItems.removeAll(keepingCapacity: true)
        searchMenuScopeItems.removeAll(keepingCapacity: true)

        let modeHeader = NSMenuItem(title: "Search Mode", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        for mode in [SearchMode.filter, .spotlight] {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(handleSearchModeMenuSelection(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            menu.addItem(item)
            searchMenuModeItems[mode] = item
        }

        menu.addItem(NSMenuItem.separator())

        let scopeHeader = NSMenuItem(title: "Spotlight Scope", action: nil, keyEquivalent: "")
        scopeHeader.isEnabled = false
        menu.addItem(scopeHeader)

        for scope in SpotlightSearchScope.allCases {
            let item = NSMenuItem(title: scope.displayName, action: #selector(handleSpotlightScopeMenuSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scope.rawValue
            menu.addItem(item)
            searchMenuScopeItems[scope] = item
        }

        searchField.searchMenuTemplate = menu
        updateSearchMenuSelectionStates()
    }

    func configureSearchFieldButtonAction() {
        guard let cell = searchField.cell as? NSSearchFieldCell else {
            return
        }
        cell.searchButtonCell?.target = self
        cell.searchButtonCell?.action = #selector(handleSearchFieldButtonClick(_:))
    }

    // MARK: NSTextFieldDelegate / NSSearchFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as? NSControl) === searchField else {
            return
        }

        onDidRequestActivate?()
        isSearchFieldFocused = true
        vimModeState.enterFilterMode()
        tableView.setVimMode(vimModeState.mode)
        mediaCollectionView.setVimMode(vimModeState.mode)
        updateSearchFieldAppearance()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let control = obj.object as? NSControl else {
            return
        }

        if control === contextMenuFilterField {
            handleContextMenuFilterChanged(contextMenuFilterField)
            return
        }

        guard control === searchField else {
            return
        }

        applySearchFromHeader()
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        guard sender === searchField else {
            return
        }

        applySearchFromHeader()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSControl) === searchField else {
            return
        }

        restoreNormalModeIfNeededAfterSearch()
        isSearchFieldFocused = false
        updateSearchFieldAppearance()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else {
            return false
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            clearSearchAndReturnToTable()
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if selectedSearchMode == .spotlight {
                viewModel.enterSelected()
                viewModel.exitSpotlightSearchMode()
                searchField.stringValue = ""
                currentSearchMode = .filter
                updateSearchModeUI()

                switchToNormalModeAndFocusTable()
                return true
            }

            applySearchFromHeader()
            let trimmedFilterQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFilterQuery.isEmpty else {
                switchToNormalModeAndFocusTable()
                return true
            }

            viewModel.focusFirstBrowsableDirectoryInFilteredResults()
            if let selectedItem = viewModel.selectedItem, selectedItem.isDirectory, !selectedItem.isPackage {
                addSlideTransition(direction: .fromRight)
                viewModel.enterSelected()
                switchToNormalModeAndFocusTable()
            }
            return true
        }

        return false
    }
}

// MARK: - Search Private Helpers

private extension FilePaneViewController {
    func updateSearchFieldButtonIcon(symbolName: String, accessibilityLabel: String) {
        guard let cell = searchField.cell as? NSSearchFieldCell,
              let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) else {
            return
        }

        let configuredImage = symbolImage.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        ) ?? symbolImage
        configuredImage.isTemplate = true

        cell.searchButtonCell?.image = configuredImage
        cell.searchButtonCell?.alternateImage = configuredImage
        searchField.toolTip = accessibilityLabel
    }

    @objc
    func handleSearchFieldButtonClick(_ sender: Any?) {
        guard let menu = searchField.searchMenuTemplate else {
            return
        }

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: searchField)
            return
        }

        menu.popUp(positioning: nil, at: .zero, in: searchField)
    }

    @objc
    func handleSearchModeMenuSelection(_ sender: NSMenuItem) {
        guard let mode = SearchMode(rawValue: sender.tag), selectedSearchMode != mode else {
            return
        }

        currentSearchMode = mode
        updateSearchModeUI()
        applySearchFromHeader()
    }

    @objc
    func handleSpotlightScopeMenuSelection(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let scope = SpotlightSearchScope(rawValue: rawValue) else {
            return
        }

        viewModel.setSpotlightSearchScope(scope)
        onSpotlightSearchScopeChanged?(scope)
        updateSearchMenuSelectionStates()
        applySearchFromHeader()
    }
}
