import AppKit
import AVFoundation
import AVKit
import ImageIO

final class PreviewPaneViewController: NSViewController {
    private let viewModel: PreviewViewModel

    private let pathBarView = NSView()
    private let pathControl = NSPathControl()
    private let toolbarView = NSView()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let positionLabel = NSTextField(labelWithString: "0 / 0")
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let zoomSlider = NSSlider(value: 1.0, minValue: 0.001, maxValue: 8.0, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let fitButton = NSButton()
    private let actualSizeButton = NSButton()

    private let contentContainerView = NSView()
    private let scrollView = NSScrollView()
    private let playerView = AVPlayerView()
    private let imageView = NSImageView()
    private let emptyStateLabel = NSTextField(labelWithString: "Select an image or video file")

    private var currentTheme: FilerTheme = .system
    private var backgroundOpacity: CGFloat = 1.0

    private var starEffectsEnabled = true
    private var animationEffectSettings = AnimationEffectSettings.allEnabled
    private var currentState: PreviewViewModel.State = .default
    private var currentMediaItems: [PreviewViewModel.MediaItem] = []
    private var currentMediaURL: URL?
    private var isFitModeActive = true
    private var preferredFitViewportWidth: CGFloat = 320
    private var preferredFitViewportHeight: CGFloat = 240
    private var imageLoadTask: Task<Void, Never>?
    private var currentPlayer: AVPlayer?
    private let imageCache = NSCache<NSString, NSImage>()
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    var onImageSelectionChanged: ((URL?) -> Void)?
    var onNavigateRequested: ((URL) -> Void)?

    init(viewModel: PreviewViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageLoadTask?.cancel()
        currentPlayer?.pause()
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        configureLayout()
        bindViewModel()
        applyState(viewModel.state)
    }

    func applyTheme(_ theme: FilerTheme, backgroundOpacity: CGFloat = 1.0) {
        currentTheme = theme
        self.backgroundOpacity = backgroundOpacity
        applyCurrentTheme()
    }

    func setStarEffectsEnabled(_ enabled: Bool) {
        starEffectsEnabled = enabled
    }

    func setAnimationEffectSettings(_ settings: AnimationEffectSettings) {
        animationEffectSettings = settings
    }

    func setPreferredFitViewportSize(width: CGFloat, height: CGFloat) {
        guard width > 0 || height > 0 else {
            return
        }

        if width > 0 {
            preferredFitViewportWidth = width
        }
        if height > 0 {
            preferredFitViewportHeight = height
        }

        if isFitModeActive {
            fitImageToView()
        }
    }

    func refreshFitIfNeeded() {
        guard isFitModeActive else {
            return
        }

        fitImageToView()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFitModeActive else {
                return
            }
            self.fitImageToView()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyCurrentTheme()
        if isFitModeActive {
            fitImageToView()
        }
    }

    private func configureView() {
        view.wantsLayer = true

        pathBarView.translatesAutoresizingMaskIntoConstraints = false
        pathBarView.wantsLayer = true

        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.target = self
        pathControl.action = #selector(handlePathControlClick(_:))

        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.wantsLayer = true

        configureButton(previousButton, systemSymbolName: "chevron.left", action: #selector(handlePreviousImage))
        configureButton(nextButton, systemSymbolName: "chevron.right", action: #selector(handleNextImage))
        configureButton(zoomOutButton, systemSymbolName: "minus.magnifyingglass", action: #selector(handleZoomOut))
        configureButton(zoomInButton, systemSymbolName: "plus.magnifyingglass", action: #selector(handleZoomIn))

        fitButton.translatesAutoresizingMaskIntoConstraints = false
        fitButton.title = "Fit"
        fitButton.bezelStyle = .rounded
        fitButton.target = self
        fitButton.action = #selector(handleFitImage)

        actualSizeButton.translatesAutoresizingMaskIntoConstraints = false
        actualSizeButton.title = "100%"
        actualSizeButton.bezelStyle = .rounded
        actualSizeButton.target = self
        actualSizeButton.action = #selector(handleActualSize)

        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.numberOfTickMarks = 0
        zoomSlider.target = self
        zoomSlider.action = #selector(handleZoomSliderChanged(_:))

        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.alignment = .center

        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        zoomLabel.alignment = .right

        contentContainerView.translatesAutoresizingMaskIntoConstraints = false
        contentContainerView.wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = CGFloat(zoomSlider.minValue)
        scrollView.maxMagnification = CGFloat(zoomSlider.maxValue)

        imageView.imageScaling = .scaleNone
        imageView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        scrollView.documentView = imageView

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .floating
        playerView.isHidden = true

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyStateLabel.maximumNumberOfLines = 3
    }

    private func configureLayout() {
        view.addSubview(pathBarView)
        view.addSubview(toolbarView)
        view.addSubview(contentContainerView)

        pathBarView.addSubview(pathControl)
        toolbarView.addSubview(previousButton)
        toolbarView.addSubview(nextButton)
        toolbarView.addSubview(positionLabel)
        toolbarView.addSubview(zoomOutButton)
        toolbarView.addSubview(zoomSlider)
        toolbarView.addSubview(zoomInButton)
        toolbarView.addSubview(zoomLabel)
        toolbarView.addSubview(fitButton)
        toolbarView.addSubview(actualSizeButton)

        contentContainerView.addSubview(scrollView)
        contentContainerView.addSubview(playerView)
        contentContainerView.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            pathBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pathBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pathBarView.topAnchor.constraint(equalTo: view.topAnchor),
            pathBarView.heightAnchor.constraint(equalToConstant: 30),

            pathControl.leadingAnchor.constraint(equalTo: pathBarView.leadingAnchor, constant: 10),
            pathControl.trailingAnchor.constraint(equalTo: pathBarView.trailingAnchor, constant: -10),
            pathControl.centerYAnchor.constraint(equalTo: pathBarView.centerYAnchor),

            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: pathBarView.bottomAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 38),

            contentContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainerView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            contentContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),

            playerView.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),

            emptyStateLabel.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor, constant: 18),
            emptyStateLabel.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor, constant: -18),
            emptyStateLabel.centerXAnchor.constraint(equalTo: contentContainerView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: contentContainerView.centerYAnchor),

            previousButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 8),
            previousButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 28),

            nextButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 4),
            nextButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 28),

            positionLabel.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 8),
            positionLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            positionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),

            zoomOutButton.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 12),
            zoomOutButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            zoomOutButton.widthAnchor.constraint(equalToConstant: 28),

            zoomSlider.leadingAnchor.constraint(equalTo: zoomOutButton.trailingAnchor, constant: 6),
            zoomSlider.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            zoomSlider.widthAnchor.constraint(equalToConstant: 150),

            zoomInButton.leadingAnchor.constraint(equalTo: zoomSlider.trailingAnchor, constant: 6),
            zoomInButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            zoomInButton.widthAnchor.constraint(equalToConstant: 28),

            zoomLabel.leadingAnchor.constraint(equalTo: zoomInButton.trailingAnchor, constant: 8),
            zoomLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            zoomLabel.widthAnchor.constraint(equalToConstant: 54),

            fitButton.leadingAnchor.constraint(equalTo: zoomLabel.trailingAnchor, constant: 10),
            fitButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            actualSizeButton.leadingAnchor.constraint(equalTo: fitButton.trailingAnchor, constant: 6),
            actualSizeButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            actualSizeButton.trailingAnchor.constraint(lessThanOrEqualTo: toolbarView.trailingAnchor, constant: -8)
        ])
    }

    private func configureButton(_ button: NSButton, systemSymbolName: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
    }

    private func bindViewModel() {
        viewModel.onStateChanged = { [weak self] state in
            self?.applyState(state)
        }
    }

    private func applyState(_ state: PreviewViewModel.State) {
        currentState = state
        updatePathControl(for: state)
        applyMediaItems(state.siblingMediaItems, selectedFileURL: state.selectedFileURL)
    }

    private func applyMediaItems(_ items: [PreviewViewModel.MediaItem], selectedFileURL: URL?) {
        currentMediaItems = items
        let cachedImageKeys = Set(
            currentMediaItems
                .filter { $0.url.isImageFile }
                .map(Self.cacheKey(for:))
        )
        prunePrefetchTasks(keeping: cachedImageKeys)

        let selectedMediaURL = selectedFileURL?.standardizedFileURL
        let selectedIsMedia = selectedMediaURL?.isMediaFile ?? false

        if
            let selectedMediaURL,
            selectedIsMedia,
            let index = currentMediaItems.firstIndex(where: { $0.url == selectedMediaURL })
        {
            setCurrentMedia(item: currentMediaItems[index], notifySelection: false)
            return
        }

        if selectedFileURL != nil, !selectedIsMedia {
            setCurrentMedia(item: nil, notifySelection: false, message: "Media preview supports images and videos.")
            return
        }

        let fallbackMessage = currentMediaItems.isEmpty ? "No media files found" : "Media preview supports images and videos."
        setCurrentMedia(item: nil, notifySelection: false, message: fallbackMessage)
    }

    private func setCurrentMedia(item: PreviewViewModel.MediaItem?, notifySelection: Bool, message: String = "No media files found") {
        currentMediaURL = item?.url.standardizedFileURL
        updateNavigationState()

        guard let url = currentMediaURL else {
            imageLoadTask?.cancel()
            imageView.image = nil
            scrollView.isHidden = true
            currentPlayer?.pause()
            currentPlayer = nil
            playerView.player = nil
            playerView.isHidden = true
            emptyStateLabel.stringValue = message
            emptyStateLabel.isHidden = false
            if notifySelection {
                onImageSelectionChanged?(nil)
            }
            return
        }

        if url.isImageFile {
            loadAndDisplayImage(from: item)
        } else if url.isVideoFile {
            displayVideo(from: url)
        } else {
            setCurrentMedia(item: nil, notifySelection: notifySelection, message: "Unsupported media format")
            return
        }

        if notifySelection {
            onImageSelectionChanged?(url)
        }
    }

    private func updateNavigationState() {
        let count = currentMediaItems.count
        let currentIndex = currentMediaURL.flatMap { currentURL in
            currentMediaItems.firstIndex(where: { $0.url == currentURL })
        }

        if let currentIndex {
            positionLabel.stringValue = "\(currentIndex + 1) / \(count)"
        } else {
            positionLabel.stringValue = "0 / \(count)"
        }

        previousButton.isEnabled = (currentIndex ?? 0) > 0
        nextButton.isEnabled = count > 0 && ((currentIndex ?? -1) < count - 1)

        let hasImage = currentMediaURL?.isImageFile ?? false
        zoomOutButton.isEnabled = hasImage
        zoomInButton.isEnabled = hasImage
        zoomSlider.isEnabled = hasImage
        fitButton.isEnabled = hasImage
        actualSizeButton.isEnabled = hasImage
    }

    private func loadAndDisplayImage(from item: PreviewViewModel.MediaItem?) {
        guard let item else {
            return
        }

        let url = item.url
        let cacheKey = Self.cacheKey(for: item)

        currentPlayer?.pause()
        currentPlayer = nil
        playerView.player = nil
        playerView.isHidden = true

        imageLoadTask?.cancel()

        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            displayLoadedImage(cached)
            return
        }

        imageLoadTask = Task { [weak self] in
            let loadedImage = await Self.decodeImage(from: url)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self, self.currentMediaURL == url else {
                    return
                }

                guard let loadedImage else {
                    self.imageView.image = nil
                    self.scrollView.isHidden = true
                    self.emptyStateLabel.stringValue = "Unable to load image"
                    self.emptyStateLabel.isHidden = false
                    return
                }

                self.imageCache.setObject(loadedImage, forKey: cacheKey as NSString)
                self.displayLoadedImage(loadedImage)
            }
        }
    }

    private func displayLoadedImage(_ image: NSImage) {
        if starEffectsEnabled, animationEffectSettings.previewCrossfade, let oldImage = imageView.image, let containerLayer = contentContainerView.layer {
            let snapshot = CALayer()
            snapshot.contents = oldImage
            snapshot.frame = scrollView.frame
            snapshot.contentsGravity = .resizeAspect
            containerLayer.addSublayer(snapshot)

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1.0
            fadeOut.toValue = 0.0
            fadeOut.duration = 0.2
            fadeOut.isRemovedOnCompletion = false
            fadeOut.fillMode = .forwards
            fadeOut.delegate = StarSparkleAnimator.makeRemovalDelegate(for: snapshot)
            snapshot.add(fadeOut, forKey: "crossfade")
        }

        scrollView.alphaValue = 0
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scrollView.documentView = imageView
        scrollView.isHidden = false
        emptyStateLabel.isHidden = true
        playerView.isHidden = true
        applyDefaultFitForLoadedImage()
        prefetchAroundCurrentImage()
    }

    private func displayVideo(from url: URL) {
        imageLoadTask?.cancel()
        imageView.image = nil
        scrollView.isHidden = true

        let player = AVPlayer(url: url)
        currentPlayer?.pause()
        currentPlayer = player
        playerView.player = player
        playerView.isHidden = false
        emptyStateLabel.isHidden = true
        isFitModeActive = false
    }

    private func applyCurrentTheme() {
        let palette = currentTheme.palette
        view.layer?.borderColor = palette.previewBorderColor.applyingBackgroundOpacity(backgroundOpacity).cgColor
        view.layer?.backgroundColor = palette.previewBackgroundColor.applyingBackgroundOpacity(backgroundOpacity).cgColor
        pathBarView.layer?.backgroundColor = palette.inactiveHeaderColor.applyingBackgroundOpacity(backgroundOpacity).cgColor
        toolbarView.layer?.backgroundColor = palette.inactiveHeaderColor.applyingBackgroundOpacity(backgroundOpacity).cgColor
        contentContainerView.layer?.backgroundColor = palette.previewBackgroundColor.applyingBackgroundOpacity(backgroundOpacity).cgColor
        scrollView.backgroundColor = palette.previewBackgroundColor.applyingBackgroundOpacity(backgroundOpacity)
        emptyStateLabel.textColor = palette.secondaryTextColor
        positionLabel.textColor = palette.secondaryTextColor
        zoomLabel.textColor = palette.secondaryTextColor
    }

    private func setZoomScale(_ scale: CGFloat, centeredAt anchorPoint: NSPoint? = nil) {
        guard imageView.image != nil, !scrollView.isHidden else {
            return
        }

        let clamped = min(max(scale, CGFloat(zoomSlider.minValue)), CGFloat(zoomSlider.maxValue))
        let centerPoint = anchorPoint ?? NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        scrollView.setMagnification(clamped, centeredAt: centerPoint)
        zoomSlider.doubleValue = Double(clamped)
        let percentValue = clamped * 100
        if percentValue < 10 {
            zoomLabel.stringValue = String(format: "%.1f%%", percentValue)
        } else {
            zoomLabel.stringValue = "\(Int(percentValue.rounded()))%"
        }
    }

    private func fitImageToView() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            return
        }

        guard let viewportSize = effectiveFitViewportSize() else {
            return
        }

        let anchorPoint = NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        let initialFitScale = fitScale(for: image.size, viewportSize: viewportSize)
        setZoomScale(initialFitScale, centeredAt: anchorPoint)

        if let settledViewportSize = effectiveFitViewportSize() {
            let settledFitScale = fitScale(for: image.size, viewportSize: settledViewportSize)
            if settledFitScale < scrollView.magnification {
                setZoomScale(settledFitScale, centeredAt: anchorPoint)
            }
        }

        alignFitToContentOrigin()
    }

    private func effectiveFitViewportSize() -> NSSize? {
        let clipBounds = scrollView.contentView.bounds.size
        let scrollBounds = scrollView.bounds.size
        let containerBounds = contentContainerView.bounds.size

        guard let effectiveWidth = firstUsableDimension(from: [
            clipBounds.width,
            scrollBounds.width,
            containerBounds.width,
            preferredFitViewportWidth
        ]) else {
            return nil
        }

        guard let effectiveHeight = firstUsableDimension(from: [
            clipBounds.height,
            scrollBounds.height,
            containerBounds.height,
            preferredFitViewportHeight
        ]) else {
            return nil
        }

        return NSSize(width: effectiveWidth, height: effectiveHeight)
    }

    private func fitScale(for imageSize: NSSize, viewportSize: NSSize) -> CGFloat {
        let widthScale = viewportSize.width / imageSize.width
        let heightScale = viewportSize.height / imageSize.height
        let rawScale = min(widthScale, heightScale, 1.0)
        let minScale = CGFloat(zoomSlider.minValue)
        return max(rawScale.nextDown, minScale)
    }

    private func firstUsableDimension(from candidates: [CGFloat]) -> CGFloat? {
        candidates.first(where: { $0 > 1 })
    }

    private func alignFitToContentOrigin() {
        let clipView = scrollView.contentView
        let origin = clipView.documentRect.origin
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func applyDefaultFitForLoadedImage() {
        isFitModeActive = true
        fitImageToView()

        // When selection changes rapidly, layout can settle a tick later.
        // Re-apply fit once to ensure the new image starts in fit mode,
        // then reveal the scroll view so the user never sees the unfitted frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isFitModeActive, self.imageView.image != nil, !self.scrollView.isHidden {
                self.fitImageToView()
            }
            self.scrollView.alphaValue = 1
        }
    }

    private func prefetchAroundCurrentImage() {
        guard let currentMediaURL,
              let currentIndex = currentMediaItems.firstIndex(where: { $0.url == currentMediaURL }) else {
            return
        }

        let candidateIndices = [currentIndex - 1, currentIndex + 1, currentIndex - 2, currentIndex + 2]
        for index in candidateIndices where currentMediaItems.indices.contains(index) {
            let item = currentMediaItems[index]
            guard item.url.isImageFile else {
                continue
            }
            prefetchImage(item)
        }
    }

    private func prefetchImage(_ item: PreviewViewModel.MediaItem) {
        let cacheKey = Self.cacheKey(for: item)
        guard imageCache.object(forKey: cacheKey as NSString) == nil else {
            return
        }
        guard prefetchTasks[cacheKey] == nil else {
            return
        }

        prefetchTasks[cacheKey] = Task(priority: .utility) { [weak self] in
            let loadedImage = await Self.decodeImage(from: item.url)
            guard let self else {
                return
            }
            if let loadedImage {
                self.imageCache.setObject(loadedImage, forKey: cacheKey as NSString)
            }
            self.prefetchTasks.removeValue(forKey: cacheKey)
        }
    }

    private func prunePrefetchTasks(keeping allowedKeys: Set<String>) {
        let staleKeys = prefetchTasks.keys.filter { !allowedKeys.contains($0) }
        for key in staleKeys {
            prefetchTasks[key]?.cancel()
            prefetchTasks.removeValue(forKey: key)
        }
    }

    @objc
    private func handlePreviousImage() {
        guard let currentMediaURL,
              let currentIndex = currentMediaItems.firstIndex(where: { $0.url == currentMediaURL }),
              currentIndex > 0 else {
            return
        }
        setCurrentMedia(item: currentMediaItems[currentIndex - 1], notifySelection: true)
    }

    @objc
    private func handleNextImage() {
        guard let currentMediaURL,
              let currentIndex = currentMediaItems.firstIndex(where: { $0.url == currentMediaURL }) else {
            return
        }
        let nextIndex = currentIndex + 1
        guard currentMediaItems.indices.contains(nextIndex) else {
            return
        }
        setCurrentMedia(item: currentMediaItems[nextIndex], notifySelection: true)
    }

    private static func cacheKey(for item: PreviewViewModel.MediaItem) -> String {
        let modifiedAt = item.dateModified?.timeIntervalSinceReferenceDate ?? -1
        return "\(item.url.path)#\(modifiedAt)"
    }

    @objc
    private func handleZoomOut() {
        isFitModeActive = false
        setZoomScale(scrollView.magnification * 0.85)
    }

    @objc
    private func handleZoomIn() {
        isFitModeActive = false
        setZoomScale(scrollView.magnification * 1.15)
    }

    @objc
    private func handleZoomSliderChanged(_ sender: NSSlider) {
        isFitModeActive = false
        setZoomScale(CGFloat(sender.doubleValue))
    }

    @objc
    private func handleFitImage() {
        isFitModeActive = true
        fitImageToView()
    }

    @objc
    private func handleActualSize() {
        isFitModeActive = false
        setZoomScale(1.0)
    }

    @objc
    private func handlePathControlClick(_ sender: NSPathControl) {
        guard let clickedURL = sender.clickedPathItem?.url?.standardizedFileURL else {
            return
        }

        var isDirectory: ObjCBool = false
        let destination: URL
        if FileManager.default.fileExists(atPath: clickedURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            destination = clickedURL
        } else {
            destination = clickedURL.deletingLastPathComponent().standardizedFileURL
        }

        onNavigateRequested?(destination)
    }

    private func updatePathControl(for state: PreviewViewModel.State) {
        if let selectedFileURL = state.selectedFileURL?.standardizedFileURL {
            pathControl.url = selectedFileURL
            return
        }

        pathControl.url = state.currentDirectoryURL?.standardizedFileURL
    }

    private static func decodeImage(from url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            return NSImage(cgImage: cgImage, size: size)
        }.value
    }
}
