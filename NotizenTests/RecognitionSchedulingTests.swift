import CoreGraphics
import Foundation
import PencilKit
import UIKit
import XCTest

@testable import Notizen

@MainActor
final class RecognitionSchedulingTests: XCTestCase {
    func testPhoneDrawingIsRecognizedAutomaticallyThroughLiveEngine() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PhoneCheckboxes", withExtension: "json"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let data = try XCTUnwrap(Data(base64Encoded: fixture["drawing"] ?? ""))
        let persisted = expectation(description: "real phone drawing recognized automatically")
        let session = TaskRecognitionSession(debounceDuration: .milliseconds(10))
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in persisted.fulfill() }

        session.drawingDidChange(data)
        await fulfillment(of: [persisted], timeout: 15)

        XCTAssertTrue(session.tasks.contains { $0.recognizedText.localizedCaseInsensitiveContains("Test") })
        XCTAssertNil(session.errorMessage)
    }

    func testAutomaticRecognitionRunsAfterDebounce() async throws {
        let candidate = Self.proposal(text: "Automatic")
        let persisted = expectation(description: "automatic recognition persisted")
        let session = TaskRecognitionSession(debounceDuration: .milliseconds(10)) { _ in
            try Task.checkCancellation()
            return [candidate]
        }
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in
            persisted.fulfill()
        }

        session.drawingDidChange(Data([1]))
        XCTAssertFalse(session.isAnalyzing)

        await fulfillment(of: [persisted], timeout: 1)

        XCTAssertEqual(session.tasks.map { $0.recognizedText }, ["Automatic"])
        XCTAssertFalse(session.isAnalyzing)
    }

    func testManualRecognitionStartsWithoutWaitingForDebounce() async throws {
        let candidate = Self.proposal(text: "Manual")
        let persisted = expectation(description: "manual recognition persisted")
        let session = TaskRecognitionSession(debounceDuration: .seconds(10)) { _ in
            try Task.checkCancellation()
            return [candidate]
        }
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in
            persisted.fulfill()
        }

        session.drawingDidChange(Data([1]))
        session.recognizeNow()
        await fulfillment(of: [persisted], timeout: 1)

        XCTAssertEqual(session.tasks.map { $0.recognizedText }, ["Manual"])
        XCTAssertFalse(session.isAnalyzing)
    }

    func testLateResultFromOlderGenerationIsIgnored() async throws {
        let staleStarted = expectation(description: "stale recognition started")
        let currentPersisted = expectation(description: "current recognition persisted")
        let session = TaskRecognitionSession(debounceDuration: .zero) { data in
            if data == Data([1]) {
                staleStarted.fulfill()
                try? await Task.sleep(for: .milliseconds(80))
                return [Self.proposal(text: "Stale")]
            }
            return [Self.proposal(text: "Current")]
        }
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in
            currentPersisted.fulfill()
        }

        session.drawingDidChange(Data([1]), automatically: false)
        await fulfillment(of: [staleStarted], timeout: 1)
        session.drawingDidChange(Data([2]), automatically: false)
        await fulfillment(of: [currentPersisted], timeout: 1)
        await Task.yield()

        XCTAssertEqual(session.tasks.map { $0.recognizedText }, ["Current"])
        XCTAssertFalse(session.isAnalyzing)
    }

    func testDeactivatePreventsLateResultAndPersistence() async throws {
        var saveCount = 0
        let recognitionStarted = expectation(description: "recognition started")
        let recognitionFinished = expectation(description: "cancelled recognition returned")
        let session = TaskRecognitionSession(debounceDuration: .zero) { _ in
            recognitionStarted.fulfill()
            try? await Task.sleep(for: .milliseconds(50))
            recognitionFinished.fulfill()
            return [Self.proposal(text: "Late")]
        }
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in
            saveCount += 1
        }

        session.drawingDidChange(Data([1]), automatically: false)
        await fulfillment(of: [recognitionStarted], timeout: 1)
        session.deactivate()
        await fulfillment(of: [recognitionFinished], timeout: 1)
        await Task.yield()

        XCTAssertTrue(session.tasks.isEmpty)
        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(session.isAnalyzing)
    }

    func testContinuousChangesDoNotResetScheduledStart() async throws {
        let probe = RecognitionProbe()
        let session = TaskRecognitionSession(debounceDuration: .milliseconds(120)) { data in
            await probe.run(data)
        }
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in }

        session.drawingDidChange(Data([1]))
        var startedBeforeFinalEdit = false
        for value in UInt8(2)...UInt8(10) {
            try await Task.sleep(for: .milliseconds(40))
            if await !probe.starts.isEmpty { startedBeforeFinalEdit = true }
            session.drawingDidChange(Data([value]))
        }
        XCTAssertTrue(startedBeforeFinalEdit, "Continuing edits must not postpone the first OCR run")
        try await waitUntil { await probe.starts.count == 1 }
        let starts = await probe.starts
        XCTAssertNotEqual(starts, [Data([10])])
        let finish = Task { await session.finishPendingRecognition() }
        await probe.releaseNext(with: [])
        try await waitUntil { await probe.starts.count == 2 }
        let finalStarts = await probe.starts
        XCTAssertEqual(finalStarts.last, Data([10]))
        await probe.releaseNext(with: [])
        await finish.value
    }

    func testOneWorkerCoalescesToNewestSnapshotAndDrawingDoesNotCancelIt() async throws {
        let probe = RecognitionProbe()
        let session = TaskRecognitionSession(debounceDuration: .zero) { data in
            await probe.run(data)
        }
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in }
        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { await probe.starts.count == 1 }

        session.drawingActivityBegan()
        session.drawingDidChange(Data([2]), automatically: false)
        session.drawingDidChange(Data([3]), automatically: false)
        let activeBeforeRelease = await probe.maxActive
        XCTAssertEqual(activeBeforeRelease, 1)
        await probe.releaseNext(with: [])
        try await waitUntil { await probe.starts.count == 2 }
        let coalescedStarts = await probe.starts
        let maxActive = await probe.maxActive
        XCTAssertEqual(coalescedStarts, [Data([1]), Data([3])])
        XCTAssertEqual(maxActive, 1)
        session.drawingActivityEnded(Data([3]))
        await probe.releaseNext(with: [Self.proposal(text: "Newest")])
        await session.finishPendingRecognition()
        XCTAssertEqual(session.tasks.map(\.recognizedText), ["Newest"])
        let finalMaxActive = await probe.maxActive
        XCTAssertEqual(finalMaxActive, 1)
    }

    func testRecognitionErrorStillDrainsNewestSnapshot() async throws {
        let probe = RecognitionProbe()
        let session = TaskRecognitionSession(debounceDuration: .zero) { data in
            try await probe.runThrowing(data)
        }
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in }
        session.drawingDidChange(Data([1]), automatically: false)
        try await waitUntil { await probe.starts.count == 1 }
        session.drawingDidChange(Data([2]), automatically: false)
        await probe.failNext()
        try await waitUntil { await probe.starts.count == 2 }
        await probe.releaseNext(with: [Self.proposal(text: "After error")])
        await session.finishPendingRecognition()
        XCTAssertEqual(session.tasks.map(\.recognizedText), ["After error"])
        XCTAssertNil(session.errorMessage)
    }

    func testOlderResultShowsOnlyUnchangedRowsWithoutPersistence() async throws {
        let probe = RecognitionProbe()
        let originalRow = Self.stroke(y: 40)
        let oldData = PKDrawing(strokes: [originalRow]).dataRepresentation()
        let newData = PKDrawing(strokes: [originalRow, Self.stroke(y: 540)]).dataRepresentation()
        let unchanged = Self.proposal(text: "Unchanged", y: 40)
        let added = Self.proposal(text: "Added", y: 540)
        var saved: [[RecognizedTask]] = []
        let session = TaskRecognitionSession(debounceDuration: .seconds(10)) { data in
            await probe.run(data)
        }
        session.configure(noteID: UUID(), savedTasks: []) { tasks, _ in saved.append(tasks) }

        session.drawingDidChange(oldData, automatically: false)
        try await waitUntil { await probe.starts.count == 1 }
        session.drawingDidChange(newData)
        await probe.releaseNext(with: [unchanged])
        try await waitUntil { session.tasks.count == 1 }
        XCTAssertEqual(session.tasks.map(\.recognizedText), ["Unchanged"])
        XCTAssertTrue(saved.isEmpty)

        let finish = Task { await session.finishPendingRecognition() }
        try await waitUntil { await probe.starts.count == 2 }
        await probe.releaseNext(with: [unchanged, added])
        await finish.value
        XCTAssertEqual(session.tasks.map(\.recognizedText), ["Unchanged", "Added"])
        XCTAssertEqual(saved.last?.count, 2)
    }

    func testOlderResultDoesNotShowChangedRow() async throws {
        let probe = RecognitionProbe()
        let originalRow = Self.stroke(y: 40)
        let oldData = PKDrawing(strokes: [originalRow]).dataRepresentation()
        let changedData = PKDrawing(strokes: [originalRow, Self.stroke(y: 50)]).dataRepresentation()
        let session = TaskRecognitionSession(debounceDuration: .seconds(10)) { data in
            await probe.run(data)
        }
        session.configure(noteID: UUID(), savedTasks: []) { _, _ in }
        session.drawingDidChange(oldData, automatically: false)
        try await waitUntil { await probe.starts.count == 1 }
        session.drawingDidChange(changedData)
        await probe.releaseNext(with: [Self.proposal(text: "Changed", y: 40)])
        try await waitUntil { !session.isAnalyzing }
        XCTAssertTrue(session.tasks.isEmpty)

        let finish = Task { await session.finishPendingRecognition() }
        try await waitUntil { await probe.starts.count == 2 }
        await probe.releaseNext(with: [])
        await finish.value
    }

    private func waitUntil(
        attempts: Int = 150,
        _ condition: () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for recognition")
    }

    nonisolated private static func proposal(text: String, y: CGFloat = 10) -> TaskCandidate {
        TaskCandidate(
            bounds: CGRect(x: 10, y: y, width: 24, height: 24),
            text: text,
            confidence: 0.9,
            isChecked: false
        )
    }

    private static func stroke(y: CGFloat) -> PKStroke {
        let points = [CGPoint(x: 20, y: y), CGPoint(x: 32, y: y + 12)].enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index),
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: .distantPast)
        )
    }
}

private actor RecognitionProbe {
    private(set) var starts: [Data] = []
    private(set) var maxActive = 0
    private var active = 0
    private var continuations: [CheckedContinuation<Result<[TaskCandidate], Error>, Never>] = []

    func run(_ data: Data) async -> [TaskCandidate] {
        (try? await runThrowing(data)) ?? []
    }

    func runThrowing(_ data: Data) async throws -> [TaskCandidate] {
        starts.append(data)
        active += 1
        maxActive = max(maxActive, active)
        let result = await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        active -= 1
        return try result.get()
    }

    func releaseNext(with candidates: [TaskCandidate]) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: .success(candidates))
    }

    func failNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: .failure(ProbeFailure()))
    }
}

private struct ProbeFailure: Error {}
