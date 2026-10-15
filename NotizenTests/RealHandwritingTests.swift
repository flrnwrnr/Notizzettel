import Foundation
import XCTest

@testable import Notizen

final class RealHandwritingTests: XCTestCase {
    func testRecognizesTwoRowsFromRealPhoneHandwriting() async throws {
        let candidates = try await recognizeFixture(named: "PhoneHandwriting")

        XCTAssertEqual(candidates.count, 2)
        guard candidates.count == 2 else { return }
        let first = try XCTUnwrap(candidates.first)
        let second = try XCTUnwrap(candidates.last)
        XCTAssertFalse(first.text.isEmpty, "Expected readable text for the Hallo row")
        XCTAssertFalse(second.text.isEmpty, "Expected readable text for the Hi row")
    }

    func testRecognizesTopTestRowFromRealPhoneCheckboxes() async throws {
        let candidates = try await recognizeFixture(named: "PhoneCheckboxes")

        let topCandidate = try XCTUnwrap(candidates.min { $0.bounds.midY < $1.bounds.midY })
        XCTAssertTrue(topCandidate.text.localizedCaseInsensitiveContains("Test"), topCandidate.text)
    }

    private func recognizeFixture(named name: String) async throws -> [TaskCandidate] {
        return try await TaskRecognitionEngine().recognize(drawingData: fixtureData(named: name))
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return try XCTUnwrap(Data(base64Encoded: fixture["drawing"] ?? ""))
    }
}
