import Foundation

/// Failures of the cloud AI; each maps to a clear message and no event is created (REQ-001).
public enum AIError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case offline
    case badResponse(String)
    case service(String)

    public func message(_ language: SpeechLanguage) -> String {
        let ru = language == .ru
        switch self {
        case .missingAPIKey:
            return ru ? "Не задан ключ OpenAI API. Укажите его в настройках. Событие не создано."
                      : "The OpenAI API key is not set. Add it in Settings. No event was created."
        case .invalidAPIKey:
            return ru ? "Ключ OpenAI API недействителен. Проверьте его в настройках. Событие не создано."
                      : "The OpenAI API key is invalid. Check it in Settings. No event was created."
        case .offline:
            return ru ? "Нет подключения к интернету. Событие не создано; уже запланированные напоминания сработают."
                      : "You're offline. No event was created; already scheduled reminders will still fire."
        case let .badResponse(detail), let .service(detail):
            return (ru ? "Ошибка AI-сервиса: " : "AI service error: ") + detail
                + (ru ? ". Событие не создано." : ". No event was created.")
        }
    }
}

public struct ChatTurn: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var role: Role
    public var text: String

    public init(_ role: Role, _ text: String) {
        self.role = role
        self.text = text
    }
}

public struct ParseContext: Sendable {
    public var now: Date
    public var localZone: TimeZone
    public var savedPlaceNames: [String]
    public var prepMinutesByType: [EventType: Int]

    public init(now: Date, localZone: TimeZone, savedPlaceNames: [String], prepMinutesByType: [EventType: Int]) {
        self.now = now
        self.localZone = localZone
        self.savedPlaceNames = savedPlaceNames
        self.prepMinutesByType = prepMinutesByType
    }
}

/// Structured output of the parser model.
public struct ParsedRequest: Codable, Equatable, Sendable {
    public enum Intent: String, Codable, Sendable { case create_event, confirm, cancel, other }
    public enum ParsedLocationType: String, Codable, Sendable { case home, off_site, no_location, unknown }

    public struct ParsedRecurrence: Codable, Equatable, Sendable {
        public var frequency: Recurrence.Frequency
        public var interval: Int
        public var by_weekday: [Weekday]
        public var count: Int?
        public var until_local: String?
    }

    public struct ParsedEvent: Codable, Equatable, Sendable {
        public var kind: RequestKind? = nil
        public var title: String?
        public var start_local: String?
        public var time_zone: String?
        public var duration_minutes: Int?
        public var recurrence: ParsedRecurrence?
        public var participants: [String]
        public var location_type: ParsedLocationType
        public var place_name: String?
        public var address: String?
        public var event_type: EventType
        public var prep_minutes: Int?
        public var prep_hint: String?
    }

    public var intent: Intent
    public var language: SpeechLanguage
    public var question: String?
    public var event: ParsedEvent
}

public protocol RequestParsing: Sendable {
    func parse(conversation: [ChatTurn], context: ParseContext) async throws -> ParsedRequest
}

