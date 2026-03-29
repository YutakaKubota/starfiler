import AppKit

// MARK: - Window Constraints & Sidebar Width

extension MainWindowController {
    func handleSidebarWidthChanged(_ width: CGFloat) {
        let clamped = Self.clampedSidebarWidth(width)
        guard abs(sidebarWidth - clamped) >= 1 else {
            return
        }

        sidebarWidth = clamped
        persistAppConfig()
    }

    static func clampedSidebarWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, CGFloat(AppConfig.sidebarWidthRange.lowerBound)), CGFloat(AppConfig.sidebarWidthRange.upperBound))
    }

    func scheduleWindowFrameConstraintIfNeeded(for window: NSWindow) {
        guard !hasPendingWindowFrameConstraint else {
            return
        }

        hasPendingWindowFrameConstraint = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else {
                return
            }

            self.hasPendingWindowFrameConstraint = false
            guard let window else {
                return
            }

            self.constrainWindowFrameToVisibleScreenIfNeeded(window)
        }
    }

    func constrainWindowFrameToVisibleScreenIfNeeded(_ window: NSWindow) {
        guard !isConstrainingWindowFrame, !window.styleMask.contains(.fullScreen) else {
            return
        }

        let fallbackVisibleFrame = NSScreen.main?.visibleFrame ?? window.frame
        let visibleFrame = window.screen?.visibleFrame ?? fallbackVisibleFrame
        let constrainedFrame = Self.constrainedWindowFrame(window.frame, within: visibleFrame)
        guard constrainedFrame != window.frame else {
            return
        }

        isConstrainingWindowFrame = true
        window.setFrame(constrainedFrame, display: true)
        isConstrainingWindowFrame = false
    }

    static func constrainedWindowFrame(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return frame
        }

        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)

        return NSRect(x: x, y: y, width: width, height: height).integral
    }

    static func initialSidebarWidth(appConfig: AppConfig, bookmarksConfig: BookmarksConfig) -> CGFloat {
        let configuredWidth = Self.clampedSidebarWidth(CGFloat(appConfig.sidebarWidth))
        let defaultWidth = CGFloat(AppConfig.defaultSidebarWidth)
        guard abs(configuredWidth - defaultWidth) < 1 else {
            return configuredWidth
        }

        let autoWidth = recommendedSidebarWidth(
            bookmarksConfig: bookmarksConfig,
            sidebarFavoritesVisible: appConfig.sidebarFavoritesVisible
        )
        return max(configuredWidth, autoWidth)
    }

    private static func recommendedSidebarWidth(bookmarksConfig: BookmarksConfig, sidebarFavoritesVisible: Bool) -> CGFloat {
        guard sidebarFavoritesVisible else {
            return Self.clampedSidebarWidth(CGFloat(AppConfig.defaultSidebarWidth))
        }

        let defaultGroup = bookmarksConfig.groups.first(where: \.isDefault)
        let title = defaultGroup?.name ?? "Favorites"
        let entries = defaultGroup?.entries.isEmpty == false ? defaultGroup?.entries ?? [] : fallbackFavoriteEntries()
        guard !entries.isEmpty else {
            return Self.clampedSidebarWidth(CGFloat(AppConfig.defaultSidebarWidth))
        }

        let titleFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let entryFont = NSFont.systemFont(ofSize: 13)
        let shortcutFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let headerPadding: CGFloat = 22
        let entryBasePadding: CGFloat = 42
        let shortcutSpacing: CGFloat = 4
        let safetyPadding: CGFloat = 18

        var requiredWidth = textWidth(title, font: titleFont) + headerPadding
        for entry in entries {
            let displayName = favoriteDisplayName(for: entry)
            let shortcutHint = BookmarkShortcut.hint(
                groupShortcut: nil,
                entryShortcut: entry.shortcutKey,
                isDefaultGroup: true
            )
            let shortcutWidth: CGFloat
            if let shortcutHint, !shortcutHint.isEmpty {
                shortcutWidth = shortcutSpacing + textWidth(shortcutHint, font: shortcutFont)
            } else {
                shortcutWidth = 0
            }

            let rowWidth = entryBasePadding + textWidth(displayName, font: entryFont) + shortcutWidth
            requiredWidth = max(requiredWidth, rowWidth)
        }

        return Self.clampedSidebarWidth(ceil(requiredWidth + safetyPadding))
    }

    private static func fallbackFavoriteEntries() -> [BookmarkEntry] {
        BookmarksConfig.withDefaults().groups.first(where: \.isDefault)?.entries ?? []
    }

    private static func favoriteDisplayName(for entry: BookmarkEntry) -> String {
        let trimmed = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let resolvedPath = UserPaths.resolveBookmarkPath(entry.path)
        let lastPathComponent = URL(fileURLWithPath: resolvedPath).lastPathComponent
        return lastPathComponent.isEmpty ? resolvedPath : lastPathComponent
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else {
            return 0
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }
}
