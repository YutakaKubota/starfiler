import AppKit
import Foundation

@MainActor
final class NetworkSyncFinderBadgeManager {
    enum FinderBadgeStatus {
        case synced
        case syncing
        case pending
        case attention
    }

    struct FinderBadgeAppearance {
        let symbolName: String
        let accentColor: NSColor
    }

    struct RefreshContext {
        let localSnapshot: [String: NetworkSyncFileEntry]
        let knownEntries: [String: NetworkSyncFileEntry]
        let pendingDeletionPaths: Set<String>
        let activeTransferPaths: Set<String>
        let conflictPaths: [String]
    }

    private let fileManager: FileManager
    private var lastFinderBadgeStatuses: [String: FinderBadgeStatus] = [:]
    private var pendingFinderBadgeStatuses: [String: FinderBadgeStatus?] = [:]
    private var pendingFinderBadgeFlushTask: Task<Void, Never>?

    private var rootURL: URL?
    private var suppressLocalRootEvents: ((TimeInterval) -> Void)?
    private var logDuration: ((String, CFAbsoluteTime) -> Void)?
    private var syncDebounceSeconds: TimeInterval = 0.5

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func configure(
        rootURL: URL?,
        syncDebounceSeconds: TimeInterval,
        suppressLocalRootEvents: @escaping (TimeInterval) -> Void,
        logDuration: @escaping (String, CFAbsoluteTime) -> Void
    ) {
        self.rootURL = rootURL
        self.syncDebounceSeconds = syncDebounceSeconds
        self.suppressLocalRootEvents = suppressLocalRootEvents
        self.logDuration = logDuration
    }

    func reset() {
        pendingFinderBadgeFlushTask?.cancel()
        pendingFinderBadgeFlushTask = nil
        pendingFinderBadgeStatuses.removeAll()
        lastFinderBadgeStatuses.removeAll()
    }

    // MARK: - Public Badge Operations

    func refreshBadges(context: RefreshContext) {
        var pendingPaths: Set<String> = []
        var syncingPaths: Set<String> = []
        var conflictPaths: Set<String> = []

        for (path, localEntry) in context.localSnapshot
            where isUnsyncedClientEntry(
                path: path,
                localEntry: localEntry,
                knownEntries: context.knownEntries,
                pendingDeletionPaths: context.pendingDeletionPaths
            ) {
            markPathAndAncestors(path, into: &pendingPaths)
        }

        for path in context.activeTransferPaths {
            markPathAndAncestors(path, into: &syncingPaths)
        }

        for path in context.conflictPaths {
            markPathAndAncestors(path, into: &conflictPaths)
        }

        var desiredStatuses: [String: FinderBadgeStatus] = [:]
        for path in context.localSnapshot.keys.sorted() {
            let status: FinderBadgeStatus
            if conflictPaths.contains(path) {
                status = .attention
            } else if syncingPaths.contains(path) {
                status = .syncing
            } else if pendingPaths.contains(path) {
                status = .pending
            } else {
                status = .synced
            }
            desiredStatuses[path] = status
        }

        queueFinderBadgeRefresh(desiredStatuses)
    }

    func applyBadges(for relativePaths: some Sequence<String>, status: FinderBadgeStatus) {
        guard let rootURL else {
            return
        }

        for relativePath in relativePaths {
            let normalizedPath = Self.normalizeRelativePath(relativePath)
            guard !normalizedPath.isEmpty else {
                continue
            }
            let fileURL = rootURL.appendingPathComponent(normalizedPath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }
            applyFinderBadge(to: fileURL, status: status)
        }
    }

    func clearBadge(for relativePath: String) {
        guard let rootURL else {
            return
        }

        let normalizedPath = Self.normalizeRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            return
        }

        let fileURL = rootURL.appendingPathComponent(normalizedPath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        suppressLocalRootEvents?(max(0.5, syncDebounceSeconds * 2))
        NSWorkspace.shared.setIcon(nil, forFile: fileURL.path, options: [])
    }

    nonisolated static func appearance(for status: FinderBadgeStatus) -> FinderBadgeAppearance {
        switch status {
        case .synced:
            return FinderBadgeAppearance(symbolName: "checkmark", accentColor: .systemGreen)
        case .syncing:
            return FinderBadgeAppearance(symbolName: "arrow.triangle.2.circlepath", accentColor: .systemBlue)
        case .pending:
            return FinderBadgeAppearance(symbolName: "clock", accentColor: .systemOrange)
        case .attention:
            return FinderBadgeAppearance(symbolName: "exclamationmark.triangle.fill", accentColor: .systemRed)
        }
    }

    // MARK: - Private Helpers

    private static func normalizeRelativePath(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
    }

    private func isUnsyncedClientEntry(
        path: String,
        localEntry: NetworkSyncFileEntry,
        knownEntries: [String: NetworkSyncFileEntry],
        pendingDeletionPaths: Set<String>
    ) -> Bool {
        if hasPendingDeletion(for: path, pendingDeletionPaths: pendingDeletionPaths) {
            return true
        }

        guard let knownEntry = knownEntries[path] else {
            return true
        }

        return !metadataEquivalent(knownEntry, localEntry)
    }

