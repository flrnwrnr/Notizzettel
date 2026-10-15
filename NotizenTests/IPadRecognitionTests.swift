import Foundation
import XCTest

@testable import Notizen

final class IPadRecognitionTests: XCTestCase {
    /// Real iPad regression page, captured before the live scheduling change.
    /// This checks existing detections survive; multiline accuracy is a separate change.
    func testRealIPadPageKeepsItsDetectionsAcrossRepeatedSnapshots() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "IPadTaskRecognition", withExtension: "json"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let data = try XCTUnwrap(Data(base64Encoded: fixture["drawing"] ?? ""))
        let engine = TaskRecognitionEngine()
        let clock = ContinuousClock()
        let firstStart = clock.now
        let first = try await engine.recognize(drawingData: data)
        let firstDuration = firstStart.duration(to: clock.now)
        let repeatStart = clock.now
        let repeated = try await engine.recognize(drawingData: data)
        let repeatDuration = repeatStart.duration(to: clock.now)

        XCTAssertEqual(first.count, 4)
        XCTAssertEqual(repeated.map(\.bounds), first.map(\.bounds))
        XCTAssertEqual(repeated.map(\.text), first.map(\.text))
        XCTAssertEqual(repeated.map(\.isChecked), first.map(\.isChecked))
        XCTAssertTrue(first.allSatisfy { !$0.text.isEmpty })
        print("iPad fixture recognition: first=\(firstDuration), repeated=\(repeatDuration), tasks=\(first.count)")
    }
}
