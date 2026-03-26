import AppKit

@MainActor
final class NetworkSyncSettingsViewController: NSViewController {
    private let viewModel: NetworkSyncViewModel

    private let titleLabel = NSTextField(labelWithString: "Network Sync")
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: "Configure the local role, root path, selective sync paths, and peer summaries for the upcoming network sync engine."
    )
    private let enabledCheckBox = NSButton(checkboxWithTitle: "Enable network sync", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(
        labels: SyncNodeMode.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let displayNameField = NSTextField()
    private let rootPathField = NSTextField()
    private let includedPathsTextView = NSTextView()
    private let conflictPolicyPopup = NSPopUpButton()
    private let heartbeatField = NSTextField()
    private let debounceField = NSTextField()
    private let peersTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)

    init(viewModel: NetworkSyncViewModel? = nil) {
        self.viewModel = viewModel ?? NetworkSyncViewModel()
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
        refreshFromViewModel()
    }

    private func configureUI() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 2

        enabledCheckBox.translatesAutoresizingMaskIntoConstraints = false
        enabledCheckBox.target = self
        enabledCheckBox.action = #selector(toggleEnabled(_:))

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))

        displayNameField.translatesAutoresizingMaskIntoConstraints = false
        displayNameField.placeholderString = "Display name shown to other Macs"

        rootPathField.translatesAutoresizingMaskIntoConstraints = false
        rootPathField.placeholderString = "/Volumes/HD-AD6U3/Shared"

        conflictPolicyPopup.translatesAutoresizingMaskIntoConstraints = false
        for policy in NetworkSyncConflictPolicy.allCases {
            conflictPolicyPopup.addItem(withTitle: policy.displayName)
            conflictPolicyPopup.lastItem?.representedObject = policy.rawValue
        }

        heartbeatField.translatesAutoresizingMaskIntoConstraints = false
        heartbeatField.formatter = decimalFormatter

        debounceField.translatesAutoresizingMaskIntoConstraints = false
        debounceField.formatter = decimalFormatter

        peersTextView.isEditable = false
        peersTextView.drawsBackground = false
        peersTextView.font = .systemFont(ofSize: 12)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveChanges(_:))

        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        reloadButton.bezelStyle = .rounded
        reloadButton.target = self
        reloadButton.action = #selector(reloadFromDisk(_:))
    }

    private func configureLayout() {
        let includedPathsScrollView = NSScrollView()
        includedPathsScrollView.translatesAutoresizingMaskIntoConstraints = false
        includedPathsScrollView.borderType = .bezelBorder
        includedPathsScrollView.hasVerticalScroller = true
        includedPathsScrollView.documentView = includedPathsTextView

        let peersScrollView = NSScrollView()
        peersScrollView.translatesAutoresizingMaskIntoConstraints = false
        peersScrollView.borderType = .bezelBorder
        peersScrollView.hasVerticalScroller = true
        peersScrollView.documentView = peersTextView

        let buttonStack = NSStackView(views: [saveButton, reloadButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12

        [
            titleLabel,
            descriptionLabel,
            enabledCheckBox,
            labeledRow(title: "Mode", field: modeControl),
            labeledRow(title: "Display Name", field: displayNameField),
            labeledRow(title: "Root Path", field: rootPathField),
            labeledSection(
                title: "Included Paths",
                detail: "One relative path per line. Leave blank to sync the whole root.",
                body: includedPathsScrollView,
                height: 110
            ),
            labeledRow(title: "Conflict Policy", field: conflictPolicyPopup),
            labeledRow(title: "Heartbeat (sec)", field: heartbeatField),
            labeledRow(title: "Debounce (sec)", field: debounceField),
            labeledSection(
                title: "Peers",
                detail: "Peer summaries are provided by the view model.",
                body: peersScrollView,
                height: 140
            ),
            statusLabel,
            buttonStack,
        ].forEach { content.addArrangedSubview($0) }

        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
    }

    private func refreshFromViewModel() {
        enabledCheckBox.state = viewModel.isEnabled ? .on : .off
        modeControl.selectedSegment = SyncNodeMode.allCases.firstIndex(of: viewModel.mode) ?? 0
        displayNameField.stringValue = viewModel.displayName
        rootPathField.stringValue = viewModel.rootPath
        includedPathsTextView.string = viewModel.includedPathsText
        conflictPolicyPopup.selectItem(withTitle: viewModel.conflictPolicy.displayName)
        heartbeatField.doubleValue = viewModel.heartbeatIntervalSeconds
        debounceField.doubleValue = viewModel.syncDebounceSeconds
        peersTextView.string = peerSummaryText()
        statusLabel.stringValue = viewModel.statusMessage
    }

    @objc
    private func toggleEnabled(_ sender: NSButton) {
        viewModel.isEnabled = sender.state == .on
    }

    @objc
    private func changeMode(_ sender: NSSegmentedControl) {
        let selectedIndex = max(sender.selectedSegment, 0)
        viewModel.mode = SyncNodeMode.allCases[selectedIndex]
    }

    @objc
    private func saveChanges(_ sender: NSButton) {
        viewModel.displayName = displayNameField.stringValue
        viewModel.rootPath = rootPathField.stringValue
        viewModel.includedPathsText = includedPathsTextView.string
        if let rawValue = conflictPolicyPopup.selectedItem?.representedObject as? String,
           let policy = NetworkSyncConflictPolicy(rawValue: rawValue) {
            viewModel.conflictPolicy = policy
        }
        viewModel.heartbeatIntervalSeconds = heartbeatField.doubleValue
        viewModel.syncDebounceSeconds = debounceField.doubleValue
        viewModel.save()
        refreshFromViewModel()
    }

    @objc
    private func reloadFromDisk(_ sender: NSButton) {
        viewModel.reload()
        refreshFromViewModel()
    }

    private func peerSummaryText() -> String {
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

    private func labeledRow(title: String, field: NSView) -> NSView {
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

    private func labeledSection(title: String, detail: String, body: NSView, height: CGFloat) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        body.heightAnchor.constraint(equalToConstant: height).isActive = true

        let stack = NSStackView(views: [titleLabel, detailLabel, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private var decimalFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }
}