/// Prompt and JSON schema for the OpenAI chat completions request (DEC-019).
public enum ParserPrompt {
    public static func system(_ c: ParseContext) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = c.localZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm, EEEE"
        let places = c.savedPlaceNames.isEmpty ? "none" : c.savedPlaceNames.joined(separator: ", ")
        let preps = EventType.allCases.map { "\($0.rawValue) \(c.prepMinutesByType[$0] ?? 10) min" }.joined(separator: ", ")
        return """
        You parse spoken requests for a personal assistant that sets local reminders or creates Google Calendar events.
        The user speaks Russian, English, or a mix of both. Reply only with JSON matching the schema.

        Current local date and time: \(f.string(from: c.now)), time zone \(c.localZone.identifier).

        Rules:
        - kind is "reminder" for a one-time reminder, alert, or notification, even about an existing meeting.
          A reminder rings locally at start_local and never creates a new Google Calendar event. If no subject is given,
          title is "Reminder" (or "Напоминание"). Do not ask for a location for a reminder.
        - kind is "habit" when the user asks for a daily consistency check, to track whether something was done,
          or to be reminded to do a task every day. A habit is local, repeats daily, and lets the user mark each day done.
          Set recurrence to DAILY, even if the user does not use the word "repeat". Ask for a time only if none was given.
        - kind is "calendar_event" only when the user asks to schedule or create a meeting, appointment, training,
          or other calendar event. Do not turn a simple reminder into a calendar event.
        - Use a short action title, such as "Принять таблетки" or "Take medication". Remove speech fillers,
          false starts, and phrases like "что мне пора" or "remind me that I need to" while preserving the task's meaning.
        - Resolve relative dates ("today", "tomorrow", "сегодня", "в пятницу") against the current local date.
        - start_local is the wall-clock start "YYYY-MM-DDTHH:MM". If the user names a time zone or city for the time \
        (e.g. "10:30 London time"), set time_zone to its IANA id and give start_local in that zone; otherwise time_zone is null.
        - For recurring requests ("every Mon/Wed/Fri at 6 pm", "каждый понедельник"), fill recurrence and set start_local \
        to the first matching occurrence that is not in the past. by_weekday uses MO,TU,WE,TH,FR,SA,SU.
        - title: short, in the user's language; keep proper names exactly as spoken (e.g. "Manoj").
        - participants: people named in the request.
        - location_type: "home" if it happens at home; "no_location" for calls, online or video meetings and plain \
        reminders without a place; "off_site" when a place other than home is named; "unknown" when the event normally \
        happens somewhere (training, doctor, dinner, ...) but no place was said.
        - place_name: the short name of the place as said ("gym", "спортзал", "office"). If it matches a saved place, \
        use the saved name exactly. Saved places: \(places).
        - address: a street address or searchable place description if one was said, else null.
        - event_type: one of training, meeting, appointment, social, other. Default preparation times: \(preps).
        - prep_minutes: only if the user said how long they need to get ready, else null.
        - prep_hint: at most 2 short sentences on how to prepare (e.g. "Change into sports clothes and take water."), \
        in the user's language, or null if there is nothing useful.
        - duration_minutes: if said, else null.
        - question: for a reminder or habit, ask only if the reminder time is missing. For a calendar event, ask if the title \
        or start time is missing, or location_type is "unknown". Ask one short question in the user's language; otherwise null.
        - intent: "create_event" for requests and corrections, "confirm" if the user only agrees ("yes", "да"), \
        "cancel" if the user wants to stop, "other" if it is not about an event.
        - The conversation may include your earlier questions, the user's answers and a draft summary. Always return \
        the complete, updated event, applying the user's corrections.
        - language: "ru" if the user mainly speaks Russian, else "en".
        """
    }

    public static var jsonSchema: [String: Any] {
        func nullable(_ type: String) -> [String: Any] { ["type": [type, "null"]] }
        let weekday: [String: Any] = ["type": "string", "enum": Weekday.allCases.map(\.rawValue)]
        let recurrence: [String: Any] = [
            "type": ["object", "null"],
            "additionalProperties": false,
            "required": ["frequency", "interval", "by_weekday", "count", "until_local"],
            "properties": [
                "frequency": ["type": "string", "enum": Recurrence.Frequency.allCases.map(\.rawValue)],
                "interval": ["type": "integer"],
                "by_weekday": ["type": "array", "items": weekday],
                "count": nullable("integer"),
                "until_local": nullable("string"),
            ],
        ]
        let event: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "start_local", "time_zone", "duration_minutes", "recurrence", "participants",
                         "location_type", "place_name", "address", "event_type", "prep_minutes", "prep_hint", "kind"],
            "properties": [
                "kind": ["type": "string", "enum": [RequestKind.reminder.rawValue, RequestKind.habit.rawValue,
                                                    RequestKind.calendarEvent.rawValue]],
                "title": nullable("string"),
                "start_local": nullable("string"),
                "time_zone": nullable("string"),
                "duration_minutes": nullable("integer"),
                "recurrence": recurrence,
                "participants": ["type": "array", "items": ["type": "string"]],
                "location_type": ["type": "string", "enum": ["home", "off_site", "no_location", "unknown"]],
                "place_name": nullable("string"),
                "address": nullable("string"),
                "event_type": ["type": "string", "enum": EventType.allCases.map(\.rawValue)],
                "prep_minutes": nullable("integer"),
                "prep_hint": nullable("string"),
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["intent", "language", "question", "event"],
            "properties": [
                "intent": ["type": "string", "enum": ["create_event", "confirm", "cancel", "other"]],
                "language": ["type": "string", "enum": ["ru", "en"]],
                "question": nullable("string"),
                "event": event,
            ],
        ]
    }

    /// Full chat completions request body.
    public static func requestBody(model: String, conversation: [ChatTurn], context: ParseContext) throws -> Data {
        var messages: [[String: String]] = [["role": "system", "content": system(context)]]
        messages += conversation.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "event_request", "strict": true, "schema": jsonSchema],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Extracts the parsed request from a chat completions response.
    public static func decodeResponse(_ data: Data) throws -> ParsedRequest {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String?; var refusal: String? }
                var message: Message
            }
            var choices: [Choice]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let message = response.choices.first?.message else { throw AIError.badResponse("empty response") }
        if let refusal = message.refusal { throw AIError.badResponse(refusal) }
        guard let content = message.content?.data(using: .utf8) else { throw AIError.badResponse("no content") }
        do {
            return try JSONDecoder().decode(ParsedRequest.self, from: content)
        } catch {
            throw AIError.badResponse("unreadable parse result")
        }
    }
}

