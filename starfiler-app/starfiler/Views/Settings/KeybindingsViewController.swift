import AppKit

final class KeybindingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onKeybindingsChanged: (() -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let segmentedControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)
    private let openConfigButton = NSButton(title: "Open Config File", target: nil, action: nil)

    private static let modes = ["all", "normal", "visual", "filter", "menu"]

    private var filterText: String = ""
    private var currentMode: String = "all"
    private var displayedBindings: [(sequence: String, action: String, isReadOnly: Bool, mode: String)] = []
    private var allBindings: [String: [(sequence: String, action: String, isReadOnly: Bool)]] = [:]
    private var conflictKeys: Set<String> = []

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadBindings()
        loadMenuBindings()
        configureUI()
        configureLayout()
        reloadTable()
    }

    private func loadBindings() {
        let defaultConfig = loadDefaultConfig()
        let userConfig = loadUserConfig()
        let merged = KeybindingManager.merge(defaultConfig: defaultConfig, userConfig: userConfig)

        for key in allBindings.keys where key != "menu" {
            allBindings.removeValue(forKey: key)
        }
        for (modeName, bindings) in merged.bindings {
            var entries: [(String, String, Bool)] = []
            for (sequence, action) in bindings.sorted(by: { $0.value < $1.value }) {
                entries.append((sequence, action, false))
            }
            allBindings[modeName] = entries
        }
    }

    private func loadMenuBindings() {
        let menuShortcuts: [(String, String)] = [
            ("\u{2318}N", "New Folder"),
            ("\u{2318}\u{21A9}", "Open"),
            ("\u{2318}Z", "Undo"),
            ("\u{2318}C", "Copy"),
            ("\u{2318}\u{2325}C", "Copy File/Folder Path"),
            ("\u{2318}V", "Paste"),
            ("\u{232B}", "Move to Trash"),
            ("\u{2318}A", "Select All"),
            ("\u{2318}S", "Toggle Sidebar"),
            ("\u{2318}1", "Show Files"),
            ("\u{2318}2", "Show Media"),
            ("\u{2303}1", "Toggle Left Pane"),
            ("\u{2303}2", "Toggle Right Pane"),
            ("\u{2303}3", "Toggle Single Pane"),
            ("\u{2303}4", "Equalize Pane Widths"),
            ("\u{2303}M", "Toggle Media Mode"),
            ("\u{2303}\u{21E7}F", "Toggle Recursive Mode"),
            ("\u{2318}.", "Toggle Hidden Files"),
            ("\u{2318}R", "Refresh"),
            ("\u{2318}[", "Go Back"),
            ("\u{2318}]", "Go Forward"),
            ("Esc", "Enclosing Folder"),
            ("\u{2318}\u{21E7}C", "HD"),
            ("\u{2318}\u{21E7}H", "Home"),
            ("\u{2318}\u{21E7}D", "Desktop"),
            ("\u{2318}\u{21E7}O", "Documents"),
            ("\u{2318}\u{2325}L", "Downloads"),
            ("\u{2318}\u{21E7}A", "Applications"),
            ("\u{2318}W", "Close Window"),
            ("\u{2318}M", "Minimize"),
            ("\u{2318}\u{21E5}", "Switch Pane"),
            ("\u{2318},", "Settings"),
            ("\u{2318}Q", "Quit"),
        ]
        allBindings["menu"] = menuShortcuts.map { ($0.0, $0.1, true) }
    }

    private func loadDefaultConfig() -> KeybindingsConfig? {
        guard let url = Bundle.main.url(forResource: "DefaultKeybindings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(KeybindingsConfig.self, from: data) else {
            return nil
        }
        return config
    }

    private func loadUserConfig() -> KeybindingsConfig? {
        guard let url = KeybindingManager.defaultUserConfigURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(KeybindingsConfig.self, from: data) else {
            return nil
        }
        return config
    }

    private func configureUI() {
        let modes = Self.modes
        segmentedControl.segmentCount = modes.count
        for (index, mode) in modes.enumerated() {
            segmentedControl.setLabel(mode.capitalized, forSegment: index)
        }
        segmentedControl.selectedSegment = 0
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.target = self
        segmentedControl.action = #selector(modeChanged(_:))

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter keybindings..."
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        searchField.sendsSearchStringImmediately = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.doubleAction = #selector(handleDoubleClick(_:))
        tableView.target = self

        let sequenceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sequence"))
        sequenceColumn.title = "Key Sequence"
        sequenceColumn.width = 200
        sequenceColumn.minWidth = 120

        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = "Action"
        actionColumn.width = 300
        actionColumn.minWidth = 150

        tableView.addTableColumn(sequenceColumn)
        tableView.addTableColumn(actionColumn)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetToDefaults(_:))

        openConfigButton.translatesAutoresizingMaskIntoConstraints = false
        openConfigButton.bezelStyle = .rounded
        openConfigButton.target = self
        openConfigButton.action = #selector(openConfigFile(_:))
    }

    private func configureLayout() {
        let outerInset: CGFloat = 24

        view.addSubview(segmentedControl)
        view.addSubview(searchField)
        view.addSubview(scrollView)
        view.addSubview(resetButton)
        view.addSubview(openConfigButton)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.topAnchor, constant: outerInset),
            segmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            searchField.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: outerInset),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -outerInset),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: outerInset),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -outerInset),
            scrollView.bottomAnchor.constraint(equalTo: resetButton.topAnchor, constant: -8),

            resetButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: outerInset),
            resetButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -outerInset),

            openConfigButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -outerInset),
            openConfigButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -outerInset),
        ])
    }

    private func reloadTable() {
        let modeColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("mode"))
        if currentMode == "all" {
            if modeColumn == nil {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
                col.title = "Mode"
                col.width = 80
                col.minWidth = 60
                tableView.addTableColumn(col)
            }
        } else {
            if let col = modeColumn {
                tableView.removeTableColumn(col)
            }
        }

        var entries: [(sequence: String, action: String, isReadOnly: Bool, mode: String)]
        if currentMode == "all" {
            entries = []
            for mode in Self.modes where mode != "all" {
                for binding in allBindings[mode] ?? [] {
                    entries.append((binding.sequence, binding.action, binding.isReadOnly, mode))
                }
            }
            entries.sort { $0.action < $1.action }
        } else {
            entries = (allBindings[currentMode] ?? []).map { ($0.sequence, $0.action, $0.isReadOnly, currentMode) }
        }

        if !filterText.isEmpty {
            let query = filterText.lowercased()
            entries = entries.filter { entry in
                formatSequence(entry.sequence).lowercased().contains(query)
                    || formatAction(entry.action).lowercased().contains(query)
                    || entry.mode.lowercased().contains(query)
            }
        }

        displayedBindings = entries
        buildConflictKeys()
        tableView.reloadData()
    }

    private func buildConflictKeys() {
        conflictKeys = []
        var seen: [String: Int] = [:]
        for entry in displayedBindings {
            let key = "\(entry.mode):\(entry.sequence)"
            seen[key, default: 0] += 1
        }
        for (key, count) in seen where count > 1 {
            conflictKeys.insert(key)
        }
    }

    private func isConflict(at row: Int) -> Bool {
        guard displayedBindings.indices.contains(row) else { return false }
        let entry = displayedBindings[row]
        return conflictKeys.contains("\(entry.mode):\(entry.sequence)")
    }

    @objc
    private func modeChanged(_ sender: NSSegmentedControl) {
        let modes = Self.modes
        let index = sender.selectedSegment
        guard modes.indices.contains(index) else {
            return
        }
        currentMode = modes[index]
        reloadTable()
    }

    @objc
    private func filterChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
        reloadTable()
    }

    @objc
    private func handleDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, displayedBindings.indices.contains(row) else {
            return
        }

        let binding = displayedBindings[row]
        if binding.isReadOnly {
            return
        }

        presentKeyRecorder(forRow: row)
    }

    private func presentKeyRecorder(forRow row: Int) {
        let binding = displayedBindings[row]
        let bindingMode = binding.mode

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Edit Keybinding"
        alert.informativeText = "Action: \(formatAction(binding.action))\nCurrent: \(formatSequence(binding.sequence))\n\nPress a new key combination, then choose Save.\nUse Clear Shortcut to remove this shortcut only."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear Shortcut")
        alert.addButton(withTitle: "Cancel")

        let recorder = KeyRecorderView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))

        var recordedNewSequence: String?
        recorder.onKeyRecorded = { sequence in
            recordedNewSequence = sequence
        }

        alert.accessoryView = recorder

        DispatchQueue.main.async {
            recorder.startRecording(currentBinding: self.formatSequence(binding.sequence))
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            guard let newSequence = recordedNewSequence else {
                presentWarning(
                    title: "No Shortcut Recorded",
                    informativeText: "Record a key combination before saving, or use Clear Shortcut."
                )
                return
            }

            if let conflict = findConflict(sequence: newSequence, mode: bindingMode, excludingSequence: binding.sequence) {
                let resolution = presentConflictResolutionAlert(
                    newSequence: newSequence,
                    conflictAction: conflict,
                    currentAction: binding.action,
                    mode: bindingMode
                )
                switch resolution {
                case .replaceExisting:
                    saveKeybinding(oldSequence: binding.sequence, newSequence: newSequence, action: binding.action, mode: bindingMode)
                case .clearCurrent:
                    clearKeybinding(sequence: binding.sequence, mode: bindingMode)
                case .cancel:
                    return
                }
            } else {
                saveKeybinding(oldSequence: binding.sequence, newSequence: newSequence, action: binding.action, mode: bindingMode)
            }
            refreshBindingsTable()
        case .alertSecondButtonReturn:
            clearKeybinding(sequence: binding.sequence, mode: bindingMode)
            refreshBindingsTable()
        default:
            return
        }
    }

    private enum ConflictResolution {
        case replaceExisting
        case clearCurrent
        case cancel
    }

    private func presentConflictResolutionAlert(
        newSequence: String,
        conflictAction: String,
        currentAction: String,
        mode: String
    ) -> ConflictResolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Key Conflict"
        alert.informativeText =
            "\"\(formatSequence(newSequence))\" is already bound to \"\(formatAction(conflictAction))\" in \(mode) mode.\n\n" +
            "Choose which shortcut to clear."
        alert.addButton(withTitle: "Clear Existing and Assign")
        alert.addButton(withTitle: "Clear \(formatAction(currentAction)) Shortcut")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .replaceExisting
        case .alertSecondButtonReturn:
            return .clearCurrent
        default:
            return .cancel
        }
    }

    private func findConflict(sequence: String, mode: String, excludingSequence: String) -> String? {
        guard let bindings = allBindings[mode] else { return nil }
        for binding in bindings {
            if binding.sequence == sequence && binding.sequence != excludingSequence {
                return binding.action
            }
        }
        return nil
    }

    private func saveKeybinding(oldSequence: String, newSequence: String, action: String, mode: String) {
        guard let (url, userConfig) = loadUserConfigForWrite() else { return }

        var updatedConfig = userConfig
        var modeBindings = userConfig.bindings[mode] ?? [:]
        if oldSequence != newSequence {
            clearSequence(oldSequence, in: &modeBindings)
        }
        modeBindings[newSequence] = action
        updatedConfig.bindings[mode] = modeBindings

        persistUserConfig(updatedConfig, to: url)
    }

    private func clearKeybinding(sequence: String, mode: String) {
        guard let (url, userConfig) = loadUserConfigForWrite() else { return }

        var updatedConfig = userConfig
        var modeBindings = userConfig.bindings[mode] ?? [:]
        clearSequence(sequence, in: &modeBindings)
        updatedConfig.bindings[mode] = modeBindings

        persistUserConfig(updatedConfig, to: url)
    }

    private func clearSequence(_ sequence: String, in modeBindings: inout [String: String]) {
        modeBindings[sequence] = KeybindingsConfig.unboundActionName
    }

    private func loadUserConfigForWrite() -> (URL, KeybindingsConfig)? {
        guard let url = KeybindingManager.defaultUserConfigURL() else {
            return nil
        }

        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode(KeybindingsConfig.self, from: data) {
            return (url, existing)
        }

        return (url, KeybindingsConfig(bindings: [:]))
    }

    private func persistUserConfig(_ config: KeybindingsConfig, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else {
            return
        }

        let parentDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        onKeybindingsChanged?()
    }

    private func refreshBindingsTable() {
        loadBindings()
        loadMenuBindings()
        reloadTable()
    }

    private func presentWarning(title: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc
    private func resetToDefaults(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Keybindings"
        alert.informativeText = "This will delete your custom keybindings and restore the defaults. Continue?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        if let url = KeybindingManager.defaultUserConfigURL(),
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            onKeybindingsChanged?()
        }

        loadBindings()
        loadMenuBindings()
        reloadTable()
    }

    @objc
    private func openConfigFile(_ sender: Any?) {
        guard let url = KeybindingManager.defaultUserConfigURL() else {
            return
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            let config = loadDefaultConfig() ?? KeybindingsConfig(bindings: [:])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(config) {
                let parentDir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try? data.write(to: url, options: [.atomic])
            }
        }

        NSWorkspace.shared.open(url)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedBindings.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedBindings.indices.contains(row) else {
            return nil
        }

        let binding = displayedBindings[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")

        let cellIdentifier = NSUserInterfaceItemIdentifier("keybindCell")
        let cell: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.textField = textField
            cell.addSubview(textField)

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let textColor: NSColor
        if isConflict(at: row) {
            textColor = .systemRed
        } else if binding.isReadOnly {
            textColor = .tertiaryLabelColor
        } else {
            textColor = .labelColor
        }

        switch identifier.rawValue {
        case "sequence":
            cell.textField?.stringValue = formatSequence(binding.sequence)
            cell.textField?.textColor = textColor
        case "action":
            cell.textField?.stringValue = formatAction(binding.action)
            cell.textField?.textColor = textColor
        case "mode":
            cell.textField?.stringValue = binding.mode.capitalized
            cell.textField?.textColor = textColor
        default:
            cell.textField?.stringValue = ""
        }

        return cell
    }

    private func formatSequence(_ sequence: String) -> String {
        sequence
            .replacingOccurrences(of: "Ctrl-", with: "^")
            .replacingOccurrences(of: "Shift-", with: "\u{21E7}")
            .replacingOccurrences(of: "Alt-", with: "\u{2325}")
            .replacingOccurrences(of: "Cmd-", with: "\u{2318}")
    }

    private func formatAction(_ action: String) -> String {
        if action.contains(" ") { return action }
        let words = action.reduce(into: "") { result, char in
            if char.isUppercase && !result.isEmpty {
                result.append(" ")
            }
            result.append(char)
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
