import CoreGraphics
import Foundation
import PencilKit
import UIKit
import Vision

enum TaskRecognitionError: LocalizedError {
    case tooManyCheckboxes(limit: Int)
    case drawingTooComplex(strokeLimit: Int)

    var errorDescription: String? {
        switch self {
        case .tooManyCheckboxes(let limit):
            return "Die Notiz enthält mehr als \(limit) mögliche Checkboxen. Bitte teile sie in mehrere Notizen auf."
        case .drawingTooComplex(let strokeLimit):
            return "Die Zeichnung ist für die automatische Erkennung zu komplex (mehr als \(strokeLimit) Striche)."
        }
    }
}

/// Performs the relatively expensive drawing and Vision work away from the main actor.
actor TaskRecognitionEngine {
    private static let pageBounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    private static let maximumCandidates = 30
    private static let maximumInputStrokes = 400
    private static let maximumGeometryPieces = 500
    private var ocrCache = RecognitionOCRCache()

    func recognize(drawingData: Data) async throws -> [TaskCandidate] {
        try Task.checkCancellation()

        let drawing = try PKDrawing(data: drawingData)
        guard drawing.strokes.count <= Self.maximumInputStrokes else {
            throw TaskRecognitionError.drawingTooComplex(strokeLimit: Self.maximumInputStrokes)
        }
        let sampledStrokes = Self.sampleVisibleGeometry(from: drawing)
        guard sampledStrokes.count <= Self.maximumGeometryPieces else {
            throw TaskRecognitionError.drawingTooComplex(strokeLimit: Self.maximumInputStrokes)
        }
        let boxes = CheckboxDetector.detect(
            strokes: sampledStrokes,
            pageBounds: Self.pageBounds,
            limit: Self.maximumCandidates + 1
        )

        guard !boxes.isEmpty else {
            ocrCache.replace(with: [])
            return []
        }
        guard boxes.count <= Self.maximumCandidates else {
            throw TaskRecognitionError.tooManyCheckboxes(limit: Self.maximumCandidates)
        }

        let sortedBoxes = boxes.sorted {
            if abs($0.bounds.midY - $1.bounds.midY) > 3 {
                return $0.bounds.midY < $1.bounds.midY
            }
            return $0.bounds.minX < $1.bounds.minX
        }

        var candidates: [TaskCandidate] = []
        candidates.reserveCapacity(sortedBoxes.count)
        var nextOCREntries: [RecognitionOCRCache.Entry] = []
        nextOCREntries.reserveCapacity(sortedBoxes.count)

        for index in sortedBoxes.indices {
            try Task.checkCancellation()

            let box = sortedBoxes[index]
            let crop = Self.textCrop(for: index, boxes: sortedBoxes)
            let recognition: (text: String, confidence: Float)
            if crop.width >= 20, crop.height >= 10 {
                let subset = RecognitionOCRCache.visibleDrawing(in: crop, from: drawing)
                if let cached = ocrCache.value(for: crop, subset: subset) {
                    recognition = cached
                    nextOCREntries.append(.init(crop: crop, subset: subset, value: cached))
                } else if let result = Self.recognizeText(in: crop, drawing: drawing) {
                    recognition = result
                    nextOCREntries.append(.init(crop: crop, subset: subset, value: result))
                } else {
                    recognition = ("", 0)
                }
            } else {
                recognition = ("", 0)
            }

            candidates.append(
                TaskCandidate(
                    bounds: box.bounds,
                    text: recognition.text,
                    confidence: recognition.confidence,
                    isChecked: CheckboxDetector.isChecked(box, among: sampledStrokes)
                )
            )
        }

        ocrCache.replace(with: nextOCREntries)
        return candidates
    }

    /// Samples transformed, visible geometry only. A partially erased stroke is split into
    /// independent pieces, which prevents an invisible bridge from completing a checkbox.
    static func sampleVisibleGeometry(from drawing: PKDrawing) -> [CheckboxGeometryStroke] {
        let maximumSamplesPerStroke = 512
        var result: [CheckboxGeometryStroke] = []
        result.reserveCapacity(drawing.strokes.count)

        for (sourceIndex, stroke) in drawing.strokes.enumerated() {
            let path = stroke.path
            guard path.count >= 2 else { continue }

            let upperBound = CGFloat(path.count - 1)
            let sampleCount = min(
                maximumSamplesPerStroke,
                max(2, Int(ceil(upperBound * 4)) + 1)
            )
            let hasMask = stroke.mask != nil
            let visibleRanges = stroke.maskedPathRanges
            var visiblePiece: [CGPoint] = []

            func finishVisiblePiece() {
                guard visiblePiece.count >= 2 else {
                    visiblePiece.removeAll(keepingCapacity: true)
                    return
                }
                result.append(CheckboxGeometryStroke(points: visiblePiece, sourceIndex: sourceIndex))
                visiblePiece.removeAll(keepingCapacity: true)
            }

            for sampleIndex in 0..<sampleCount {
                let fraction = CGFloat(sampleIndex) / CGFloat(sampleCount - 1)
                let parameter = upperBound * fraction
                // `mask` clips rendering to the path, and `maskedPathRanges` reports path
                // ranges intersecting that visible mask. With no mask the complete stroke is
                // visible regardless of what a particular PencilKit version reports here.
                let intersectsVisibleMask = visibleRanges.contains { range in
                    parameter >= range.lowerBound && parameter <= range.upperBound
                }

                guard !hasMask || intersectsVisibleMask else {
                    finishVisiblePiece()
                    continue
                }

                let point = path.interpolatedLocation(at: parameter).applying(stroke.transform)
                guard point.x.isFinite, point.y.isFinite else { continue }
                if visiblePiece.last.map({ $0.distance(to: point) >= 0.75 }) ?? true {
                    visiblePiece.append(point)
                }
            }

            finishVisiblePiece()
        }

        return result
    }

    private static func textCrop(for index: Int, boxes: [CheckboxDetection]) -> CGRect {
        let box = boxes[index].bounds
        let centerY = box.midY
        // Real handwriting is commonly taller than the checkbox. Keep enough vertical context
        // for ascenders and descenders, then let neighbouring checkbox rows bound the crop.
        let desiredHalfHeight = max(48, min(76, box.height * 1.25))
        var top = centerY - desiredHalfHeight
        var bottom = centerY + desiredHalfHeight

        if index > boxes.startIndex {
            let previous = boxes[index - 1].bounds
            if previous.midY < centerY {
                top = max(top, (previous.midY + centerY) / 2 + 1)
            }
        }
        if index < boxes.index(before: boxes.endIndex) {
            let next = boxes[index + 1].bounds
            if next.midY > centerY {
                bottom = min(bottom, (next.midY + centerY) / 2 - 1)
            }
        }

        let left = max(pageBounds.minX, box.maxX + max(6, box.width * 0.18))
        let right = pageBounds.maxX - 8
        top = max(pageBounds.minY, top)
        bottom = min(pageBounds.maxY, bottom)
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// Vision failures for an individual row do not discard geometry proposals. This is useful
    /// for the review UI, which can still show and let the user correct an empty task title.
    private static func recognizeText(in crop: CGRect, drawing: PKDrawing) -> (String, Float)? {
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let format = UIGraphicsImageRendererFormat(for: lightTraits)
        format.opaque = true
        format.scale = 2

        var image: UIImage?
        lightTraits.performAsCurrent {
            let renderer = UIGraphicsImageRenderer(size: crop.size, format: format)
            image = renderer.image { context in
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: crop.size))
                drawing.image(from: crop, scale: format.scale)
                    .draw(in: CGRect(origin: .zero, size: crop.size))
            }
        }

        guard let cgImage = image?.cgImage else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.12

        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return ("", 0) }
        // A checkbox crop represents one task row. Detached marks such as the dot of an i can
        // have a very different height, so horizontal position is the stable reading order.
        let ordered = observations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }

        var words: [String] = []
        var weightedConfidence: Float = 0
        var characterCount: Float = 0
        for observation in ordered {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            words.append(text)
            let weight = Float(max(text.count, 1))
            weightedConfidence += candidate.confidence * weight
            characterCount += weight
        }

        guard !words.isEmpty else { return ("", 0) }
        return (words.joined(separator: " "), weightedConfidence / max(characterCount, 1))
    }
}