/// A fully resolved event awaiting confirmation (DEC-015).
public struct EventDraft: Equatable, Sendable {
    public var kind: RequestKind = .calendarEvent
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneID: String
    public var recurrence: Recurrence?
    public var participants: [String]
    public var locationType: LocationType
    public var place: ResolvedPlace?
    /// Name to store as a new saved place (DEC-023), nil when the place is known or unnamed.
    public var newPlaceName: String?
    public var savePlace: Bool
    public var eventType: EventType
    public var alarmSoundID: String?
    public var prepMinutes: Int
    public var prepHint: String?
    public var origin: OriginChoice
    public var language: SpeechLanguage
    /// Travel estimate at creation, if one was obtained.
    public var travelSeconds: TimeInterval?

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    public func makeRecord(id: UUID = UUID(), createdAt: Date) -> EventRecord {
        var record = EventRecord(
            id: id, kind: kind, title: title, start: start, end: end, timeZoneID: timeZoneID, recurrence: recurrence,
            participants: participants, locationType: locationType, place: place,
            locationText: EventRecord.locationText(type: locationType, place: place),
            eventType: eventType, alarmSoundID: alarmSoundID, prepMinutes: prepMinutes, prepHint: prepHint, origin: origin,
            language: language, createdAt: createdAt)
        if let travelSeconds {
            record.travel[OccurrenceKey.make(start)] = TravelEstimate(seconds: travelSeconds, computedAt: createdAt)
        }
        return record
    }
}

public enum LocalTimeParser {
    /// Parses "YYYY-MM-DDTHH:MM" (optionally with seconds) as wall-clock time in `zone`.
    public static func date(_ text: String, zone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    /// Zone for the event: a valid named IANA zone (DEC-026), else the Mac zone (DEC-013).
    public static func zone(named: String?, fallback: TimeZone) -> TimeZone {
        named.flatMap(TimeZone.init(identifier:)) ?? fallback
    }

    public static func recurrence(_ p: ParsedRequest.ParsedRecurrence?, zone: TimeZone) -> Recurrence? {
        guard let p else { return nil }
        var until: Date?
        if let text = p.until_local, let day = date(text, zone: zone) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            until = cal.date(bySettingHour: 23, minute: 59, second: 59, of: day)
        }
        return Recurrence(frequency: p.frequency, interval: max(1, p.interval), byWeekday: p.by_weekday,
                          count: p.count, until: until)
    }
}
