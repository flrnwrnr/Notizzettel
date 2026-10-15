import CoreGraphics
import Foundation
import PencilKit

/// Visible frame samples survive OCR changes and distinguish erasing the box
/// from erasing only its checkmark. Samples use the engine's mask-aware geometry.
enum CheckboxRemovalEvidence {
    static func strokeEvidence(in drawing: PKDrawing, near bounds: CGRect) -> [String] {
        strokeEvidence(in: drawing,
                       sampled: TaskRecognitionEngine.sampleVisibleGeometry(from: drawing),
                       near: bounds)
    }

    static func strokeEvidence(
        in drawing: PKDrawing, sampled: [CheckboxGeometryStroke], near bounds: CGRect
    ) -> [String] {
        let indices = Set(sampled.compactMap { stroke -> Int? in
            edgeBins(stroke.points, near: bounds).count >= 3 ? stroke.sourceIndex : nil
        })
        return indices.sorted().map { index in
            let stroke = drawing.strokes[index]
            return strokeKey(stroke) + "|" + String(describing: stroke.transform)
        }
    }

    static func sameSource(_ lhs: [String], _ rhs: [String]) -> Bool {
        let left = Set(lhs.map(sourceKey))
        let right = Set(rhs.map(sourceKey))
        return !left.isEmpty && left == right
    }

    static func wasMoved(_ evidence: [String], in drawing: PKDrawing) -> Bool {
        var old: [String: String] = [:]
        for signature in evidence { old[sourceKey(signature)] = signature }
        return drawing.strokes.contains { stroke in
            let new = strokeKey(stroke) + "|" + String(describing: stroke.transform)
            return old[strokeKey(stroke)].map { $0 != new } ?? false
        }
    }

    private static func sourceKey(_ signature: String) -> String {
        String(signature.split(separator: "|", maxSplits: 1).first ?? "")
    }

    private static func strokeKey(_ stroke: PKStroke) -> String {
        let path = stroke.path
        let first = path.count > 0 ? String(describing: path[0].location) : ""
        let last = path.count > 0 ? String(describing: path[path.count - 1].location) : ""
        return "\(path.creationDate.timeIntervalSinceReferenceDate.bitPattern):\(stroke.randomSeed):\(path.count):\(first):\(last)"
    }

    static func samples(in drawingData: Data, near bounds: CGRect) -> [Int]? {
        guard let drawing = try? PKDrawing(data: drawingData) else { return nil }
        return samples(in: drawing, near: bounds)
    }

    static func samples(in drawing: PKDrawing, near bounds: CGRect) -> [Int] {
        samples(in: TaskRecognitionEngine.sampleVisibleGeometry(from: drawing), near: bounds)
    }

    static func samples(in sampled: [CheckboxGeometryStroke], near bounds: CGRect) -> [Int] {
        var samples = Set<Int>()
        for stroke in sampled {
            samples.formUnion(edgeBins(stroke.points, near: bounds))
        }
        return samples.sorted()
    }

    private static func edgeBins(_ points: [CGPoint], near bounds: CGRect) -> Set<Int> {
        let tolerance = max(2.5, min(bounds.width, bounds.height) * 0.12)
        let region = bounds.insetBy(dx: -tolerance, dy: -tolerance)
        var samples = Set<Int>()
        for point in points where region.contains(point) {
                let x = min(15, max(0, Int(16 * (point.x - bounds.minX) / max(bounds.width, 1))))
                let y = min(15, max(0, Int(16 * (point.y - bounds.minY) / max(bounds.height, 1))))
                if abs(point.y - bounds.minY) <= tolerance { samples.insert(x) }
                if abs(point.x - bounds.maxX) <= tolerance { samples.insert(16 + y) }
                if abs(point.y - bounds.maxY) <= tolerance { samples.insert(32 + x) }
                if abs(point.x - bounds.minX) <= tolerance { samples.insert(48 + y) }
        }
        return samples
    }

    static func provesRemoval(_ previous: [Int], current: [Int]) -> Bool {
        guard previous.count >= 12 else { return false }
        let retained = Set(previous).intersection(current).count
        return retained <= max(3, previous.count / 3)
    }
}