/// One prior recognition pass, bounded by the engine's 30 checkbox limit. Cache entries
/// contain only successful Vision results; an empty recognized string is still a success.
struct RecognitionOCRCache {
    struct Entry {
        let crop: CGRect
        let subset: PKDrawing
        let value: (text: String, confidence: Float)
    }

    private(set) var entries: [Entry] = []

    func value(for crop: CGRect, subset: PKDrawing) -> (text: String, confidence: Float)? {
        entries.first {
            $0.crop == crop &&
                RecognitionStrokeComparison.equal($0.subset.strokes, subset.strokes)
        }?.value
    }

    mutating func replace(with entries: [Entry]) {
        self.entries = Array(entries.prefix(30))
    }

    static func visibleDrawing(in crop: CGRect, from drawing: PKDrawing) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes.filter { $0.renderBounds.intersects(crop) })
    }
}

// MARK: - Pure checkbox geometry

struct CheckboxGeometryStroke: Sendable {
    let points: [CGPoint]
    let sourceIndex: Int
}

struct CheckboxDetection: Sendable {
    let bounds: CGRect
    let sourceIndices: Set<Int>
    let geometryConfidence: Float
}

enum CheckboxDetector {
    private static let minimumSide: CGFloat = 12
    private static let maximumSide: CGFloat = 90

