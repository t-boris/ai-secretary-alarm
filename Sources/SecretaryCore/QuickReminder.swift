import Foundation

public struct QuickReminder: Equatable, Sendable {
    public let title: String
    public let dueAt: Date
    public let language: SpeechLanguage
}

/// Handles unambiguous relative reminders locally, without waiting for a model or opening a window.
public enum QuickReminderParser {
    public static func parse(_ text: String, now: Date) -> QuickReminder? {
        let language: SpeechLanguage = text.range(of: "\\p{Cyrillic}", options: .regularExpression) == nil ? .en : .ru
        let marker = language == .ru ? "напомни|напоминани[ея]" : "remind|reminder"
        guard text.range(of: marker, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        // Repeating reminders and habit checks need the full parser so their recurrence is retained.
        let recurringOrHabit = language == .ru
            ? #"(?i)кажд(?:ый|ую|ое|ые|ого)|ежедневн|еженедельн|по\s+будням|привычк|проверяй|контролируй"#
            : #"(?i)every\s+|each\s+|daily|weekly|habit|check[ -]?in|track\s+whether"#
        guard text.range(of: recurringOrHabit, options: .regularExpression) == nil else { return nil }

        let pattern = language == .ru
            ? #"через\s+(?:(\d+)\s*)?(полчас(?:а|ика)?|час(?:а|ов|ик(?:а|ов)?)?|минут(?:у|ы|ку|ки)?|мин)\b"#
            : #"in\s+(?:(\d+|an?|one)\s+)?(half\s+an?\s+hour|hours?|minutes?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }

        let unit = text[unitRange].lowercased()
        let count: Double
        if unit.contains("полчас") || unit.contains("half") {
            count = 0.5
        } else if let numberRange = Range(match.range(at: 1), in: text),
                  let number = Double(text[numberRange]) {
            count = number
        } else {
            count = 1
        }
        let seconds = count * ((unit.contains("час") || unit.contains("hour")) ? 3600 : 60)
        guard (60...30 * 86_400).contains(seconds) else { return nil }

        var subject = text.replacingCharacters(in: whole, with: " ")
        let prefix = language == .ru
            ? #"(?i)^\s*(?:(?:сделай|поставь|создай|установи)\s+(?:мне\s+)?напоминание|напомни(?:\s+мне)?)(?:\s+(?:о|про|чтобы))?\s*"#
            : #"(?i)^\s*(?:remind\s+me|(?:set|make)\s+(?:me\s+)?(?:a\s+)?reminder)(?:\s+(?:to|about))?\s*"#
        let withoutCommand = subject.replacingOccurrences(of: prefix, with: "", options: .regularExpression)
        guard withoutCommand != subject else { return nil }
        subject = withoutCommand
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let filler = language == .ru
            ? #"(?i)^(?:(?:о\s+том,?\s+)?что|чтобы)\s+(?:(?:мне|нам)\s+)?(?:(?:пора|нужно|надо)\s+)?|^(?:(?:мне|нам)\s+)?(?:пора|нужно|надо)\s+"#
            : #"(?i)^(?:that\s+)?(?:I\s+need\s+to|it's\s+time\s+to|to)\s+"#
        subject = subject.replacingOccurrences(of: filler, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let first = subject.first { subject.replaceSubrange(subject.startIndex...subject.startIndex, with: String(first).uppercased()) }
        if subject.isEmpty { subject = language == .ru ? "Напоминание" : "Reminder" }
        return QuickReminder(title: subject, dueAt: now.addingTimeInterval(seconds), language: language)
    }
}
