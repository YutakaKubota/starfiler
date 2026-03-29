import AppKit

final class AppearanceSettingsViewController: NSViewController {
    var onThemeChanged: ((FilerTheme) -> Void)?
    var onTransparentBackgroundChanged: ((Bool) -> Void)?
    var onTransparentBackgroundOpacityChanged: ((CGFloat) -> Void)?
    var onActionFeedbackChanged: ((Bool) -> Void)?
    var onSpotlightSearchScopeChanged: ((SpotlightSearchScope) -> Void)?
    var onFileIconSizeChanged: ((CGFloat) -> Void)?
    var onSidebarFavoritesVisibilityChanged: ((Bool) -> Void)?
    var onSidebarRecentItemsLimitChanged: ((Int) -> Void)?
    var onStarEffectsChanged: ((Bool) -> Void)?
    var onAnimationEffectSettingsChanged: ((AnimationEffectSettings) -> Void)?
    var onShortcutGuideChanged: ((Bool) -> Void)?
    var onShootingStarTestRequested: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Theme")
    private let themePopUpButton = NSPopUpButton()
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let swatchContainer = NSView()
    private let transparentBackgroundButton = NSButton(checkboxWithTitle: "Transparent Background", target: nil, action: nil)
    private let transparentOpacityLabel = NSTextField(labelWithString: "Background Opacity")
    private let transparentOpacitySlider = NSSlider(value: 0.7, minValue: 0.15, maxValue: 1.0, target: nil, action: nil)
    private let transparentOpacityValueLabel = NSTextField(labelWithString: "")
    private let actionFeedbackButton = NSButton(checkboxWithTitle: "Show Action Feedback Toasts", target: nil, action: nil)
    private let shortcutGuideButton = NSButton(checkboxWithTitle: "Show Shortcut Guide Popup", target: nil, action: nil)
    private let starEffectsButton = NSButton(checkboxWithTitle: "Enable Star Effects", target: nil, action: nil)
    private let shootingStarTestButton = NSButton(title: "Play Shooting Star Test", target: nil, action: nil)
    private var effectButtons: [(kind: AnimationEffectSettings.EffectKind, button: NSButton)] = []
    private let fileListSettingsLabel = NSTextField(labelWithString: "File List")
    private let fileIconSizeLabel = NSTextField(labelWithString: "Icon Size")
    private let fileIconSizeSlider = NSSlider(value: 16, minValue: 12, maxValue: 40, target: nil, action: nil)
    private let fileIconSizeValueLabel = NSTextField(labelWithString: "")
    private let sidebarFavoritesVisibilityButton = NSButton(
        checkboxWithTitle: "Show Favorites Section",
        target: nil,
        action: nil
    )
    private let sidebarRecentItemsLimitLabel = NSTextField(labelWithString: "Sidebar Recent Items")
    private let sidebarRecentItemsLimitSlider = NSSlider(
        value: 10,
        minValue: Double(AppConfig.sidebarRecentItemsLimitRange.lowerBound),
        maxValue: Double(AppConfig.sidebarRecentItemsLimitRange.upperBound),
        target: nil,
        action: nil
    )
    private let sidebarRecentItemsLimitValueLabel = NSTextField(labelWithString: "")
    private let searchSettingsLabel = NSTextField(labelWithString: "Spotlight Search Scope")
    private let spotlightScopePopUpButton = NSPopUpButton()
    private let spotlightScopeDescriptionLabel = NSTextField(wrappingLabelWithString: "")
    private var selectedTheme: FilerTheme
    private var isTransparentBackgroundEnabled: Bool
    private var transparentBackgroundOpacity: CGFloat
    private var isActionFeedbackEnabled: Bool
    private var selectedSpotlightSearchScope: SpotlightSearchScope
    private var fileIconSize: CGFloat
    private var isSidebarFavoritesVisible: Bool
    private var sidebarRecentItemsLimit: Int
    private var isStarEffectsEnabled: Bool
    private var animationEffectSettings: AnimationEffectSettings
    private var isShortcutGuideEnabled: Bool

