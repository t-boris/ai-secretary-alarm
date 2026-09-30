import Foundation

/// Subset of the Google Calendar v3 Event resource.
public struct GoogleEvent: Codable, Equatable, Sendable {
    public struct DateTime: Codable, Equatable, Sendable {
        public var dateTime: String?
        public var date: String?
        public var timeZone: String?

        public init(dateTime: String? = nil, date: String? = nil, timeZone: String? = nil) {
            self.dateTime = dateTime
            self.date = date
            self.timeZone = timeZone
        }
    }

    public struct ExtendedProperties: Codable, Equatable, Sendable {
        public var `private`: [String: String]?

        public init(private: [String: String]?) { self.private = `private` }
    }

    public var id: String?
    public var status: String?
    public var summary: String?
    public var description: String?
    public var location: String?
    public var start: DateTime?
    public var end: DateTime?
    public var recurrence: [String]?
    public var recurringEventId: String?
    public var originalStartTime: DateTime?
    public var extendedProperties: ExtendedProperties?
    public var htmlLink: String?

    public init(id: String? = nil, status: String? = nil, summary: String? = nil, description: String? = nil,
                location: String? = nil, start: DateTime? = nil, end: DateTime? = nil, recurrence: [String]? = nil,
                recurringEventId: String? = nil, originalStartTime: DateTime? = nil,
                extendedProperties: ExtendedProperties? = nil, htmlLink: String? = nil) {
        self.id = id
        self.status = status
        self.summary = summary
        self.description = description
        self.location = location
        self.start = start
        self.end = end
        self.recurrence = recurrence
        self.recurringEventId = recurringEventId
        self.originalStartTime = originalStartTime
        self.extendedProperties = extendedProperties
        self.htmlLink = htmlLink
    }

    public var isCancelled: Bool { status == "cancelled" }

    /// Private extended property that marks assistant-created events (DEC-009).
    public static let tagKey = "aiSecretary"
    public static let localIDKey = "aiSecretaryLocalID"

    public var isAssistantTagged: Bool { extendedProperties?.private?[Self.tagKey] == "1" }
}

public enum GoogleTime {
    public static func format(_ date: Date, in zone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public static func parse(_ value: GoogleEvent.DateTime?, fallbackZone: TimeZone) -> Date? {
        guard let value else { return nil }
        if let text = value.dateTime {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: text) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: text)
        }
        if let day = value.date {  // all-day event: midnight in the event zone
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = value.timeZone.flatMap(TimeZone.init(identifier:)) ?? fallbackZone
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: day)
        }
        return nil
    }
}

extension EventRecord {
    /// Event body written to Google Calendar, with an explicit IANA zone (DEC-013) and the private tag.
    public func googleEvent() -> GoogleEvent {
        let zone = timeZone
        var notes: [String] = []
        if let prepHint, !prepHint.isEmpty { notes.append(prepHint) }
        if !participants.isEmpty { notes.append("Participants: " + participants.joined(separator: ", ")) }
        notes.append("Created by AI Secretary Alarm.")
        return GoogleEvent(
            summary: title,
            description: notes.joined(separator: "\n"),
            location: locationText.isEmpty ? nil : locationText,
            start: .init(dateTime: GoogleTime.format(start, in: zone), timeZone: timeZoneID),
            end: .init(dateTime: GoogleTime.format(end, in: zone), timeZone: timeZoneID),
            recurrence: recurrence?.googleLines(timeZone: zone),
            extendedProperties: .init(private: [GoogleEvent.tagKey: "1", GoogleEvent.localIDKey: id.uuidString])
        )
    }

    /// Text written to the calendar's location field.
    public static func locationText(type: LocationType, place: ResolvedPlace?) -> String {
        switch type {
        case .noLocation: return ""
        case .home: return place?.address ?? "Home"
        case .offSite:
            guard let place else { return "" }
            if let name = place.name, !name.isEmpty, name.caseInsensitiveCompare(place.address) != .orderedSame {
                return "\(name), \(place.address)"
            }
            return place.address
        }
    }
}