    /// Convenience entry point used by geometry-only unit tests.
    static func detect(
        in strokes: [[CGPoint]],
        pageBounds: CGRect = CGRect(x: 0, y: 0, width: 600, height: 800),
        limit: Int = 30
    ) -> [CheckboxDetection] {
        detect(
            strokes: strokes.enumerated().map {
                CheckboxGeometryStroke(points: $0.element, sourceIndex: $0.offset)
            },
            pageBounds: pageBounds,
            limit: limit
        )
    }

    static func detect(
        strokes: [CheckboxGeometryStroke],
        pageBounds: CGRect,
        limit: Int
    ) -> [CheckboxDetection] {
        guard limit > 0 else { return [] }

        let normalized = strokes.prefix(500).compactMap(normalize)
        var proposals: [CheckboxDetection] = []

        // A single hand-drawn, closed rectangle is the common and cheapest case.
        for stroke in normalized {
            let rectanglePoints = closedLoopPrefix(in: stroke.points)
            guard proposals.count < limit * 3,
                  let bounds = plausibleBoxBounds(for: rectanglePoints),
                  isClosedRectangle(rectanglePoints, bounds: bounds),
                  pageBounds.intersects(bounds) else { continue }
            proposals.append(
                CheckboxDetection(
                    bounds: bounds,
                    sourceIndices: [stroke.sourceIndex],
                    geometryConfidence: rectangleConfidence(for: [stroke], bounds: bounds)
                )
            )
        }

        // A checkbox may have been drawn with a separate stroke for each side. For each stroke,
        // inspect only its five nearest local neighbours, bounding combinations and runtime.
        let pieces = normalized.filter { stroke in
            let bounds = pointsBounds(stroke.points)
            let length = pathLength(stroke.points)
            return length >= 7 && length <= 260 &&
                bounds.width <= maximumSide * 1.35 && bounds.height <= maximumSide * 1.35
        }

        for seedIndex in pieces.indices {
            guard proposals.count < limit * 4 else { break }
            let seed = pieces[seedIndex]
            let seedBounds = pointsBounds(seed.points)
            let neighbourRadius = min(
                maximumSide * 1.1,
                max(14, max(seedBounds.width, seedBounds.height) + 4)
            )
            let neighbours = pieces.indices
                .filter { $0 != seedIndex }
                .map { index in
                    (index, rectangleDistance(seedBounds, pointsBounds(pieces[index].points)))
                }
                .filter { $0.1 <= neighbourRadius }
                .sorted { $0.1 < $1.1 }
                .prefix(5)
                .map(\.0)

            let localIndices = [seedIndex] + neighbours
            guard localIndices.count >= 2 else { continue }

            for subsetSize in 2...min(4, localIndices.count) {
                for combination in combinations(localIndices, choosing: subsetSize) where combination.contains(seedIndex) {
                    let group = combination.map { pieces[$0] }
                    let allPoints = group.flatMap(\.points)
                    guard let bounds = plausibleBoxBounds(for: allPoints),
                          pageBounds.intersects(bounds),
                          hasRectangleBoundary(group, bounds: bounds) else { continue }

                    proposals.append(
                        CheckboxDetection(
                            bounds: bounds,
                            sourceIndices: Set(group.map(\.sourceIndex)),
                            geometryConfidence: rectangleConfidence(for: group, bounds: bounds)
                        )
                    )
                }
            }
        }

        return deduplicated(proposals)
            .sorted {
                if abs($0.bounds.midY - $1.bounds.midY) > 3 {
                    return $0.bounds.midY < $1.bounds.midY
                }
                return $0.bounds.minX < $1.bounds.minX
            }
            .prefix(limit)
            .map { $0 }
    }

