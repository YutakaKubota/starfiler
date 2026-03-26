import AppKit

enum SyncStatusLevel: Int, Sendable {
    case idle
    case syncing
    case attention
    case offline

    var symbolName: String {
        switch self {
        case .idle:
            return "cloud.fill"
        case .syncing:
            return "cloud.bolt.fill"
        case .attention:
            return "exclamationmark.icloud.fill"
        case .offline:
            return "wifi.slash"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:
            return "Sync idle"
        case .syncing:
            return "Syncing"
        case .attention:
            return "Sync attention"
        case .offline:
            return "Sync offline"
        }
    }
}

struct SyncPeerSummary: Hashable, Sendable {
    let id: String
    let name: String
    let role: String
    let status: String
    let isConnected: Bool
    let isServer: Bool
}

struct SyncConflictSummary: Hashable, Sendable {
    let id: String
    let relativePath: String
    let detail: String
    let timestamp: Date?
}

struct SyncTransferSummary: Hashable, Sendable {
    let id: String
    let relativePath: String
    let direction: String
    let status: String
    let progress: Double?
    let detail: String
}

protocol SyncStatusBarPresenting: AnyObject {
    var statusLevel: SyncStatusLevel { get }
    var statusTitle: String { get }
    var statusDetail: String? { get }
    var peers: [SyncPeerSummary] { get }
    var conflicts: [SyncConflictSummary] { get }
    var recentTransfers: [SyncTransferSummary] { get }
    var onDidChange: (() -> Void)? { get set }

    func requestRefresh()
}

@MainActor
final class SyncStatusBarController: NSObject {
    var onOpenSettingsRequested: (() -> Void)?

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: any SyncStatusBarPresenting
    private weak var popoverViewController: SyncStatusPopoverViewController?

    init(viewModel: any SyncStatusBarPresenting) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.animates = true
        super.init()

        configureStatusItem()
        configurePopover()
        bindViewModel()
        refreshStatus()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func refresh() {
        viewModel.requestRefresh()
        refreshStatus()
        popoverViewController?.reload(using: viewModel)
    }

    func showPopover() {
        guard let button = statusItem.button else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        viewModel.requestRefresh()
        refreshStatus()
        popoverViewController?.reload(using: viewModel)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.image = Self.makeSymbolImage(named: viewModel.statusLevel.symbolName)
        button.toolTip = tooltipText()
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let contentViewController = SyncStatusPopoverViewController(
            viewModel: viewModel,
            onRefreshRequested: { [weak self] in
                self?.refresh()
            },
            onOpenSettingsRequested: { [weak self] in
                self?.onOpenSettingsRequested?()
            }
        )

        popover.contentViewController = contentViewController
        popover.delegate = self
        popoverViewController = contentViewController
    }

    private func bindViewModel() {
        viewModel.onDidChange = { [weak self] in
            Task { @MainActor in
                self?.refreshStatus()
                self?.popoverViewController?.reload(using: self?.viewModel)
            }
        }
    }

    private func refreshStatus() {
        guard let button = statusItem.button else {
            return
        }

        button.image = Self.makeSymbolImage(named: viewModel.statusLevel.symbolName)
        button.toolTip = tooltipText()
    }

    private func tooltipText() -> String {
        let detail = viewModel.statusDetail.map { " - \($0)" } ?? ""
        return "\(viewModel.statusTitle)\(detail)"
    }

    private static func makeSymbolImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
            return
        }

        showPopover()
    }
}

extension SyncStatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        refreshStatus()
    }
}