    private func hasPendingDeletion(for path: String, pendingDeletionPaths: Set<String>) -> Bool {
        pendingDeletionPaths.contains { pendingPath in
            path == pendingPath || path.hasPrefix(pendingPath + "/")
        }
    }

    private func metadataEquivalent(_ lhs: NetworkSyncFileEntry?, _ rhs: NetworkSyncFileEntry?) -> Bool {
        guard let lhs, let rhs else {
            return lhs == nil && rhs == nil
        }

        if lhs.isDirectory && rhs.isDirectory {
            return lhs.relativePath == rhs.relativePath &&
                lhs.deleted == rhs.deleted
        }

        if let lhsHash = lhs.contentHash, let rhsHash = rhs.contentHash {
            return lhs.relativePath == rhs.relativePath &&
                lhs.isDirectory == rhs.isDirectory &&
                lhs.size == rhs.size &&
                lhs.deleted == rhs.deleted &&
                lhsHash == rhsHash
        }

        return lhs.relativePath == rhs.relativePath &&
            lhs.isDirectory == rhs.isDirectory &&
            lhs.size == rhs.size &&
            abs(lhs.modificationTimestamp - rhs.modificationTimestamp) < 1 &&
            lhs.deleted == rhs.deleted &&
            lhs.contentHash == rhs.contentHash
    }

    private func markPathAndAncestors(_ relativePath: String, into set: inout Set<String>) {
        let normalizedPath = Self.normalizeRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            return
        }

        var path = normalizedPath
        while !path.isEmpty {
            set.insert(path)
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == "." || parent == path {
                break
            }
            path = parent
        }
    }

    private func queueFinderBadgeRefresh(_ desiredStatuses: [String: FinderBadgeStatus]) {
        for (path, status) in desiredStatuses where lastFinderBadgeStatuses[path] != status {
            pendingFinderBadgeStatuses[path] = status
        }
        for path in lastFinderBadgeStatuses.keys where desiredStatuses[path] == nil {
            pendingFinderBadgeStatuses[path] = nil
        }

        lastFinderBadgeStatuses = desiredStatuses
        guard !pendingFinderBadgeStatuses.isEmpty else {
            return
        }

        pendingFinderBadgeFlushTask?.cancel()
        pendingFinderBadgeFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.flushFinderBadgeUpdates()
            }
        }
    }

    private func flushFinderBadgeUpdates() {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let updates = pendingFinderBadgeStatuses
        pendingFinderBadgeStatuses.removeAll()
        suppressLocalRootEvents?(max(0.5, syncDebounceSeconds * 2))

        for (path, status) in updates {
            if let status {
                applyBadges(for: [path], status: status)
            } else {
                clearBadge(for: path)
            }
        }

        logDuration?("refreshFinderBadges", startedAt)
    }

    private func applyFinderBadge(to fileURL: URL, status: FinderBadgeStatus) {
        NSWorkspace.shared.setIcon(nil, forFile: fileURL.path, options: [])
        let baseIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
        baseIcon.isTemplate = false

        let appearance = Self.appearance(for: status)

        guard let symbol = NSImage(systemSymbolName: appearance.symbolName, accessibilityDescription: nil) else {
            return
        }

        let iconSize = max(max(baseIcon.size.width, baseIcon.size.height), 32)
        let canvasSize = NSSize(width: iconSize, height: iconSize)
        let badgedIcon = NSImage(size: canvasSize)
        badgedIcon.lockFocus()
        baseIcon.size = canvasSize
        baseIcon.draw(in: NSRect(origin: .zero, size: canvasSize))

        let badgeSide = max(16, canvasSize.width * 0.46)
        let badgeRect = NSRect(
            x: canvasSize.width - badgeSide - 1,
            y: 1,
            width: badgeSide,
            height: badgeSide
        )
        let plateRect = badgeRect.insetBy(dx: 0.5, dy: 0.5)
        let platePath = NSBezierPath(roundedRect: plateRect, xRadius: badgeSide * 0.34, yRadius: badgeSide * 0.34)
        NSColor.white.withAlphaComponent(0.96).setFill()
        platePath.fill()
        appearance.accentColor.setStroke()
        platePath.lineWidth = max(1.4, badgeSide * 0.1)
        platePath.stroke()

        let configuredSymbol = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: badgeSide * 0.68, weight: .bold)
        ) ?? symbol
        let tinted = configuredSymbol.copy() as? NSImage ?? configuredSymbol
        tinted.isTemplate = true
        tinted.size = NSSize(width: badgeSide * 0.72, height: badgeSide * 0.72)
        appearance.accentColor.set()
        let symbolOrigin = NSPoint(
            x: badgeRect.midX - (tinted.size.width / 2),
            y: badgeRect.midY - (tinted.size.height / 2)
        )
        tinted.draw(in: NSRect(origin: symbolOrigin, size: tinted.size), from: .zero, operation: .sourceOver, fraction: 1)
        badgedIcon.unlockFocus()

        NSWorkspace.shared.setIcon(badgedIcon, forFile: fileURL.path, options: [])
    }
}
