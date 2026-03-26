import XCTest
@testable import Starfiler

@MainActor
final class PreviewViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeFileItem(
        name: String,
        isDirectory: Bool = false,
        isPackage: Bool = false
    ) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/test/\(name)"),
            name: name,
            isDirectory: isDirectory,
            size: 1024,
            dateModified: Date(),
            isHidden: false,
            isSymlink: false,
            isPackage: isPackage
        )
    }

    // MARK: - Tests

    func testInitialStateIsDefault() {
        let sut = PreviewViewModel()

        XCTAssertNil(sut.state.selectedFileURL)
        XCTAssertNil(sut.state.selectedFileDateModified)
        XCTAssertNil(sut.state.currentDirectoryURL)
        XCTAssertTrue(sut.state.siblingMediaURLs.isEmpty)
    }

    func testUpdateContextSetsSelectedFileURL() {
        let sut = PreviewViewModel()
        let file = makeFileItem(name: "photo.txt")
        let directoryURL = URL(fileURLWithPath: "/tmp/test")

        sut.updateContext(
            selectedItem: file,
            currentDirectoryURL: directoryURL,
            displayedItems: [file]
        )

        XCTAssertEqual(sut.state.selectedFileURL, file.url)
        XCTAssertEqual(sut.state.selectedFileDateModified, file.dateModified)
        XCTAssertEqual(sut.state.currentDirectoryURL, directoryURL)
    }

    func testUpdateContextClearsURLForDirectory() {
        let sut = PreviewViewModel()
        let directory = makeFileItem(name: "Folder", isDirectory: true, isPackage: false)
        let directoryURL = URL(fileURLWithPath: "/tmp/test")

        sut.updateContext(
            selectedItem: directory,
            currentDirectoryURL: directoryURL,
            displayedItems: [directory]
        )

        XCTAssertNil(sut.state.selectedFileURL)
    }

    func testUpdateContextKeepsURLForPackage() {
        let sut = PreviewViewModel()
        let pkg = makeFileItem(name: "App.app", isDirectory: true, isPackage: true)
        let directoryURL = URL(fileURLWithPath: "/tmp/test")

        sut.updateContext(
            selectedItem: pkg,
            currentDirectoryURL: directoryURL,
            displayedItems: [pkg]
        )

        XCTAssertEqual(sut.state.selectedFileURL, pkg.url)
    }

    func testUpdateContextIncludesAudioFilesInSiblingMediaItems() {
        let sut = PreviewViewModel()
        let audio = makeFileItem(name: "theme.mp3")
        let image = makeFileItem(name: "cover.jpg")
        let text = makeFileItem(name: "notes.txt")
        let directoryURL = URL(fileURLWithPath: "/tmp/test")

        sut.updateContext(
            selectedItem: audio,
            currentDirectoryURL: directoryURL,
            displayedItems: [audio, image, text]
        )

        XCTAssertEqual(
            Set(sut.state.siblingMediaURLs.map(\.lastPathComponent)),
            Set(["cover.jpg", "theme.mp3"])
        )
    }

    func testSetSelectedFileURLUpdatesState() {
        let sut = PreviewViewModel()
        let url = URL(fileURLWithPath: "/tmp/test/file.txt")

        sut.setSelectedFileURL(url)

        XCTAssertEqual(sut.state.selectedFileURL, url)
    }

    func testOnStateChangedCallbackFires() {
        let sut = PreviewViewModel()
        var callbackCount = 0
        sut.onStateChanged = { _ in callbackCount += 1 }

        sut.setSelectedFileURL(URL(fileURLWithPath: "/tmp/test/file.txt"))

        XCTAssertEqual(callbackCount, 1)
    }

    func testUpdateSelectionRefreshesStateWhenSelectedFileTimestampChanges() {
        let sut = PreviewViewModel()
        let originalDate = Date(timeIntervalSinceReferenceDate: 100)
        let updatedDate = Date(timeIntervalSinceReferenceDate: 200)
        let original = FileItem(
            url: URL(fileURLWithPath: "/tmp/test/photo.jpg"),
            name: "photo.jpg",
            isDirectory: false,
            size: 1024,
            dateModified: originalDate,
            isHidden: false,
            isSymlink: false,
            isPackage: false
        )
        let updated = FileItem(
            url: original.url,
            name: original.name,
            isDirectory: false,
            size: 2048,
            dateModified: updatedDate,
            isHidden: false,
            isSymlink: false,
            isPackage: false
        )

        sut.updateContext(
            selectedItem: original,
            currentDirectoryURL: URL(fileURLWithPath: "/tmp/test"),
            displayedItems: [original]
        )
        sut.updateSelection(selectedItem: updated)

        XCTAssertEqual(sut.state.selectedFileURL, original.url)
        XCTAssertEqual(sut.state.selectedFileDateModified, updatedDate)
    }
}
