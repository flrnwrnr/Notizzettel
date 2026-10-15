import PencilKit
import XCTest
@testable import Notizen

@MainActor
final class NoteSearchTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchTests-\(UUID())")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testMetadataAndCorrectedTasksCombineTermsAndRespectCustomerScope() throws {
        let store = NoteStore(storageDirectory: directory, searchRecognizer: { _ in "" })
        let customer = try XCTUnwrap(store.createCustomer(name: "Müller Beratung"))
        let other = try XCTUnwrap(store.createCustomer(name: "Andere Firma"))
        let note = try XCTUnwrap(store.createNote(customerID: customer.id))
        let secondPage = try XCTUnwrap(store.addPage(to: note.id))
        let task = RecognizedTask(id: UUID(), bounds: .zero, recognizedText: "falsch", correctedText: "Angebot überarbeiten", confidence: 1, isChecked: false)
        store.saveRecognizedTasks([task], for: secondPage)
        store.setCustomerArchived(customer.id, archived: true)

        let matches = store.searchResults(query: "MÜLLER ANGEBOT")
        XCTAssertEqual(matches.map(\.pageID), [secondPage])
        XCTAssertEqual(matches.first?.pageNumber, 2)
        XCTAssertTrue(matches.first?.snippet.contains("Angebot") == true)
        XCTAssertTrue(store.searchResults(query: "Müller fehlt").isEmpty)
        XCTAssertTrue(store.searchResults(query: "Angebot", customerID: other.id).isEmpty)
        XCTAssertEqual(store.searchResults(query: "angebot", customerID: customer.id).count, 1)
        XCTAssertTrue(store.searchResults(query: "  \n ").isEmpty)

        store.renameCustomer(customer.id, name: "Neuer Kunde")
        XCTAssertTrue(store.searchResults(query: "Müller Angebot").isEmpty)
        XCTAssertEqual(store.searchResults(query: "Neuer Angebot").count, 1)
        XCTAssertTrue(store.deletePage(secondPage, from: note.id))
        XCTAssertTrue(store.searchResults(query: "Angebot").isEmpty)
    }

    func testIndexPersistsAndReusesUnchangedDrawingWithoutChangingNoteDate() async throws {
        let counter = SearchRecognitionCounter()
        let store = NoteStore(storageDirectory: directory, searchRecognizer: { data in
            try await counter.recognize(data)
        })
        let note = try XCTUnwrap(store.createNote())
        let drawing = try fixtureDrawing()
        store.saveDrawing(drawing, for: note.id)
        let savedDate = try XCTUnwrap(store.notes.first?.updatedAt)
        try await eventually { !store.searchResults(query: "Handschrift").isEmpty }
        XCTAssertEqual(store.notes.first?.updatedAt, savedDate)
        let calls = await counter.calls
        let reloaded = NoteStore(storageDirectory: directory, searchRecognizer: { data in
            try await counter.recognize(data)
        })
        try await eventually { !reloaded.searchIndexProgress.isIndexing }
        XCTAssertEqual(reloaded.searchResults(query: "Handschrift").first?.pageID, note.id)
        let callsAfterReload = await counter.calls
        XCTAssertEqual(callsAfterReload, calls)
        store.deleteNote(note.id)
        XCTAssertTrue(store.searchResults(query: "Handschrift").isEmpty)
    }

    func testExistingPagesBackfillAndFailedRecognitionCanRetry() async throws {
        let original = NoteStore(storageDirectory: directory, searchRecognizer: { _ in throw CocoaError(.fileReadUnknown) })
        let note = try XCTUnwrap(original.createNote())
        original.saveDrawing(try fixtureDrawing(), for: note.id)
        try await eventually { original.searchIndexProgress.failed > 0 && !original.searchIndexProgress.isIndexing }
        let recognizer = SearchFailOnceRecognizer()
        let reloaded = NoteStore(storageDirectory: directory, searchRecognizer: { _ in try await recognizer.recognize() })
        try await eventually { reloaded.searchIndexProgress.failed > 0 && !reloaded.searchIndexProgress.isIndexing }
        reloaded.retrySearchIndexing()
        try await eventually { !reloaded.searchResults(query: "Wiedergefunden").isEmpty }
        XCTAssertEqual(reloaded.searchResults(query: "Wiedergefunden").first?.noteID, note.id)
        XCTAssertEqual(reloaded.searchIndexProgress.failed, 0)
    }

    func testLateRecognitionCannotRestoreErasedOrDeletedPage() async throws {
        let gate = SearchRecognitionGate()
        let store = NoteStore(storageDirectory: directory, searchRecognizer: { data in
            try await gate.recognize(data)
        })
        let note = try XCTUnwrap(store.createNote())
        store.saveDrawing(try fixtureDrawing(), for: note.id)
        for _ in 0..<100 {
            if await gate.waiting { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let didStart = await gate.waiting
        XCTAssertTrue(didStart)
        store.saveDrawing(PKDrawing(), for: note.id)
        await gate.release()
        try await eventually { !store.searchIndexProgress.isIndexing }
        XCTAssertTrue(store.searchResults(query: "Veraltet").isEmpty)

        store.saveDrawing(try fixtureDrawing(), for: note.id)
        for _ in 0..<100 {
            if await gate.waiting { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        store.deleteNote(note.id)
        await gate.release()
        try await eventually { !store.searchIndexProgress.isIndexing }
        XCTAssertTrue(store.searchResults(query: "Veraltet").isEmpty)
        let reloaded = NoteStore(storageDirectory: directory, searchRecognizer: { _ in "" })
        XCTAssertTrue(reloaded.searchResults(query: "Veraltet").isEmpty)
    }

    func testFullPageOCRReadsRealPhoneHandwriting() async throws {
        let text = try await Task.detached {
            try await NoteSearchIndex.recognize(self.fixtureDrawingData())
        }.value
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Test"), "Recognized: \(text)")
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Search indexing did not reach the expected state")
    }

    nonisolated private func fixtureDrawingData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PhoneCheckboxes", withExtension: "json"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return try XCTUnwrap(Data(base64Encoded: fixture["drawing"] ?? ""))
    }

    private func fixtureDrawing() throws -> PKDrawing { try PKDrawing(data: fixtureDrawingData()) }
}

private actor SearchRecognitionCounter {
    var calls = 0
    func recognize(_ data: Data) throws -> String {
        calls += 1
        return try PKDrawing(data: data).strokes.isEmpty ? "" : "Handschrift durchsuchen"
    }
}

private actor SearchFailOnceRecognizer {
    var calls = 0
    func recognize() throws -> String {
        calls += 1
        if calls == 1 { throw CocoaError(.fileReadUnknown) }
        return "Wiedergefunden"
    }
}

private actor SearchRecognitionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func recognize(_ data: Data) async throws -> String {
        if try PKDrawing(data: data).strokes.isEmpty { return "" }
        await withCheckedContinuation { continuation = $0 }
        return "Veraltet"
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
