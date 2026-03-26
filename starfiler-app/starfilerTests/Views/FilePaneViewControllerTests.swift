import XCTest
@testable import Starfiler

final class FilePaneViewControllerTests: XCTestCase {

    func testBrowserColumnWidthsStayWithinAvailablePaneWidth() {
        let availableWidth = CGFloat(410)
        let spacing = CGFloat(8)

        let widths = FilePaneViewController.browserColumnWidths(
            availableWidth: availableWidth,
            intercellSpacing: spacing
        )

        XCTAssertLessThanOrEqual(widths.name + widths.size + widths.modified + (spacing * 2), availableWidth + 0.5)
        XCTAssertGreaterThanOrEqual(widths.name, widths.size)
        XCTAssertGreaterThanOrEqual(widths.name, widths.modified)
    }

    func testBrowserColumnWidthsGiveExtraSpaceToNameColumnWhenWide() {
        let availableWidth = CGFloat(900)
        let spacing = CGFloat(8)

        let widths = FilePaneViewController.browserColumnWidths(
            availableWidth: availableWidth,
            intercellSpacing: spacing
        )

        XCTAssertEqual(widths.size, 120, accuracy: 0.5)
        XCTAssertEqual(widths.modified, 180, accuracy: 0.5)
        XCTAssertEqual(widths.name + widths.size + widths.modified + (spacing * 2), availableWidth, accuracy: 0.5)
    }
}
