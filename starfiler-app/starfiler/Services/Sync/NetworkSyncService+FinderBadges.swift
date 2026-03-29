import AppKit

// MARK: - Finder Badge Management

extension NetworkSyncService {
    func refreshClientFinderBadges() {
        guard config.role == .client else {
            return
        }

        var pendingPaths: Set<String> = []
        var syncingPaths: Set<String> = []
        var conflictPaths: Set<String> = []

        for (path, localEntry) in localSnapshot where isUnsyncedClientEntry(path: path, localEntry: localEntry) {
            markPathAndAncestors(path, into: &pendingPaths)
        }

        for path in activeTransfersByPath.keys {
            markPathAndAncestors(path, into: &syncingPaths)
        }

        for conflict in conflicts {
            markPathAndAncestors(conflict.relativePath, into: &conflictPaths)
        }

        var desiredStatuses: [String: FinderBadgeStatus] = [:]
        for path in localSnapshot.keys.sorted() {
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

    func applyFinderBadges(for relativePaths: some Sequence<String>, status: FinderBadgeStatus) {
        guard config.role == .client, let rootURL else {
            return
        }

        for relativePath in relativePaths {
            let normalizedPath = normalizeRelativePath(relativePath)
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

    func clearFinderBadge(for relativePath: String) {
        guard config.role == .client, let rootURL else {
            return
        }

        let normalizedPath = normalizeRelativePath(relativePath)
        guard !normalizedPath.isEmpty else {
            return
        }

        let fileURL = rootURL.appendingPathComponent(normalizedPath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        suppressLocalRootEvents(for: max(0.5, config.syncDebounceSeconds * 2))
        NSWorkspace.shared.setIcon(nil, forFile: fileURL.path, options: [])
    }
}

// MARK: - Private Finder Badge Helpers

private extension NetworkSyncService {
    func isUnsyncedClientEntry(path: String, localEntry: NetworkSyncFileEntry) -> Bool {
        guard config.role == .client else {
            return false
        }

        if hasPendingDeletion(for: path, pendingDeletionPaths: clientState.pendingDeletionPaths) {
            return true
        }

        guard let knownEntry = clientState.knownEntries[path] else {
            return true
        }

        return !metadataEquivalent(knownEntry, localEntry)
    }

    func markPathAndAncestors(_ relativePath: String, into set: inout Set<String>) {
        let normalizedPath = normalizeRelativePath(relativePath)
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

    func queueFinderBadgeRefresh(_ desiredStatuses: [String: FinderBadgeStatus]) {
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

    func flushFinderBadgeUpdates() {
        guard config.role == .client else {
            pendingFinderBadgeStatuses.removeAll()
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let updates = pendingFinderBadgeStatuses
        pendingFinderBadgeStatuses.removeAll()
        suppressLocalRootEvents(for: max(0.5, config.syncDebounceSeconds * 2))

        for (path, status) in updates {
            if let status {
                applyFinderBadges(for: [path], status: status)
            } else {
                clearFinderBadge(for: path)
            }
        }

        logDuration("refreshFinderBadges", startedAt: startedAt)
    }

    func applyFinderBadge(to fileURL: URL, status: FinderBadgeStatus) {
        NSWorkspace.shared.setIcon(nil, forFile: fileURL.path, options: [])
        let baseIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
        baseIcon.isTemplate = false

        let appearance = Self.finderBadgeAppearance(for: status)

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
