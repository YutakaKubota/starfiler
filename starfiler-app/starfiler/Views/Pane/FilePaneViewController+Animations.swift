import AppKit

// MARK: - Animation Helpers

extension FilePaneViewController {
    func addSlideTransition(direction: CATransitionSubtype) {
        animationCoordinator.addSlideTransition(direction: direction, to: scrollView.layer)
    }

    func flashRow(at row: Int, color: NSColor, duration: CFTimeInterval) {
        animationCoordinator.flashRow(at: row, in: tableView, color: color, duration: duration)
    }

    func animateCursorRipple(at row: Int) {
        animationCoordinator.isVisualMode = vimModeState.mode == .visual
        animationCoordinator.animateCursorRipple(at: row, in: tableView)
    }

    func animateMarkCascade(topToBottom: Bool) {
        animationCoordinator.animateMarkCascade(topToBottom: topToBottom, in: tableView)
    }

    func startDropPulse() {
        animationCoordinator.startDropPulse(in: view.layer)
    }

    func stopDropPulse() {
        animationCoordinator.stopDropPulse(in: view.layer)
    }
}
