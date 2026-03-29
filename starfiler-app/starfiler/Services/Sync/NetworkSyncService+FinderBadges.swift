// MARK: - Finder Badge Management (delegates to NetworkSyncFinderBadgeManager)

extension NetworkSyncService {
    func refreshClientFinderBadges() {
        guard config.role == .client else {
            return
        }

        let context = NetworkSyncFinderBadgeManager.RefreshContext(
            localSnapshot: localSnapshot,
            knownEntries: clientState.knownEntries,
            pendingDeletionPaths: clientState.pendingDeletionPaths,
            activeTransferPaths: Set(activeTransfersByPath.keys),
            conflictPaths: conflicts.map(\.relativePath)
        )
        finderBadgeManager.refreshBadges(context: context)
    }

    func applyFinderBadges(for relativePaths: some Sequence<String>, status: NetworkSyncFinderBadgeManager.FinderBadgeStatus) {
        guard config.role == .client else {
            return
        }
        finderBadgeManager.applyBadges(for: relativePaths, status: status)
    }

    func clearFinderBadge(for relativePath: String) {
        guard config.role == .client else {
            return
        }
        finderBadgeManager.clearBadge(for: relativePath)
    }
}
