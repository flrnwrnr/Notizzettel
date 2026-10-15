import PencilKit
import UIKit
import XCTest

@testable import Notizen

@MainActor
final class NotePagePresentationTests: XCTestCase {
    private let fileManager = FileManager.default
    private var storageURL: URL!

    override func setUpWithError() throws {
        storageURL = fileManager.temporaryDirectory
            .appendingPathComponent("NotePagePresentationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
    }

    func testHeaderAppearsOnlyForFirstPageWithSavedEvent() {
        let firstPageID = UUID()
        let secondPageID = UUID()
        let noteWithoutEvent = Note(
            id: UUID(),
            createdAt: .now,
            updatedAt: .now,
            pageIDs: [firstPageID, secondPageID]
        )

        XCTAssertNil(NotePagePresentation.header(for: noteWithoutEvent, pageID: firstPageID))

        var noteWithEvent = noteWithoutEvent
        noteWithEvent.calendarEvent = makeEvent(title: "Planung", date: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(
            NotePagePresentation.header(for: noteWithEvent, pageID: firstPageID)?.title,
            "Planung"
        )
        XCTAssertNil(NotePagePresentation.header(for: noteWithEvent, pageID: secondPageID))
    }

    func testReassigningEventChangesDisplayedThumbnailWithoutChangingRawCacheOrDrawing() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let firstEvent = makeEvent(title: "Erster Termin", date: Date(timeIntervalSince1970: 1_800_000_000))
        let note = try XCTUnwrap(store.createNote(event: firstEvent))
        let drawing = makeDrawing()
        store.saveDrawing(drawing, for: note.id)

        let rawThumbnailURL = storageURL.appendingPathComponent("Thumbnails/\(note.id.uuidString).png")
        let rawBefore = try Data(contentsOf: rawThumbnailURL)
        let drawingBefore = store.drawing(for: note.id).dataRepresentation()
        let firstDisplayedThumbnail = try XCTUnwrap(store.thumbnail(for: note.id)?.pngData())

        let secondEvent = makeEvent(title: "Anderer Termin", date: Date(timeIntervalSince1970: 1_900_000_000))
        store.assignCustomer(nil, event: secondEvent, to: note.id)
        let secondDisplayedThumbnail = try XCTUnwrap(store.thumbnail(for: note.id)?.pngData())

        XCTAssertNotEqual(firstDisplayedThumbnail, secondDisplayedThumbnail)
        XCTAssertEqual(try Data(contentsOf: rawThumbnailURL), rawBefore)
        XCTAssertEqual(store.drawing(for: note.id).dataRepresentation(), drawingBefore)
    }

    func testCompositePlacesRawDrawingOverEntirePage() throws {
        let rawImage = drawingImage(color: .systemRed)
        let presentation = NotePagePresentation(
            title: "Termin",
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let composite = presentation.composite(rawDrawingImage: rawImage)

        let bodyColor = try rgba(of: color(at: CGPoint(x: 300, y: 40), in: composite))
        XCTAssertGreaterThan(bodyColor.red, 0.9)
        XCTAssertLessThan(bodyColor.green, 0.4)
        XCTAssertLessThan(bodyColor.blue, 0.4)

        let edgeColor = try rgba(of: color(at: CGPoint(x: 1, y: 75), in: composite))
        XCTAssertGreaterThan(edgeColor.red, 0.9)
        XCTAssertLessThan(edgeColor.green, 0.4)
        XCTAssertLessThan(edgeColor.blue, 0.4)
        XCTAssertTrue(try imageContainsDarkPixel(composite, in: CGRect(x: 24, y: 12, width: 100, height: 72)))
    }

    func testPageIsPortraitA4AndRuledBackgroundIsRendered() throws {
        XCTAssertEqual(
            NotePagePresentation.pageSize.height / NotePagePresentation.pageSize.width,
            297.0 / 210.0,
            accuracy: 0.0001
        )
        let ruled = NotePagePresentation.backgroundImage(background: .ruled)
        let plain = NotePagePresentation.backgroundImage(background: .plain)
        XCTAssertNotEqual(try ruled.pngData(), plain.pngData())
        let ruledColor = try rgba(of: color(at: CGPoint(x: 300, y: 112), in: ruled))
        XCTAssertLessThan(ruledColor.blue, 0.99)
    }

    func testHighResolutionPageKeepsLogicalDrawingCoordinates() throws {
        let scale: CGFloat = 2
        let presentation = NotePagePresentation(
            title: "Termin",
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let background = NotePagePresentation.backgroundImage(
            background: .ruled, header: presentation, scale: scale
        )
        XCTAssertEqual(background.size.width, NotePagePresentation.pageSize.width)
        XCTAssertEqual(background.cgImage?.width, Int(NotePagePresentation.pageSize.width * scale))

        let drawing = makeDrawing().image(
            from: CGRect(origin: .zero, size: NotePagePresentation.pageSize), scale: scale
        )
        let composite = NotePagePresentation.composite(
            rawDrawingImage: drawing, background: .ruled, header: presentation, scale: scale
        )
        XCTAssertEqual(composite.size.width, NotePagePresentation.pageSize.width)
        XCTAssertEqual(
            composite.size.height, NotePagePresentation.pageSize.height,
            accuracy: 1 / scale
        )
        XCTAssertEqual(composite.cgImage?.width, background.cgImage?.width)
    }

    func testHeaderUsesDarkTextEvenWhenRenderedWithDarkTraits() throws {
        let presentation = NotePagePresentation(
            title: "Termin",
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            image = presentation.headerImage()
        }

        XCTAssertTrue(try imageContainsDarkPixel(image, in: CGRect(x: 24, y: 12, width: 368, height: 72)))
    }

    private func makeEvent(title: String, date: Date) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: UUID().uuidString,
            eventIdentifier: nil,
            calendarIdentifier: "calendar",
            calendarTitle: "Kalender",
            title: title,
            startDate: date,
            endDate: date.addingTimeInterval(3_600),
            isAllDay: false
        )
    }

    private func makeDrawing() -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 30, y: 30), timeOffset: 0,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 120, y: 100), timeOffset: 0.1,
                size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2
            )
        ]
        return PKDrawing(strokes: [
            PKStroke(
                ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: points, creationDate: Date())
            )
        ])
    }

    private func drawingImage(color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: NotePagePresentation.pageSize, format: format).image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 290, y: 30, width: 20, height: 20))
            context.cgContext.fill(CGRect(x: 0, y: 70, width: 20, height: 20))
        }
    }

    private func color(at point: CGPoint, in image: UIImage) throws -> UIColor {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileReadCorruptFile) }
        context.translateBy(x: -point.x, y: point.y - CGFloat(cgImage.height) + 1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return UIColor(
            red: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255,
            alpha: CGFloat(bytes[3]) / 255
        )
    }

    private func imageContainsDarkPixel(_ image: UIImage, in rect: CGRect) throws -> Bool {
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) {
                var white: CGFloat = 0
                var alpha: CGFloat = 0
                try color(at: CGPoint(x: x, y: y), in: image).getWhite(&white, alpha: &alpha)
                if alpha > 0.9, white < 0.25 { return true }
            }
        }
        return false
    }

    private func rgba(of color: UIColor) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (red, green, blue, alpha)
    }
}