    static func isChecked(_ detection: CheckboxDetection, among strokes: [CheckboxGeometryStroke]) -> Bool {
        let normalized = strokes.compactMap(normalize)
        var possibleMarks = normalized.filter {
            !detection.sourceIndices.contains($0.sourceIndex) &&
                pointsBounds($0.points).intersects(detection.bounds.insetBy(dx: -5, dy: -5))
        }

        // A person may close the box and continue directly into a tick without lifting the
        // Pencil. The loop prefix is the boundary; only its trailing geometry is a possible mark.
        possibleMarks.append(contentsOf: normalized.compactMap { stroke in
            guard detection.sourceIndices.contains(stroke.sourceIndex) else { return nil }
            let loop = closedLoopPrefix(in: stroke.points)
            guard loop.count >= 4, loop.count + 2 < stroke.points.count else { return nil }
            let tail = Array(stroke.points[loop.count...])
            guard pathLength(tail) >= min(detection.bounds.width, detection.bounds.height) * 0.16,
                  pointsBounds(tail).intersects(detection.bounds.insetBy(dx: -5, dy: -5)) else {
                return nil
            }
            return CheckboxGeometryStroke(points: tail, sourceIndex: stroke.sourceIndex)
        })

        if possibleMarks.contains(where: { isCompleteTick($0.points, in: detection.bounds) }) {
            return true
        }

        for firstIndex in possibleMarks.indices {
            for secondIndex in possibleMarks.indices where secondIndex > firstIndex {
                let first = possibleMarks[firstIndex]
                let second = possibleMarks[secondIndex]
                guard first.sourceIndex != second.sourceIndex,
                      isTwoStrokeTick(first.points, second.points, in: detection.bounds) else { continue }
                return true
            }
        }

        let diagonalMarks = possibleMarks.filter { isBoxSpanningDiagonal($0.points, in: detection.bounds) }
        guard diagonalMarks.count >= 2 else { return false }

        for firstIndex in diagonalMarks.indices {
            for secondIndex in diagonalMarks.indices where secondIndex > firstIndex {
                let first = diagonalMarks[firstIndex].points
                let second = diagonalMarks[secondIndex].points
                guard let a = first.first, let b = first.last,
                      let c = second.first, let d = second.last else { continue }
                let firstSlope = (b.x - a.x) * (b.y - a.y)
                let secondSlope = (d.x - c.x) * (d.y - c.y)
                guard firstSlope * secondSlope < 0,
                      let intersection = segmentIntersection(a, b, c, d),
                      centralRegion(of: detection.bounds).contains(intersection) else { continue }
                return true
            }
        }
        return false
    }

