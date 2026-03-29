import AppKit

extension MainSplitViewController {

    func applySidebarVisibility(animated: Bool) {
        let shouldCollapse = !viewModel.sidebarVisible
        guard sidebarSplitItem.isCollapsed != shouldCollapse else {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                sidebarSplitItem.animator().isCollapsed = shouldCollapse
            }, completionHandler: { [weak self] in
                self?.restoreSidebarWidthIfNeeded()
                self?.reportSidebarWidthIfNeeded(force: true)
            })
        } else {
            sidebarSplitItem.isCollapsed = shouldCollapse
            restoreSidebarWidthIfNeeded()
            reportSidebarWidthIfNeeded(force: true)
        }
    }

    func applyPaneVisibility(leftVisible: Bool, rightVisible: Bool, animated: Bool) {
        let normalizedLeftVisible: Bool
        let normalizedRightVisible: Bool
        if !leftVisible, !rightVisible {
            normalizedLeftVisible = true
            normalizedRightVisible = false
        } else {
            normalizedLeftVisible = leftVisible
            normalizedRightVisible = rightVisible
        }

        setPaneVisibility(splitItem: leftSplitItem, visible: normalizedLeftVisible, animated: animated)
        setPaneVisibility(splitItem: rightSplitItem, visible: normalizedRightVisible, animated: animated)

        if !normalizedLeftVisible, viewModel.activePaneSide == .left {
            setActivePane(.right)
        } else if !normalizedRightVisible, viewModel.activePaneSide == .right {
            setActivePane(.left)
        }

        onPaneVisibilityChanged?(normalizedLeftVisible, normalizedRightVisible)
    }

    func togglePaneVisibility(side: PaneSide, animated: Bool) {
        let leftVisible = !leftSplitItem.isCollapsed
        let rightVisible = !rightSplitItem.isCollapsed
        switch side {
        case .left:
            if leftVisible, !rightVisible {
                return
            }
            applyPaneVisibility(leftVisible: !leftVisible, rightVisible: rightVisible, animated: animated)
        case .right:
            if rightVisible, !leftVisible {
                return
            }
            applyPaneVisibility(leftVisible: leftVisible, rightVisible: !rightVisible, animated: animated)
        }
    }

    func setPaneVisibility(splitItem: NSSplitViewItem, visible: Bool, animated: Bool) {
        let shouldCollapse = !visible
        guard splitItem.isCollapsed != shouldCollapse else {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                splitItem.animator().isCollapsed = shouldCollapse
            }
        } else {
            splitItem.isCollapsed = shouldCollapse
        }
    }

    func applyInitialSidebarWidthIfNeeded() {
        guard !hasAppliedInitialSidebarWidth else {
            return
        }

        hasAppliedInitialSidebarWidth = true
        if !sidebarSplitItem.isCollapsed, splitView.arrangedSubviews.count > 1 {
            splitView.setPosition(initialSidebarWidth, ofDividerAt: 0)
        }

        reportSidebarWidthIfNeeded(force: true)
    }

    func adjustSplitLayoutIfNeeded() {
        guard !isAdjustingSplitLayout else {
            return
        }

        let arrangedSubviews = splitView.arrangedSubviews
        guard !arrangedSubviews.isEmpty else {
            return
        }

        isAdjustingSplitLayout = true
        defer { isAdjustingSplitLayout = false }

        if !sidebarSplitItem.isCollapsed,
           let sidebarIndex = arrangedSubviewIndex(for: sidebarViewController.view, in: arrangedSubviews),
           sidebarIndex < arrangedSubviews.count - 1 {
            let currentSidebarWidth = arrangedSubviews[sidebarIndex].frame.width
            let maximumSidebarWidth = maximumAllowedSidebarWidth(for: arrangedSubviews)
            let clampedSidebarWidth = min(currentSidebarWidth, maximumSidebarWidth)
            if abs(clampedSidebarWidth - currentSidebarWidth) >= 1 {
                splitView.setPosition(clampedSidebarWidth, ofDividerAt: sidebarIndex)
            }
        }

        guard !leftSplitItem.isCollapsed,
              !rightSplitItem.isCollapsed else {
            return
        }

        let updatedSubviews = splitView.arrangedSubviews
        guard let leftIndex = arrangedSubviewIndex(for: leftPaneViewController.view, in: updatedSubviews),
              let rightIndex = arrangedSubviewIndex(for: rightPaneViewController.view, in: updatedSubviews),
              rightIndex == leftIndex + 1 else {
            return
        }

        let leftMinX = updatedSubviews[leftIndex].frame.minX
        let rightMaxX = updatedSubviews[rightIndex].frame.maxX
        let currentDividerPosition = updatedSubviews[leftIndex].frame.maxX
        let minimumDividerPosition = leftMinX + leftSplitItem.minimumThickness
        let maximumDividerPosition = rightMaxX - splitView.dividerThickness - rightSplitItem.minimumThickness

        guard maximumDividerPosition >= minimumDividerPosition else {
            return
        }

        let clampedDividerPosition = min(max(currentDividerPosition, minimumDividerPosition), maximumDividerPosition)
        if abs(clampedDividerPosition - currentDividerPosition) >= 1 {
            splitView.setPosition(clampedDividerPosition, ofDividerAt: leftIndex)
        }
    }

    func restoreSidebarWidthIfNeeded() {
        guard !sidebarSplitItem.isCollapsed, splitView.arrangedSubviews.count > 1 else {
            return
        }

        splitView.setPosition(lastReportedSidebarWidth, ofDividerAt: 0)
    }

    func reportSidebarWidthIfNeeded(force: Bool) {
        guard !sidebarSplitItem.isCollapsed else {
            return
        }

        let width = Self.clampedSidebarWidth(sidebarViewController.view.frame.width)
        guard force || abs(width - lastReportedSidebarWidth) >= 1 else {
            return
        }

        lastReportedSidebarWidth = width
        onSidebarWidthChanged?(width)
    }

    static func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    func maximumAllowedSidebarWidth(for arrangedSubviews: [NSView]) -> CGFloat {
        let dividerCount = max(arrangedSubviews.count - 1, 0)
        let visiblePaneMinimumWidths =
            (!leftSplitItem.isCollapsed ? leftSplitItem.minimumThickness : 0) +
            (!rightSplitItem.isCollapsed ? rightSplitItem.minimumThickness : 0)
        let availableSidebarWidth = splitView.bounds.width
            - (CGFloat(dividerCount) * splitView.dividerThickness)
            - visiblePaneMinimumWidths

        return min(
            Self.sidebarWidthRange.upperBound,
            max(Self.sidebarWidthRange.lowerBound, availableSidebarWidth)
        )
    }
}
