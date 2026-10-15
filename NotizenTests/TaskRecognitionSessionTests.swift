import CoreGraphics
import XCTest

@testable import Notizen

@MainActor
final class TaskRecognitionSessionTests: XCTestCase {
    func testJitteredBoxKeepsIdentityAndManualCorrection() {
        let previous = task(bounds: CGRect(x: 40, y: 40, width: 36, height: 36), correctedText: "Call Alex")
        let candidate = proposal(bounds: CGRect(x: 42, y: 39, width: 35, height: 37))

        let merged = TaskRecognitionSession.merge([candidate], with: [previous])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, previous.id)
        XCTAssertEqual(merged[0].correctedText, "Call Alex")
        XCTAssertEqual(merged[0].bounds, candidate.bounds)
    }

    func testFarAndAdjacentNonOverlappingBoxesReceiveNewIdentityWithoutCorrection() {
        let previous = task(bounds: CGRect(x: 40, y: 40, width: 36, height: 36), correctedText: "Keep this correction")
        let far = proposal(bounds: CGRect(x: 180, y: 180, width: 36, height: 36))
        let adjacent = proposal(bounds: CGRect(x: 78, y: 40, width: 36, height: 36))

        let merged = TaskRecognitionSession.merge([far, adjacent], with: [previous])

        XCTAssertEqual(merged.count, 2)
        for result in merged {
            XCTAssertNotEqual(result.id, previous.id)
            XCTAssertNil(result.correctedText)
        }
    }

    func testOnePreviousTaskCannotBeAssignedToTwoCandidates() {
        let previous = task(bounds: CGRect(x: 40, y: 40, width: 36, height: 36), correctedText: "Corrected")
        let first = proposal(bounds: CGRect(x: 40, y: 40, width: 36, height: 36))
        let competing = proposal(bounds: CGRect(x: 43, y: 40, width: 36, height: 36))

        let merged = TaskRecognitionSession.merge([first, competing], with: [previous])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
        XCTAssertEqual(merged.filter { $0.id == previous.id }.count, 1)
        XCTAssertEqual(merged.filter { $0.correctedText == "Corrected" }.count, 1)
    }

    func testBoxesMissingFromRecognitionAreRemoved() {
        let retained = task(bounds: CGRect(x: 40, y: 40, width: 36, height: 36), correctedText: "Retained")
        let missing = task(bounds: CGRect(x: 140, y: 140, width: 36, height: 36), correctedText: "Removed")
        let candidate = proposal(bounds: CGRect(x: 41, y: 40, width: 36, height: 36))

        let merged = TaskRecognitionSession.merge([candidate], with: [retained, missing])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, retained.id)
        XCTAssertFalse(merged.contains { $0.id == missing.id })
    }

    private func task(bounds: CGRect, correctedText: String?) -> RecognizedTask {
        RecognizedTask(
            id: UUID(),
            bounds: bounds,
            recognizedText: "Original",
            correctedText: correctedText,
            confidence: 0.9,
            isChecked: false
        )
    }

    private func proposal(bounds: CGRect) -> TaskCandidate {
        TaskCandidate(bounds: bounds, text: "Recognized", confidence: 0.9, isChecked: false)
    }
}
