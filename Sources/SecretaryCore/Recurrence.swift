import Foundation

public enum Weekday: String, Codable, Sendable, CaseIterable {
    case MO, TU, WE, TH, FR, SA, SU

    /// `Calendar` weekday number (Sunday = 1).
    public var calendarWeekday: Int {
        switch self {
        case .SU: return 1
        case .MO: return 2
        case .TU: return 3
        case .WE: return 4
        case .TH: return 5
        case .FR: return 6
        case .SA: return 7
        }
    }

    public init?(calendarWeekday: Int) {
        guard let match = Weekday.allCases.first(where: { $0.calendarWeekday == calendarWeekday }) else { return nil }
        self = match
    }
}

/// Subset of RFC 5545 RRULE used by the assistant and by Google Calendar edits.
public struct Recurrence: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    }

    public var frequency: Frequency
    public var interval: Int
    public var byWeekday: [Weekday]
    public var count: Int?
    public var until: Date?
    /// Original starts removed via EXDATE lines.
    public var exceptionDates: [Date]
    /// True when Google holds a rule this parser cannot expand (e.g. BYDAY=1MO, BYMONTHDAY, HOURLY).
    /// Occurrences then come from the Google instances API (`explicitStarts`).
    public var needsInstances: Bool = false
    /// Original starts listed by Google for rules in `needsInstances` mode, refreshed on every sync.
    public var explicitStarts: [Date]?

    public init(frequency: Frequency, interval: Int = 1, byWeekday: [Weekday] = [], count: Int? = nil,
                until: Date? = nil, exceptionDates: [Date] = []) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.byWeekday = byWeekday
        self.count = count
        self.until = until
        self.exceptionDates = exceptionDates
    }

    private enum CodingKeys: String, CodingKey {
        case frequency, interval, byWeekday, count, until, exceptionDates, needsInstances, explicitStarts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Frequency.self, forKey: .frequency)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        byWeekday = try c.decodeIfPresent([Weekday].self, forKey: .byWeekday) ?? []
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        until = try c.decodeIfPresent(Date.self, forKey: .until)
        exceptionDates = try c.decodeIfPresent([Date].self, forKey: .exceptionDates) ?? []
        needsInstances = try c.decodeIfPresent(Bool.self, forKey: .needsInstances) ?? false
        explicitStarts = try c.decodeIfPresent([Date].self, forKey: .explicitStarts)
    }

    // MARK: - RRULE text

    /// Lines for the Google Calendar `recurrence` field.
    public func googleLines(timeZone: TimeZone) -> [String] {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if !byWeekday.isEmpty { parts.append("BYDAY=" + byWeekday.map(\.rawValue).joined(separator: ",")) }
        if let count { parts.append("COUNT=\(count)") }
        if let until { parts.append("UNTIL=" + Self.utcStamp.string(from: until)) }
        var lines = ["RRULE:" + parts.joined(separator: ";")]
        if !exceptionDates.isEmpty {
            let local = Self.localStampFormatter(timeZone)
            lines.append("EXDATE;TZID=\(timeZone.identifier):" + exceptionDates.map { local.string(from: $0) }.joined(separator: ","))
        }
        return lines
    }

    /// Parses Google `recurrence` lines. Returns nil when no RRULE is present or it is unsupported.
    public static func parse(googleLines lines: [String], timeZone: TimeZone) -> Recurrence? {
        var result: Recurrence?
        var exdates: [Date] = []
        for line in lines {
            if line.hasPrefix("RRULE:") {
                result = parseRule(String(line.dropFirst("RRULE:".count)), timeZone: timeZone)
            } else if line.hasPrefix("EXDATE") {
                exdates += parseExdate(line, defaultZone: timeZone)
            }
        }
        result?.exceptionDates = exdates
        return result
    }

    private static func parseRule(_ rule: String, timeZone: TimeZone) -> Recurrence? {
        var fields: [String: String] = [:]
        for pair in rule.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0].uppercased()] = kv[1] }
        }
        guard let freqText = fields["FREQ"] else { return nil }
        let interval = fields["INTERVAL"].flatMap(Int.init) ?? 1
        let dayTokens = (fields["BYDAY"] ?? "").split(separator: ",").map(String.init)
        let days = dayTokens.compactMap { Weekday(rawValue: $0) }
        let count = fields["COUNT"].flatMap(Int.init)
        let until = fields["UNTIL"].flatMap { text -> Date? in
            // A DATE-only UNTIL includes that whole day (RFC 5545).
            text.count == 8 ? parseStamp(text, zone: timeZone)?.addingTimeInterval(86_399) : parseStamp(text, zone: timeZone)
        }
        let supportedKeys: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "COUNT", "UNTIL", "WKST"]
        let freq = Frequency(rawValue: freqText)
        var result = Recurrence(frequency: freq ?? .daily, interval: interval, byWeekday: days, count: count, until: until)
        // Monthly/yearly BYDAY and ordinal weekdays ("1MO") are not expanded locally either.
        result.needsInstances = freq == nil
            || !Set(fields.keys).isSubset(of: supportedKeys)
            || days.count != dayTokens.count
            || (!days.isEmpty && (freq == .monthly || freq == .yearly))
        return result
    }

    private static func parseExdate(_ line: String, defaultZone: TimeZone) -> [Date] {
        guard let colon = line.firstIndex(of: ":") else { return [] }
        let params = line[..<colon]
        var zone = defaultZone
        if let tzRange = params.range(of: "TZID=") {
            let id = params[tzRange.upperBound...].split(separator: ";").first.map(String.init) ?? ""
            zone = TimeZone(identifier: id) ?? defaultZone
        }
        return line[line.index(after: colon)...].split(separator: ",").compactMap { parseStamp(String($0), zone: zone) }
    }

    static func parseStamp(_ text: String, zone: TimeZone) -> Date? {
        if text.hasSuffix("Z") { return utcStamp.date(from: text) }
        if text.count == 8 {  // DATE form
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "yyyyMMdd"
            return f.date(from: text)
        }
        return localStampFormatter(zone).date(from: text)
    }

    private static let utcStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static func localStampFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }

    // MARK: - Expansion

    /// Original starts of occurrences, in order, anchored to wall-clock time in `timeZone` (DEC-013).
    /// Stops after `limit` or once past `through`. EXDATEs are removed but still count toward COUNT.
    public func originalStarts(dtstart: Date, timeZone: TimeZone, through: Date, limit: Int = 5000) -> [Date] {
        let excludedKeys = Set(exceptionDates.map { OccurrenceKey.make($0) })
        if needsInstances {
            return (explicitStarts ?? []).filter { $0 <= through && !excludedKeys.contains(OccurrenceKey.make($0)) }.sorted()
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2  // WKST=MO
        let time = calendar.dateComponents([.hour, .minute, .second], from: dtstart)
        let excluded = excludedKeys

        var results: [Date] = []
        var produced = 0
        func accept(_ date: Date) -> Bool {  // returns false to stop
            if date < dtstart { return true }
            if let until, date > until { return false }
            if date > through { return false }
            if let count, produced >= count { return false }
            produced += 1
            if !excluded.contains(OccurrenceKey.make(date)) { results.append(date) }
            return produced < limit
        }
        func at(_ day: Date) -> Date? {
            calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
        }

        let startDay = calendar.startOfDay(for: dtstart)
        switch frequency {
        case .daily:
            var step = 0
            while let day = calendar.date(byAdding: .day, value: step * interval, to: startDay), let d = at(day) {
                if !accept(d) { break }
                step += 1
            }
        case .weekly:
            let days = byWeekday.isEmpty
                ? [Weekday(calendarWeekday: calendar.component(.weekday, from: dtstart)) ?? .MO]
                : byWeekday
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: dtstart)?.start else { return [] }
            var week = 0
            outer: while let base = calendar.date(byAdding: .weekOfYear, value: week * interval, to: weekStart) {
                let candidates = days.compactMap { wd -> Date? in
                    let offset = (wd.calendarWeekday - calendar.firstWeekday + 7) % 7
                    return calendar.date(byAdding: .day, value: offset, to: base).flatMap(at)
                }.sorted()
                for d in candidates where !accept(d) { break outer }
                week += 1
                if week > 100_000 { break }
            }
        case .monthly, .yearly:
            let unit: Calendar.Component = frequency == .monthly ? .month : .year
            let dayOfMonth = calendar.component(.day, from: dtstart)
            var step = 0
            while let shifted = calendar.date(byAdding: unit, value: step * interval, to: startDay) {
                step += 1
                // Skip months that do not contain the day (e.g. the 31st), per RFC 5545.
                var comps = calendar.dateComponents([.year, .month], from: shifted)
                comps.day = dayOfMonth
                guard let day = calendar.date(from: comps),
                      calendar.component(.day, from: day) == dayOfMonth,
                      let d = at(day) else { continue }
                if !accept(d) { break }
                if step > 100_000 { break }
            }
        }
        return results
    }
}
