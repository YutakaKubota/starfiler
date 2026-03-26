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

    func testHeaderLayoutMetricsReduceBreadcrumbReservationOnNarrowPane() {
        let metrics = FilePaneViewController.headerLayoutMetrics(
            availableWidth: 360,
            nonSearchControlsWidth: 130
        )

        XCTAssertEqual(metrics.searchFieldMinimumWidth, 132, accuracy: 0.5)
        XCTAssertLessThan(metrics.breadcrumbReservation, 280)
        XCTAssertGreaterThan(metrics.breadcrumbReservation, 0)
    }

    func testHeaderLayoutMetricsShrinkSearchFieldBeforeClippingControls() {
        let metrics = FilePaneViewController.headerLayoutMetrics(
            availableWidth: 240,
            nonSearchControlsWidth: 130
        )

        XCTAssertLessThan(metrics.searchFieldMinimumWidth, 132)
        XCTAssertGreaterThanOrEqual(metrics.searchFieldMinimumWidth, 80)
        XCTAssertGreaterThanOrEqual(metrics.breadcrumbReservation, 0)
        XCTAssertLessThanOrEqual(
            metrics.breadcrumbReservation + metrics.searchFieldMinimumWidth + 130 + 8,
            240.5
        )
    }
}
