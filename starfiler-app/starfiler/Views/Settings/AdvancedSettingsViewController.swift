import AppKit

final class AdvancedSettingsViewController: NSViewController {
    private let configManager: ConfigManager

    var onConfigDirectoryChanged: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Advanced")
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: "Configure the folder where all settings data (bookmarks, keybindings, etc.) is stored."
    )
    private let dataFolderTitleLabel = NSTextField(labelWithString: "Data Folder")
    private let dataFolderPathLabel = NSTextField(labelWithString: "")
    private let changeButton = NSButton(title: "Change...", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset to Default", target: nil, action: nil)
    private let copyPathButton = NSButton(title: "Copy Path", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    init(configManager: ConfigManager = ConfigManager()) {
        self.configManager = configManager
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
        updateDataFolderPath()
    }

    private func configureUI() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.lineBreakMode = .byWordWrapping

        dataFolderTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        dataFolderTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        dataFolderPathLabel.translatesAutoresizingMaskIntoConstraints = false
        dataFolderPathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        dataFolderPathLabel.lineBreakMode = .byTruncatingMiddle
        dataFolderPathLabel.isSelectable = true

        changeButton.translatesAutoresizingMaskIntoConstraints = false
        changeButton.bezelStyle = .rounded
        changeButton.target = self
        changeButton.action = #selector(changeDataFolder(_:))

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetToDefault(_:))

        copyPathButton.translatesAutoresizingMaskIntoConstraints = false
        copyPathButton.bezelStyle = .rounded
        copyPathButton.target = self
        copyPathButton.action = #selector(copyPath(_:))

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
    }

    private func configureLayout() {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(descriptionLabel)
        contentView.addSubview(dataFolderTitleLabel)
        contentView.addSubview(dataFolderPathLabel)

        let buttonStack = NSStackView(views: [changeButton, resetButton, copyPathButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        contentView.addSubview(buttonStack)
        contentView.addSubview(statusLabel)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentView)
        scrollView.documentView = documentView
        view.addSubview(scrollView)

        let horizontalInset: CGFloat = 28
        let verticalInset: CGFloat = 28
        let maxContentWidth: CGFloat = 820
        let flexibleWidthConstraint = contentView.widthAnchor.constraint(
            equalTo: documentView.widthAnchor,
            constant: -(horizontalInset * 2)
        )
        flexibleWidthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            contentView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: verticalInset),
            contentView.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: horizontalInset),
            contentView.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -horizontalInset),
            contentView.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            contentView.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -verticalInset),
            contentView.widthAnchor.constraint(lessThanOrEqualToConstant: maxContentWidth),
            flexibleWidthConstraint,

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),

            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            dataFolderTitleLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 20),
            dataFolderTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            dataFolderPathLabel.topAnchor.constraint(equalTo: dataFolderTitleLabel.bottomAnchor, constant: 8),
            dataFolderPathLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dataFolderPathLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            buttonStack.topAnchor.constraint(equalTo: dataFolderPathLabel.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            statusLabel.centerYAnchor.constraint(equalTo: buttonStack.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: buttonStack.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
        ])
    }

    private func updateDataFolderPath() {
        dataFolderPathLabel.stringValue = configManager.configDirectory.path
        let isCustom = ConfigManager.customConfigDirectoryURL() != nil
        resetButton.isEnabled = isCustom
    }

    @objc
    private func changeDataFolder(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder to store Starfiler settings data."

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        let currentDirectory = configManager.configDirectory

        if selectedURL.standardizedFileURL == currentDirectory.standardizedFileURL {
            statusLabel.stringValue = "Same folder selected."
            return
        }

        let existingFiles = ConfigManager.existingConfigFileNames(in: selectedURL)
        if !existingFiles.isEmpty {
            switch promptExistingConfig(fileNames: existingFiles) {
            case .overwrite:
                do {
                    try ConfigManager.migrateConfigFiles(from: currentDirectory, to: selectedURL)
                } catch {
                    statusLabel.stringValue = "Failed to copy files."
                    return
                }
            case .import:
                break // 既存の設定をそのまま使う
            case .cancel:
                return
            }
        } else {
            do {
                try ConfigManager.migrateConfigFiles(from: currentDirectory, to: selectedURL)
            } catch {
                statusLabel.stringValue = "Failed to copy files."
                return
            }
        }

        ConfigManager.setCustomConfigDirectory(selectedURL)
        dataFolderPathLabel.stringValue = selectedURL.path
        resetButton.isEnabled = true
        statusLabel.stringValue = ""
        promptRestart()
    }

    @objc
    private func resetToDefault(_ sender: NSButton) {
        ConfigManager.setCustomConfigDirectory(nil)
        let defaultDir = ConfigManager.defaultFallbackConfigDirectory()
        dataFolderPathLabel.stringValue = defaultDir.path
        resetButton.isEnabled = false
        statusLabel.stringValue = ""
        promptRestart()
    }

    @objc
    private func copyPath(_ sender: NSButton) {
        let path = dataFolderPathLabel.stringValue
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        statusLabel.stringValue = "Copied"
    }

    private enum ExistingConfigAction {
        case overwrite
        case `import`
        case cancel
    }

    private func promptExistingConfig(fileNames: [String]) -> ExistingConfigAction {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Existing Configuration Found"
        let fileList = fileNames.joined(separator: ", ")
        alert.informativeText = "The selected folder already contains configuration files:\n\(fileList)\n\nWould you like to overwrite them with your current settings, or import the existing settings?"
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .overwrite
        case .alertSecondButtonReturn:
            return .import
        default:
            return .cancel
        }
    }

    private func promptRestart() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Restart Required"
        alert.informativeText = "The data folder has been changed. Starfiler needs to restart for the change to take effect."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            onConfigDirectoryChanged?()
        }
    }
}
