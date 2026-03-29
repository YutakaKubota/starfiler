import AppKit

final class BookmarksSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onBookmarksChanged: (() -> Void)?

    struct BookmarkRow {
        let groupName: String
        let isDefaultGroup: Bool
        let displayName: String
        let path: String
        let shortcutKey: String?
        let groupShortcutKey: String?
    }

    struct EditorResult {
        let groupName: String
        let displayName: String
        let path: String
        let shortcutKey: String?
    }

    struct GroupEditorResult {
        let name: String
        let shortcutKey: String?
    }

    struct BookmarkSelectionTarget {
        let groupName: String
        let displayName: String
        let path: String
    }

    struct BookmarkPosition {
        let groupIndex: Int
        let entryIndex: Int
    }

    struct BookmarkIdentity: Hashable {
        let groupName: String
        let displayName: String
        let path: String
        let shortcutKey: String?
    }

    let configManager: ConfigManager
    let securityScopedBookmarkService: any SecurityScopedBookmarkProviding

    private let descriptionLabel = NSTextField(
        wrappingLabelWithString:
            "Configure group shortcut keys and folder shortcut keys separately. " +
            "Shortcut keys can be a sequence (example: \"r d\" or \"d u\"). " +
            "Set group keys with the group actions, then assign each folder to a group. " +
            "Use Move buttons to reorder groups and folders."
    )
    private let groupActionsStack = NSStackView()
    private let addGroupButton = NSButton(title: "Add Group", target: nil, action: nil)
    private let editGroupButton = NSButton(title: "Edit Group", target: nil, action: nil)
    private let deleteGroupButton = NSButton(title: "Delete Group", target: nil, action: nil)
    private let moveGroupUpButton = NSButton(title: "Move Group Up", target: nil, action: nil)
    private let moveGroupDownButton = NSButton(title: "Move Group Down", target: nil, action: nil)

    private let scrollView = NSScrollView()
    let tableView = NSTableView()

    private let addButton = NSButton(title: "Add Folder", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit Folder", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Folder", target: nil, action: nil)
    private let moveUpButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let moveDownButton = NSButton(title: "Move Down", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let openConfigButton = NSButton(title: "Open Config File", target: nil, action: nil)

    var bookmarksConfig = BookmarksConfig()
    var rows: [BookmarkRow] = []
    weak var folderEditorPathField: NSTextField?

    init(
        configManager: ConfigManager = ConfigManager(),
        securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared
    ) {
        self.configManager = configManager
        self.securityScopedBookmarkService = securityScopedBookmarkService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        configureLayout()
        reloadFromDisk()
    }

    private func configureUI() {
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 3
        descriptionLabel.lineBreakMode = .byWordWrapping

        groupActionsStack.translatesAutoresizingMaskIntoConstraints = false
        groupActionsStack.orientation = .horizontal
        groupActionsStack.spacing = 8
        groupActionsStack.alignment = .centerY

        addGroupButton.translatesAutoresizingMaskIntoConstraints = false
        addGroupButton.bezelStyle = .rounded
        addGroupButton.target = self
        addGroupButton.action = #selector(addGroup(_:))

        editGroupButton.translatesAutoresizingMaskIntoConstraints = false
        editGroupButton.bezelStyle = .rounded
        editGroupButton.target = self
        editGroupButton.action = #selector(editGroup(_:))

        deleteGroupButton.translatesAutoresizingMaskIntoConstraints = false
        deleteGroupButton.bezelStyle = .rounded
        deleteGroupButton.target = self
        deleteGroupButton.action = #selector(deleteGroup(_:))

        moveGroupUpButton.translatesAutoresizingMaskIntoConstraints = false
        moveGroupUpButton.bezelStyle = .rounded
        moveGroupUpButton.target = self
        moveGroupUpButton.action = #selector(moveGroupUp(_:))

        moveGroupDownButton.translatesAutoresizingMaskIntoConstraints = false
        moveGroupDownButton.bezelStyle = .rounded
        moveGroupDownButton.target = self
        moveGroupDownButton.action = #selector(moveGroupDown(_:))

        groupActionsStack.addArrangedSubview(addGroupButton)
        groupActionsStack.addArrangedSubview(editGroupButton)
        groupActionsStack.addArrangedSubview(deleteGroupButton)
        groupActionsStack.addArrangedSubview(moveGroupUpButton)
        groupActionsStack.addArrangedSubview(moveGroupDownButton)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = true
        tableView.target = self
        tableView.doubleAction = #selector(editBookmark(_:))

        let groupColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        groupColumn.title = "Group"
        groupColumn.width = 140
        groupColumn.minWidth = 100

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Display Name"
        nameColumn.width = 150
        nameColumn.minWidth = 120

        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "Path"
        pathColumn.width = 320
        pathColumn.minWidth = 220

        let shortcutColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutColumn.title = "Shortcut"
        shortcutColumn.width = 200
        shortcutColumn.minWidth = 140

        tableView.addTableColumn(groupColumn)
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(pathColumn)
        tableView.addTableColumn(shortcutColumn)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addBookmark(_:))

        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editBookmark(_:))

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteBookmark(_:))

        moveUpButton.translatesAutoresizingMaskIntoConstraints = false
        moveUpButton.bezelStyle = .rounded
        moveUpButton.target = self
        moveUpButton.action = #selector(moveBookmarkUp(_:))

        moveDownButton.translatesAutoresizingMaskIntoConstraints = false
        moveDownButton.bezelStyle = .rounded
        moveDownButton.target = self
        moveDownButton.action = #selector(moveBookmarkDown(_:))

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.bezelStyle = .rounded
        reloadButton.target = self
        reloadButton.action = #selector(reloadBookmarks(_:))

        openConfigButton.translatesAutoresizingMaskIntoConstraints = false
        openConfigButton.bezelStyle = .rounded
        openConfigButton.target = self
        openConfigButton.action = #selector(openConfigFile(_:))
    }

    private func configureLayout() {
        view.addSubview(descriptionLabel)
        view.addSubview(groupActionsStack)
        view.addSubview(scrollView)
        view.addSubview(addButton)
        view.addSubview(editButton)
        view.addSubview(deleteButton)
        view.addSubview(moveUpButton)
        view.addSubview(moveDownButton)
        view.addSubview(reloadButton)
        view.addSubview(openConfigButton)

        NSLayoutConstraint.activate([
            descriptionLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            descriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            groupActionsStack.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 8),
            groupActionsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            groupActionsStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: groupActionsStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            editButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            editButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            deleteButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 8),
            deleteButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            moveUpButton.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 8),
            moveUpButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            moveDownButton.leadingAnchor.constraint(equalTo: moveUpButton.trailingAnchor, constant: 8),
            moveDownButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            openConfigButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            openConfigButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            reloadButton.trailingAnchor.constraint(equalTo: openConfigButton.leadingAnchor, constant: -8),
            reloadButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])
    }

    func reloadFromDisk() {
        bookmarksConfig = configManager.loadBookmarksConfig()
        rows = flattenRows(from: bookmarksConfig)
        tableView.reloadData()
        updateButtonState()
    }

    func flattenRows(from config: BookmarksConfig) -> [BookmarkRow] {
        var result: [BookmarkRow] = []
        for group in config.groups {
            for entry in group.entries {
                result.append(
                    BookmarkRow(
                        groupName: group.name,
                        isDefaultGroup: group.isDefault,
                        displayName: entry.displayName,
                        path: entry.path,
                        shortcutKey: entry.shortcutKey,
                        groupShortcutKey: group.shortcutKey
                    )
                )
            }
        }
        return result
    }

    func updateButtonState() {
        let hasSelection = !selectedRows.isEmpty
        let hasSingleSelection = selectedRows.count == 1
        editButton.isEnabled = hasSingleSelection
        deleteButton.isEnabled = hasSelection
        moveUpButton.isEnabled = canMoveSelectedBookmarkUp
        moveDownButton.isEnabled = canMoveSelectedBookmarkDown
        addButton.isEnabled = !bookmarksConfig.groups.isEmpty

        let hasGroups = !bookmarksConfig.groups.isEmpty
        editGroupButton.isEnabled = hasGroups
        deleteGroupButton.isEnabled = bookmarksConfig.groups.contains { !$0.isDefault }
        let canMoveGroups = bookmarksConfig.groups.count > 1
        moveGroupUpButton.isEnabled = canMoveGroups
        moveGroupDownButton.isEnabled = canMoveGroups
    }

    var selectedRow: BookmarkRow? {
        guard selectedRows.count == 1 else {
            return nil
        }
        let row = tableView.selectedRow
        guard row >= 0, rows.indices.contains(row) else {
            return nil
        }
        return rows[row]
    }

    var selectedRows: [BookmarkRow] {
        tableView.selectedRowIndexes.compactMap { rowIndex in
            guard rows.indices.contains(rowIndex) else {
                return nil
            }
            return rows[rowIndex]
        }
    }

    var canMoveSelectedBookmarkUp: Bool {
        guard let selectedRow, let position = position(for: selectedRow) else {
            return false
        }
        return position.entryIndex > 0
    }

    var canMoveSelectedBookmarkDown: Bool {
        guard let selectedRow, let position = position(for: selectedRow) else {
            return false
        }
        return position.entryIndex + 1 < bookmarksConfig.groups[position.groupIndex].entries.count
    }

    func position(for row: BookmarkRow) -> BookmarkPosition? {
        guard let groupIndex = bookmarksConfig.groups.firstIndex(where: { $0.name == row.groupName }) else {
            return nil
        }

        let entries = bookmarksConfig.groups[groupIndex].entries
        guard let entryIndex = entries.firstIndex(where: { entry in
            isSameBookmarkPath(entry.path, row.path) &&
                entry.displayName == row.displayName &&
                entry.shortcutKey == row.shortcutKey
        }) else {
            return nil
        }

        return BookmarkPosition(groupIndex: groupIndex, entryIndex: entryIndex)
    }
}