    private static func normalize(_ stroke: CheckboxGeometryStroke) -> CheckboxGeometryStroke? {
        let finite = stroke.points.filter { $0.x.isFinite && $0.y.isFinite }
        guard finite.count >= 2 else { return nil }

        let maximumPoints = 256
        if finite.count <= maximumPoints {
            return CheckboxGeometryStroke(points: finite, sourceIndex: stroke.sourceIndex)
        }

        let stride = CGFloat(finite.count - 1) / CGFloat(maximumPoints - 1)
        let reduced = (0..<maximumPoints).map { finite[Int((CGFloat($0) * stride).rounded())] }
        return CheckboxGeometryStroke(points: reduced, sourceIndex: stroke.sourceIndex)
    }

    private static func plausibleBoxBounds(for points: [CGPoint]) -> CGRect? {
        let bounds = pointsBounds(points)
        guard bounds.width >= minimumSide,
              bounds.height >= minimumSide,
              bounds.width <= maximumSide,
              bounds.height <= maximumSide else { return nil }
        let aspect = bounds.width / max(bounds.height, 0.001)
        guard aspect >= 0.58, aspect <= 1.72 else { return nil }
        return bounds
    }

    private static func isClosedRectangle(_ points: [CGPoint], bounds: CGRect) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        let diagonal = hypot(bounds.width, bounds.height)
        let perimeter = 2 * (bounds.width + bounds.height)
        let length = pathLength(points)
        guard first.distance(to: last) <= max(7, diagonal * 0.24),
              length >= perimeter * 0.68,
              length <= perimeter * 1.9 else { return false }
        return hasRectangleBoundary(
            [CheckboxGeometryStroke(points: points, sourceIndex: 0)],
            bounds: bounds
        )
    }

    private static func hasRectangleBoundary(_ strokes: [CheckboxGeometryStroke], bounds: CGRect) -> Bool {
        let tolerance = max(2.5, min(bounds.width, bounds.height) * 0.13)
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY)
        ]
        let tightCornerTolerance = max(2.5, min(bounds.width, bounds.height) * 0.19)
        let roundedCornerTolerance = max(2.5, min(bounds.width, bounds.height) * 0.28)
        let allPoints = strokes.flatMap(\.points)
        let cornerDistances = corners.map { corner in
            allPoints.map { $0.distance(to: corner) }.min() ?? .greatestFiniteMagnitude
        }
        guard cornerDistances.filter({ $0 <= tightCornerTolerance }).count >= 3,
              cornerDistances.allSatisfy({ $0 <= roundedCornerTolerance }) else { return false }

        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var left: CGFloat = 0
        var right: CGFloat = 0

        for stroke in strokes {
            for (start, end) in zip(stroke.points, stroke.points.dropFirst()) {
                let dx = abs(end.x - start.x)
                let dy = abs(end.y - start.y)
                let length = hypot(dx, dy)
                guard length >= 0.5 else { continue }
                let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)

                if dx >= dy * 1.15 {
                    if abs(midpoint.y - bounds.minY) <= tolerance { top += length }
                    if abs(midpoint.y - bounds.maxY) <= tolerance { bottom += length }
                }
                if dy >= dx * 1.15 {
                    if abs(midpoint.x - bounds.minX) <= tolerance { left += length }
                    if abs(midpoint.x - bounds.maxX) <= tolerance { right += length }
                }
            }
        }

        return top >= bounds.width * 0.42 &&
            bottom >= bounds.width * 0.42 &&
            left >= bounds.height * 0.42 &&
            right >= bounds.height * 0.42
    }

    private static func rectangleConfidence(
        for strokes: [CheckboxGeometryStroke],
        bounds: CGRect
    ) -> Float {
        let aspect = min(bounds.width, bounds.height) / max(bounds.width, bounds.height)
        let strokePenalty = min(CGFloat(strokes.count - 1) * 0.025, 0.075)
        return Float(max(0.6, min(0.98, 0.72 + aspect * 0.25 - strokePenalty)))
    }

    /// Pencil input often returns to the starting corner and then continues a few points past
    /// it. Use the closest sufficiently late return as the end of the loop so that this small
    /// tail does not move one side of the candidate's bounding box.
    private static func closedLoopPrefix(in points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 5, let first = points.first else { return points }
        let bounds = pointsBounds(points)
        let perimeter = 2 * (bounds.width + bounds.height)
        let closureTolerance = max(7, hypot(bounds.width, bounds.height) * 0.24)

        var travelled: CGFloat = 0
        var closestIndex: Int?
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for index in points.indices.dropFirst() {
            travelled += points[index - 1].distance(to: points[index])
            guard travelled >= perimeter * 0.68 else { continue }
            let distance = first.distance(to: points[index])
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        guard closestDistance <= closureTolerance, let closestIndex else { return points }
        return Array(points[...closestIndex])
    }

    private static func deduplicated(_ proposals: [CheckboxDetection]) -> [CheckboxDetection] {
        let ranked = proposals.sorted { $0.geometryConfidence > $1.geometryConfidence }
        var accepted: [CheckboxDetection] = []

        for proposal in ranked {
            let duplicate = accepted.contains { existing in
                intersectionOverUnion(proposal.bounds, existing.bounds) >= 0.52 ||
                    (proposal.bounds.center.distance(to: existing.bounds.center) <= 5 &&
                     abs(proposal.bounds.width - existing.bounds.width) <= 8 &&
                     abs(proposal.bounds.height - existing.bounds.height) <= 8)
            }
            if !duplicate { accepted.append(proposal) }
        }
        return accepted
    }

    private static func isBoxSpanningDiagonal(_ points: [CGPoint], in box: CGRect) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        let expanded = box.insetBy(dx: -4, dy: -4)
        let chord = first.distance(to: last)
        let length = pathLength(points)
        let dx = abs(last.x - first.x)
        let dy = abs(last.y - first.y)
        return points.allSatisfy(expanded.contains) &&
            chord >= hypot(box.width, box.height) * 0.5 &&
            length <= chord * 1.28 &&
            dx >= box.width * 0.48 &&
            dy >= box.height * 0.48
    }

    private static func isCompleteTick(_ points: [CGPoint], in box: CGRect) -> Bool {
        guard points.count >= 3,
              let originalFirst = points.first,
              let originalLast = points.last else { return false }
        let orderedPoints = originalFirst.x <= originalLast.x
            ? points
            : Array(points.reversed())
        guard let first = orderedPoints.first, let last = orderedPoints.last else { return false }

        let lowestIndex = orderedPoints.indices.max(
            by: { orderedPoints[$0].y < orderedPoints[$1].y }
        ) ?? 0
        guard lowestIndex > orderedPoints.startIndex,
              lowestIndex < orderedPoints.index(before: orderedPoints.endIndex) else { return false }
        let vertex = orderedPoints[lowestIndex]
        let vertexRegion = box.insetBy(dx: box.width * 0.10, dy: box.height * 0.05)
        guard vertexRegion.contains(vertex) else { return false }

        let firstArm = Array(orderedPoints[...lowestIndex])
        let secondArm = Array(orderedPoints[lowestIndex...])
        let horizontalMargin = max(5, min(16, box.width * 0.22))
        let verticalMargin = max(5, min(16, box.height * 0.22))
        let nearBox = box.insetBy(dx: -horizontalMargin, dy: -verticalMargin)
        guard firstArm.allSatisfy(nearBox.contains) else { return false }

        // Natural ticks often start and turn inside the box, then finish well above and to the
        // right of it. Keep the first arm tightly associated with the box, while allowing only
        // the rising arm a proportional, capped reach in those two expected directions.
        let upperReach = min(48, max(8, box.height * 0.55))
        let rightReach = min(48, max(8, box.width * 0.55))
        let risingArmRegion = CGRect(
            x: box.minX - horizontalMargin,
            y: box.minY - upperReach,
            width: box.width + horizontalMargin + rightReach,
            height: box.height + upperReach + verticalMargin
        )
        guard secondArm.allSatisfy(risingArmRegion.contains) else { return false }

        let firstChord = first.distance(to: vertex)
        let secondChord = vertex.distance(to: last)
        let firstRise = vertex.y - first.y
        let secondRise = vertex.y - last.y

        return first.x < vertex.x && vertex.x < last.x &&
            firstRise >= box.height * 0.12 &&
            secondRise >= box.height * 0.24 &&
            secondRise >= firstRise * 0.80 &&
            last.x - first.x >= box.width * 0.28 &&
            firstChord >= box.width * 0.12 && secondChord >= box.width * 0.24 &&
            pathLength(firstArm) <= firstChord * 1.55 &&
            pathLength(secondArm) <= secondChord * 1.55
    }

    private static func isTwoStrokeTick(
        _ firstPoints: [CGPoint],
        _ secondPoints: [CGPoint],
        in box: CGRect
    ) -> Bool {
        guard let firstStart = firstPoints.first,
              let firstEnd = firstPoints.last,
              let secondStart = secondPoints.first,
              let secondEnd = secondPoints.last else { return false }

        let firstChord = firstStart.distance(to: firstEnd)
        let secondChord = secondStart.distance(to: secondEnd)
        guard firstChord >= box.width * 0.10,
              secondChord >= box.width * 0.18,
              pathLength(firstPoints) <= firstChord * 1.45,
              pathLength(secondPoints) <= secondChord * 1.45 else { return false }

        let pairings = [
            (firstStart, firstEnd, secondStart, secondEnd),
            (firstStart, firstEnd, secondEnd, secondStart),
            (firstEnd, firstStart, secondStart, secondEnd),
            (firstEnd, firstStart, secondEnd, secondStart)
        ]
        guard let joined = pairings.min(by: { lhs, rhs in
            lhs.1.distance(to: lhs.2) < rhs.1.distance(to: rhs.2)
        }) else { return false }

        let joinTolerance = max(5, min(box.width, box.height) * 0.18)
        guard joined.1.distance(to: joined.2) <= joinTolerance else { return false }
        let vertex = CGPoint(
            x: (joined.1.x + joined.2.x) / 2,
            y: (joined.1.y + joined.2.y) / 2
        )
        return isCompleteTick([joined.0, vertex, joined.3], in: box)
    }

    private static func centralRegion(of rect: CGRect) -> CGRect {
        rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
    }

    private static func pointsBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    private static func rectangleDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = max(0, max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX))
        let dy = max(0, max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY))
        return hypot(dx, dy)
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private static func combinations(_ values: [Int], choosing count: Int) -> [[Int]] {
        guard count > 0, values.count >= count else { return [] }
        if count == 1 { return values.map { [$0] } }
        if values.count == count { return [values] }

        var result: [[Int]] = []
        for index in 0...(values.count - count) {
            let head = values[index]
            let tail = Array(values[(index + 1)...])
            result.append(contentsOf: combinations(tail, choosing: count - 1).map { [head] + $0 })
        }
        return result
    }

    private static func segmentIntersection(
        _ a: CGPoint,
        _ b: CGPoint,
        _ c: CGPoint,
        _ d: CGPoint
    ) -> CGPoint? {
        let denominator = (b.x - a.x) * (d.y - c.y) - (b.y - a.y) * (d.x - c.x)
        guard abs(denominator) > 0.001 else { return nil }
        let t = ((c.x - a.x) * (d.y - c.y) - (c.y - a.y) * (d.x - c.x)) / denominator
        let u = ((c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x)) / denominator
        guard (0...1).contains(t), (0...1).contains(u) else { return nil }
        return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
