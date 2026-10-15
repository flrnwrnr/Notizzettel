import UIKit

enum NotePageBackground: String, Codable {
    case plain
    case ruled
}

struct NotePagePresentation: Equatable {
    // Keep the drawing width so saved strokes retain their coordinates.
    static let pageSize = CGSize(width: 600, height: 600.0 * 297.0 / 210.0)
    static let ruledNewPagesPreferenceKey = "newPagesRuled"

    let title: String
    let date: Date

    static func header(for note: Note, pageID: UUID) -> NotePagePresentation? {
        guard note.pageIDs.first == pageID, let event = note.calendarEvent else { return nil }
        return NotePagePresentation(title: event.title, date: event.startDate)
    }

    static func backgroundImage(
        background: NotePageBackground,
        header: NotePagePresentation? = nil,
        scale: CGFloat = 1
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = max(scale, 1)
        return UIGraphicsImageRenderer(size: pageSize, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: pageSize))

            if background == .ruled {
                context.setStrokeColor(UIColor(red: 0.79, green: 0.83, blue: 0.88, alpha: 1).cgColor)
                context.setLineWidth(0.6)
                for y in stride(from: CGFloat(112), through: pageSize.height - 20, by: 28) {
                    context.move(to: CGPoint(x: 20, y: y))
                    context.addLine(to: CGPoint(x: pageSize.width - 20, y: y))
                }
                context.strokePath()
            }

            header?.drawHeader()
        }
    }

    func headerImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: Self.pageSize.width, height: 96), format: format
        ).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: Self.pageSize.width, height: 96))
            drawHeader()
        }
    }

    private func drawHeader() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        paragraph.lineSpacing = 1
        (title as NSString).draw(
            with: CGRect(x: 24, y: 12, width: 368, height: 72),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: UIFont.systemFont(ofSize: 27, weight: .semibold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph
            ],
            context: nil
        )

        let dateParagraph = NSMutableParagraphStyle()
        dateParagraph.alignment = .right
        dateParagraph.lineBreakMode = .byClipping
        (Self.dateFormatter.string(from: date) as NSString).draw(
            in: CGRect(x: 408, y: 18, width: 168, height: 32),
            withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: dateParagraph
            ]
        )
    }

    var accessibilityLabel: String {
        "\(title), \(Self.dateFormatter.string(from: date))"
    }

    func composite(rawDrawingImage: UIImage, background: NotePageBackground = .plain) -> UIImage {
        Self.composite(rawDrawingImage: rawDrawingImage, background: background, header: self)
    }

    static func composite(
        rawDrawingImage: UIImage,
        background: NotePageBackground,
        header: NotePagePresentation?,
        scale: CGFloat = 1
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = max(scale, 1)
        return UIGraphicsImageRenderer(size: pageSize, format: format).image { _ in
            backgroundImage(background: background, header: header, scale: scale).draw(at: .zero)
            rawDrawingImage.draw(at: .zero)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()
}
