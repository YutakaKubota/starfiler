import AppKit

extension MainSplitViewController {

    func presentGoToPathPrompt() {
        let activePaneSide = viewModel.activePaneSide
        let currentPath = viewModel.activePane.paneState.currentDirectory.path
        let paneView = paneViewController(for: activePaneSide).view
        let accentColor = goToPathAccentColor(for: activePaneSide)

        dismissGoToPathPopover(refocusActivePane: false)

        var popoverContentController: GoToPathPopoverViewController?
        let contentController = GoToPathPopoverViewController(
            currentPath: currentPath,
            accentColor: accentColor,
            onSubmit: { [weak self] rawInput in
                guard let self else {
                    return
                }

                let trimmedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedInput.isEmpty else {
                    popoverContentController?.showValidationError("Enter a path")
                    return
                }

                guard let destination = self.resolveNavigationDestination(from: trimmedInput) else {
                    popoverContentController?.showValidationError("Path not found")
                    return
                }

                self.dismissGoToPathPopover(refocusActivePane: true)
                self.navigateActivePane(to: destination)
            },
            onCancel: { [weak self] in
                self?.dismissGoToPathPopover(refocusActivePane: true)
            }
        )
        popoverContentController = contentController

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = contentController

        showGoToPathHighlight(on: paneView, accentColor: accentColor)

        let anchorRect = NSRect(x: paneView.bounds.midX - 1, y: paneView.bounds.height - 28, width: 2, height: 2)
        popover.show(relativeTo: anchorRect, of: paneView, preferredEdge: .minY)
        contentController.focusInputField()
        goToPathPopover = popover
    }

    func handlePopoverDidClose(refocusActivePane: Bool) {
        clearGoToPathPresentation(refocusActivePane: refocusActivePane)
        shouldRefocusAfterGoToPathDismiss = true
    }

    func dismissGoToPathPopover(refocusActivePane: Bool) {
        shouldRefocusAfterGoToPathDismiss = refocusActivePane

        guard let popover = goToPathPopover else {
            clearGoToPathPresentation(refocusActivePane: refocusActivePane)
            return
        }

        popover.performClose(nil)
    }

    private func clearGoToPathPresentation(refocusActivePane: Bool) {
        goToPathPopover?.delegate = nil
        goToPathPopover = nil
        goToPathHighlightView?.removeFromSuperview()
        goToPathHighlightView = nil

        if refocusActivePane {
            focusActivePane()
        }
    }

    private func goToPathAccentColor(for side: PaneSide) -> NSColor {
        switch side {
        case .left:
            return .systemBlue
        case .right:
            return .systemOrange
        }
    }

    private func showGoToPathHighlight(on paneView: NSView, accentColor: NSColor) {
        goToPathHighlightView?.removeFromSuperview()

        let overlay = PaneHighlightOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.borderWidth = 3
        overlay.layer?.cornerRadius = 8
        overlay.layer?.borderColor = accentColor.withAlphaComponent(0.85).cgColor
        overlay.layer?.backgroundColor = accentColor.withAlphaComponent(0.08).cgColor

        paneView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: paneView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: paneView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: paneView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: paneView.bottomAnchor)
        ])

        goToPathHighlightView = overlay
    }
}
