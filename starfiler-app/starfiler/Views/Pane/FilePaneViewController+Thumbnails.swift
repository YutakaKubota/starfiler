import AppKit
import AVFoundation
import ImageIO

// MARK: - Thumbnail & Icon Management

extension FilePaneViewController {
    func icon(for item: FileItem, row: Int) -> NSImage {
        if !item.isDirectory && item.url.isMediaFile {
            let thumbnailKey = thumbnailCacheKey(for: item)

            if let thumbnail = thumbnailCache.object(forKey: thumbnailKey) {
                return thumbnail
            }

            scheduleThumbnailLoadIfNeeded(for: item, row: row, key: thumbnailKey)
        }

        return fallbackIcon(for: item)
    }

    func sizeText(for item: FileItem) -> String {
        guard !item.isDirectory || item.isPackage, let size = item.size else {
            return ""
        }
        return Self.byteFormatter.string(fromByteCount: size)
    }

    func modifiedText(for item: FileItem) -> String {
        guard let date = item.dateModified else {
            return ""
        }
        return Self.dateFormatter.string(from: date)
    }

    func preferredMediaTileWidth() -> CGFloat {
        min(max(fileIconSize * 5.5, 120), 260)
    }

    func invalidateThumbnailCaches() {
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        thumbnailCache.removeAllObjects()
    }
}

private extension FilePaneViewController {
    func fallbackIcon(for item: FileItem) -> NSImage {
        let iconSize = currentDisplayMode == .media ? fileIconSize : Self.browserModeIconSize
        let pixelSize = Int(iconSize.rounded())
        let cacheKey = "\(item.url.path)#\(pixelSize)" as NSString

        if let cached = iconCache.object(forKey: cacheKey) {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.isTemplate = false
        icon.size = NSSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize))
        iconCache.setObject(icon, forKey: cacheKey)
        return icon
    }

    func thumbnailCacheKey(for item: FileItem) -> NSString {
        let pixelSize = thumbnailPixelSizeForCurrentDisplayMode()
        return "thumb#\(item.url.path)#\(pixelSize)" as NSString
    }

    func scheduleThumbnailLoadIfNeeded(for item: FileItem, row: Int, key: NSString) {
        guard thumbnailTasks[key] == nil else {
            return
        }

        let targetURL = item.url.standardizedFileURL
        let size = thumbnailPixelSizeForCurrentDisplayMode()

        thumbnailTasks[key] = Task { [weak self] in
            guard let self else {
                return
            }

            let thumbnail = await Self.generateThumbnail(for: targetURL, maxPixelSize: size)
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.thumbnailTasks.removeValue(forKey: key)
                }
                return
            }

            await MainActor.run {
                self.thumbnailTasks.removeValue(forKey: key)
                guard let thumbnail else {
                    return
                }

                self.thumbnailCache.setObject(thumbnail, forKey: key)

                guard self.viewModel.directoryContents.displayedItems.indices.contains(row) else {
                    return
                }

                if self.viewModel.directoryContents.displayedItems[row].url.standardizedFileURL != targetURL {
                    return
                }

                let rowIndexes = IndexSet(integer: row)
                let columnIndexes = IndexSet(integersIn: 0 ..< self.tableView.numberOfColumns)
                self.tableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
                self.mediaCollectionView.reloadItems(at: [IndexPath(item: row, section: 0)])
            }
        }
    }

    func thumbnailPixelSizeForCurrentDisplayMode() -> Int {
        if currentDisplayMode == .media {
            return max(128, Int((preferredMediaTileWidth() * 2).rounded()))
        }

        return max(16, Int((Self.browserModeIconSize * 2).rounded()))
    }

    static func generateThumbnail(for url: URL, maxPixelSize: Int) async -> NSImage? {
        await Task.detached(priority: .utility) {
            if url.isImageFile {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    return nil
                }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: false,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]

                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }

                let size = NSSize(width: cgImage.width, height: cgImage.height)
                return NSImage(cgImage: cgImage, size: size)
            }

            if url.isVideoFile {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 1)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 1)

                let time = CMTime(seconds: 1, preferredTimescale: 600)
                if let result = try? await generator.image(at: time) {
                    let size = NSSize(width: result.image.width, height: result.image.height)
                    return NSImage(cgImage: result.image, size: size)
                }
                return nil
            }

            return nil
        }.value
    }
}
