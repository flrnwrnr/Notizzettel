import Foundation
import XCTest

@testable import Notizen

final class TaskDueDateParserTests: XCTestCase {
    private let anchor = TaskDueDate(year: 2026, month: 9, day: 28)

    func testClearDatesAndRelativeDaysAreAutomatic() {
        let cases: [(String, TaskDueDate, String)] = [
            ("Rechnung bis 02.10.2026 zahlen", day(2026, 10, 2), "02.10.2026"),
            ("Rechnung bis 02.10.2026.", day(2026, 10, 2), "02.10.2026"),
            ("Paket am 2.10. abholen", day(2026, 10, 2), "2.10."),
            ("Abgabe 2026-10-02", day(2026, 10, 2), "2026-10-02"),
            ("heute anrufen", day(2026, 9, 28), "heute"),
            ("morgen einkaufen", day(2026, 9, 29), "morgen"),
            ("übermorgen schreiben", day(2026, 9, 30), "übermorgen"),
            ("in 5 Tagen nachfragen", day(2026, 10, 3), "in 5 Tagen")
        ]

        for (text, expectedDate, sourceText) in cases {
            guard case .automatic(let suggestion) = TaskDueDateParser.parse(
                text, referenceDate: anchor, confidence: 0.98
            ) else {
                XCTFail("Expected automatic date in: \(text)")
                continue
            }
            XCTAssertEqual(suggestion.date, expectedDate, text)
            XCTAssertEqual(suggestion.sourceText, sourceText, text)
            XCTAssertFalse(suggestion.reason.isEmpty, text)
        }
    }

    func testInvalidDatesAndNonDueReferencesAreIgnored() {
        let texts = [
            "Besprechung vom 02.10. nachbereiten",
            "Besprechung am 02.10. nachbereiten",
            "Am Morgen Unterlagen sortieren",
            "Protokoll seit 2026-10-02 prüfen",
            "31.02.2026 korrigieren",
            "29.02.2027 korrigieren",
            "Version 1.2.3 prüfen",
            "Anruf bei 0171.12.10. vorbereiten",
            "Ticket A02.10. prüfen"
        ]
        for text in texts {
            XCTAssertEqual(TaskDueDateParser.parse(
                text, referenceDate: anchor, confidence: 0.99
            ), .none, text)
        }

        guard case .automatic(let due) = TaskDueDateParser.parse(
            "Protokoll vom 02.10. bis 04.10. abgeben",
            referenceDate: anchor, confidence: 0.99
        ) else {
            return XCTFail("The due phrase should select its own date")
        }
        XCTAssertEqual(due.date, day(2026, 10, 4))
        XCTAssertEqual(due.sourceText, "04.10.")
    }

    func testAmbiguousDatesRequireReview() {
        let cases: [(String, TaskDueDate, TaskDueDate, String)] = [
            ("bis 25.09.", anchor, day(2026, 9, 25), "25.09."),
            ("bis 25.09.2026", anchor, day(2026, 9, 25), "25.09.2026"),
            ("bis 2026-09-25", anchor, day(2026, 9, 25), "2026-09-25"),
            ("bis 02.01.", day(2026, 12, 29), day(2027, 1, 2), "02.01."),
            ("bis 02.10. oder 03.10.", anchor, day(2026, 10, 2), "02.10."),
            ("nächsten Freitag anrufen", anchor, day(2026, 10, 2), "nächsten Freitag"),
            ("Freitag anrufen", anchor, day(2026, 10, 2), "Freitag"),
            ("Ende nächster Woche abgeben", anchor, day(2026, 10, 11), "Ende nächster Woche")
        ]
        for (text, reference, expectedDate, sourceText) in cases {
            guard case .proposal(let suggestion) = TaskDueDateParser.parse(
                text, referenceDate: reference, confidence: 0.98
            ) else {
                XCTFail("Expected review proposal in: \(text)")
                continue
            }
            XCTAssertEqual(suggestion.date, expectedDate, text)
            XCTAssertEqual(suggestion.sourceText, sourceText, text)
            XCTAssertTrue(suggestion.reason.contains("prüfen"), text)
        }
    }

