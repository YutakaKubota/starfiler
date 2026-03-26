import XCTest
@testable import Starfiler

final class FileSystemServiceIntegrationTests: XCTestCase {
    func testContentsOfDirectoryIncludesHiddenAndPackageFlags() async throws {
        let workspace = try SandboxFixtureWorkspace()
        let sut = FileSystemService()

        let items = try await sut.contentsOfDirectory(at: workspace.url("left"))

        XCTAssertTrue(items.contains(where: { $0.name == ".hidden.txt" && $0.isHidden }))
        XCTAssertTrue(items.contains(where: { $0.name == "Sample.app" && $0.isPackage }))
        XCTAssertTrue(items.contains(where: { $0.name == "docs" && $0.isDirectory }))
    }

    func testContentsOfDirectorySupportsDirectorySymlinkRoots() async throws {
        let workspace = try SandboxFixtureWorkspace()
        let fileManager = FileManager.default
        let targetURL = workspace.url("left/docs")
        let symlinkURL = workspace.url("left/docs-link")
        try fileManager.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: targetURL.path)

        let sut = FileSystemService()
        let items = try await sut.contentsOfDirectory(at: symlinkURL)

        XCTAssertEqual(Set(items.map(\.name)), Set(["notes.md", "readme.md"]))
        XCTAssertTrue(items.allSatisfy { $0.url.path.hasPrefix(symlinkURL.path + "/") })
    }

    func testRecursiveContentsRespectsHiddenFlagAndSkipsPackageDescendants() async throws {
        let workspace = try SandboxFixtureWorkspace()
        let sut = FileSystemService()

        let withoutHidden = try await sut.recursiveContentsOfDirectory(
            at: workspace.url("left"),
            includeHiddenFiles: false
        )
        let withHidden = try await sut.recursiveContentsOfDirectory(
            at: workspace.url("left"),
            includeHiddenFiles: true
        )

        XCTAssertFalse(withoutHidden.contains(where: { $0.name == ".hidden.txt" }))
        XCTAssertTrue(withHidden.contains(where: { $0.name == ".hidden.txt" }))
        XCTAssertFalse(withHidden.contains(where: { $0.url.path.contains("Sample.app/Contents") }))
    }

    func testRecursiveContentsSupportsDirectorySymlinkRoots() async throws {
        let workspace = try SandboxFixtureWorkspace()
        let fileManager = FileManager.default
        let targetURL = workspace.url("left/docs")
        let symlinkURL = workspace.url("left/docs-recursive-link")
        try fileManager.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: targetURL.path)

        let nestedDirectoryURL = targetURL.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectoryURL, withIntermediateDirectories: true)
        let nestedFileURL = nestedDirectoryURL.appendingPathComponent("deep.txt")
        try "nested".write(to: nestedFileURL, atomically: true, encoding: .utf8)

        let sut = FileSystemService()
        let items = try await sut.recursiveContentsOfDirectory(at: symlinkURL, includeHiddenFiles: true)

        let expectedPath = symlinkURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deep.txt")
            .standardizedFileURL.path
        XCTAssertTrue(items.contains(where: { $0.url.path == expectedPath }))
    }

    func testMediaItemsFiltersByMediaExtensions() async throws {
        let workspace = try SandboxFixtureWorkspace()
        try Data("mp3 fixture".utf8).write(to: workspace.url("left/media/theme.mp3"))
        try Data("wav fixture".utf8).write(to: workspace.url("left/media/click.wav"))
        let sut = FileSystemService()

        let nonRecursive = try await sut.mediaItems(
            in: workspace.url("left/media"),
            recursive: false,
            includeHiddenFiles: true
        )

        XCTAssertEqual(Set(nonRecursive.map(\.name)), Set(["click.wav", "photo.jpg", "theme.mp3", "video.mp4"]))
    }

    func testMediaItemsRecursiveFindsNestedMediaFiles() async throws {
        let workspace = try SandboxFixtureWorkspace()
        let nestedDir = workspace.url("left/media/nested")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try "nested media".write(to: nestedDir.appendingPathComponent("nested.png"), atomically: true, encoding: .utf8)

        let sut = FileSystemService()
        let recursive = try await sut.mediaItems(
            in: workspace.url("left"),
            recursive: true,
            includeHiddenFiles: true
        )

        XCTAssertTrue(recursive.contains(where: { $0.name == "nested.png" }))
    }

    func testMediaItemsTreatsPhotoshopDocumentsAsMedia() async throws {
        let workspace = try SandboxFixtureWorkspace()
        try "photoshop fixture".write(
            to: workspace.url("left/media/layout.psd"),
            atomically: true,
            encoding: .utf8
        )
        try "large photoshop fixture".write(
            to: workspace.url("left/media/layout-large.psb"),
            atomically: true,
            encoding: .utf8
        )

        let sut = FileSystemService()
        let items = try await sut.mediaItems(
            in: workspace.url("left/media"),
            recursive: false,
            includeHiddenFiles: true
        )

        XCTAssertTrue(items.contains(where: { $0.name == "layout.psd" }))
        XCTAssertTrue(items.contains(where: { $0.name == "layout-large.psb" }))
    }

    func testMediaItemsDoesNotTreatTypeScriptAsMedia() async throws {
        let workspace = try SandboxFixtureWorkspace()
        try Data("mp3 fixture".utf8).write(to: workspace.url("left/media/theme.mp3"))
        try Data("wav fixture".utf8).write(to: workspace.url("left/media/click.wav"))
        try "const answer: number = 42".write(
            to: workspace.url("left/media/script.ts"),
            atomically: true,
            encoding: .utf8
        )

        let sut = FileSystemService()
        let nonRecursive = try await sut.mediaItems(
            in: workspace.url("left/media"),
            recursive: false,
            includeHiddenFiles: true
        )

        XCTAssertEqual(Set(nonRecursive.map(\.name)), Set(["click.wav", "photo.jpg", "theme.mp3", "video.mp4"]))
        XCTAssertFalse(nonRecursive.contains(where: { $0.name == "script.ts" }))
    }

    func testMediaItemsUsesWhitelistAndExcludesMTS() async throws {
        let workspace = try SandboxFixtureWorkspace()
        try Data("mp3 fixture".utf8).write(to: workspace.url("left/media/theme.mp3"))
        try Data("wav fixture".utf8).write(to: workspace.url("left/media/click.wav"))
        try "transport stream fixture".write(
            to: workspace.url("left/media/capture.mts"),
            atomically: true,
            encoding: .utf8
        )

        let sut = FileSystemService()
        let nonRecursive = try await sut.mediaItems(
            in: workspace.url("left/media"),
            recursive: false,
            includeHiddenFiles: true
        )

        XCTAssertEqual(Set(nonRecursive.map(\.name)), Set(["click.wav", "photo.jpg", "theme.mp3", "video.mp4"]))
        XCTAssertFalse(nonRecursive.contains(where: { $0.name == "capture.mts" }))
    }
}
