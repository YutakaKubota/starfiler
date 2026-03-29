import AppKit

// MARK: - Animation Helpers

extension FilePaneViewController {
    func addSlideTransition(direction: CATransitionSubtype) {
        guard starEffectsEnabled, animationEffectSettings.directoryTransitionSlide else { return }
        let transition = CATransition()
        transition.type = .push
        transition.subtype = direction
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollView.layer?.add(transition, forKey: "directoryTransition")
    }

    func flashRow(at row: Int, color: NSColor, duration: CFTimeInterval) {
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

    func animateCursorRipple(at row: Int) {
        lastCursorRippleLayer?.removeFromSuperlayer()
        lastCursorRippleLayer = nil

        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return }
        rowView.wantsLayer = true

        let palette = filerTheme.palette
        let alpha: CGFloat = vimModeState.mode == .visual ? 0.3 : 0.15
        let duration: CFTimeInterval = vimModeState.mode == .visual ? 0.25 : 0.2

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

    func animateMarkCascade(topToBottom: Bool) {
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.length > 0 else { return }

        let rows = Array(visibleRange.location ..< NSMaxRange(visibleRange))
        let orderedRows = topToBottom ? rows : rows.reversed()
        let palette = filerTheme.palette

        for (i, row) in orderedRows.enumerated() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(i) * 20))
                guard let self else { return }
                self.flashRow(at: row, color: palette.starGlowColor.withAlphaComponent(0.25), duration: 0.3)
            }
        }
    }

    func startDropPulse() {
        guard starEffectsEnabled, animationEffectSettings.dropZonePulse else { return }
        let pulse = CABasicAnimation(keyPath: "borderWidth")
        pulse.fromValue = 1.0
        pulse.toValue = 2.5
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        view.layer?.add(pulse, forKey: "dropPulse")
    }

    func stopDropPulse() {
        view.layer?.removeAnimation(forKey: "dropPulse")
    }
}