    func testConfidenceAndRelativeDateSettingRequireReview() {
        let lowConfidence = TaskDueDateParser.parse(
            "fällig 02.10.2026", referenceDate: anchor, confidence: 0.84
        )
        guard case .proposal(let uncertain) = lowConfidence else {
            return XCTFail("Low OCR confidence must not assign a date automatically")
        }
        XCTAssertEqual(uncertain.date, day(2026, 10, 2))

        let relativeDisabled = TaskDueDateParser.parse(
            "morgen abgeben", referenceDate: anchor, confidence: 0.99,
            allowsRelativeDates: false
        )
        guard case .proposal(let relative) = relativeDisabled else {
            return XCTFail("Disabled relative dates should remain reviewable")
        }
        XCTAssertEqual(relative.date, day(2026, 9, 29))
        XCTAssertEqual(relative.sourceText, "morgen")
    }

    func testClearTimesAttachedToDatesAreAutomatic() {
        let cases: [(String, TaskDueDate, String)] = [
            ("morgen 16 Uhr anrufen", TaskDueDate(year: 2026, month: 9, day: 29, hour: 16, minute: 0), "morgen 16 Uhr"),
            ("bis 02.10. 16:30 abgeben", TaskDueDate(year: 2026, month: 10, day: 2, hour: 16, minute: 30), "02.10. 16:30"),
            ("2026-10-02 um 9 Uhr abgeben", TaskDueDate(year: 2026, month: 10, day: 2, hour: 9, minute: 0), "2026-10-02 um 9 Uhr")
        ]
        for (text, expectedDate, sourceText) in cases {
            guard case .automatic(let suggestion) = TaskDueDateParser.parse(
                text, referenceDate: anchor, confidence: 0.99
            ) else { XCTFail("Expected automatic time: \(text)"); continue }
            XCTAssertEqual(suggestion.date, expectedDate)
            XCTAssertEqual(suggestion.sourceText, sourceText)
        }
    }

    func testUnclearOrMultipleTimesRequireReviewAndTimeWithoutDateIsIgnored() {
        XCTAssertEqual(TaskDueDateParser.parse(
            "um 16 Uhr anrufen", referenceDate: anchor, confidence: 0.99
        ), .none)
        for text in ["morgen 16 Uhr oder 17 Uhr anrufen", "morgen abgeben um 16 Uhr", "morgen 25 Uhr anrufen"] {
            guard case .proposal(let suggestion) = TaskDueDateParser.parse(
                text, referenceDate: anchor, confidence: 0.99
            ) else { XCTFail("Expected time proposal: \(text)"); continue }
            XCTAssertTrue(suggestion.reason.contains("prüfen"))
        }
    }

    func testCalendarArithmeticAndSuggestionCoding() throws {
        guard case .automatic(let suggestion) = TaskDueDateParser.parse(
            "in 3 Tagen", referenceDate: day(2028, 2, 27), confidence: 0.99
        ) else {
            return XCTFail("Expected valid leap-year arithmetic")
        }
        XCTAssertEqual(suggestion.date, day(2028, 3, 1))
        XCTAssertEqual(
            try JSONDecoder().decode(TaskDueDateSuggestion.self, from: JSONEncoder().encode(suggestion)),
            suggestion
        )

        guard case .automatic(let yearEnd) = TaskDueDateParser.parse(
            "morgen", referenceDate: day(2026, 12, 31), confidence: 0.99
        ) else {
            return XCTFail("Expected new-year arithmetic")
        }
        XCTAssertEqual(yearEnd.date, day(2027, 1, 1))
        guard case .automatic(let leapDay) = TaskDueDateParser.parse(
            "29.02.2028", referenceDate: anchor, confidence: 0.99
        ) else {
            return XCTFail("Leap day should be valid")
        }
        XCTAssertEqual(leapDay.date, day(2028, 2, 29))
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> TaskDueDate {
        TaskDueDate(year: year, month: month, day: day)
    }
}
