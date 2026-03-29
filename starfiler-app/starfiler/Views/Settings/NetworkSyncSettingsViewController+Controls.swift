import AppKit

// MARK: - Control Actions & Helpers

extension NetworkSyncSettingsViewController {
    @objc
    func toggleServerEnabled(_ sender: NSButton) {
        viewModel.setServerEnabled(sender.state == .on)
    }

    @objc
    func toggleClientEnabled(_ sender: NSButton) {
        viewModel.setClientEnabled(sender.state == .on)
    }

    @objc
    func chooseServerRootPath(_ sender: NSButton) {
        guard let selectedURL = chooseDirectory(initialPath: serverRootPathField.stringValue, prompt: "Choose Server Root") else {
            return
        }
        serverRootPathField.stringValue = selectedURL.path
    }

    @objc
    func chooseClientRootPath(_ sender: NSButton) {
        guard let selectedURL = chooseDirectory(initialPath: clientRootPathField.stringValue, prompt: "Choose Client Folder") else {
            return
        }
        clientRootPathField.stringValue = selectedURL.path
        withSuppressedViewModelRefresh {
            viewModel.clientRootPath = selectedURL.path
            viewModel.applyClientDefaultsIfNeeded()
            viewModel.refreshSelectiveSyncPreview()
        }
        refreshFromViewModel()
    }

    @objc
    func toggleSyncEntireRoot(_ sender: NSButton) {
        viewModel.setClientSyncEntireRoot(sender.state == .on)
    }

    @objc
    func refreshSelectiveSyncTree(_ sender: NSButton) {
        withSuppressedViewModelRefresh {
            viewModel.clientRootPath = clientRootPathField.stringValue
            viewModel.refreshSelectiveSyncPreview()
            viewModel.requestRefresh()
        }
        refreshFromViewModel()
    }

    @objc
    func selectAllSelectiveSyncItems(_ sender: NSButton) {
        viewModel.selectAllSelectiveSyncItems()
    }

    @objc
    func clearSelectiveSyncItems(_ sender: NSButton) {
        viewModel.clearAllSelectiveSyncItems()
    }

    @objc
    func expandAllSelectiveSyncItems(_ sender: NSButton) {
        expandSelectiveSyncTree()
        hasPerformedInitialSelectiveSyncExpansion = true
    }

    @objc
    func collapseAllSelectiveSyncItems(_ sender: NSButton) {
        for node in viewModel.selectiveSyncNodes {
            collapseRecursively(node)
        }
        hasPerformedInitialSelectiveSyncExpansion = true
    }

    @objc
    func saveChanges(_ sender: NSButton) {
        withSuppressedViewModelRefresh {
            viewModel.displayName = displayNameField.stringValue
            viewModel.serverRootPath = serverRootPathField.stringValue
            viewModel.clientRootPath = clientRootPathField.stringValue
            if let rawValue = conflictPolicyPopup.selectedItem?.representedObject as? String,
               let policy = NetworkSyncConflictPolicy(rawValue: rawValue) {
                viewModel.conflictPolicy = policy
            }
            viewModel.heartbeatIntervalSeconds = heartbeatField.doubleValue
            viewModel.syncDebounceSeconds = debounceField.doubleValue
            viewModel.save()
        }
        refreshFromViewModel()
    }

    @objc
    func reloadFromDisk(_ sender: NSButton) {
        viewModel.reload()
    }

    @objc
    func toggleSelectiveSyncItem(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              node(for: path, in: viewModel.selectiveSyncNodes) != nil else {
            return
        }

        let shouldSelect = sender.state != .off
        viewModel.toggleSelectiveNode(path: path, isSelected: shouldSelect)
    }

    func collapseRecursively(_ node: SelectiveSyncBrowserNode) {
        for child in node.children where child.isDirectory {
            collapseRecursively(child)
        }
        selectiveSyncOutlineView.collapseItem(node)
    }

    func node(for path: String, in roots: [SelectiveSyncBrowserNode]) -> SelectiveSyncBrowserNode? {
        for candidate in roots {
            if candidate.path == path {
                return candidate
            }
            if let found = node(for: path, in: candidate.children) {
                return found
            }
        }
        return nil
    }

    func peerSummaryText() -> String {
        if viewModel.peerSummaries.isEmpty {
            return "No peers configured yet."
        }

        return viewModel.peerSummaries
            .map { summary in
                [summary.title, summary.subtitle, summary.detail]
                    .joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    func rolesDescription() -> String {
        switch (viewModel.serverEnabled, viewModel.clientEnabled) {
        case (true, true):
            return "This Mac is publishing a shared root and mirroring checked folders locally. Keep the server root and client folder separate so changes do not loop back into each other."
        case (true, false):
            return "This Mac is acting as the authoritative server. Other Macs can discover it on the LAN and sync from the published shared root."
        case (false, true):
            return "This Mac is acting as a client. Checked folders are mirrored from the server into the local sync folder."
        case (false, false):
            return "Enable the server role to publish a shared root, the client role to mirror selected folders locally, or both at once."
        }
    }

    func serverRootHelpText() -> String {
        "Server role: this folder is the authoritative shared root. Put it on HD-ADU3 or another always-mounted volume."
    }

    func clientRootHelpText() -> String {
        "Client role: checked folders and files are downloaded into this local folder. Default is \(NetworkSyncConfig.defaultClientRootPath)."
    }

    func chooseDirectory(initialPath: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        if !initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: UserPaths.expandHomeVariables(in: initialPath))
        }
        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            return nil
        }
        return selectedURL
    }

    func labeledRow(title: String, field: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [titleLabel, field])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return row
    }

    func labeledSection(title: String, detail: String, body: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4

        let stack = NSStackView(views: [titleLabel, detailLabel, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    var decimalFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }
}
