import Foundation

protocol FileSystemProviding {
    func contentsOfDirectory(at url: URL) async throws -> [FileItem]
    func recursiveContentsOfDirectory(at url: URL, includeHiddenFiles: Bool, onProgress: (@Sendable (Int) -> Void)?) async throws -> [FileItem]
    func mediaItems(in directory: URL, recursive: Bool, includeHiddenFiles: Bool, onProgress: (@Sendable (Int) -> Void)?) async throws -> [FileItem]
}

extension FileSystemProviding {
    func recursiveContentsOfDirectory(at url: URL, includeHiddenFiles: Bool) async throws -> [FileItem] {
        try await recursiveContentsOfDirectory(at: url, includeHiddenFiles: includeHiddenFiles, onProgress: nil)
    }

    func mediaItems(in directory: URL, recursive: Bool, includeHiddenFiles: Bool) async throws -> [FileItem] {
        try await mediaItems(in: directory, recursive: recursive, includeHiddenFiles: includeHiddenFiles, onProgress: nil)
    }
}

private actor FileSystemWorker {
    private struct EnumerationContext {
        let requestedURL: URL
        let enumeratedURL: URL
    }

    private let fileManager: FileManager
    private let resourceKeys: Set<URLResourceKey>

    init(fileManager: FileManager, resourceKeys: Set<URLResourceKey>) {
        self.fileManager = fileManager
        self.resourceKeys = resourceKeys
    }

    func contentsOfDirectory(at url: URL) throws -> [FileItem] {
        try Task.checkCancellation()
        let context = resolveEnumerationContext(for: url)
        let urls = try fileManager.contentsOfDirectory(
            at: context.enumeratedURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsSubdirectoryDescendants]
        )

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for entryURL in urls {
            try Task.checkCancellation()
            let values = try? entryURL.resourceValues(forKeys: resourceKeys)
            let mappedURL = mapEnumeratedURL(entryURL, context: context)
            items.append(makeFileItem(from: mappedURL, values: values))
        }
        return items
    }

    func recursiveContentsOfDirectory(at url: URL, includeHiddenFiles: Bool, onProgress: (@Sendable (Int) -> Void)?) throws -> [FileItem] {
        try Task.checkCancellation()
        let context = resolveEnumerationContext(for: url)
        let options: FileManager.DirectoryEnumerationOptions = includeHiddenFiles
            ? [.skipsPackageDescendants]
            : [.skipsPackageDescendants, .skipsHiddenFiles]

        guard let enumerator = fileManager.enumerator(
            at: context.enumeratedURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            return []
        }

        var items: [FileItem] = []
        while let entryURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? entryURL.resourceValues(forKeys: resourceKeys)
            let mappedURL = mapEnumeratedURL(entryURL, context: context)
            let item = makeFileItem(from: mappedURL, values: values)
            if !includeHiddenFiles, item.isHidden {
                continue
            }
            items.append(item)
            if items.count % 200 == 0 {
                onProgress?(items.count)
            }
        }

        return items.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    func mediaItems(in directory: URL, recursive: Bool, includeHiddenFiles: Bool, onProgress: (@Sendable (Int) -> Void)?) throws -> [FileItem] {
        try Task.checkCancellation()
        if !recursive {
            let items = try contentsOfDirectory(at: directory)
            var filtered: [FileItem] = []
            filtered.reserveCapacity(items.count)
            for item in items {
                try Task.checkCancellation()
                if item.isDirectory {
                    continue
                }
                if !includeHiddenFiles, item.isHidden {
                    continue
                }
                if item.url.isMediaFile {
                    filtered.append(item)
                }
            }
            return filtered
        }

        let options: FileManager.DirectoryEnumerationOptions = includeHiddenFiles
            ? [.skipsPackageDescendants]
            : [.skipsPackageDescendants, .skipsHiddenFiles]
        let context = resolveEnumerationContext(for: directory)

        guard let enumerator = fileManager.enumerator(
            at: context.enumeratedURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            return []
        }

        var items: [FileItem] = []
        while let entryURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? entryURL.resourceValues(forKeys: resourceKeys)
            let mappedURL = mapEnumeratedURL(entryURL, context: context)
            let item = makeFileItem(from: mappedURL, values: values)
            if item.isDirectory {
                continue
            }
            if !includeHiddenFiles, item.isHidden {
                continue
            }
            if item.url.isMediaFile {
                items.append(item)
                if items.count % 200 == 0 {
                    onProgress?(items.count)
                }
            }
        }

        return items.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private func makeFileItem(from entryURL: URL, values: URLResourceValues?) -> FileItem {
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false

        return FileItem(
            url: entryURL,
            name: values?.name ?? entryURL.displayName,
            isDirectory: isDirectory,
            size: values?.fileSize.map(Int64.init),
            dateModified: values?.contentModificationDate,
            isHidden: values?.isHidden ?? false,
            isSymlink: values?.isSymbolicLink ?? false,
            isPackage: isPackage
        )
    }

    private func resolveEnumerationContext(for url: URL) -> EnumerationContext {
        let requestedURL = url.standardizedFileURL
        let enumeratedURL = requestedURL.resolvingSymlinksInPath().standardizedFileURL
        return EnumerationContext(requestedURL: requestedURL, enumeratedURL: enumeratedURL)
    }

    private func mapEnumeratedURL(_ entryURL: URL, context: EnumerationContext) -> URL {
        let standardizedEntryURL = entryURL.standardizedFileURL
        guard context.requestedURL.path != context.enumeratedURL.path else {
            return standardizedEntryURL
        }

        let rootComponents = context.enumeratedURL.pathComponents
        let entryComponents = standardizedEntryURL.pathComponents
        guard entryComponents.starts(with: rootComponents) else {
            return standardizedEntryURL
        }

        let relativeComponents = entryComponents.dropFirst(rootComponents.count)
        guard !relativeComponents.isEmpty else {
            return context.requestedURL
        }

        var mappedURL = context.requestedURL
        for component in relativeComponents {
            mappedURL.appendPathComponent(component, isDirectory: false)
        }
        return mappedURL.standardizedFileURL
    }
}

struct FileSystemService: FileSystemProviding {
    private static let resourceKeys: Set<URLResourceKey> = [
            .nameKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
            .isPackageKey
        ]
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private func makeWorker() -> FileSystemWorker {
        FileSystemWorker(fileManager: fileManager, resourceKeys: Self.resourceKeys)
    }

    func contentsOfDirectory(at url: URL) async throws -> [FileItem] {
        try await makeWorker().contentsOfDirectory(at: url)
    }

    func recursiveContentsOfDirectory(at url: URL, includeHiddenFiles: Bool, onProgress: (@Sendable (Int) -> Void)?) async throws -> [FileItem] {
        try await makeWorker().recursiveContentsOfDirectory(at: url, includeHiddenFiles: includeHiddenFiles, onProgress: onProgress)
    }

    func mediaItems(in directory: URL, recursive: Bool, includeHiddenFiles: Bool, onProgress: (@Sendable (Int) -> Void)?) async throws -> [FileItem] {
        try await makeWorker().mediaItems(in: directory, recursive: recursive, includeHiddenFiles: includeHiddenFiles, onProgress: onProgress)
    }
}
