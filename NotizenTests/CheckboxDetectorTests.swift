import PencilKit
import UIKit
import XCTest

@testable import Notizen

final class CheckboxDetectorTests: XCTestCase {
    func testIrregularClosedRectangleIsDetected() throws {
        let rectangle = [
            point(20, 22), point(35, 20), point(54, 23),
            point(56, 40), point(53, 57), point(35, 55),
            point(19, 57), point(21, 39), point(20, 22)
        ]

        let detections = CheckboxDetector.detect(in: [rectangle])

        let detection = try XCTUnwrap(detections.first)
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detection.bounds.width, 37, accuracy: 2)
        XCTAssertEqual(detection.bounds.height, 37, accuracy: 2)
    }

    func testFourSeparateSidesAreDetectedAsOneBox() {
        let strokes = [
            [point(20, 20), point(55, 20)],
            [point(55, 20), point(55, 55)],
            [point(55, 55), point(20, 55)],
            [point(20, 55), point(20, 20)]
        ]

        let detections = CheckboxDetector.detect(in: strokes)

        XCTAssertEqual(detections.count, 1)
    }

    func testCircleOpenUAndLetterLikeStrokesAreRejected() {
        let circle = [
            point(55, 37), point(51, 26), point(38, 20), point(26, 25),
            point(20, 37), point(25, 50), point(38, 55), point(50, 50), point(55, 37)
        ]
        let openU = [point(80, 20), point(80, 55), point(115, 55), point(115, 20)]
        let letterA = [point(140, 55), point(157, 20), point(175, 55), point(148, 42), point(168, 42)]

        XCTAssertTrue(CheckboxDetector.detect(in: [circle, openU, letterA]).isEmpty)
    }

    func testCrossingStrokeAloneDoesNotMarkBoxChecked() throws {
        let rectangle = [
            point(20, 20), point(55, 20), point(55, 55), point(20, 55), point(20, 20)
        ]
        let crossingLine = [point(10, 37), point(65, 37)]
        let strokes = [rectangle, crossingLine]
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: strokes).first)
        let geometry = strokes.enumerated().map {
            CheckboxGeometryStroke(points: $0.element, sourceIndex: $0.offset)
        }

        XCTAssertFalse(CheckboxDetector.isChecked(detection, among: geometry))
    }

    func testCompleteTickMarksBoxChecked() throws {
        let rectangle = [
            point(20, 20), point(55, 20), point(55, 55), point(20, 55), point(20, 20)
        ]
        let tick = [point(25, 38), point(35, 48), point(51, 27)]
        let strokes = [rectangle, tick]
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: strokes).first)
        let geometry = strokes.enumerated().map {
            CheckboxGeometryStroke(points: $0.element, sourceIndex: $0.offset)
        }

        XCTAssertTrue(CheckboxDetector.isChecked(detection, among: geometry))
    }

    func testNaturalTickMayProtrudeBeyondARealPhoneSizedBox() throws {
        let rectangle = largeRectangle
        let tick = [point(10, 52), point(48, 76), point(101, 10)]
        let strokes = [rectangle, tick]
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: strokes).first)

        XCTAssertTrue(CheckboxDetector.isChecked(detection, among: geometry(strokes)))
    }

    func testReversedTickDirectionMarksBoxChecked() throws {
        let rectangle = largeRectangle
        let tick = [point(101, 10), point(48, 76), point(10, 52)]
        let strokes = [rectangle, tick]
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: strokes).first)

        XCTAssertTrue(CheckboxDetector.isChecked(detection, among: geometry(strokes)))
    }

    func testSmallProportionalTickMarksLargeBoxChecked() throws {
        let rectangle = largeRectangle
        let tick = [point(37, 49), point(47, 60), point(68, 37)]
        let strokes = [rectangle, tick]
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: strokes).first)

        XCTAssertTrue(CheckboxDetector.isChecked(detection, among: geometry(strokes)))
    }

    func testTickDrawnAfterBoxWithoutLiftingMarksBoxChecked() throws {
        let combinedStroke = largeRectangle + [
            point(30, 50), point(48, 70), point(78, 34)
        ]
        let geometry = [CheckboxGeometryStroke(points: combinedStroke, sourceIndex: 0)]
        let detection = try XCTUnwrap(CheckboxDetector.detect(
            strokes: geometry,
            pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800),
            limit: 30
        ).first)

        XCTAssertTrue(CheckboxDetector.isChecked(detection, among: geometry))
    }

    func testTwoSeparatelyDrawnTickArmsMarkBoxChecked() throws {
        let rectangle = largeRectangle
        let strokes = [
            CheckboxGeometryStroke(points: rectangle, sourceIndex: 0),
            CheckboxGeometryStroke(points: [point(30, 48), point(47, 66)], sourceIndex: 1),
            CheckboxGeometryStroke(points: [point(48, 65), point(76, 32)], sourceIndex: 2)
        ]
        let detection = try XCTUnwrap(CheckboxDetector.detect(
            strokes: strokes,
            pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800),
            limit: 30
        ).first)

        XCTAssertTrue(CheckboxDetector.isChecked(detection, among: strokes))
    }

    func testAdjacentVShapeDoesNotMarkBoxChecked() throws {
        let rectangle = largeRectangle
        let adjacentV = [point(86, 35), point(108, 67), point(130, 32)]
        let strokes = [rectangle, adjacentV]
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: strokes).first)

        XCTAssertFalse(CheckboxDetector.isChecked(detection, among: geometry(strokes)))
    }

    func testPartiallyErasedTickDoesNotMarkBoxChecked() throws {
        let rectangle = largeRectangle
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: [rectangle]).first)
        let strokes = [
            CheckboxGeometryStroke(points: rectangle, sourceIndex: 0),
            // Visible pieces from one masked PencilKit stroke retain the same source index.
            CheckboxGeometryStroke(points: [point(30, 48), point(40, 58)], sourceIndex: 1),
            CheckboxGeometryStroke(points: [point(53, 56), point(76, 32)], sourceIndex: 1)
        ]

        XCTAssertFalse(CheckboxDetector.isChecked(detection, among: strokes))
    }

    func testEmptyBoundaryDoesNotCountAsCheckmark() throws {
        let rectangle = largeRectangle
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: [rectangle]).first)

        XCTAssertFalse(CheckboxDetector.isChecked(detection, among: geometry([rectangle])))
    }

    func testRealUncheckedPhoneDrawingChangesOnlyAfterAddingNaturalTick() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "PhoneUncheckedCheckbox", withExtension: "json")
        )
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let data = try XCTUnwrap(Data(base64Encoded: fixture["drawing"] ?? ""))
        let drawing = try PKDrawing(data: data)

        let uncheckedCandidates = try await TaskRecognitionEngine().recognize(drawingData: data)
        let unchecked = try XCTUnwrap(uncheckedCandidates.first { $0.bounds.minX < 140 })
        XCTAssertFalse(unchecked.isChecked)

        let tick = makeStroke([
            point(45, 82), point(78, 108), point(137, 41)
        ], mask: nil)
        let checkedDrawing = PKDrawing(strokes: drawing.strokes + [tick])
        let checkedCandidates = try await TaskRecognitionEngine().recognize(
            drawingData: checkedDrawing.dataRepresentation()
        )
        let checked = try XCTUnwrap(checkedCandidates.first { $0.bounds.minX < 140 })
        XCTAssertTrue(checked.isChecked)
    }

    func testRealPhoneTicksAreCheckedAndRemovingThemClearsBothBoxes() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "PhoneTwoCheckedBoxes", withExtension: "json")
        )
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let data = try XCTUnwrap(Data(base64Encoded: fixture["drawing"] ?? ""))

        let checkedCandidates = try await TaskRecognitionEngine().recognize(drawingData: data)
        XCTAssertEqual(checkedCandidates.count, 2)
        XCTAssertTrue(checkedCandidates.allSatisfy(\.isChecked))

        let drawing = try PKDrawing(data: data)
        let tickIndices: Set<Int> = [7, 17]
        let withoutTicks = PKDrawing(strokes: drawing.strokes.enumerated().compactMap { index, stroke in
            tickIndices.contains(index) ? nil : stroke
        })
        let uncheckedCandidates = try await TaskRecognitionEngine().recognize(
            drawingData: withoutTicks.dataRepresentation()
        )
        XCTAssertEqual(uncheckedCandidates.count, 2)
        XCTAssertTrue(uncheckedCandidates.allSatisfy { !$0.isChecked })
    }

    func testTwoCompleteDiagonalsMarkBoxChecked() throws {
        let rectangle = [
            point(20, 20), point(55, 20), point(55, 55), point(20, 55), point(20, 20)
        ]
        let strokes = [
            rectangle,
            [point(24, 24), point(51, 51)],
            [point(51, 24), point(24, 51)]
        ]
        let detection = try XCTUnwrap(CheckboxDetector.detect(in: strokes).first)
        let geometry = strokes.enumerated().map {
            CheckboxGeometryStroke(points: $0.element, sourceIndex: $0.offset)
        }

        XCTAssertTrue(CheckboxDetector.isChecked(detection, among: geometry))
    }

    func testClippedAwaySidesCannotCompleteRectangle() async throws {
        let points = [
            point(40, 40), point(75, 40), point(75, 75), point(40, 75), point(40, 40)
        ]
        let mask = UIBezierPath(rect: CGRect(x: 35, y: 35, width: 45, height: 20))
        let unmaskedDrawing = PKDrawing(strokes: [makeStroke(points, mask: nil)])
        let maskedDrawing = PKDrawing(strokes: [makeStroke(points, mask: mask)])

        let unmaskedCandidates = try await TaskRecognitionEngine().recognize(
            drawingData: unmaskedDrawing.dataRepresentation()
        )
        XCTAssertEqual(unmaskedCandidates.count, 1, "The fixture must be a detectable box before clipping")

        let candidates = try await TaskRecognitionEngine().recognize(
            drawingData: maskedDrawing.dataRepresentation()
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y)
    }

    private var largeRectangle: [CGPoint] {
        [point(20, 20), point(91, 20), point(91, 81), point(20, 81), point(20, 20)]
    }

    private func geometry(_ strokes: [[CGPoint]]) -> [CheckboxGeometryStroke] {
        strokes.enumerated().map {
            CheckboxGeometryStroke(points: $0.element, sourceIndex: $0.offset)
        }
    }

    private func makeStroke(_ locations: [CGPoint], mask: UIBezierPath?) -> PKStroke {
        var sampledLocations: [CGPoint] = []
        if let first = locations.first {
            sampledLocations.append(first)
        }
        for (start, end) in zip(locations, locations.dropFirst()) {
            let distance = hypot(end.x - start.x, end.y - start.y)
            let steps = max(1, Int(ceil(distance / 3)))
            for step in 1...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                sampledLocations.append(
                    CGPoint(
                        x: start.x + (end.x - start.x) * fraction,
                        y: start.y + (end.y - start.y) * fraction
                    )
                )
            }
        }

        let controlPoints = sampledLocations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.1,
                size: CGSize(width: 4, height: 4),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .label),
            path: PKStrokePath(
                controlPoints: controlPoints,
                creationDate: Date(timeIntervalSinceReferenceDate: 0)
            ),
            mask: mask
        )
    }
}
