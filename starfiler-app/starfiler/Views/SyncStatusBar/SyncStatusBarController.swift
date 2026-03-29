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

@MainActor
protocol SyncStatusBarPresenting: AnyObject {
    var statusLevel: SyncStatusLevel { get }
    var statusTitle: String { get }
    var statusDetail: String? { get }
    var menuBarLabel: String? { get }
    var menuBarDetail: String? { get }
    var peers: [SyncPeerSummary] { get }
    var conflicts: [SyncConflictSummary] { get }
    var recentTransfers: [SyncTransferSummary] { get }
    var onDidChange: (() -> Void)? { get set }

    func requestRefresh()
    @discardableResult func addDidChangeObserver(_ observer: @escaping @MainActor () -> Void) -> UUID
    func removeDidChangeObserver(_ token: UUID)
}

extension SyncStatusBarPresenting {
    var menuBarLabel: String? { nil }
    var menuBarDetail: String? { statusDetail }
}

@MainActor
final class SyncStatusBarController: NSObject {
    var onOpenSettingsRequested: (() -> Void)?

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: any SyncStatusBarPresenting
    private weak var popoverViewController: SyncStatusPopoverViewController?
    private var changeObserverToken: UUID?
    private var pendingPopoverReloadTask: Task<Void, Never>?

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
        schedulePopoverReload()
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
        button.isBordered = false
        button.image = Self.makeSymbolImage(named: viewModel.statusLevel.symbolName)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem(button)
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
        changeObserverToken = viewModel.addDidChangeObserver { [weak self] in
            self?.refreshStatus()
            self?.schedulePopoverReload()
        }
    }

    private func schedulePopoverReload() {
        guard popover.isShown else {
            pendingPopoverReloadTask?.cancel()
            pendingPopoverReloadTask = nil
            return
        }

        pendingPopoverReloadTask?.cancel()
        pendingPopoverReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard let self, self.popover.isShown else {
                    return
                }
                self.popoverViewController?.reload(using: self.viewModel)
            }
        }
    }

    private func refreshStatus() {
        guard let button = statusItem.button else {
            return
        }

        button.image = Self.makeSymbolImage(named: viewModel.statusLevel.symbolName)
        updateStatusItem(button)
    }

    private func updateStatusItem(_ button: NSStatusBarButton) {
        let title = viewModel.menuBarLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = tooltipText()
    }

    private func tooltipText() -> String {
        let detailSource = viewModel.menuBarDetail ?? viewModel.statusDetail
        let detail = detailSource.map { " - \($0)" } ?? ""
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
        pendingPopoverReloadTask?.cancel()
        pendingPopoverReloadTask = nil
        refreshStatus()
    }
}
