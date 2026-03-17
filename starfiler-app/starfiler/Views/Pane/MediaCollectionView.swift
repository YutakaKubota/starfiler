import AppKit

final class MediaCollectionView: NSCollectionView {
    weak var keyActionDelegate: MediaKeyActionDelegate?
    var didBecomeFirstResponderHandler: (() -> Void)?
    var dragSourceHandler: FileDragSource?
    var dragURLsProvider: (() -> [URL])?
    var onBookmarkJump: ((String) -> Void)?
    var onBookmarkJumpPending: ((BookmarkJumpHint) -> Void)?
    var onBookmarkJumpEnded: (() -> Void)?
    var onShortcutGuideUpdated: (([KeybindingHintCandidate], [KeyEvent], KeyModifiers) -> Void)?
    var onShortcutGuideEnded: (() -> Void)?
    var shortcutGuideEnabled = false {
        didSet {
            if !shortcutGuideEnabled {
                endShortcutGuideIfNeeded()
            }
        }
    }
    private var keyInterpreter = KeyInterpreter()
    private var bookmarkJumpInterpreter: BookmarkJumpInterpreter?
    private var mouseDownLocation: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var isDragging = false
    private var isShortcutGuideVisible = false
    private static let minimumDragDistance: CGFloat = 5

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        normalizeFilterModeForKeyboardInputIfNeeded()

        let isAwaitingBookmarkJump = bookmarkJumpInterpreter?.state != .idle
        if isAwaitingBookmarkJump {
            endShortcutGuideIfNeeded()
        }

        if event.modifierFlags.contains(.command), !isAwaitingBookmarkJump {
            bookmarkJumpInterpreter?.reset()
            guard let keyEvent = event.keyEvent else {
                if updateShortcutGuideForModifierFlagsIfNeeded(event.modifierFlags) {
                    return
                }
                endShortcutGuideIfNeeded()
                super.keyDown(with: event)
                return
            }

            switch keyInterpreter.interpret(keyEvent) {
            case .action(let action):
                endShortcutGuideIfNeeded()
                if keyActionDelegate?.mediaCollectionView(self, didTrigger: action) == true {
                    return
                }
            case .pending:
                updateShortcutGuideForPendingSequenceIfNeeded()
            case .unhandled:
                endShortcutGuideIfNeeded()
            }
            endShortcutGuideIfNeeded()
            super.keyDown(with: event)
            return
        }

        guard let keyEvent = event.keyEvent else {
            if updateShortcutGuideForModifierFlagsIfNeeded(event.modifierFlags) {
                return
            }
            endShortcutGuideIfNeeded()
            super.keyDown(with: event)
            return
        }

        if isAwaitingBookmarkJump, !keyEvent.modifiers.isEmpty, keyEvent.key != "Escape" {
            endShortcutGuideIfNeeded()
            return
        }

        if bookmarkJumpInterpreter != nil {
            if keyEvent.key == "Escape", bookmarkJumpInterpreter?.state != .idle {
                bookmarkJumpInterpreter?.reset()
                onBookmarkJumpEnded?()
                endShortcutGuideIfNeeded()
                return
            }

            let wasAwaitingBookmarkJump = bookmarkJumpInterpreter?.state != .idle

            switch bookmarkJumpInterpreter!.interpret(keyEvent, now: Date()) {
            case .jumpTo(let path):
                onBookmarkJumpEnded?()
                onBookmarkJump?(path)
                endShortcutGuideIfNeeded()
                return
            case .pending(let hint):
                onBookmarkJumpPending?(hint)
                endShortcutGuideIfNeeded()
                return
            case .unhandled:
                if wasAwaitingBookmarkJump {
                    onBookmarkJumpEnded?()
                }
                break
            }
        }

        if shouldPreferTypeSelect(for: keyEvent) {
            keyInterpreter.clearPendingSequence()
            endShortcutGuideIfNeeded()
            super.keyDown(with: event)
            return
        }

