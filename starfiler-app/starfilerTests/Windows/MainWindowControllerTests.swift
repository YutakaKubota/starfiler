import XCTest
@testable import Starfiler

final class MainWindowControllerTests: XCTestCase {

    func testConstrainedWindowFrameClampsHorizontalOverflowToVisibleFrame() {
        let frame = NSRect(x: -80, y: 40, width: 1680, height: 900)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let constrained = MainWindowController.constrainedWindowFrame(frame, within: visibleFrame)

        XCTAssertEqual(constrained, visibleFrame)
    }

    func testConstrainedWindowFramePreservesFrameAlreadyInsideVisibleFrame() {
        let frame = NSRect(x: 120, y: 60, width: 1100, height: 720)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let constrained = MainWindowController.constrainedWindowFrame(frame, within: visibleFrame)

        XCTAssertEqual(constrained, frame)
    }
}
