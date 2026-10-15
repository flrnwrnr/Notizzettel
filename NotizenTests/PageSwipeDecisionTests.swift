import CoreGraphics
import XCTest

@testable import Notizen

final class PageSwipeDecisionTests: XCTestCase {
    func testHorizontalSwipeNeedsDistanceAndDominance() {
        XCTAssertEqual(
            PageSwipeDecision.destinationIndex(
                translation: CGSize(width: -80, height: 15), currentIndex: 2, pageCount: 5
            ), 3
        )
        XCTAssertEqual(
            PageSwipeDecision.destinationIndex(
                translation: CGSize(width: 80, height: -15), currentIndex: 2, pageCount: 5
            ), 1
        )
        XCTAssertNil(PageSwipeDecision.destinationIndex(
            translation: CGSize(width: -54, height: 0), currentIndex: 2, pageCount: 5
        ))
        XCTAssertNil(PageSwipeDecision.destinationIndex(
            translation: CGSize(width: -80, height: 70), currentIndex: 2, pageCount: 5
        ))
    }

    func testSwipeStopsAtFirstAndLastPage() {
        XCTAssertNil(PageSwipeDecision.destinationIndex(
            translation: CGSize(width: 100, height: 0), currentIndex: 0, pageCount: 5
        ))
        XCTAssertNil(PageSwipeDecision.destinationIndex(
            translation: CGSize(width: -100, height: 0), currentIndex: 4, pageCount: 5
        ))
    }

    func testCanvasPagingOnlyForSingleFingerAtInitialZoom() {
        XCTAssertTrue(PageSwipeDecision.canvasAllowsPaging(
            allowsFingerDrawing: false, zoomedAtStart: false, hadMultipleTouches: false
        ))
        XCTAssertFalse(PageSwipeDecision.canvasAllowsPaging(
            allowsFingerDrawing: true, zoomedAtStart: false, hadMultipleTouches: false
        ))
        XCTAssertFalse(PageSwipeDecision.canvasAllowsPaging(
            allowsFingerDrawing: false, zoomedAtStart: true, hadMultipleTouches: false
        ))
        XCTAssertFalse(PageSwipeDecision.canvasAllowsPaging(
            allowsFingerDrawing: false, zoomedAtStart: false, hadMultipleTouches: true
        ))
    }
}
