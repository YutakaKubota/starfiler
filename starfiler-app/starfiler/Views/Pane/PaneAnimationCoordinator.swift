import AppKit

/// Encapsulates all animation effects for a file pane.
///
/// Instead of accessing the view controller's properties directly,
/// each method takes the needed views/values as parameters.
final class PaneAnimationCoordinator {
    var starEffectsEnabled: Bool = true
    var animationEffectSettings: AnimationEffectSettings = .allEnabled
    var palette: FilerThemePalette = FilerTheme.system.palette
    var isVisualMode: Bool = false
    private weak var lastCursorRippleLayer: CALayer?

    func addSlideTransition(direction: CATransitionSubtype, to layer: CALayer?) {
        guard starEffectsEnabled, animationEffectSettings.directoryTransitionSlide else { return }
        let transition = CATransition()
        transition.type = .push
        transition.subtype = direction
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(transition, forKey: "directoryTransition")
    }

    func flashRow(at row: Int, in tableView: NSTableView, color: NSColor, duration: CFTimeInterval) {
        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return }
        rowView.wantsLayer = true
        let flash = CALayer()
        flash.frame = rowView.bounds
        flash.backgroundColor = color.cgColor
        flash.cornerRadius = 2
        rowView.layer?.addSublayer(flash)

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.duration = duration
        fadeOut.isRemovedOnCompletion = false
        fadeOut.fillMode = .forwards
        fadeOut.delegate = StarSparkleAnimator.makeRemovalDelegate(for: flash)
        flash.add(fadeOut, forKey: "rowFlash")
    }

    func animateCursorRipple(at row: Int, in tableView: NSTableView) {
        lastCursorRippleLayer?.removeFromSuperlayer()
        lastCursorRippleLayer = nil

        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return }
        rowView.wantsLayer = true

        let alpha: CGFloat = isVisualMode ? 0.3 : 0.15
        let duration: CFTimeInterval = isVisualMode ? 0.25 : 0.2

        let ripple = CALayer()
        ripple.frame = rowView.bounds
        ripple.backgroundColor = palette.starAccentColor.withAlphaComponent(alpha).cgColor
        ripple.cornerRadius = 2
        rowView.layer?.addSublayer(ripple)
        lastCursorRippleLayer = ripple

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.duration = duration
        fadeOut.isRemovedOnCompletion = false
        fadeOut.fillMode = .forwards
        fadeOut.delegate = StarSparkleAnimator.makeRemovalDelegate(for: ripple)
        ripple.add(fadeOut, forKey: "cursorRipple")
    }

    func animateMarkCascade(topToBottom: Bool, in tableView: NSTableView) {
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }

        let rows = Array(visibleRange.location ..< NSMaxRange(visibleRange))
        let orderedRows = topToBottom ? rows : rows.reversed()

        for (i, row) in orderedRows.enumerated() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(i) * 20))
                guard let self else { return }
                self.flashRow(at: row, in: tableView, color: self.palette.starGlowColor.withAlphaComponent(0.25), duration: 0.3)
            }
        }
    }

    func startDropPulse(in layer: CALayer?) {
        guard starEffectsEnabled, animationEffectSettings.dropZonePulse else { return }
        let pulse = CABasicAnimation(keyPath: "borderWidth")
        pulse.fromValue = 1.0
        pulse.toValue = 2.5
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "dropPulse")
    }

    func stopDropPulse(in layer: CALayer?) {
        layer?.removeAnimation(forKey: "dropPulse")
    }
}
