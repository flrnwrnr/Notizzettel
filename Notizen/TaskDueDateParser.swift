import Foundation

struct TaskDueDateSuggestion: Codable, Equatable, Sendable {
    let date: TaskDueDate
    let sourceText: String
    let reason: String
}

enum TaskDueDateParseResult: Equatable {
    case none
    case automatic(TaskDueDateSuggestion)
    case proposal(TaskDueDateSuggestion)
}

/// Extracts a possible due day from OCR text. It never changes the task title.
enum TaskDueDateParser {
    private struct Candidate {
        let range: NSRange
        let date: TaskDueDate
        let sourceText: String
        let reason: String
        let needsReview: Bool
        let isRelative: Bool
        let hasDueCue: Bool
    }

    private struct TimeCandidate {
        let range: NSRange
        let hour: Int
        let minute: Int
        let isValid: Bool
    }

    private static let numericDate = expression(
        #"(?<![\p{L}\p{N}._/+-])(\d{1,2})\.(\d{1,2})\.(?:(\d{4})(?![\p{L}\p{N}_/+-]|\.\d)|(?![\p{L}\p{N}._/+-]))"#
    )
    private static let isoDate = expression(
        #"(?<![\p{L}\p{N}._/+-])(\d{4})-(\d{2})-(\d{2})(?![\p{L}\p{N}._/+-])"#
    )
    private static let relativeDate = expression(
        #"\b(übermorgen|uebermorgen|morgen|heute|in\s+(\d{1,3})\s+Tagen?)\b"#
    )
    private static let nextWeekday = expression(
        #"\b(?:(nächsten|naechsten)\s+)?(Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag)\b"#
    )
    private static let endOfNextWeek = expression(
        #"\bEnde\s+(?:der\s+)?nächster\s+Woche\b|\bEnde\s+(?:der\s+)?nächsten\s+Woche\b"#
    )
    private static let dueCue = expression(
        #"\b(?:bis|fällig|faellig|Frist|spätestens|spaetestens)\s*(?::|\s)?\s*(?:(?:zum|am)\s+)?$"#
    )
    private static let historicalCue = expression(#"\b(?:vom|seit)\s*$"#)
    private static let eventReferenceCue = expression(
        #"\b(?:Besprechung|Meeting|Sitzung|Termin|Konferenz)\s+am\s*$"#
    )
    private static let nonDateCue = expression(#"\b(?:Version|Build|Revision|Rev\.?|Telefon|Tel\.?)\s*$"#)
    private static let morningNounCue = expression(#"\b(?:am|vom|heutigen)\s*$"#)
    private static let clockTime = expression(
        #"(?<![\p{L}\p{N}:])(?:um\s+)?(\d{1,2}):(\d{2})(?:\s*Uhr\b)?(?![\p{L}\p{N}:])"#
    )
    private static let hourTime = expression(
        #"(?<![\p{L}\p{N}:])(?:um\s+)?(\d{1,2})\s*Uhr\b"#
    )

    static func parse(
        _ text: String,
        referenceDate: TaskDueDate,
        confidence: Float,
        allowsRelativeDates: Bool = true
    ) -> TaskDueDateParseResult {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var candidates: [Candidate] = []

        for match in isoDate.matches(in: text, range: fullRange) {
            guard let year = number(match, at: 1, in: source),
                  let month = number(match, at: 2, in: source),
                  let day = number(match, at: 3, in: source),
                  TaskDueDate.isValid(year: year, month: month, day: day),
                  let context = context(for: match.range, in: source) else { continue }
            let date = TaskDueDate(year: year, month: month, day: day)
            let isPast = isBefore(date, referenceDate)
            candidates.append(Candidate(
                range: match.range, date: date,
                sourceText: source.substring(with: match.range),
                reason: isPast ? "Datum liegt zurück; bitte prüfen." : "Datum im Text erkannt.",
                needsReview: isPast, isRelative: false, hasDueCue: context
            ))
        }

        for match in numericDate.matches(in: text, range: fullRange) {
            guard let day = number(match, at: 1, in: source),
                  let month = number(match, at: 2, in: source),
                  let hasDueCue = context(for: match.range, in: source) else { continue }
            let explicitYear = number(match, at: 3, in: source)
            var year = explicitYear ?? referenceDate.year
            var reason = "Datum im Text erkannt."
            var needsReview = false
            guard TaskDueDate.isValid(year: year, month: month, day: day) else { continue }

            if explicitYear == nil {
                let sameYear = TaskDueDate(year: year, month: month, day: day)
                if isBefore(sameYear, referenceDate) {
                    if referenceDate.month >= 11, month <= 2, year < 9999,
                       TaskDueDate.isValid(year: year + 1, month: month, day: day) {
                        let nextYear = TaskDueDate(year: year + 1, month: month, day: day)
                        if daysBetween(referenceDate, nextYear) <= 90 {
                            year += 1
                            reason = "Jahr an der Jahresgrenze unklar; bitte prüfen."
                        } else {
                            reason = "Datum ohne Jahr liegt zurück; bitte prüfen."
                        }
                    } else {
                        reason = "Datum ohne Jahr liegt zurück; bitte prüfen."
                    }
                    needsReview = true
                }
            } else if isBefore(TaskDueDate(year: year, month: month, day: day), referenceDate) {
                reason = "Datum liegt zurück; bitte prüfen."
                needsReview = true
            }
            guard TaskDueDate.isValid(year: year, month: month, day: day) else { continue }
            candidates.append(Candidate(
                range: match.range, date: TaskDueDate(year: year, month: month, day: day),
                sourceText: source.substring(with: match.range), reason: reason,
                needsReview: needsReview, isRelative: false, hasDueCue: hasDueCue
            ))
        }

        for match in relativeDate.matches(in: text, range: fullRange) {
            guard let hasDueCue = context(for: match.range, in: source) else { continue }
            let phrase = source.substring(with: match.range).lowercased()
            if phrase == "morgen", prefixMatches(morningNounCue, before: match.range, in: source) {
                continue
            }
            let offset: Int
            switch phrase {
            case "heute": offset = 0
            case "morgen": offset = 1
            case "übermorgen", "uebermorgen": offset = 2
            default:
                guard let days = number(match, at: 2, in: source), days <= 365 else { continue }
                offset = days
            }
            guard let date = addingDays(offset, to: referenceDate) else { continue }
            candidates.append(Candidate(
                range: match.range, date: date, sourceText: source.substring(with: match.range),
                reason: "Relative Datumsangabe erkannt.", needsReview: false,
                isRelative: true, hasDueCue: hasDueCue
            ))
        }

        let weekdays = ["montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5,
                        "freitag": 6, "samstag": 7, "sonntag": 1]
        for match in nextWeekday.matches(in: text, range: fullRange) {
            guard let hasDueCue = context(for: match.range, in: source),
                  let weekday = weekdays[source.substring(with: match.range(at: 2)).lowercased()] else {
                continue
            }
            let today = weekdayNumber(referenceDate)
            let offset = (weekday - today + 7 - 1) % 7 + 1
            guard let date = addingDays(offset, to: referenceDate) else { continue }
            candidates.append(Candidate(
                range: match.range, date: date, sourceText: source.substring(with: match.range),
                reason: "Wochentag kann unterschiedlich gemeint sein; bitte prüfen.",
                needsReview: true, isRelative: true, hasDueCue: hasDueCue
            ))
        }

        for match in endOfNextWeek.matches(in: text, range: fullRange) {
            guard let hasDueCue = context(for: match.range, in: source) else { continue }
            let today = weekdayNumber(referenceDate)
            let daysUntilSunday = (1 - today + 7) % 7
            guard let date = addingDays(daysUntilSunday + 7, to: referenceDate) else { continue }
            candidates.append(Candidate(
                range: match.range, date: date, sourceText: source.substring(with: match.range),
                reason: "Ende nächster Woche als Sonntag vorgeschlagen; bitte prüfen.",
                needsReview: true, isRelative: true, hasDueCue: hasDueCue
            ))
        }

        candidates.sort { $0.range.location < $1.range.location }
        guard !candidates.isEmpty else { return .none }
        let selected = candidates.first(where: \.hasDueCue) ?? candidates[0]
        let times = timeCandidates(in: text, source: source, range: fullRange)
        let attachedTime = times.first { time in
            guard time.range.location >= NSMaxRange(selected.range) else { return false }
            let gap = source.substring(with: NSRange(
                location: NSMaxRange(selected.range),
                length: time.range.location - NSMaxRange(selected.range)
            ))
            return gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let validAttachedTime = attachedTime.map { time in
            time.isValid && TaskDueDate.isValid(
                year: selected.date.year, month: selected.date.month, day: selected.date.day,
                hour: time.hour, minute: time.minute
            )
        } ?? false
        let timeNeedsReview = !times.isEmpty && (times.count != 1 || !validAttachedTime)
        let selectedDate: TaskDueDate
        if let attachedTime, validAttachedTime {
            selectedDate = TaskDueDate(
                year: selected.date.year, month: selected.date.month, day: selected.date.day,
                hour: attachedTime.hour, minute: attachedTime.minute
            )
        } else {
            selectedDate = selected.date
        }
        let needsReview = candidates.count > 1 || selected.needsReview || timeNeedsReview ||
            confidence < 0.85 || (selected.isRelative && !allowsRelativeDates)
        let reason: String
        if candidates.count > 1 {
            reason = "Mehrere Datumsangaben erkannt; bitte Fälligkeit prüfen."
        } else if timeNeedsReview {
            reason = "Uhrzeit unklar oder mehrfach erkannt; bitte prüfen."
        } else if selected.isRelative && !allowsRelativeDates {
            reason = "Relative Datumsangabe benötigt Bestätigung."
        } else if confidence < 0.85 {
            reason = "Handschrifterkennung unsicher; Datum bitte prüfen."
        } else {
            reason = selected.reason
        }
        let sourceText: String
        if let attachedTime, validAttachedTime {
            sourceText = source.substring(with: NSRange(
                location: selected.range.location,
                length: NSMaxRange(attachedTime.range) - selected.range.location
            ))
        } else {
            sourceText = selected.sourceText
        }
        let suggestion = TaskDueDateSuggestion(
            date: selectedDate, sourceText: sourceText, reason: reason
        )
        return needsReview ? .proposal(suggestion) : .automatic(suggestion)
    }

    private static func timeCandidates(
        in text: String, source: NSString, range: NSRange
    ) -> [TimeCandidate] {
        let clockMatches = clockTime.matches(in: text, range: range)
        let hourMatches = hourTime.matches(in: text, range: range).filter { hourMatch in
            !clockMatches.contains { NSIntersectionRange($0.range, hourMatch.range).length > 0 }
        }
        return (clockMatches + hourMatches).compactMap { match in
            guard let hour = number(match, at: 1, in: source) else { return nil }
            let minute = match.numberOfRanges > 2 ? (number(match, at: 2, in: source) ?? 0) : 0
            return TimeCandidate(
                range: match.range, hour: hour, minute: minute,
                isValid: (0...23).contains(hour) && (0...59).contains(minute)
            )
        }.sorted { $0.range.location < $1.range.location }
    }

    /// Returns nil for dates mentioned as history or as part of a version/phone label.
    private static func context(for range: NSRange, in source: NSString) -> Bool? {
        let hasDueCue = prefixMatches(dueCue, before: range, in: source)
        if !hasDueCue && (prefixMatches(historicalCue, before: range, in: source) ||
                          prefixMatches(eventReferenceCue, before: range, in: source) ||
                          prefixMatches(nonDateCue, before: range, in: source)) {
            return nil
        }
        return hasDueCue
    }

    private static func prefixMatches(
        _ expression: NSRegularExpression, before range: NSRange, in source: NSString
    ) -> Bool {
        let start = max(0, range.location - 48)
        let prefix = source.substring(with: NSRange(location: start, length: range.location - start))
        let prefixRange = NSRange(location: 0, length: (prefix as NSString).length)
        return expression.firstMatch(in: prefix, range: prefixRange) != nil
    }

    private static func number(_ match: NSTextCheckingResult, at index: Int, in source: NSString) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return Int(source.substring(with: range))
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // Static, known patterns. A malformed pattern is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func isBefore(_ lhs: TaskDueDate, _ rhs: TaskDueDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func dateValue(_ day: TaskDueDate) -> Date? {
        calendar().date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
    }

    private static func addingDays(_ amount: Int, to day: TaskDueDate) -> TaskDueDate? {
        guard let start = dateValue(day),
              let result = calendar().date(byAdding: .day, value: amount, to: start) else { return nil }
        let parts = calendar().dateComponents([.year, .month, .day], from: result)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              TaskDueDate.isValid(year: year, month: month, day: day) else { return nil }
        return TaskDueDate(year: year, month: month, day: day)
    }

    private static func weekdayNumber(_ day: TaskDueDate) -> Int {
        calendar().component(.weekday, from: dateValue(day)!)
    }

    private static func daysBetween(_ first: TaskDueDate, _ second: TaskDueDate) -> Int {
        calendar().dateComponents([.day], from: dateValue(first)!, to: dateValue(second)!).day ?? 0
    }
}