    init(
        selectedTheme: FilerTheme,
        isTransparentBackgroundEnabled: Bool,
        transparentBackgroundOpacity: CGFloat,
        isActionFeedbackEnabled: Bool,
        selectedSpotlightSearchScope: SpotlightSearchScope,
        initialFileIconSize: CGFloat,
        initialSidebarFavoritesVisible: Bool,
        initialSidebarRecentItemsLimit: Int,
        initialStarEffectsEnabled: Bool = true,
        initialAnimationEffectSettings: AnimationEffectSettings = .allEnabled,
        initialShortcutGuideEnabled: Bool = false
    ) {
        self.selectedTheme = selectedTheme
        self.isTransparentBackgroundEnabled = isTransparentBackgroundEnabled
        self.transparentBackgroundOpacity = min(max(transparentBackgroundOpacity, 0.15), 1.0)
        self.isActionFeedbackEnabled = isActionFeedbackEnabled
        self.selectedSpotlightSearchScope = selectedSpotlightSearchScope
        self.fileIconSize = min(max(initialFileIconSize, 12), 40)
        self.isSidebarFavoritesVisible = initialSidebarFavoritesVisible
        self.sidebarRecentItemsLimit = Self.clampedSidebarRecentItemsLimit(initialSidebarRecentItemsLimit)
        self.isStarEffectsEnabled = initialStarEffectsEnabled
        self.animationEffectSettings = initialAnimationEffectSettings
        self.isShortcutGuideEnabled = initialShortcutGuideEnabled
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        configureLayout()
        applyThemeSelection(selectedTheme, notify: false)
    }

    private func configureUI() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        themePopUpButton.translatesAutoresizingMaskIntoConstraints = false
        themePopUpButton.target = self
        themePopUpButton.action = #selector(themeChanged(_:))
        themePopUpButton.removeAllItems()
        themePopUpButton.addItems(withTitles: FilerTheme.allCases.map(\.displayName))

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.lineBreakMode = .byWordWrapping

        swatchContainer.translatesAutoresizingMaskIntoConstraints = false

        transparentBackgroundButton.translatesAutoresizingMaskIntoConstraints = false
        transparentBackgroundButton.target = self
        transparentBackgroundButton.action = #selector(transparentBackgroundChanged(_:))
        transparentBackgroundButton.state = isTransparentBackgroundEnabled ? .on : .off

        transparentOpacityLabel.translatesAutoresizingMaskIntoConstraints = false
        transparentOpacityLabel.font = .systemFont(ofSize: 12, weight: .regular)
        transparentOpacityLabel.textColor = .secondaryLabelColor

        transparentOpacitySlider.translatesAutoresizingMaskIntoConstraints = false
        transparentOpacitySlider.target = self
        transparentOpacitySlider.action = #selector(transparentOpacityChanged(_:))
        transparentOpacitySlider.doubleValue = Double(transparentBackgroundOpacity)
        transparentOpacitySlider.isEnabled = isTransparentBackgroundEnabled

        transparentOpacityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        transparentOpacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        transparentOpacityValueLabel.alignment = .right
        transparentOpacityValueLabel.stringValue = "\(Int((transparentBackgroundOpacity * 100).rounded())) %"
        transparentOpacityValueLabel.textColor = .secondaryLabelColor

        actionFeedbackButton.translatesAutoresizingMaskIntoConstraints = false
        actionFeedbackButton.target = self
        actionFeedbackButton.action = #selector(actionFeedbackChanged(_:))
        actionFeedbackButton.state = isActionFeedbackEnabled ? .on : .off

        shortcutGuideButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutGuideButton.target = self
        shortcutGuideButton.action = #selector(shortcutGuideChanged(_:))
        shortcutGuideButton.state = isShortcutGuideEnabled ? .on : .off

        starEffectsButton.translatesAutoresizingMaskIntoConstraints = false
        starEffectsButton.target = self
        starEffectsButton.action = #selector(starEffectsChanged(_:))
        starEffectsButton.state = isStarEffectsEnabled ? .on : .off

