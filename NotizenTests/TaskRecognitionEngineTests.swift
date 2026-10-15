import PencilKit
import UIKit
import XCTest

@testable import Notizen

final class TaskRecognitionEngineTests: XCTestCase {
    func testRecognizesCheckboxDrawnWithMouseInSimulator() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SimulatorCheckbox", withExtension: "json"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let data = try XCTUnwrap(Data(base64Encoded: fixture["drawing"] ?? ""))
        let candidates = try await TaskRecognitionEngine().recognize(drawingData: data)
        XCTAssertEqual(candidates.count, 1)
    }

    func testRecognizesBlockHandwritingToRightOfCheckbox() async throws {
        // Deliberately simple stroke-based lettering exercises the real render/OCR pipeline.
        let paths: [[CGPoint]] = [
            [point(40, 40), point(75, 40), point(75, 75), point(40, 75), point(40, 40)],
            [point(105, 40), point(133, 40)], [point(119, 40), point(119, 75)],
            [point(168, 40), point(144, 40), point(144, 75), point(168, 75)],
            [point(144, 57), point(164, 57)],
            [point(204, 42), point(182, 40), point(177, 47), point(182, 55),
             point(199, 60), point(204, 68), point(198, 75), point(177, 73)],
            [point(214, 40), point(242, 40)], [point(228, 40), point(228, 75)]
        ]
        let drawing = PKDrawing(strokes: paths.map(polyline))
        let candidates = try await TaskRecognitionEngine().recognize(drawingData: drawing.dataRepresentation())
        let candidate = try XCTUnwrap(candidates.first { $0.bounds.minX < 80 })
        XCTAssertFalse(candidate.text.isEmpty, "Vision should read the simple TEST lettering")
    }

    func testRecognizesSingleClosedSquareWithoutText() async throws {
        let drawing = PKDrawing(strokes: [polyline([point(40, 40), point(75, 40), point(75, 75), point(40, 75), point(40, 40)])])

        let candidates = try await TaskRecognitionEngine().recognize(drawingData: drawing.dataRepresentation())

        let candidate = try XCTUnwrap(candidates.only)
        XCTAssertTrue(candidate.bounds.insetBy(dx: -8, dy: -8).contains(CGPoint(x: 57.5, y: 57.5)))
        XCTAssertEqual(candidate.bounds.width, 35, accuracy: 12)
        XCTAssertEqual(candidate.bounds.height, 35, accuracy: 12)
        XCTAssertEqual(candidate.text, "")
        XCTAssertFalse(candidate.isChecked)
    }

    func testRecognizesSquareMadeFromFourSeparateSides() async throws {
        let drawing = PKDrawing(strokes: [
            line(from: point(40, 40), to: point(75, 40)),
            line(from: point(75, 40), to: point(75, 75)),
            line(from: point(75, 75), to: point(40, 75)),
            line(from: point(40, 75), to: point(40, 40))
        ])

        let candidates = try await TaskRecognitionEngine().recognize(drawingData: drawing.dataRepresentation())

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(try XCTUnwrap(candidates.first).text, "")
    }

    func testOpenUAndCircleDoNotProduceCheckboxCandidates() async throws {
        let openU = PKDrawing(strokes: [polyline([point(40, 40), point(40, 75), point(75, 75), point(75, 40)])])
        let circle = PKDrawing(strokes: [polyline([
            point(75, 57), point(70, 45), point(57, 40), point(45, 45), point(40, 57),
            point(45, 70), point(57, 75), point(70, 70), point(75, 57)
        ])])
        let engine = TaskRecognitionEngine()

        let openUCandidates = try await engine.recognize(drawingData: openU.dataRepresentation())
        let circleCandidates = try await engine.recognize(drawingData: circle.dataRepresentation())
        XCTAssertTrue(openUCandidates.isEmpty)
        XCTAssertTrue(circleCandidates.isEmpty)
    }

    func testRecognizesTwoWellSeparatedSquares() async throws {
        let drawing = PKDrawing(strokes: [
            polyline([point(30, 30), point(65, 30), point(65, 65), point(30, 65), point(30, 30)]),
            polyline([point(150, 150), point(185, 150), point(185, 185), point(150, 185), point(150, 150)])
        ])

        let candidates = try await TaskRecognitionEngine().recognize(drawingData: drawing.dataRepresentation())

        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.contains { $0.bounds.insetBy(dx: -8, dy: -8).contains(CGPoint(x: 47.5, y: 47.5)) })
        XCTAssertTrue(candidates.contains { $0.bounds.insetBy(dx: -8, dy: -8).contains(CGPoint(x: 167.5, y: 167.5)) })
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y)
    }

    private func line(from start: CGPoint, to end: CGPoint) -> PKStroke {
        polyline([start, end])
    }

    private func polyline(_ locations: [CGPoint]) -> PKStroke {
        // PencilKit interpolates control points as a B-spline. Sample the pen movement
        // along each edge, as real touch input does, instead of rendering five corners
        // as a rounded loop with almost no straight edge left.
        var samples: [CGPoint] = []
        for (start, end) in zip(locations, locations.dropFirst()) {
            let steps = max(1, Int(ceil(hypot(end.x - start.x, end.y - start.y) / 3)))
            for step in 0..<steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                samples.append(CGPoint(x: start.x + (end.x - start.x) * fraction,
                                       y: start.y + (end.y - start.y) * fraction))
            }
        }
        if let last = locations.last { samples.append(last) }
        let controlPoints = samples.enumerated().map { index, location in
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
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSinceReferenceDate: 0))
        )
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
