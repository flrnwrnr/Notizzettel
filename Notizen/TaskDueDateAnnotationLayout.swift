import PencilKit
import UIKit

enum TaskCanvasAnnotationSizing {
    static func factors(for idiom: UIUserInterfaceIdiom) -> (marker: CGFloat, date: CGFloat) {
        idiom == .phone ? (marker: 0.6, date: 0.9) : (marker: 1, date: 1)
    }
}

/// Places a small date immediately above its recognized checkbox.
enum TaskDueDateAnnotationLayout {
    static let fontSize: CGFloat = 9

    static func rects(
        for tasks: [RecognizedTask],
        in drawing: PKDrawing,
        pageSize: CGSize,
        displayScale: CGFloat,
        markerSizeFactor: CGFloat = 1,
        dateSizeFactor: CGFloat = 1
    ) -> [UUID: CGRect] {
        let datedTasks = tasks.filter { $0.isPresent && $0.dueDate != nil }
        guard !datedTasks.isEmpty else { return [:] }

        let scale = max(displayScale, 0.2)
        // Page coordinates keep the label proportional to the drawn checkbox
        // when the page is shown on an iPhone, iPad, or at a different zoom.
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize * dateSizeFactor, weight: .medium)
        let textHeight = ceil(font.lineHeight)
        let page = CGRect(origin: .zero, size: pageSize).insetBy(dx: 1, dy: 1)
        var placed: [UUID: CGRect] = [:]

        for task in datedTasks {
            guard let date = task.dueDate else { continue }
            let textWidth = ceil((shortDate(date) as NSString).size(withAttributes: [.font: font]).width)
            let size = CGSize(width: textWidth, height: textHeight)
            let marker = CGPoint(x: task.bounds.minX, y: task.bounds.minY)
            let rect = CGRect(
                x: min(max(marker.x + 8 * markerSizeFactor / scale + 1, page.minX), page.maxX - size.width),
                y: min(max(marker.y - size.height - 2, page.minY), page.maxY - size.height),
                width: size.width,
                height: size.height
            )
            placed[task.id] = rect
        }
        return placed
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM."
        return formatter.string(from: date)
    }

    static func shortDate(_ dueDate: TaskDueDate) -> String {
        let day = shortDate(dueDate.date)
        guard let hour = dueDate.hour, let minute = dueDate.minute else { return day }
        return String(format: "%@ %02d:%02d", day, hour, minute)
    }

    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    static func fullDate(_ dueDate: TaskDueDate) -> String {
        let day = fullDate(dueDate.date)
        guard let hour = dueDate.hour, let minute = dueDate.minute else { return day }
        return String(format: "%@, %02d:%02d Uhr", day, hour, minute)
    }
}

/// Page offset changes are frequent while panning; layout is only recomputed
/// when the drawing, task geometry, or zoom level changes.
@MainActor
final class TaskDueDateAnnotationCache {
    private struct Snapshot: Equatable {
        let id: UUID
        let bounds: CGRect
        let isPresent: Bool
        let dueDate: TaskDueDate?
    }

    private var drawingRevision = -1
    private var displayScale: CGFloat = 0
    private var markerSizeFactor: CGFloat = 0
    private var dateSizeFactor: CGFloat = 0
    private var snapshots: [Snapshot] = []
    private var cachedRects: [UUID: CGRect] = [:]

    func rects(
        for tasks: [RecognizedTask],
        in drawing: PKDrawing,
        drawingRevision: Int,
        pageSize: CGSize,
        displayScale: CGFloat,
        markerSizeFactor: CGFloat = 1,
        dateSizeFactor: CGFloat = 1
    ) -> [UUID: CGRect] {
        let currentSnapshots = tasks.map {
            Snapshot(id: $0.id, bounds: $0.bounds, isPresent: $0.isPresent, dueDate: $0.dueDate)
        }
        guard self.drawingRevision != drawingRevision
                || self.displayScale != displayScale
                || self.markerSizeFactor != markerSizeFactor
                || self.dateSizeFactor != dateSizeFactor
                || snapshots != currentSnapshots else { return cachedRects }

        cachedRects = TaskDueDateAnnotationLayout.rects(
            for: tasks, in: drawing, pageSize: pageSize,
            displayScale: displayScale,
            markerSizeFactor: markerSizeFactor,
            dateSizeFactor: dateSizeFactor
        )
        self.drawingRevision = drawingRevision
        self.displayScale = displayScale
        self.markerSizeFactor = markerSizeFactor
        self.dateSizeFactor = dateSizeFactor
        snapshots = currentSnapshots
        return cachedRects
    }
}
