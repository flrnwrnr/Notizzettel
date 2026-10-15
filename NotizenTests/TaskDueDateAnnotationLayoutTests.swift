import PencilKit
import XCTest

@testable import Notizen

final class TaskDueDateAnnotationLayoutTests: XCTestCase {
    func testUndatedTaskHasNoAnnotation() {
        let task = makeTask(dueDate: nil)
        XCTAssertTrue(TaskDueDateAnnotationLayout.rects(
            for: [task], in: PKDrawing(), pageSize: CGSize(width: 300, height: 300), displayScale: 1
        ).isEmpty)
    }

    func testDateSitsAboveCheckboxAndRightOfMarker() throws {
        let task = makeTask()
        let rect = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task], in: PKDrawing(), pageSize: CGSize(width: 300, height: 300), displayScale: 1
        )[task.id])
        XCTAssertEqual(rect.maxY, task.bounds.minY - 2)
        XCTAssertGreaterThan(rect.minX, task.bounds.minX + 8)
        XCTAssertLessThanOrEqual(rect.width, task.bounds.width * 1.6)
    }

    func testTimedDateShowsTimeAndReservesItsWidth() throws {
        let allDay = TaskDueDate(year: 2026, month: 9, day: 28)
        let timed = TaskDueDate(year: 2026, month: 9, day: 28, hour: 14, minute: 5)
        XCTAssertEqual(TaskDueDateAnnotationLayout.shortDate(allDay), "28.09.")
        XCTAssertEqual(TaskDueDateAnnotationLayout.shortDate(timed), "28.09. 14:05")
        XCTAssertTrue(TaskDueDateAnnotationLayout.fullDate(timed).hasSuffix("14:05 Uhr"))

        let allDayTask = makeTask(dueDate: allDay)
        let timedTask = makeTask(dueDate: timed)
        let pageSize = CGSize(width: 300, height: 300)
        let allDayRect = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [allDayTask], in: PKDrawing(), pageSize: pageSize, displayScale: 1
        )[allDayTask.id])
        let timedRect = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [timedTask], in: PKDrawing(), pageSize: pageSize, displayScale: 1
        )[timedTask.id])
        XCTAssertGreaterThan(timedRect.width, allDayRect.width)
        XCTAssertEqual(timedRect.maxY, allDayRect.maxY)
    }

    func testDateScalesWithPageInsteadOfDisplay() throws {
        let task = makeTask()
        let phone = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task], in: PKDrawing(), pageSize: CGSize(width: 300, height: 300), displayScale: 0.5
        )[task.id])
        let ipad = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task], in: PKDrawing(), pageSize: CGSize(width: 300, height: 300), displayScale: 1
        )[task.id])
        XCTAssertEqual(phone.size, ipad.size)
        XCTAssertEqual(phone.maxY, ipad.maxY)
    }

    func testCanvasSizingKeepsDateAndIPadMarkerWhileShrinkingPhoneMarker() {
        let phone = TaskCanvasAnnotationSizing.factors(for: .phone)
        let ipad = TaskCanvasAnnotationSizing.factors(for: .pad)

        XCTAssertEqual(16 * phone.marker, 9.6, accuracy: 0.001)
        XCTAssertEqual(phone.date, 0.9)
        XCTAssertEqual(ipad.marker, 1)
        XCTAssertEqual(ipad.date, 1)
    }

    func testPhoneDateFollowsSmallerMarkerWithoutChangingItsSize() throws {
        let task = makeTask()
        let drawing = PKDrawing()
        let pageSize = CGSize(width: 300, height: 300)
        let ipad = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task], in: drawing, pageSize: pageSize,
            displayScale: 1, markerSizeFactor: 1, dateSizeFactor: 1
        )[task.id])
        let phone = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task], in: drawing, pageSize: pageSize,
            displayScale: 1, markerSizeFactor: 0.6, dateSizeFactor: 0.9
        )[task.id])
        let previousPhoneDate = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task], in: drawing, pageSize: pageSize,
            displayScale: 1, markerSizeFactor: 0.9, dateSizeFactor: 0.9
        )[task.id])

        XCTAssertLessThan(phone.width, ipad.width)
        XCTAssertLessThan(phone.height, ipad.height)
        XCTAssertEqual(phone.size, previousPhoneDate.size)
        XCTAssertEqual(ipad.minX, task.bounds.minX + 9, accuracy: 0.001)
        XCTAssertEqual(phone.minX, task.bounds.minX + 5.8, accuracy: 0.001)
        XCTAssertEqual(phone.maxY, ipad.maxY)
    }

    @MainActor
    func testCacheInvalidatesWhenMarkerOrDateSizeChanges() throws {
        let task = makeTask()
        let cache = TaskDueDateAnnotationCache()
        let drawing = PKDrawing()
        let pageSize = CGSize(width: 300, height: 300)
        let ipad = try XCTUnwrap(cache.rects(
            for: [task], in: drawing, drawingRevision: 1,
            pageSize: pageSize, displayScale: 1, markerSizeFactor: 1, dateSizeFactor: 1
        )[task.id])
        let smallerMarker = try XCTUnwrap(cache.rects(
            for: [task], in: drawing, drawingRevision: 1,
            pageSize: pageSize, displayScale: 1, markerSizeFactor: 0.6, dateSizeFactor: 1
        )[task.id])
        let smallerDate = try XCTUnwrap(cache.rects(
            for: [task], in: drawing, drawingRevision: 1,
            pageSize: pageSize, displayScale: 1, markerSizeFactor: 0.6, dateSizeFactor: 0.9
        )[task.id])

        XCTAssertEqual(smallerMarker.size, ipad.size)
        XCTAssertLessThan(smallerMarker.minX, ipad.minX)
        XCTAssertLessThan(smallerDate.width, smallerMarker.width)
        XCTAssertEqual(smallerDate.minX, smallerMarker.minX)
    }

    func testInkAtDatePositionKeepsAnnotationNearCheckbox() throws {
        let task = makeTask()
        let drawing = PKDrawing(strokes: [
            stroke(from: CGPoint(x: 95, y: 0), to: CGPoint(x: 95, y: 160), width: 8)
        ])
        let rect = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task], in: drawing, pageSize: CGSize(width: 300, height: 300), displayScale: 1
        )[task.id])
        XCTAssertEqual(rect.maxY, task.bounds.minY - 2)
        XCTAssertGreaterThan(rect.minX, task.bounds.minX)
    }

    func testOtherMarkerDoesNotHideDate() throws {
        let task = makeTask()
        let other = makeTask(bounds: CGRect(x: 101, y: 70, width: 20, height: 20), dueDate: nil)
        let rect = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task, other], in: PKDrawing(), pageSize: CGSize(width: 200, height: 100), displayScale: 1
        )[task.id])
        XCTAssertEqual(rect.maxY, task.bounds.minY - 2)
    }

    func testDateNearPageEdgeIsClampedButStaysWithMarker() throws {
        let task = makeTask(bounds: CGRect(x: 190, y: 4, width: 20, height: 20))
        let rect = try XCTUnwrap(TaskDueDateAnnotationLayout.rects(
            for: [task], in: PKDrawing(), pageSize: CGSize(width: 200, height: 100), displayScale: 1
        )[task.id])
        XCTAssertEqual(rect.maxX, 199)
        XCTAssertEqual(rect.minY, 1)
        XCTAssertGreaterThan(rect.minX, 150)
    }

    func testOverlappingDatedMarkersEachKeepAnAnnotation() {
        let first = makeTask()
        let second = makeTask(bounds: CGRect(x: 82, y: 82, width: 20, height: 20))
        let rects = TaskDueDateAnnotationLayout.rects(
            for: [first, second], in: PKDrawing(), pageSize: CGSize(width: 300, height: 300), displayScale: 1
        )
        XCTAssertNotNil(rects[first.id])
        XCTAssertNotNil(rects[second.id])
    }

    private func makeTask(
        bounds: CGRect = CGRect(x: 80, y: 80, width: 20, height: 20),
        dueDate: TaskDueDate? = TaskDueDate(year: 2026, month: 9, day: 28)
    ) -> RecognizedTask {
        RecognizedTask(
            id: UUID(), bounds: bounds, recognizedText: "Test", correctedText: nil,
            confidence: 0.9, isChecked: false, dueDate: dueDate
        )
    }

    private func stroke(from start: CGPoint, to end: CGPoint, width: CGFloat) -> PKStroke {
        let points = [start, end].enumerated().map { index, point in
            PKStrokePoint(
                location: point, timeOffset: TimeInterval(index),
                size: CGSize(width: width, height: width), opacity: 1,
                force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date())
        )
    }
}