        if keyEvent.key == "Space", keyInterpreter.action(for: keyEvent) == .togglePreview {
            endShortcutGuideIfNeeded()
            if keyEvent.modifiers == [.shift],
               keyActionDelegate?.mediaCollectionView(self, didTrigger: .togglePreview) == true {
                return
            }
            if keyEvent.modifiers.isEmpty {
                return
            }
        }

        switch keyInterpreter.interpret(keyEvent) {
        case .action(let action):
            endShortcutGuideIfNeeded()
            if keyActionDelegate?.mediaCollectionView(self, didTrigger: action) == true {
                return
            }
        case .pending:
            updateShortcutGuideForPendingSequenceIfNeeded()
            return
        case .unhandled:
            endShortcutGuideIfNeeded()
            if shouldFallbackToPaneSwitch(for: keyEvent),
               keyActionDelegate?.mediaCollectionView(self, didTrigger: .switchPane) == true {
                return
            }
        }

        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        defer { super.flagsChanged(with: event) }

        guard keyInterpreter.currentPendingSequence.isEmpty else {
            return
        }

        if updateShortcutGuideForModifierFlagsIfNeeded(event.modifierFlags) {
            return
        }

        endShortcutGuideIfNeeded()
    }

    private func updateShortcutGuideForModifierFlagsIfNeeded(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard shortcutGuideEnabled else {
            return false
        }

        guard bookmarkJumpInterpreter?.state == .idle else {
            return false
        }

        let modifiers = KeyModifiers(modifierFlags: modifierFlags)
        guard !modifiers.isEmpty else {
            return false
        }

        let candidates = keyInterpreter.candidatesForInitialModifiers(modifiers)
        guard !candidates.isEmpty else {
            return false
        }

        onShortcutGuideUpdated?(candidates, [], modifiers)
        isShortcutGuideVisible = true
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            didBecomeFirstResponderHandler?()
        }
        return didBecome
    }

    override func mouseDown(with event: NSEvent) {
        // Keep pane activation responsive on single-click selection.
        _ = window?.makeFirstResponder(self)
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        mouseDownEvent = event
        isDragging = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging else {
            return
        }

        guard let origin = mouseDownLocation else {
            super.mouseDragged(with: event)
            return
        }

        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        let distance = sqrt(dx * dx + dy * dy)

        guard distance >= Self.minimumDragDistance else {
            super.mouseDragged(with: event)
            return
        }

        if
            let dragSourceHandler,
            let dragURLsProvider,
            dragSourceHandler.beginDragging(from: self, with: mouseDownEvent ?? event, urls: dragURLsProvider())
        {
            isDragging = true
            return
        }

        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        mouseDownEvent = nil
        isDragging = false
        super.mouseUp(with: event)
    }

    func setVimMode(_ mode: VimMode) {
        keyInterpreter.setMode(mode)
        endShortcutGuideIfNeeded()
    }

    func reloadKeybindings() {
        keyInterpreter = KeyInterpreter(
            mode: keyInterpreter.mode,
            timeout: keyInterpreter.timeout
        )
        endShortcutGuideIfNeeded()
    }

    func setBookmarkJumpConfig(_ config: BookmarksConfig) {
        bookmarkJumpInterpreter = BookmarkJumpInterpreter(bookmarksConfig: config)
        onBookmarkJumpEnded?()
        endShortcutGuideIfNeeded()
    }

    private func normalizeFilterModeForKeyboardInputIfNeeded() {
        guard keyInterpreter.mode == .filter else {
            return
        }

        // Collection input should always run in normal mode.
        // Filter mode is only valid while the search field is actively editing.
        keyInterpreter.setMode(.normal)
    }

    private func shouldPreferTypeSelect(for event: KeyEvent) -> Bool {
        guard event.key.count == 1 else {
            return false
        }

        if event.key == "/" {
            return false
        }

        let unsupportedModifiers = event.modifiers.subtracting([.shift])
        return unsupportedModifiers.isEmpty
    }

    private func shouldFallbackToPaneSwitch(for event: KeyEvent) -> Bool {
        guard event.key == "Tab" else {
            return false
        }

        let unsupportedModifiers = event.modifiers.subtracting([.shift])
        return unsupportedModifiers.isEmpty
    }

    private func updateShortcutGuideForPendingSequenceIfNeeded() {
        guard shortcutGuideEnabled else {
            endShortcutGuideIfNeeded()
            return
        }

        let pendingSequence = keyInterpreter.currentPendingSequence
        guard !pendingSequence.isEmpty else {
            endShortcutGuideIfNeeded()
            return
        }

        let firstEventHasModifier = pendingSequence.first?.modifiers.isEmpty == false
        guard firstEventHasModifier || isShortcutGuideVisible else {
            endShortcutGuideIfNeeded()
            return
        }

        let candidates = keyInterpreter.candidatesForPendingSequence()
        guard !candidates.isEmpty else {
            endShortcutGuideIfNeeded()
            return
        }

        onShortcutGuideUpdated?(candidates, pendingSequence, [])
        isShortcutGuideVisible = true
    }

    private func endShortcutGuideIfNeeded() {
        guard isShortcutGuideVisible else {
            return
        }

        isShortcutGuideVisible = false
        onShortcutGuideEnded?()
    }
}

