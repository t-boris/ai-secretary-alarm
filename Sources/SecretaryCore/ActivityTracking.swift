import Foundation

/// A durable snapshot of a task the assistant was asked to create.
public struct ActivityHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var eventID: UUID
    public var title: String
    public var kind: RequestKind
    public var createdAt: Date
    public var scheduledAt: Date
    public var recurring: Bool

    public init(record: EventRecord) {
        id = record.id
        eventID = record.id
        title = record.title
        kind = record.kind ?? .calendarEvent
        createdAt = record.createdAt
        scheduledAt = record.start
        recurring = record.recurrence != nil
    }
}

/// A stopwatch session for one project; nil `endedAt` means it is currently running.
public struct ProjectTimerSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var project: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: UUID = UUID(), project: String, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.project = project
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public func elapsed(at now: Date) -> TimeInterval { max(0, (endedAt ?? now).timeIntervalSince(startedAt)) }
}

public struct ProjectTimeTotal: Equatable, Sendable {
    public var project: String
    public var seconds: TimeInterval
}

public enum ActivityStatistics {
    public static func projectTotals(_ sessions: [ProjectTimerSession], from cutoff: Date? = nil,
                                     now: Date) -> [ProjectTimeTotal] {
        var totals: [String: TimeInterval] = [:]
        var displayNames: [String: String] = [:]
        for session in sessions {
            let key = session.project.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let start = max(session.startedAt, cutoff ?? .distantPast)
            let seconds = max(0, min(session.endedAt ?? now, now).timeIntervalSince(start))
            guard seconds > 0 else { continue }
            totals[key, default: 0] += seconds
            displayNames[key] = displayNames[key] ?? session.project
        }
        return totals.map { ProjectTimeTotal(project: displayNames[$0.key] ?? $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    public static func durationText(_ seconds: TimeInterval, language: SpeechLanguage = .en) -> String {
        let minutes = max(0, Int(seconds / 60))
        let hours = minutes / 60
        let rest = minutes % 60
        if minutes == 0 {
            if seconds <= 0 { return language == .ru ? "0 мин" : "0 min" }
            return language == .ru ? "<1 мин" : "<1 min"
        }
        if hours == 0 { return language == .ru ? "\(rest) мин" : "\(rest) min" }
        return language == .ru ? "\(hours) ч \(rest) мин" : "\(hours)h \(rest)m"
    }
}

public enum TimerCommand: Equatable, Sendable {
    case start(project: String)
    case startNeedsProject
    case stop
    case summary(project: String?)
}

/// Conservative local parsing prevents a project stopwatch from being mistaken for a countdown reminder.
public enum TimerCommandParser {
    public static func parse(_ text: String) -> TimerCommand? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ru = input.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
        if ru {
            if input.range(of: #"(?i)\b(?:останови|выключи|закончи|заверши)\s+(?:мой\s+)?таймер\b"#,
                           options: .regularExpression) != nil { return .stop }
            if input.range(of: #"(?i)\bсколько\b.*\b(?:потратил|тратил|работал)\b"#,
                           options: .regularExpression) != nil {
                return .summary(project: project(in: input, russian: true))
            }
            guard input.range(of: #"(?i)\b(?:запусти|включи|начни|поставь|засеки)\b"#,
                              options: .regularExpression) != nil,
                  input.range(of: #"(?i)\b(?:таймер|уч[её]т\s+времени|отслеживание\s+времени)\b"#,
                              options: .regularExpression) != nil else { return nil }
            if let name = project(in: input, russian: true) { return .start(project: name) }
            if input.range(of: #"(?i)\bна\s+\d+\s*(?:минут|мин|час)"#,
                           options: .regularExpression) != nil { return nil }
            return .startNeedsProject
        }
        if input.range(of: #"(?i)\b(?:stop|end|finish)\s+(?:my\s+|the\s+)?timer\b"#,
                       options: .regularExpression) != nil { return .stop }
        if input.range(of: #"(?i)\bhow\s+(?:much|long).*\b(?:time|spent|work|worked)\b"#,
                       options: .regularExpression) != nil {
            return .summary(project: project(in: input, russian: false))
        }
        guard input.range(of: #"(?i)\b(?:start|begin|run|track)\b"#, options: .regularExpression) != nil,
              input.range(of: #"(?i)\b(?:timer|time\s+tracking)\b"#, options: .regularExpression) != nil else { return nil }
        if let name = project(in: input, russian: false) { return .start(project: name) }
        if input.range(of: #"(?i)\bfor\s+\d+\s*(?:minutes?|hours?)"#,
                       options: .regularExpression) != nil { return nil }
        return .startNeedsProject
    }

    private static func project(in input: String, russian: Bool) -> String? {
        let pattern = russian ? #"(?i)\bпроект(?:ом|а|у|е)?\s+(.+)$"#
                              : #"(?i)\bproject\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else { return nil }
        let name = input[range].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return name.isEmpty ? nil : name
    }
}
