import Foundation
import UIKit
import Vision

enum ObsidianExportContent {
    struct Output {
        let baseName: String
        let pdfData: Data
        let markdown: String
    }

    enum ExportError: LocalizedError {
        case noPages
        case invalidPage(Int)

        var errorDescription: String? {
            switch self {
            case .noPages:
                return "Die Notiz enthält keine exportierbaren Seiten."
            case .invalidPage(let number):
                return "Seite \(number) konnte für die Texterkennung nicht gerendert werden."
            }
        }
    }

    /// `pages` contains finished page images, including background, calendar header and ink.
    @MainActor
    static func make(note: Note, customerName: String?, pages: [UIImage]) async throws -> Output {
        guard !pages.isEmpty else { throw ExportError.noPages }

        var imageData: [Data] = []
        imageData.reserveCapacity(pages.count)
        for (index, page) in pages.enumerated() {
            guard let data = page.pngData() else { throw ExportError.invalidPage(index + 1) }
            imageData.append(data)
        }

        let pageSize = NotePagePresentation.pageSize
        let bounds = CGRect(origin: .zero, size: pageSize)
        let pdfData = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            for page in pages {
                renderer.beginPage()
                page.draw(in: bounds)
            }
        }

        // Vision runs off the main actor. A failed request throws so the caller can retry the
        // complete export instead of leaving a Markdown file that only appears searchable.
        let recognizedPages = try await Task.detached(priority: .utility) {
            try imageData.map { try recognizeText(in: $0) }
        }.value

        let baseName = "Notiz-\(fileDateFormatter.string(from: note.createdAt))-\(note.id.uuidString.lowercased())"
        let title = (note.calendarEvent?.title ?? "Notiz vom \(displayDateFormatter.string(from: note.createdAt))")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let customer = customerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            "---",
            "note_id: \(note.id.uuidString.lowercased())",
            "created: \(metadataDateFormatter.string(from: note.createdAt))",
            "updated: \(metadataDateFormatter.string(from: note.updatedAt))",
            "customer: \(yamlString(customer ?? ""))",
            "---",
            "",
            "# \(title)",
            "",
            "![[\(baseName).pdf]]",
            "",
            "## Erkannter Text",
            ""
        ]
        for (index, text) in recognizedPages.enumerated() {
            lines.append("### Seite \(index + 1)")
            lines.append("")
            lines.append(text.isEmpty ? "*Kein Text erkannt.*" : text)
            lines.append("")
        }

        return Output(baseName: baseName, pdfData: pdfData, markdown: lines.joined(separator: "\n"))
    }

    private static func recognizeText(in imageData: Data) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: imageData, options: [:]).perform([request])

        let observations = request.results ?? []
        // Vision coordinates start at the bottom; sort top to bottom, then left to right.
        let ordered = observations.sorted { left, right in
            let leftRow = Int((1 - left.boundingBox.midY) / 0.012)
            let rightRow = Int((1 - right.boundingBox.midY) / 0.012)
            if leftRow != rightRow { return leftRow < rightRow }
            return left.boundingBox.minX < right.boundingBox.minX
        }
        return ordered.compactMap { observation in
            observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func yamlString(_ value: String) -> String {
        let oneLine = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "'\(oneLine.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let metadataDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
