import PencilKit
import UIKit
import XCTest

@testable import Notizen

final class RecognitionSnapshotTests: XCTestCase {
    func testTextAdditionAndDeletionInvalidateOnlyNearbyCandidate() async {
        let upper = candidate(at: 50)
        let lower = candidate(at: 500)
        let upperStroke = line(y: 55)
        let lowerStroke = line(y: 505)
        let old = PKDrawing(strokes: [upperStroke, lowerStroke])
        let added = PKDrawing(strokes: [upperStroke, lowerStroke, line(y: 80)])
        let deleted = PKDrawing(strokes: [lowerStroke])

        let afterAddition = await TaskRecognitionSnapshot.unchangedCandidates(
            [upper, lower], from: old.dataRepresentation(), to: added.dataRepresentation()
        )
        let afterDeletion = await TaskRecognitionSnapshot.unchangedCandidates(
            [upper, lower], from: old.dataRepresentation(), to: deleted.dataRepresentation()
        )

        XCTAssertEqual(afterAddition.map(\.bounds.midY), [lower.bounds.midY])
        XCTAssertEqual(afterDeletion.map(\.bounds.midY), [lower.bounds.midY])
    }

    func testMovedAndMaskedStrokeInvalidateCandidate() async {
        let upper = candidate(at: 50)
        let lower = candidate(at: 500)
        let original = line(y: 55)
        var moved = original
        moved.transform = CGAffineTransform(translationX: 0, y: 15)
        var masked = original
        masked.mask = UIBezierPath(rect: CGRect(x: 100, y: 52, width: 15, height: 10))
        let lowerStroke = line(y: 505)
        let old = PKDrawing(strokes: [original, lowerStroke])

        for changed in [moved, masked] {
            let current = PKDrawing(strokes: [changed, lowerStroke])
            let result = await TaskRecognitionSnapshot.unchangedCandidates(
                [upper, lower], from: old.dataRepresentation(), to: current.dataRepresentation()
            )
            XCTAssertEqual(result.map(\.bounds.midY), [lower.bounds.midY])
        }
    }

    func testInvalidDrawingRetainsNothing() async {
        let valid = PKDrawing(strokes: [line(y: 55)]).dataRepresentation()
        let result = await TaskRecognitionSnapshot.unchangedCandidates(
            [candidate(at: 50)], from: valid, to: Data("invalid".utf8)
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testNearbyCheckboxCanChangeCropBoundary() async {
        let upper = candidate(at: 50)
        let lower = candidate(at: 500)
        let upperStroke = line(y: 55)
        let lowerStroke = line(y: 505)
        let old = PKDrawing(strokes: [upperStroke, lowerStroke])
        // This checkbox is beyond the text image itself, but can move the midpoint
        // that bounds the upper row's OCR crop.
        let nearbyBox = line(y: 200)
        let changed = PKDrawing(strokes: [upperStroke, nearbyBox, lowerStroke])

        let result = await TaskRecognitionSnapshot.unchangedCandidates(
            [upper, lower], from: old.dataRepresentation(), to: changed.dataRepresentation()
        )
        XCTAssertEqual(result.map(\.bounds.midY), [lower.bounds.midY])
    }

    func testSamePositionStrokePointChangeInvalidatesCandidate() async {
        let candidate = candidate(at: 50)
        let old = PKDrawing(strokes: [line(y: 55)])
        let changed = PKDrawing(strokes: [line(y: 55, opacity: 0.5)])
        let result = await TaskRecognitionSnapshot.unchangedCandidates(
            [candidate], from: old.dataRepresentation(), to: changed.dataRepresentation()
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testOCRCacheUsesExactCropAndVisibleDrawingAndReplacesPriorPass() {
        let crop = CGRect(x: 80, y: 20, width: 400, height: 80)
        let upperStroke = line(y: 55)
        let original = PKDrawing(strokes: [upperStroke])
        let distant = PKDrawing(strokes: [upperStroke, line(y: 505)])
        let changed = PKDrawing(strokes: [upperStroke, line(y: 75)])
        let subset = RecognitionOCRCache.visibleDrawing(in: crop, from: original)
        var cache = RecognitionOCRCache()
        cache.replace(with: [.init(crop: crop, subset: subset, value: ("Milk", 0.8))])

        XCTAssertEqual(cache.value(for: crop, subset: RecognitionOCRCache.visibleDrawing(in: crop, from: distant))?.text, "Milk")
        let roundTripped = try? PKDrawing(data: original.dataRepresentation())
        XCTAssertEqual(roundTripped.flatMap {
            cache.value(for: crop, subset: RecognitionOCRCache.visibleDrawing(in: crop, from: $0))?.text
        }, "Milk")
        XCTAssertNil(cache.value(for: crop.offsetBy(dx: 0, dy: 1), subset: subset))
        XCTAssertNil(cache.value(for: crop, subset: RecognitionOCRCache.visibleDrawing(in: crop, from: changed)))
        XCTAssertNil(cache.value(for: crop, subset: RecognitionOCRCache.visibleDrawing(
            in: crop, from: PKDrawing(strokes: [line(y: 55, opacity: 0.5)])
        )))
        var moved = upperStroke
        moved.transform = CGAffineTransform(translationX: 0, y: 10)
        XCTAssertNil(cache.value(for: crop, subset: RecognitionOCRCache.visibleDrawing(in: crop, from: PKDrawing(strokes: [moved]))))
        var masked = upperStroke
        masked.mask = UIBezierPath(rect: CGRect(x: 100, y: 52, width: 15, height: 10))
        XCTAssertNil(cache.value(for: crop, subset: RecognitionOCRCache.visibleDrawing(in: crop, from: PKDrawing(strokes: [masked]))))
        cache.replace(with: [])
        XCTAssertNil(cache.value(for: crop, subset: subset))
    }

    private func candidate(at y: CGFloat) -> TaskCandidate {
        TaskCandidate(bounds: CGRect(x: 30, y: y - 15, width: 30, height: 30),
                      text: "Task", confidence: 0.8, isChecked: false)
    }

    private func line(y: CGFloat, opacity: CGFloat = 1) -> PKStroke {
        let points = [CGPoint(x: 100, y: y), CGPoint(x: 160, y: y)]
            .enumerated().map { index, location in
                PKStrokePoint(location: location, timeOffset: TimeInterval(index),
                              size: CGSize(width: 4, height: 4), opacity: opacity, force: 1,
                              azimuth: 0, altitude: .pi / 2)
            }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: .distantPast))
    }
}