        shootingStarTestButton.translatesAutoresizingMaskIntoConstraints = false
        shootingStarTestButton.target = self
        shootingStarTestButton.action = #selector(shootingStarTestRequested(_:))
        shootingStarTestButton.bezelStyle = .rounded
        shootingStarTestButton.controlSize = .small

        configureEffectButtons()

        fileListSettingsLabel.translatesAutoresizingMaskIntoConstraints = false
        fileListSettingsLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        fileIconSizeLabel.translatesAutoresizingMaskIntoConstraints = false
        fileIconSizeLabel.font = .systemFont(ofSize: 12, weight: .regular)
        fileIconSizeLabel.textColor = .secondaryLabelColor

        fileIconSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        fileIconSizeSlider.target = self
        fileIconSizeSlider.action = #selector(fileIconSizeChanged(_:))
        fileIconSizeSlider.doubleValue = Double(fileIconSize)

        fileIconSizeValueLabel.translatesAutoresizingMaskIntoConstraints = false
        fileIconSizeValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        fileIconSizeValueLabel.alignment = .right
        fileIconSizeValueLabel.stringValue = "\(Int(fileIconSize.rounded())) px"

        sidebarFavoritesVisibilityButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarFavoritesVisibilityButton.target = self
        sidebarFavoritesVisibilityButton.action = #selector(sidebarFavoritesVisibilityChanged(_:))
        sidebarFavoritesVisibilityButton.state = isSidebarFavoritesVisible ? .on : .off

        sidebarRecentItemsLimitLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebarRecentItemsLimitLabel.font = .systemFont(ofSize: 12, weight: .regular)
        sidebarRecentItemsLimitLabel.textColor = .secondaryLabelColor

        sidebarRecentItemsLimitSlider.translatesAutoresizingMaskIntoConstraints = false
        sidebarRecentItemsLimitSlider.target = self
        sidebarRecentItemsLimitSlider.action = #selector(sidebarRecentItemsLimitChanged(_:))
        sidebarRecentItemsLimitSlider.numberOfTickMarks = AppConfig.sidebarRecentItemsLimitRange.count
        sidebarRecentItemsLimitSlider.allowsTickMarkValuesOnly = true
        sidebarRecentItemsLimitSlider.doubleValue = Double(sidebarRecentItemsLimit)

        sidebarRecentItemsLimitValueLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebarRecentItemsLimitValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sidebarRecentItemsLimitValueLabel.alignment = .right
        sidebarRecentItemsLimitValueLabel.stringValue = sidebarRecentItemsLimitText(sidebarRecentItemsLimit)

        searchSettingsLabel.translatesAutoresizingMaskIntoConstraints = false
        searchSettingsLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        spotlightScopePopUpButton.translatesAutoresizingMaskIntoConstraints = false
        spotlightScopePopUpButton.target = self
        spotlightScopePopUpButton.action = #selector(spotlightScopeChanged(_:))
        spotlightScopePopUpButton.removeAllItems()
        spotlightScopePopUpButton.addItems(withTitles: SpotlightSearchScope.allCases.map(\.displayName))
        if let selectedIndex = SpotlightSearchScope.allCases.firstIndex(of: selectedSpotlightSearchScope) {
            spotlightScopePopUpButton.selectItem(at: selectedIndex)
        }

        spotlightScopeDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        spotlightScopeDescriptionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        spotlightScopeDescriptionLabel.textColor = .secondaryLabelColor
        spotlightScopeDescriptionLabel.maximumNumberOfLines = 2
        spotlightScopeDescriptionLabel.lineBreakMode = .byWordWrapping
        spotlightScopeDescriptionLabel.stringValue = selectedSpotlightSearchScope.descriptionText
    }

    private func configureEffectButtons() {
        for kind in AnimationEffectSettings.EffectKind.allCases {
            let button = NSButton(checkboxWithTitle: kind.displayName, target: self, action: #selector(effectToggleChanged(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.font = .systemFont(ofSize: 11)
            button.controlSize = .small
            button.state = animationEffectSettings[kind] ? .on : .off
            button.isEnabled = isStarEffectsEnabled
            button.tag = AnimationEffectSettings.EffectKind.allCases.firstIndex(of: kind) ?? 0
            effectButtons.append((kind: kind, button: button))
        }
    }

    private func configureLayout() {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(themePopUpButton)
        contentView.addSubview(descriptionLabel)
        contentView.addSubview(swatchContainer)
        contentView.addSubview(transparentBackgroundButton)
        contentView.addSubview(transparentOpacityLabel)
        contentView.addSubview(transparentOpacitySlider)
        contentView.addSubview(transparentOpacityValueLabel)
        contentView.addSubview(actionFeedbackButton)
        contentView.addSubview(shortcutGuideButton)
        contentView.addSubview(starEffectsButton)

        for (_, button) in effectButtons {
            contentView.addSubview(button)
        }
        contentView.addSubview(shootingStarTestButton)

        contentView.addSubview(fileListSettingsLabel)
        contentView.addSubview(fileIconSizeLabel)
        contentView.addSubview(fileIconSizeSlider)
        contentView.addSubview(fileIconSizeValueLabel)
        contentView.addSubview(sidebarFavoritesVisibilityButton)
        contentView.addSubview(sidebarRecentItemsLimitLabel)
        contentView.addSubview(sidebarRecentItemsLimitSlider)
        contentView.addSubview(sidebarRecentItemsLimitValueLabel)
        contentView.addSubview(searchSettingsLabel)
        contentView.addSubview(spotlightScopePopUpButton)
        contentView.addSubview(spotlightScopeDescriptionLabel)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = contentView
        view.addSubview(scrollView)

        var constraints = [
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            themePopUpButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            themePopUpButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            themePopUpButton.widthAnchor.constraint(equalToConstant: 220),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            descriptionLabel.topAnchor.constraint(equalTo: themePopUpButton.bottomAnchor, constant: 10),

            swatchContainer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            swatchContainer.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            swatchContainer.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 14),
            swatchContainer.heightAnchor.constraint(equalToConstant: 28),

            transparentBackgroundButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            transparentBackgroundButton.topAnchor.constraint(equalTo: swatchContainer.bottomAnchor, constant: 16),

            transparentOpacityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            transparentOpacityLabel.topAnchor.constraint(equalTo: transparentBackgroundButton.bottomAnchor, constant: 10),

            transparentOpacitySlider.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            transparentOpacitySlider.topAnchor.constraint(equalTo: transparentOpacityLabel.bottomAnchor, constant: 6),
            transparentOpacitySlider.widthAnchor.constraint(equalToConstant: 220),

            transparentOpacityValueLabel.leadingAnchor.constraint(equalTo: transparentOpacitySlider.trailingAnchor, constant: 10),
            transparentOpacityValueLabel.centerYAnchor.constraint(equalTo: transparentOpacitySlider.centerYAnchor),
            transparentOpacityValueLabel.widthAnchor.constraint(equalToConstant: 72),

            actionFeedbackButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actionFeedbackButton.topAnchor.constraint(equalTo: transparentOpacitySlider.bottomAnchor, constant: 10),

            shortcutGuideButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            shortcutGuideButton.topAnchor.constraint(equalTo: actionFeedbackButton.bottomAnchor, constant: 6),

            starEffectsButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            starEffectsButton.topAnchor.constraint(equalTo: shortcutGuideButton.bottomAnchor, constant: 6),

            shootingStarTestButton.leadingAnchor.constraint(greaterThanOrEqualTo: starEffectsButton.trailingAnchor, constant: 12),
            shootingStarTestButton.centerYAnchor.constraint(equalTo: starEffectsButton.centerYAnchor),
            shootingStarTestButton.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
        ]

        // Effect toggle buttons: indented under the master star effects button
        var previousAnchor = starEffectsButton.bottomAnchor
        for (_, button) in effectButtons {
            constraints.append(button.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: 20))
            constraints.append(button.topAnchor.constraint(equalTo: previousAnchor, constant: 3))
            previousAnchor = button.bottomAnchor
        }

        constraints.append(contentsOf: [
            fileListSettingsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fileListSettingsLabel.topAnchor.constraint(equalTo: previousAnchor, constant: 16),

            fileIconSizeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fileIconSizeLabel.topAnchor.constraint(equalTo: fileListSettingsLabel.bottomAnchor, constant: 10),

            fileIconSizeSlider.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fileIconSizeSlider.topAnchor.constraint(equalTo: fileIconSizeLabel.bottomAnchor, constant: 6),
            fileIconSizeSlider.widthAnchor.constraint(equalToConstant: 220),

            fileIconSizeValueLabel.leadingAnchor.constraint(equalTo: fileIconSizeSlider.trailingAnchor, constant: 10),
            fileIconSizeValueLabel.centerYAnchor.constraint(equalTo: fileIconSizeSlider.centerYAnchor),
            fileIconSizeValueLabel.widthAnchor.constraint(equalToConstant: 72),

            sidebarFavoritesVisibilityButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sidebarFavoritesVisibilityButton.topAnchor.constraint(equalTo: fileIconSizeSlider.bottomAnchor, constant: 10),

            sidebarRecentItemsLimitLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sidebarRecentItemsLimitLabel.topAnchor.constraint(equalTo: sidebarFavoritesVisibilityButton.bottomAnchor, constant: 10),

            sidebarRecentItemsLimitSlider.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sidebarRecentItemsLimitSlider.topAnchor.constraint(equalTo: sidebarRecentItemsLimitLabel.bottomAnchor, constant: 6),
            sidebarRecentItemsLimitSlider.widthAnchor.constraint(equalToConstant: 220),

            sidebarRecentItemsLimitValueLabel.leadingAnchor.constraint(equalTo: sidebarRecentItemsLimitSlider.trailingAnchor, constant: 10),
            sidebarRecentItemsLimitValueLabel.centerYAnchor.constraint(equalTo: sidebarRecentItemsLimitSlider.centerYAnchor),
            sidebarRecentItemsLimitValueLabel.widthAnchor.constraint(equalToConstant: 72),

            searchSettingsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            searchSettingsLabel.topAnchor.constraint(equalTo: sidebarRecentItemsLimitSlider.bottomAnchor, constant: 20),

            spotlightScopePopUpButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            spotlightScopePopUpButton.topAnchor.constraint(equalTo: searchSettingsLabel.bottomAnchor, constant: 8),
            spotlightScopePopUpButton.widthAnchor.constraint(equalToConstant: 220),

            spotlightScopeDescriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            spotlightScopeDescriptionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            spotlightScopeDescriptionLabel.topAnchor.constraint(equalTo: spotlightScopePopUpButton.bottomAnchor, constant: 8),

            // Bottom anchor to define scrollable content height
            spotlightScopeDescriptionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        NSLayoutConstraint.activate(constraints)
    }

    @objc
    private func themeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard FilerTheme.allCases.indices.contains(index) else {
            return
        }
        applyThemeSelection(FilerTheme.allCases[index], notify: true)
    }

    @objc
    private func transparentBackgroundChanged(_ sender: NSButton) {
        isTransparentBackgroundEnabled = sender.state == .on
        transparentOpacitySlider.isEnabled = isTransparentBackgroundEnabled
        onTransparentBackgroundChanged?(isTransparentBackgroundEnabled)
    }

    @objc
    private func transparentOpacityChanged(_ sender: NSSlider) {
        transparentBackgroundOpacity = CGFloat(sender.doubleValue)
        transparentOpacityValueLabel.stringValue = "\(Int((transparentBackgroundOpacity * 100).rounded())) %"
        onTransparentBackgroundOpacityChanged?(transparentBackgroundOpacity)
    }

    @objc
    private func actionFeedbackChanged(_ sender: NSButton) {
        isActionFeedbackEnabled = sender.state == .on
        onActionFeedbackChanged?(isActionFeedbackEnabled)
    }

    @objc
    private func shortcutGuideChanged(_ sender: NSButton) {
        isShortcutGuideEnabled = sender.state == .on
        onShortcutGuideChanged?(isShortcutGuideEnabled)
    }

    @objc
    private func starEffectsChanged(_ sender: NSButton) {
        isStarEffectsEnabled = sender.state == .on
        updateEffectButtonsEnabled()
        onStarEffectsChanged?(isStarEffectsEnabled)
    }

    @objc
    private func effectToggleChanged(_ sender: NSButton) {
        let allCases = AnimationEffectSettings.EffectKind.allCases
        guard allCases.indices.contains(sender.tag) else { return }
        let kind = allCases[sender.tag]
        animationEffectSettings[kind] = sender.state == .on
        onAnimationEffectSettingsChanged?(animationEffectSettings)
    }

    @objc
    private func shootingStarTestRequested(_ sender: NSButton) {
        onShootingStarTestRequested?()
    }

    @objc
    private func spotlightScopeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard SpotlightSearchScope.allCases.indices.contains(index) else {
            return
        }

        let scope = SpotlightSearchScope.allCases[index]
        selectedSpotlightSearchScope = scope
        spotlightScopeDescriptionLabel.stringValue = scope.descriptionText
        onSpotlightSearchScopeChanged?(scope)
    }

    @objc
    private func fileIconSizeChanged(_ sender: NSSlider) {
        fileIconSize = CGFloat(sender.doubleValue)
        fileIconSizeValueLabel.stringValue = "\(Int(fileIconSize.rounded())) px"
        onFileIconSizeChanged?(fileIconSize)
    }

    @objc
    private func sidebarFavoritesVisibilityChanged(_ sender: NSButton) {
        isSidebarFavoritesVisible = sender.state == .on
        onSidebarFavoritesVisibilityChanged?(isSidebarFavoritesVisible)
    }

    @objc
    private func sidebarRecentItemsLimitChanged(_ sender: NSSlider) {
        let limit = Self.clampedSidebarRecentItemsLimit(Int(sender.doubleValue.rounded()))
        sender.doubleValue = Double(limit)
        sidebarRecentItemsLimit = limit
        sidebarRecentItemsLimitValueLabel.stringValue = sidebarRecentItemsLimitText(limit)
        onSidebarRecentItemsLimitChanged?(limit)
    }

    private func updateEffectButtonsEnabled() {
        for (_, button) in effectButtons {
            button.isEnabled = isStarEffectsEnabled
        }
    }

    private func applyThemeSelection(_ theme: FilerTheme, notify: Bool) {
        selectedTheme = theme
        descriptionLabel.stringValue = theme.descriptionText

        if let index = FilerTheme.allCases.firstIndex(of: theme) {
            themePopUpButton.selectItem(at: index)
        }

        updateSwatches(for: theme)

        if notify {
            onThemeChanged?(theme)
        }
    }

    private func updateSwatches(for theme: FilerTheme) {
        swatchContainer.subviews.forEach { $0.removeFromSuperview() }

        let palette = theme.palette
        let colors: [NSColor] = [
            palette.windowBackgroundColor,
            palette.paneBackgroundColor,
            palette.activeBorderColor,
            palette.accentColor,
            palette.activeHeaderColor,
            palette.markedColor,
            palette.sidebarIconTintColor,
            palette.filterBarBackgroundColor,
            palette.statusBarTextColor,
        ]

        var previousView: NSView?
        for color in colors {
            let swatch = NSView()
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.cgColor
            swatch.layer?.cornerRadius = 4
            swatch.layer?.borderWidth = 1
            swatch.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            swatchContainer.addSubview(swatch)

            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 28),
                swatch.heightAnchor.constraint(equalToConstant: 28),
                swatch.centerYAnchor.constraint(equalTo: swatchContainer.centerYAnchor),
            ])

            if let prev = previousView {
                swatch.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 6).isActive = true
            } else {
                swatch.leadingAnchor.constraint(equalTo: swatchContainer.leadingAnchor).isActive = true
            }

            previousView = swatch
        }
    }

    private func sidebarRecentItemsLimitText(_ value: Int) -> String {
        value == 0 ? "Off" : "\(value) items"
    }

    private static func clampedSidebarRecentItemsLimit(_ value: Int) -> Int {
        min(max(value, AppConfig.sidebarRecentItemsLimitRange.lowerBound), AppConfig.sidebarRecentItemsLimitRange.upperBound)
    }
}
