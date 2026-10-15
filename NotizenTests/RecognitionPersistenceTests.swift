import PencilKit
import UIKit
import XCTest

@testable import Notizen

@MainActor
final class RecognitionPersistenceTests: XCTestCase {
    private var storageURL: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        storageURL = fileManager.temporaryDirectory
            .appendingPathComponent("RecognitionPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if fileManager.fileExists(atPath: storageURL.path) {
            try fileManager.removeItem(at: storageURL)
        }
    }

    func testRecognizedTasksRoundTripAndDoesNotChangeDrawing() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let drawing = makeDrawing()
        store.saveDrawing(drawing, for: note.id)
        let drawingURL = self.drawingURL(for: note.id)
        let drawingDataBeforeSavingTasks = try Data(contentsOf: drawingURL)

        let task = RecognizedTask(
            id: UUID(),
            bounds: CGRect(x: 40, y: 40, width: 30, height: 30),
            recognizedText: "Buy milk",
            correctedText: "Buy oat milk",
            confidence: 0.92,
            isChecked: false
        )
        store.saveRecognizedTasks([task], for: note.id)
        XCTAssertEqual(try Data(contentsOf: drawingURL), drawingDataBeforeSavingTasks)

        let reloadedStore = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        XCTAssertEqual(reloadedStore.recognizedTasks(for: note.id), [task])
        assertSameDrawingSemantics(reloadedStore.drawing(for: note.id), as: drawing)
    }

    func testLegacyNoteWithoutTaskSidecarReturnsNoRecognizedTasks() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())

        let reloadedStore = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        XCTAssertEqual(reloadedStore.recognizedTasks(for: note.id), [])
    }

    func testCorruptTaskMetadataIsNotOverwrittenBySave() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let sidecarURL = recognizedTasksURL(for: note.id)
        let corruptData = Data("not valid JSON".utf8)
        try corruptData.write(to: sidecarURL)

        let reloadedStore = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        XCTAssertEqual(reloadedStore.recognizedTasks(for: note.id), [])
        reloadedStore.saveRecognizedTasks([makeTask()], for: note.id)

        XCTAssertEqual(try Data(contentsOf: sidecarURL), corruptData)
    }

    func testDeletingNoteRemovesRecognizedTaskSidecar() throws {
        let store = NoteStore(storageDirectory: storageURL, fileManager: fileManager)
        let note = try XCTUnwrap(store.createNote())
        let sidecarURL = recognizedTasksURL(for: note.id)
        store.saveRecognizedTasks([makeTask()], for: note.id)
        XCTAssertTrue(fileManager.fileExists(atPath: sidecarURL.path))

        store.deleteNote(note.id)

        XCTAssertFalse(fileManager.fileExists(atPath: sidecarURL.path))
    }

    private func makeTask() -> RecognizedTask {
        RecognizedTask(
            id: UUID(),
            bounds: CGRect(x: 40, y: 40, width: 30, height: 30),
            recognizedText: "Task",
            correctedText: nil,
            confidence: 0.8,
            isChecked: false
        )
    }

    private func makeDrawing() -> PKDrawing {
        let points = [
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 40, y: 40), timeOffset: 0.1, size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 0))
        let stroke = PKStroke(ink: PKInk(.pen, color: .systemBlue), path: path)
        return PKDrawing(strokes: [stroke])
    }

    private func recognizedTasksURL(for id: UUID) -> URL {
        storageURL
            .appendingPathComponent("RecognizedTasks", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func drawingURL(for id: UUID) -> URL {
        storageURL
            .appendingPathComponent("Drawings", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).drawing")
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
}
