import PDFKit
import UIKit
import XCTest

@testable import Notizen

@MainActor
final class ObsidianExportContentTests: XCTestCase {
    func testMakeBuildsMultipagePDFAndSearchableMarkdown() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let noteID = UUID(uuidString: "A1B2C3D4-1111-2222-3333-1234567890AB")!
        let note = Note(id: noteID, createdAt: createdAt, updatedAt: createdAt)
        let pages = [printedPage("OBSIDIAN EXPORT"), printedPage("SECOND PAGE")]

        let output = try await ObsidianExportContent.make(
            note: note,
            customerName: "Kunde Beispiel",
            pages: pages
        )

        XCTAssertEqual(
            output.baseName,
            "Notiz-2027-01-15-080000-a1b2c3d4-1111-2222-3333-1234567890ab"
        )
        XCTAssertEqual(PDFDocument(data: output.pdfData)?.pageCount, 2)
        XCTAssertTrue(output.markdown.contains("![[\(output.baseName).pdf]]"))
        XCTAssertTrue(output.markdown.contains("customer: 'Kunde Beispiel'"))
        XCTAssertTrue(output.markdown.contains("### Seite 1"))
        XCTAssertTrue(output.markdown.contains("### Seite 2"))
        XCTAssertTrue(output.markdown.localizedCaseInsensitiveContains("OBSIDIAN EXPORT"))
    }

    func testMakeRejectsNotesWithoutPages() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let note = Note(id: UUID(), createdAt: date, updatedAt: date)

        do {
            _ = try await ObsidianExportContent.make(note: note, customerName: nil, pages: [])
            XCTFail("Expected an empty page list to be rejected")
        } catch let error as ObsidianExportContent.ExportError {
            guard case .noPages = error else {
                return XCTFail("Unexpected export error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExportFoldersUseISOWeekYearAndCreationDate() {
        let decemberMonday = ISO8601DateFormatter().date(from: "2024-12-30T12:00:00Z")!
        let januaryFriday = ISO8601DateFormatter().date(from: "2021-01-01T12:00:00Z")!

        XCTAssertEqual(
            ObsidianExportService.relativeFolder(for: decemberMonday, customerName: "Kunde Beispiel"),
            "Kunde Beispiel/2025/KW 01"
        )
        XCTAssertEqual(
            ObsidianExportService.relativeFolder(for: januaryFriday, customerName: nil),
            "2020/KW 53"
        )
    }

    func testExportFolderSanitizesCustomerAndOmitsItForUnassignedNotes() {
        let date = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
        XCTAssertEqual(
            ObsidianExportService.relativeFolder(for: date, customerName: "Firma / Berlin"),
            "Firma - Berlin/2026/KW 39"
        )
        XCTAssertEqual(
            ObsidianExportService.relativeFolder(for: date, customerName: nil),
            "2026/KW 39"
        )
    }

    private func printedPage(_ text: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: NotePagePresentation.pageSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: NotePagePresentation.pageSize))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            text.draw(at: CGPoint(x: 32, y: 120), withAttributes: attributes)
        }
    }
}
