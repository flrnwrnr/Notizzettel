import PencilKit
import UIKit
import XCTest

@testable import Notizen

@MainActor
final class NoteStorePagePersistenceTests: XCTestCase {
    private var storageURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        storageURL = fileManager.temporaryDirectory
            .appendingPathComponent("NoteStorePagePersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
    }

    func testLegacySinglePageMetadataMigratesToPageIDs() throws {
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let id = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        let legacyNote = LegacyNote(id: id, createdAt: createdAt, updatedAt: updatedAt)
        try JSONEncoder().encode([legacyNote]).write(to: metadataURL, options: .atomic)

        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)

        let migratedNote = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(migratedNote.id, id)
        XCTAssertEqual(migratedNote.pageIDs, [id])

        // The migrated note remains writable through the existing page-based API.
        let drawing = makeDrawing(color: .systemPurple, end: CGPoint(x: 70, y: 35))
        store.saveDrawing(drawing, for: id)
        assertSameDrawingSemantics(store.drawing(for: id), as: drawing)
    }

    func testExplicitPageIDsRemainAuthoritativeWhenNoteIDIsNotAPage() throws {
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let noteID = UUID()
        let firstPageID = UUID()
        let secondPageID = UUID()
        let note = Note(
            id: noteID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            pageIDs: [firstPageID, secondPageID]
        )
        try JSONEncoder().encode([note]).write(to: metadataURL, options: .atomic)

        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)

        XCTAssertEqual(store.notes.first?.pageIDs, [firstPageID, secondPageID])
    }

    func testPageDrawingsAndTasksPersistIndependentlyAcrossReload() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let secondPageID = try XCTUnwrap(store.addPage(to: note.id))
        let firstDrawing = makeDrawing(color: .systemBlue, end: CGPoint(x: 40, y: 40))
        let secondDrawing = makeDrawing(color: .systemRed, end: CGPoint(x: 110, y: 85))
        let firstTask = makeTask(text: "First page")
        let secondTask = makeTask(text: "Second page")

        store.saveDrawing(firstDrawing, for: note.id)
        let firstPageThumbnail = try Data(contentsOf: thumbnailURL(for: note.id))
        let updatedAtBeforeSecondPageSave = try XCTUnwrap(
            store.notes.first(where: { $0.id == note.id })?.updatedAt
        )
        store.saveDrawing(secondDrawing, for: secondPageID)
        XCTAssertEqual(try Data(contentsOf: thumbnailURL(for: note.id)), firstPageThumbnail)
        XCTAssertGreaterThan(
            try XCTUnwrap(store.notes.first(where: { $0.id == note.id })?.updatedAt),
            updatedAtBeforeSecondPageSave
        )
        store.saveRecognizedTasks([firstTask], for: note.id)
        store.saveRecognizedTasks([secondTask], for: secondPageID)

        let reloadedStore = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let reloadedNote = try XCTUnwrap(reloadedStore.notes.first(where: { $0.id == note.id }))
        XCTAssertEqual(reloadedNote.pageIDs, [note.id, secondPageID])
        assertSameDrawingSemantics(reloadedStore.drawing(for: note.id), as: firstDrawing)
        assertSameDrawingSemantics(reloadedStore.drawing(for: secondPageID), as: secondDrawing)
        XCTAssertEqual(reloadedStore.recognizedTasks(for: note.id), [firstTask])
        XCTAssertEqual(reloadedStore.recognizedTasks(for: secondPageID), [secondTask])
    }

    func testMissingThumbnailIsRebuiltWithoutShowingAnError() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let drawing = makeDrawing(color: .systemBlue, end: CGPoint(x: 80, y: 60))
        store.saveDrawing(drawing, for: note.id)
        let url = thumbnailURL(for: note.id)
        try fileManager.removeItem(at: url)

        XCTAssertNotNil(store.thumbnail(for: note.id))
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))
        XCTAssertNotNil(UIImage(data: try Data(contentsOf: url)))
        assertSameDrawingSemantics(store.drawing(for: note.id), as: drawing)
    }

    func testAddingPagePersistsBlankDrawingBeforeReload() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let pageID = try XCTUnwrap(store.addPage(to: note.id))

        XCTAssertTrue(fileManager.fileExists(atPath: drawingURL(for: pageID).path))

        let reloadedStore = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        XCTAssertEqual(reloadedStore.notes.first(where: { $0.id == note.id })?.pageIDs, [note.id, pageID])
        XCTAssertTrue(reloadedStore.drawing(for: pageID).strokes.isEmpty)
    }

    func testNewPageStyleIsCapturedAtCreationAndSurvivesPreferenceChanges() throws {
        let key = NotePagePresentation.ruledNewPagesPreferenceKey
        let priorValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let priorValue {
                UserDefaults.standard.set(priorValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(true, forKey: key)
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        XCTAssertEqual(store.background(for: note.id), .ruled)

        UserDefaults.standard.set(false, forKey: key)
        let secondPage = try XCTUnwrap(store.addPage(to: note.id))
        XCTAssertEqual(store.background(for: secondPage), .plain)

        let reloaded = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        XCTAssertEqual(reloaded.background(for: note.id), .ruled)
        XCTAssertEqual(reloaded.background(for: secondPage), .plain)
    }

    func testDeletingNoteRemovesArtifactsForEveryPage() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let secondPageID = try XCTUnwrap(store.addPage(to: note.id))
        store.saveRecognizedTasks([makeTask(text: "First")], for: note.id)
        store.saveRecognizedTasks([makeTask(text: "Second")], for: secondPageID)

        XCTAssertTrue(fileManager.fileExists(atPath: drawingURL(for: note.id).path))
        XCTAssertTrue(fileManager.fileExists(atPath: drawingURL(for: secondPageID).path))
        XCTAssertTrue(fileManager.fileExists(atPath: tasksURL(for: note.id).path))
        XCTAssertTrue(fileManager.fileExists(atPath: tasksURL(for: secondPageID).path))
        XCTAssertTrue(fileManager.fileExists(atPath: thumbnailURL(for: note.id).path))

        store.deleteNote(note.id)

        for pageID in [note.id, secondPageID] {
            XCTAssertFalse(fileManager.fileExists(atPath: drawingURL(for: pageID).path))
            XCTAssertFalse(fileManager.fileExists(atPath: tasksURL(for: pageID).path))
            XCTAssertFalse(fileManager.fileExists(atPath: thumbnailURL(for: pageID).path))
        }
        XCTAssertFalse(store.notes.contains(where: { $0.id == note.id }))
    }

    func testDeletingFirstPagePersistsNewFirstPageAndRefreshesThumbnail() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let secondPageID = try XCTUnwrap(store.addPage(to: note.id))
        let thirdPageID = try XCTUnwrap(store.addPage(to: note.id))
        let firstDrawing = makeDrawing(color: .systemBlue, end: CGPoint(x: 40, y: 40))
        let secondDrawing = makeDrawing(color: .systemRed, end: CGPoint(x: 150, y: 120))
        let secondTask = makeTask(text: "Second remains")
        let thirdTask = makeTask(text: "Third remains")
        store.saveDrawing(firstDrawing, for: note.id)
        store.saveDrawing(secondDrawing, for: secondPageID)
        store.saveRecognizedTasks([secondTask], for: secondPageID)
        store.saveRecognizedTasks([thirdTask], for: thirdPageID)
        let oldThumbnail = try Data(contentsOf: thumbnailURL(for: note.id))

        XCTAssertTrue(store.deletePage(note.id, from: note.id))

        XCTAssertFalse(fileManager.fileExists(atPath: drawingURL(for: note.id).path))
        XCTAssertFalse(fileManager.fileExists(atPath: tasksURL(for: note.id).path))
        XCTAssertNotEqual(try Data(contentsOf: thumbnailURL(for: note.id)), oldThumbnail)
        XCTAssertNotNil(store.thumbnail(for: note.id))
        assertReloadedPages(
            noteID: note.id,
            expectedPageIDs: [secondPageID, thirdPageID],
            expectedArtifacts: [(secondPageID, secondDrawing, [secondTask]), (thirdPageID, PKDrawing(), [thirdTask])]
        )
    }

    func testDeletingMiddlePagePersistsSurroundingPagesAndArtifacts() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let middlePageID = try XCTUnwrap(store.addPage(to: note.id))
        let lastPageID = try XCTUnwrap(store.addPage(to: note.id))
        let firstDrawing = makeDrawing(color: .systemBlue, end: CGPoint(x: 60, y: 45))
        let lastDrawing = makeDrawing(color: .systemGreen, end: CGPoint(x: 130, y: 100))
        let firstTask = makeTask(text: "First remains")
        let lastTask = makeTask(text: "Last remains")
        store.saveDrawing(firstDrawing, for: note.id)
        store.saveDrawing(makeDrawing(color: .systemRed, end: CGPoint(x: 90, y: 80)), for: middlePageID)
        store.saveDrawing(lastDrawing, for: lastPageID)
        store.saveRecognizedTasks([firstTask], for: note.id)
        store.saveRecognizedTasks([lastTask], for: lastPageID)

        XCTAssertTrue(store.deletePage(middlePageID, from: note.id))

        XCTAssertFalse(fileManager.fileExists(atPath: drawingURL(for: middlePageID).path))
        assertReloadedPages(
            noteID: note.id,
            expectedPageIDs: [note.id, lastPageID],
            expectedArtifacts: [(note.id, firstDrawing, [firstTask]), (lastPageID, lastDrawing, [lastTask])]
        )
    }

    func testDeletingLastPagePersistsPreviousPagesAndArtifacts() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let middlePageID = try XCTUnwrap(store.addPage(to: note.id))
        let lastPageID = try XCTUnwrap(store.addPage(to: note.id))
        let firstDrawing = makeDrawing(color: .systemBlue, end: CGPoint(x: 55, y: 40))
        let middleDrawing = makeDrawing(color: .systemOrange, end: CGPoint(x: 120, y: 95))
        let firstTask = makeTask(text: "First remains")
        let middleTask = makeTask(text: "Middle remains")
        store.saveDrawing(firstDrawing, for: note.id)
        store.saveDrawing(middleDrawing, for: middlePageID)
        store.saveRecognizedTasks([firstTask], for: note.id)
        store.saveRecognizedTasks([middleTask], for: middlePageID)

        XCTAssertTrue(store.deletePage(lastPageID, from: note.id))

        XCTAssertFalse(fileManager.fileExists(atPath: drawingURL(for: lastPageID).path))
        assertReloadedPages(
            noteID: note.id,
            expectedPageIDs: [note.id, middlePageID],
            expectedArtifacts: [(note.id, firstDrawing, [firstTask]), (middlePageID, middleDrawing, [middleTask])]
        )
    }

    func testDeletingOnlyPageIsRejectedWithoutRemovingArtifacts() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let drawing = makeDrawing(color: .systemPurple, end: CGPoint(x: 75, y: 65))
        let task = makeTask(text: "Keep me")
        store.saveDrawing(drawing, for: note.id)
        store.saveRecognizedTasks([task], for: note.id)

        XCTAssertFalse(store.deletePage(note.id, from: note.id))

        assertReloadedPages(
            noteID: note.id,
            expectedPageIDs: [note.id],
            expectedArtifacts: [(note.id, drawing, [task])]
        )
        XCTAssertTrue(fileManager.fileExists(atPath: thumbnailURL(for: note.id).path))
    }

    private func assertReloadedPages(
        noteID: UUID,
        expectedPageIDs: [UUID],
        expectedArtifacts: [(UUID, PKDrawing, [RecognizedTask])],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reloadedStore = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        XCTAssertEqual(
            reloadedStore.notes.first(where: { $0.id == noteID })?.pageIDs,
            expectedPageIDs,
            file: file,
            line: line
        )
        for (pageID, drawing, tasks) in expectedArtifacts {
            assertSameDrawingSemantics(reloadedStore.drawing(for: pageID), as: drawing)
            XCTAssertEqual(reloadedStore.recognizedTasks(for: pageID), tasks, file: file, line: line)
        }
    }

    private func makeTask(text: String) -> RecognizedTask {
        RecognizedTask(
            id: UUID(),
            bounds: CGRect(x: 20, y: 20, width: 25, height: 25),
            recognizedText: text,
            correctedText: nil,
            confidence: 0.9,
            isChecked: false
        )
    }

    private func makeDrawing(color: UIColor, end: CGPoint) -> PKDrawing {
        let points = [
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: end, timeOffset: 0.1, size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: color), path: path)])
    }

    private func assertSameDrawingSemantics(_ actual: PKDrawing, as expected: PKDrawing) {
        XCTAssertEqual(actual.strokes.count, expected.strokes.count)
        for (actualStroke, expectedStroke) in zip(actual.strokes, expected.strokes) {
            XCTAssertEqual(actualStroke.ink.inkType, expectedStroke.ink.inkType)
            XCTAssertEqual(actualStroke.path.count, expectedStroke.path.count)
            for index in 0..<actualStroke.path.count {
                XCTAssertEqual(actualStroke.path[index].location, expectedStroke.path[index].location)
            }
        }
    }

    private var metadataURL: URL {
        storageURL.appendingPathComponent("notes.json")
    }

    private func drawingURL(for id: UUID) -> URL {
        storageURL.appendingPathComponent("Drawings", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).drawing")
    }

    private func tasksURL(for id: UUID) -> URL {
        storageURL.appendingPathComponent("RecognizedTasks", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func thumbnailURL(for id: UUID) -> URL {
        storageURL.appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).png")
    }
}

private struct LegacyNote: Encodable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
}
