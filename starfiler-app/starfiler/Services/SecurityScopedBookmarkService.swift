import Foundation

protocol SecurityScopedBookmarkProviding: Sendable {
    func loadBookmarks() async throws
    func hasBookmarks() async throws -> Bool
    func saveBookmark(for url: URL) async throws
    func resolveBookmark(for url: URL) async throws -> URL?
    func startAccessing(_ url: URL) async throws
    func stopAccessing(_ url: URL) async
}

enum SecurityScopedBookmarkError: LocalizedError, Sendable {
    case bookmarkNotFound(requestedPath: String)
    case symlinkEscapesAuthorizedScope(requestedPath: String, authorizedPath: String)
    case cannotStartAccess(scopePath: String)

    var errorDescription: String? {
        switch self {
        case .bookmarkNotFound(let requestedPath):
            return "No security-scoped bookmark found for path: \(requestedPath)"
        case .symlinkEscapesAuthorizedScope(let requestedPath, let authorizedPath):
            return "Path \(requestedPath) resolves outside authorized scope \(authorizedPath)."
        case .cannotStartAccess(let scopePath):
            return "Failed to start accessing security-scoped resource: \(scopePath)"
        }
    }
}

actor SecurityScopedBookmarkService: SecurityScopedBookmarkProviding {
    static let shared = SecurityScopedBookmarkService()

    private struct BookmarkStore: Codable, Sendable {
        var version: Int = 1
        var bookmarks: [BookmarkRecord] = []
    }

    private struct BookmarkRecord: Codable, Sendable {
        var id: UUID
        var selectedPath: String
        var resolvedPath: String
        var bookmarkData: Data
        var createdAt: Date
        var updatedAt: Date
    }

    private struct ResolvedBookmark: Sendable {
        let url: URL
        let selectedPath: String
        let resolvedPath: String
    }

    private struct ActiveScope: Sendable {
        let url: URL
        var refCount: Int
        let startedSecurityScope: Bool
    }

    private struct ActiveLease: Sendable {
        var scopeResolvedPath: String
        var count: Int
    }

    private let fileManager: FileManager
    private let bundleIdentifier: String
    private let isSandboxed: Bool
    private let bookmarkStoreURLOverride: URL?

    private var store = BookmarkStore()
    private var isStoreLoaded = false

    private var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        isSandboxed ? [.withSecurityScope] : []
    }

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        isSandboxed ? [.withSecurityScope] : []
    }

    private var activeScopes: [String: ActiveScope] = [:]
    private var activeLeases: [String: ActiveLease] = [:]

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.nilone.starfiler",
        bookmarkStoreURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundleIdentifier = bundleIdentifier
        self.bookmarkStoreURLOverride = bookmarkStoreURL
        self.isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    func loadBookmarks() async throws {
        try loadStore(forceReload: true)
    }

    func hasBookmarks() async throws -> Bool {
        try loadStoreIfNeeded()
        return !store.bookmarks.isEmpty
    }

    func saveBookmark(for url: URL) async throws {
        try loadStoreIfNeeded()

        let standardizedURL = canonicalAccessURL(for: url)
        let selectedPath = normalizedPath(for: standardizedURL)
        let resolvedPath = normalizedPath(for: standardizedURL.resolvingSymlinksInPath())
        let bookmarkData = try standardizedURL.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let now = Date()
        if let index = store.bookmarks.firstIndex(where: { $0.selectedPath == selectedPath || $0.resolvedPath == resolvedPath }) {
            var updated = store.bookmarks[index]
            updated.selectedPath = selectedPath
            updated.resolvedPath = resolvedPath
            updated.bookmarkData = bookmarkData
            updated.updatedAt = now
            store.bookmarks[index] = updated
        } else {
            store.bookmarks.append(
                BookmarkRecord(
                    id: UUID(),
                    selectedPath: selectedPath,
                    resolvedPath: resolvedPath,
                    bookmarkData: bookmarkData,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        try persistStore()
    }

    func resolveBookmark(for url: URL) async throws -> URL? {
        try loadStoreIfNeeded()

        let standardizedURL = canonicalAccessURL(for: url)
        let requestedPath = normalizedPath(for: standardizedURL)
        let requestedResolvedPath = normalizedPath(for: standardizedURL.resolvingSymlinksInPath())

        guard let bookmarkIndex = bestBookmarkIndex(forResolvedPath: requestedResolvedPath) else {
            if let apparentIndex = bestBookmarkIndex(forSelectedPath: requestedPath) {
                let record = store.bookmarks[apparentIndex]
                throw SecurityScopedBookmarkError.symlinkEscapesAuthorizedScope(
                    requestedPath: requestedResolvedPath,
                    authorizedPath: record.resolvedPath
                )
            }
            return nil
        }

        let resolvedBookmark = try resolveBookmarkRecord(at: bookmarkIndex)

        guard isSameOrDescendant(requestedResolvedPath, of: resolvedBookmark.resolvedPath) else {
            throw SecurityScopedBookmarkError.symlinkEscapesAuthorizedScope(
                requestedPath: requestedResolvedPath,
                authorizedPath: resolvedBookmark.resolvedPath
            )
        }

        return resolvedBookmark.url
    }

    func startAccessing(_ url: URL) async throws {
        try loadStoreIfNeeded()

        let standardizedURL = canonicalAccessURL(for: url)
        let requestedResolvedPath = normalizedPath(for: standardizedURL.resolvingSymlinksInPath())

        if var existingLease = activeLeases[requestedResolvedPath] {
            existingLease.count += 1
            activeLeases[requestedResolvedPath] = existingLease
            incrementScopeCount(for: existingLease.scopeResolvedPath)
            return
        }

        let parentActiveScopePath = activeScopePath(containing: requestedResolvedPath)

        if let bookmarkIndex = bestBookmarkIndex(forResolvedPath: requestedResolvedPath) {
            do {
                let resolvedBookmark = try resolveBookmarkRecord(at: bookmarkIndex)

                guard isSameOrDescendant(requestedResolvedPath, of: resolvedBookmark.resolvedPath) else {
                    throw SecurityScopedBookmarkError.symlinkEscapesAuthorizedScope(
                        requestedPath: requestedResolvedPath,
                        authorizedPath: resolvedBookmark.resolvedPath
                    )
                }

                if let activeScopePath = parentActiveScopePath,
                   pathDepth(activeScopePath) >= pathDepth(resolvedBookmark.resolvedPath)
                {
                    activeLeases[requestedResolvedPath] = ActiveLease(scopeResolvedPath: activeScopePath, count: 1)
                    incrementScopeCount(for: activeScopePath)
                    return
                }

                if let existingScope = activeScopes[resolvedBookmark.resolvedPath] {
                    activeScopes[resolvedBookmark.resolvedPath] = ActiveScope(
                        url: existingScope.url,
                        refCount: existingScope.refCount + 1,
                        startedSecurityScope: existingScope.startedSecurityScope
                    )
                    activeLeases[requestedResolvedPath] = ActiveLease(scopeResolvedPath: resolvedBookmark.resolvedPath, count: 1)
                    return
                }

                if resolvedBookmark.url.startAccessingSecurityScopedResource() {
                    activeScopes[resolvedBookmark.resolvedPath] = ActiveScope(
                        url: resolvedBookmark.url,
                        refCount: 1,
                        startedSecurityScope: true
                    )
                    activeLeases[requestedResolvedPath] = ActiveLease(scopeResolvedPath: resolvedBookmark.resolvedPath, count: 1)
                    return
                }
                // startAccessingSecurityScopedResource failed — fall through to canAccessWithoutBookmark
            } catch {
                // Bookmark resolution failed (e.g. sandbox state changed) — fall through to canAccessWithoutBookmark
            }
        }

        if let activeScopePath = parentActiveScopePath {
            activeLeases[requestedResolvedPath] = ActiveLease(scopeResolvedPath: activeScopePath, count: 1)
            incrementScopeCount(for: activeScopePath)
            return
        }

        if canAccessWithoutBookmark(standardizedURL) {
            activeScopes[requestedResolvedPath] = ActiveScope(
                url: standardizedURL,
                refCount: 1,
                startedSecurityScope: false
            )
            activeLeases[requestedResolvedPath] = ActiveLease(scopeResolvedPath: requestedResolvedPath, count: 1)
            return
        }

        throw SecurityScopedBookmarkError.bookmarkNotFound(requestedPath: requestedResolvedPath)
    }

    func stopAccessing(_ url: URL) async {
        let requestedResolvedPath = normalizedPath(for: canonicalAccessURL(for: url).resolvingSymlinksInPath())
        guard var lease = activeLeases[requestedResolvedPath] else {
            return
        }

        let scopePath = lease.scopeResolvedPath

        lease.count -= 1
        if lease.count <= 0 {
            activeLeases.removeValue(forKey: requestedResolvedPath)
        } else {
            activeLeases[requestedResolvedPath] = lease
        }

        guard var scope = activeScopes[scopePath] else {
            return
        }

        scope.refCount -= 1
        if scope.refCount <= 0 {
            if scope.startedSecurityScope {
                scope.url.stopAccessingSecurityScopedResource()
            }
            activeScopes.removeValue(forKey: scopePath)
        } else {
            activeScopes[scopePath] = scope
        }
    }

    private func incrementScopeCount(for resolvedPath: String) {
        guard var scope = activeScopes[resolvedPath] else {
            return
        }
        scope.refCount += 1
        activeScopes[resolvedPath] = scope
    }

    private func activeScopePath(containing requestedResolvedPath: String) -> String? {
        activeScopes.keys
            .filter { isSameOrDescendant(requestedResolvedPath, of: $0) }
            .max(by: { pathDepth($0) < pathDepth($1) })
    }

    private func bestBookmarkIndex(forResolvedPath requestedResolvedPath: String) -> Int? {
        store.bookmarks
            .enumerated()
            .filter { isSameOrDescendant(requestedResolvedPath, of: $0.element.resolvedPath) }
            .max(by: { pathDepth($0.element.resolvedPath) < pathDepth($1.element.resolvedPath) })?
            .offset
    }

    private func bestBookmarkIndex(forSelectedPath requestedPath: String) -> Int? {
        store.bookmarks
            .enumerated()
            .filter { isSameOrDescendant(requestedPath, of: $0.element.selectedPath) }
            .max(by: { pathDepth($0.element.selectedPath) < pathDepth($1.element.selectedPath) })?
            .offset
    }

    private func resolveBookmarkRecord(at index: Int) throws -> ResolvedBookmark {
        let record = store.bookmarks[index]

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: record.bookmarkData,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL

        let selectedPath = normalizedPath(for: resolvedURL)
        let resolvedPath = normalizedPath(for: resolvedURL.resolvingSymlinksInPath())

        if isStale || record.selectedPath != selectedPath || record.resolvedPath != resolvedPath {
            var refreshedRecord = record
            refreshedRecord.selectedPath = selectedPath
            refreshedRecord.resolvedPath = resolvedPath
            refreshedRecord.bookmarkData = try resolvedURL.bookmarkData(
                options: bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            refreshedRecord.updatedAt = Date()
            store.bookmarks[index] = refreshedRecord
            try persistStore()
        }

        return ResolvedBookmark(
            url: resolvedURL,
            selectedPath: selectedPath,
            resolvedPath: resolvedPath
        )
    }

    private func loadStoreIfNeeded() throws {
        try loadStore(forceReload: false)
    }

    private func loadStore(forceReload: Bool) throws {
        if isStoreLoaded && !forceReload {
            return
        }

        let storeURL = try bookmarkStoreURL()

        guard fileManager.fileExists(atPath: storeURL.path) else {
            store = BookmarkStore()
            isStoreLoaded = true
            return
        }

        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        store = try decoder.decode(BookmarkStore.self, from: data)
        if normalizeStoredPathsIfNeeded() {
            try persistStore()
        }
        isStoreLoaded = true
    }

    private func persistStore() throws {
        let storeURL = try bookmarkStoreURL()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(store)
        try data.write(to: storeURL, options: [.atomic])
    }

    private func bookmarkStoreURL() throws -> URL {
        if let bookmarkStoreURLOverride {
            let directoryURL = bookmarkStoreURLOverride.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            return bookmarkStoreURLOverride
        }

        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let appDirectoryURL = applicationSupportURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
        if !fileManager.fileExists(atPath: appDirectoryURL.path) {
            try fileManager.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true)
        }

        return appDirectoryURL.appendingPathComponent("SecurityScopedBookmarks.json")
    }

    private func normalizedPath(for url: URL) -> String {
        normalizePath(url.path)
    }

    private func canonicalAccessURL(for url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL
        let resolvedPath = PathNormalizer.resolveExistingPath(standardizedURL.path, fileManager: fileManager)
        return URL(fileURLWithPath: resolvedPath).standardizedFileURL
    }

    private func normalizePath(_ path: String) -> String {
        PathNormalizer.normalizeForComparison(path)
    }

    private func isSameOrDescendant(_ child: String, of parent: String) -> Bool {
        PathNormalizer.isSameOrDescendant(child, of: parent)
    }

    private func pathDepth(_ path: String) -> Int {
        path.split(separator: "/", omittingEmptySubsequences: true).count
    }

    private func normalizeStoredPathsIfNeeded() -> Bool {
        var didChange = false

        for index in store.bookmarks.indices {
            let normalizedSelectedPath = normalizePath(store.bookmarks[index].selectedPath)
            let normalizedResolvedPath = normalizePath(store.bookmarks[index].resolvedPath)

            if normalizedSelectedPath != store.bookmarks[index].selectedPath {
                store.bookmarks[index].selectedPath = normalizedSelectedPath
                didChange = true
            }

            if normalizedResolvedPath != store.bookmarks[index].resolvedPath {
                store.bookmarks[index].resolvedPath = normalizedResolvedPath
                didChange = true
            }
        }

        return didChange
    }

    private func canAccessWithoutBookmark(_ url: URL) -> Bool {
        fileManager.isReadableFile(atPath: url.path)
    }
}