final class MediaCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("mediaCollectionItem")

    private let titleLabel = NSTextField(labelWithString: "")
    private let markBadge = NSImageView()
    private let videoIndicator = NSImageView()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 0
        imageView.layer?.masksToBounds = true
        self.imageView = imageView

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 2

        markBadge.translatesAutoresizingMaskIntoConstraints = false
        markBadge.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Marked")
        markBadge.contentTintColor = .systemOrange
        markBadge.isHidden = true

        videoIndicator.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        videoIndicator.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Video")?
            .withSymbolConfiguration(config)
        videoIndicator.contentTintColor = .white
        videoIndicator.wantsLayer = true
        videoIndicator.layer?.shadowColor = NSColor.black.cgColor
        videoIndicator.layer?.shadowOpacity = 0.6
        videoIndicator.layer?.shadowOffset = CGSize(width: 0, height: -1)
        videoIndicator.layer?.shadowRadius = 2
        videoIndicator.isHidden = true

        view.wantsLayer = true
        view.layer?.cornerRadius = 0
        view.layer?.borderWidth = 1
        view.layer?.masksToBounds = true

        view.addSubview(imageView)
        view.addSubview(titleLabel)
        view.addSubview(markBadge)
        view.addSubview(videoIndicator)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 0.75),

            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),

            markBadge.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            markBadge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),

            videoIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            videoIndicator.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -6),
            videoIndicator.widthAnchor.constraint(equalToConstant: 24),
            videoIndicator.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    override var isSelected: Bool {
        didSet {
            applySelectionAppearance()
        }
    }

    func configure(name: String, thumbnail: NSImage?, isMarked: Bool, isVideo: Bool, palette: FilerThemePalette) {
        titleLabel.stringValue = name
        titleLabel.textColor = palette.primaryTextColor
        imageView?.image = thumbnail
        markBadge.isHidden = !isMarked
        markBadge.contentTintColor = palette.starAccentColor
        videoIndicator.isHidden = !isVideo
        applySelectionAppearance(palette: palette)
    }

    private func applySelectionAppearance(palette: FilerThemePalette? = nil) {
        let palette = palette ?? FilerTheme.system.palette
        if isSelected {
            view.layer?.borderColor = palette.activeBorderColor.cgColor
            view.layer?.backgroundColor = palette.accentColor.withAlphaComponent(0.18).cgColor
        } else {
            view.layer?.borderColor = palette.inactiveBorderColor.cgColor
            view.layer?.backgroundColor = palette.tableBackgroundColor.withAlphaComponent(0.35).cgColor
        }
    }
}
