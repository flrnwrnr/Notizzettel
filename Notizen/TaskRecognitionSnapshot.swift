import CoreGraphics
import Foundation
import PencilKit

/// Keeps proposals whose checkbox and surrounding text could not have changed.
enum TaskRecognitionSnapshot {
    static func unchangedCandidates(
        _ candidates: [TaskCandidate],
        from analyzedData: Data,
        to currentData: Data
    ) async -> [TaskCandidate] {
        guard !candidates.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let analyzed = try? PKDrawing(data: analyzedData),
                  let current = try? PKDrawing(data: currentData) else { return [] }

            return candidates.filter { candidate in
                guard !Task.isCancelled else { return false }
                // textCrop reaches 76 pt above/below the box. A neighbouring checkbox can
                // split that crop from as far as 152 pt away. Include the complete box and
                // a little beyond the page edges for strokes crossing the page boundary.
                let dependency = CGRect(x: -90, y: candidate.bounds.midY - 152,
                                        width: 780, height: 304)
                    .union(candidate.bounds)
                let oldStrokes = analyzed.strokes.filter { $0.renderBounds.intersects(dependency) }
                let newStrokes = current.strokes.filter { $0.renderBounds.intersects(dependency) }
                return RecognitionStrokeComparison.equal(oldStrokes, newStrokes)
            }
        }.value
    }
}
