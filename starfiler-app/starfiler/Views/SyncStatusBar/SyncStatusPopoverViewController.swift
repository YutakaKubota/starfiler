import AppKit

@MainActor
final class SyncStatusPopoverViewController: NSViewController {
    private let viewModel: any SyncStatusBarPresenting
    private let onRefreshRequested: () -> Void
    private let onOpenSettingsRequested: () -> Void

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let headerTitleLabel = NSTextField(labelWithString: "")
    private let headerDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Settings", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No sync activity")

    init(
        viewModel: any SyncStatusBarPresenting,
        onRefreshRequested: @escaping () -> Void,
        onOpenSettingsRequested: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onRefreshRequested = onRefreshRequested
        self.onOpenSettingsRequested = onOpenSettingsRequested
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload(using: viewModel)
    }

    func reload(using viewModel: (any SyncStatusBarPresenting)?) {
        guard let viewModel else {
            return
        }

        headerTitleLabel.stringValue = viewModel.statusTitle
        headerDetailLabel.stringValue = viewModel.statusDetail ?? " "
        emptyLabel.isHidden = !(viewModel.peers.isEmpty && viewModel.conflicts.isEmpty && viewModel.recentTransfers.isEmpty)

        rebuildContent(using: viewModel)
        updatePreferredContentSize()
    }

    private func setupUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        headerDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        headerDetailLabel.font = .systemFont(ofSize: 12)
        headerDetailLabel.textColor = .secondaryLabelColor

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)

        let headerButtonStack = NSStackView(views: [refreshButton, settingsButton])
        headerButtonStack.translatesAutoresizingMaskIntoConstraints = false
        headerButtonStack.orientation = .horizontal
        headerButtonStack.spacing = 8

        let headerStack = NSStackView(views: [headerTitleLabel, headerDetailLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        let headerRow = NSStackView(views: [headerStack, NSView(), headerButtonStack])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = contentStack

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        view.addSubview(headerRow)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    private func rebuildContent(using viewModel: any SyncStatusBarPresenting) {
        clearStack(contentStack)

        contentStack.addArrangedSubview(sectionView(title: "Peers", rows: peerRows(for: viewModel.peers)))
        contentStack.addArrangedSubview(sectionView(title: "Conflicts", rows: conflictRows(for: viewModel.conflicts)))
        contentStack.addArrangedSubview(sectionView(title: "Recent Transfers", rows: transferRows(for: viewModel.recentTransfers)))
    }

    private func sectionView(title: String, rows: [NSView]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        container.addArrangedSubview(titleLabel)

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "None")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            container.addArrangedSubview(empty)
        } else {
            for row in rows {
                container.addArrangedSubview(row)
            }
        }

        return container
    }

    private func peerRows(for peers: [SyncPeerSummary]) -> [NSView] {
        peers.map { peer in
            let iconName = peer.isConnected ? (peer.isServer ? "server.rack" : "checkmark.circle.fill") : "circle.dashed"
            return rowView(
                iconName: iconName,
                title: peer.name,
                detail: "\(peer.role) · \(peer.status)"
            )
        }
    }

    private func conflictRows(for conflicts: [SyncConflictSummary]) -> [NSView] {
        conflicts.map { conflict in
            let timestamp = conflict.timestamp.map(Self.conflictFormatter.string(from:)) ?? ""
            let detail = timestamp.isEmpty ? conflict.detail : "\(conflict.detail) · \(timestamp)"
            return rowView(
                iconName: "exclamationmark.triangle.fill",
                title: conflict.relativePath,
                detail: detail,
                tint: .systemRed
            )
        }
    }

    private func transferRows(for transfers: [SyncTransferSummary]) -> [NSView] {
        transfers.map { transfer in
            let progress = transfer.progress.map {
                String(format: "%.0f%%", $0 * 100.0)
            } ?? transfer.status
            let detail = "\(transfer.direction) · \(progress) · \(transfer.detail)"
            return rowView(
                iconName: transfer.progress == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill",
                title: transfer.relativePath,
                detail: detail,
                tint: .controlAccentColor
            )
        }
    }

    private func rowView(iconName: String, title: String, detail: String, tint: NSColor? = nil) -> NSView {
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = tint ?? .controlAccentColor
        iconView.symbolConfiguration = .init(pointSize: 12, weight: .medium)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [iconView, textStack])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14)
        ])

        return row
    }

    private func clearStack(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func updatePreferredContentSize() {
        let estimatedHeight = 120 + CGFloat(contentStack.arrangedSubviews.count) * 92
        preferredContentSize = NSSize(width: 460, height: min(max(estimatedHeight, 320), 620))
    }

    @objc
    private func refreshTapped() {
        onRefreshRequested()
    }

    @objc
    private func settingsTapped() {
        onOpenSettingsRequested()
    }

    private static let conflictFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
