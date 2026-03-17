import Foundation
@testable import Starfiler

@MainActor
final class MockFileSystemService: FileSystemProviding, @unchecked Sendable {
    // MARK: - contentsOfDirectory

    var contentsOfDirectoryResult: Result<[FileItem], Error> = .success([])
    var contentsOfDirectoryHandler: ((URL) async throws -> [FileItem])?
    private(set) var contentsOfDirectoryCallCount = 0
    private(set) var contentsOfDirectoryCapturedURLs: [URL] = []

    func contentsOfDirectory(at url: URL) async throws -> [FileItem] {
        contentsOfDirectoryCallCount += 1
        contentsOfDirectoryCapturedURLs.append(url)
        if let contentsOfDirectoryHandler {
            return try await contentsOfDirectoryHandler(url)
        }
        return try contentsOfDirectoryResult.get()
    }

    // MARK: - recursiveContentsOfDirectory

    var recursiveContentsOfDirectoryResult: Result<[FileItem], Error> = .success([])
    var recursiveContentsOfDirectoryHandler: ((URL, Bool) async throws -> [FileItem])?
    private(set) var recursiveContentsOfDirectoryCallCount = 0
    private(set) var recursiveContentsOfDirectoryCapturedArgs: [(url: URL, includeHiddenFiles: Bool)] = []

    func recursiveContentsOfDirectory(at url: URL, includeHiddenFiles: Bool, onProgress: (@Sendable (Int) -> Void)?) async throws -> [FileItem] {
        recursiveContentsOfDirectoryCallCount += 1
        recursiveContentsOfDirectoryCapturedArgs.append((url, includeHiddenFiles))
        if let recursiveContentsOfDirectoryHandler {
            return try await recursiveContentsOfDirectoryHandler(url, includeHiddenFiles)
        }
        return try recursiveContentsOfDirectoryResult.get()
    }

    // MARK: - mediaItems

    var mediaItemsResult: Result<[FileItem], Error> = .success([])
    var mediaItemsHandler: ((URL, Bool, Bool) async throws -> [FileItem])?
    private(set) var mediaItemsCallCount = 0
    private(set) var mediaItemsCapturedArgs: [(directory: URL, recursive: Bool, includeHiddenFiles: Bool)] = []

    func mediaItems(in directory: URL, recursive: Bool, includeHiddenFiles: Bool, onProgress: (@Sendable (Int) -> Void)?) async throws -> [FileItem] {
        mediaItemsCallCount += 1
        mediaItemsCapturedArgs.append((directory, recursive, includeHiddenFiles))
        if let mediaItemsHandler {
            return try await mediaItemsHandler(directory, recursive, includeHiddenFiles)
        }
        return try mediaItemsResult.get()
    }
}
