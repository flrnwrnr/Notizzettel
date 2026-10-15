import CryptoKit
import Foundation
import PencilKit
import UIKit
import Vision

struct NoteSearchResult: Identifiable {
    let noteID: UUID
    let pageID: UUID
    let pageNumber: Int
    let customerName: String?
    let eventTitle: String?
    let snippet: String
    let updatedAt: Date

    var id: UUID { pageID }
}

enum NoteSearchScope {
    case all
    case customer(UUID)
    case unassigned
}

struct NoteSearchIndexProgress {
    var completed = 0
    var total = 0
    var failed = 0
    var isIndexing = false
}

enum NoteSearchIndex {
    static let version = 1

    struct Entry: Codable {
        let hash: String
        let text: String
    }

    struct File: Codable {
        let version: Int
        var pages: [UUID: Entry]
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// This function is called from a detached task, so rendering and Vision never block the UI.
    static func recognize(_ drawingData: Data) async throws -> String {
        try Task.checkCancellation()
        let drawing = try PKDrawing(data: drawingData)
        guard !drawing.strokes.isEmpty else { return "" }

        let size = NotePagePresentation.pageSize
        let traits = UITraitCollection(userInterfaceStyle: .light)
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.opaque = true
        format.scale = 2
        var imageData: Data?
        traits.performAsCurrent {
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: size))
                drawing.image(from: CGRect(origin: .zero, size: size), scale: format.scale)
                    .draw(in: CGRect(origin: .zero, size: size))
            }
            imageData = image.pngData()
        }
        guard let imageData else { throw CocoaError(.fileReadCorruptFile) }

        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: imageData, options: [:]).perform([request])
        try Task.checkCancellation()

        let ordered = (request.results ?? []).sorted { left, right in
            let leftRow = Int((1 - left.boundingBox.midY) / 0.012)
            let rightRow = Int((1 - right.boundingBox.midY) / 0.012)
            if leftRow != rightRow { return leftRow < rightRow }
            return left.boundingBox.minX < right.boundingBox.minX
        }
        return ordered.compactMap {
            $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}
