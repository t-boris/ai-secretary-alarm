import Foundation

/// Where an event takes place (DEC-011).
public enum LocationType: String, Codable, Sendable, CaseIterable {
    case home
    case offSite
    case noLocation
}

/// Fixed list of event types; each has an editable preparation time (DEC-022).
public enum EventType: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
    case training, meeting, appointment, social, other

    public static let defaultPrepMinutes: [EventType: Int] = [
        .training: 15, .meeting: 5, .appointment: 10, .social: 10, .other: 10,
    ]
}

/// Transport modes supported by MapKit ETA (DEC-020).
public enum TransportMode: String, Codable, Sendable, CaseIterable {
    case driving, transit, walking
}

public struct Coordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A named place remembered by the assistant (DEC-011). Home is reserved (DEC-023).
public struct SavedPlace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var coordinate: Coordinate
    public var isHome: Bool

    public init(id: UUID = UUID(), name: String, address: String, coordinate: Coordinate, isHome: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.isHome = isHome
    }
}

/// A geocoded destination attached to an event.
public struct ResolvedPlace: Codable, Equatable, Sendable {
    public var name: String?
    public var address: String
    public var coordinate: Coordinate?

    public init(name: String?, address: String, coordinate: Coordinate?) {
        self.name = name
        self.address = address
        self.coordinate = coordinate
    }
}

/// Travel origin for an off-site event (DEC-014).
public enum OriginChoice: Codable, Hashable, Sendable {
    /// Mac location if a fix is at most 30 minutes old, otherwise home.
    case automatic
    /// A saved place (including home) chosen during confirmation.
    case place(UUID)
}

/// Per-occurrence change coming from Google Calendar (DEC-009).
public struct OccurrenceOverride: Codable, Equatable, Sendable {
    public var cancelled: Bool
    public var start: Date?
    public var end: Date?
    public var title: String?
    public var locationType: LocationType?
    public var place: ResolvedPlace?
    /// Raw calendar location text of this occurrence when it differs from the series.
    public var locationText: String?
    /// Hint regenerated for an occurrence whose title or location was changed on its own (DEC-016).
    public var prepHint: String?

    public init(cancelled: Bool = false, start: Date? = nil, end: Date? = nil, title: String? = nil,
                locationType: LocationType? = nil, place: ResolvedPlace? = nil, locationText: String? = nil) {
        self.cancelled = cancelled
        self.start = start
        self.end = end
        self.title = title
        self.locationType = locationType
        self.place = place
        self.locationText = locationText
    }
}

/// Latest travel-time estimate for one occurrence.
public struct TravelEstimate: Codable, Equatable, Sendable {
    public var seconds: TimeInterval
    public var computedAt: Date

    public init(seconds: TimeInterval, computedAt: Date) {
        self.seconds = seconds
        self.computedAt = computedAt
    }
}

public enum SpeechLanguage: String, Codable, Sendable {
    case ru, en
}

public enum AlarmCloudVoice: String, Codable, Sendable, CaseIterable {
    case cedar, marin, onyx, coral, nova, ash, alloy, ballad, echo, fable, sage, shimmer, verse
}

public enum RussianSpeechStyle: String, Codable, Sendable, CaseIterable {
    case gentleJapanese
    case natural
}

public enum AlarmSpeechDirection {
    public static func instructions(language: SpeechLanguage, russianStyle: RussianSpeechStyle) -> String {
        if language == .ru {
            switch russianStyle {
            case .gentleJapanese:
                return "Speak entirely in Russian with a light but clearly audible Japanese accent and melodic Japanese intonation, like a friendly Japanese speaker who speaks Russian fluently. Keep every Russian word intelligible. Sound warm and playful, never robotic or exaggerated. Do not switch languages or add Japanese words."
            case .natural:
                return "Speak entirely in clear Russian, with a warm, calm, natural voice. Sound like a friendly person, never robotic."
            }
        }
        return "Speak in clear English with a warm, calm, natural voice. Sound like a friendly person, never robotic."
    }
}

/// A local alarm is independent of Google Calendar; a calendar event may also have alarms.
public enum RequestKind: String, Codable, Sendable {
    case reminder
    case habit
    case calendarEvent = "calendar_event"
}

/// A calendar event tracked by the app for reminders (DEC-003).
public struct EventRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var googleEventID: String?
    /// Nil is a calendar event for records saved before this distinction was added.
    public var kind: RequestKind?
    /// False for an existing calendar event linked for reminders. Nil means true for older saved records.
    public var managesGoogleEvent: Bool?
    public var htmlLink: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneID: String
    public var recurrence: Recurrence?
    public var participants: [String]
    public var locationType: LocationType
    public var place: ResolvedPlace?
    /// Location text as written to Google Calendar; used to detect location edits.
    public var locationText: String
    public var eventType: EventType
    /// Optional per-event sound; nil uses the current sound for this event type.
    public var alarmSoundID: String?
    public var prepMinutes: Int
    public var prepHint: String?
    public var origin: OriginChoice
    public var language: SpeechLanguage
    public var createdAt: Date
    /// Keyed by `OccurrenceKey` of the original start.
    public var overrides: [String: OccurrenceOverride]
    /// Keyed by `OccurrenceKey` of the original start.
    public var travel: [String: TravelEstimate]

    public init(id: UUID = UUID(), googleEventID: String? = nil, kind: RequestKind? = nil,
                managesGoogleEvent: Bool? = true,
                htmlLink: String? = nil, title: String,
                start: Date, end: Date, timeZoneID: String, recurrence: Recurrence? = nil,
                participants: [String] = [], locationType: LocationType, place: ResolvedPlace? = nil,
                locationText: String = "", eventType: EventType = .other, alarmSoundID: String? = nil,
                prepMinutes: Int = 10,
                prepHint: String? = nil, origin: OriginChoice = .automatic, language: SpeechLanguage = .en,
                createdAt: Date, overrides: [String: OccurrenceOverride] = [:],
                travel: [String: TravelEstimate] = [:]) {
        self.id = id
        self.googleEventID = googleEventID
        self.kind = kind
        self.managesGoogleEvent = managesGoogleEvent
        self.htmlLink = htmlLink
        self.title = title
        self.start = start
        self.end = end
        self.timeZoneID = timeZoneID
        self.recurrence = recurrence
        self.participants = participants
        self.locationType = locationType
        self.place = place
        self.locationText = locationText
        self.eventType = eventType
        self.alarmSoundID = alarmSoundID
        self.prepMinutes = prepMinutes
        self.prepHint = prepHint
        self.origin = origin
        self.language = language
        self.createdAt = createdAt
        self.overrides = overrides
        self.travel = travel
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var isStandaloneReminder: Bool { kind == .reminder || kind == .habit }
    public var isHabit: Bool { kind == .habit }
}

public enum OccurrenceKey {
    public static func make(_ originalStart: Date) -> String {
        String(Int64(originalStart.timeIntervalSince1970.rounded()))
    }
}

/// User settings that are not secrets (secrets live in the Keychain, DEC-012).
public struct AppSettings: Codable, Equatable, Sendable {
    public var homeLeadMinutes: Int
    public var fallbackBufferMinutes: Int
    public var transportMode: TransportMode
    public var prepMinutesByType: [EventType: Int]
    public var alarmSoundsByType: [EventType: String]
    public var transcriptionModel: String
    public var chatModel: String
    public var alarmCloudVoice: AlarmCloudVoice
    public var alarmRussianStyle: RussianSpeechStyle
    public var alarmSpeechEnabled: Bool
    public var launchAtLogin: Bool

    /// Defaults from DEC-022 and DEC-027.
    public init(homeLeadMinutes: Int = 5, fallbackBufferMinutes: Int = 45, transportMode: TransportMode = .driving,
                prepMinutesByType: [EventType: Int] = EventType.defaultPrepMinutes,
                alarmSoundsByType: [EventType: String] = [:],
                transcriptionModel: String = "gpt-4o-transcribe", chatModel: String = "gpt-4.1",
                alarmCloudVoice: AlarmCloudVoice = .cedar,
                alarmRussianStyle: RussianSpeechStyle = .gentleJapanese,
                alarmSpeechEnabled: Bool = true,
                launchAtLogin: Bool = true) {
        self.homeLeadMinutes = homeLeadMinutes
        self.fallbackBufferMinutes = fallbackBufferMinutes
        self.transportMode = transportMode
        self.prepMinutesByType = prepMinutesByType
        self.alarmSoundsByType = alarmSoundsByType
        self.transcriptionModel = transcriptionModel
        self.chatModel = chatModel
        self.alarmCloudVoice = alarmCloudVoice
        self.alarmRussianStyle = alarmRussianStyle
        self.alarmSpeechEnabled = alarmSpeechEnabled
        self.launchAtLogin = launchAtLogin
    }

    private enum CodingKeys: String, CodingKey {
        case homeLeadMinutes, fallbackBufferMinutes, transportMode, prepMinutesByType, alarmSoundsByType,
             transcriptionModel, chatModel,
             alarmCloudVoice, alarmRussianStyle, alarmSpeechEnabled,
             launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        homeLeadMinutes = try c.decodeIfPresent(Int.self, forKey: .homeLeadMinutes) ?? d.homeLeadMinutes
        fallbackBufferMinutes = try c.decodeIfPresent(Int.self, forKey: .fallbackBufferMinutes) ?? d.fallbackBufferMinutes
        transportMode = try c.decodeIfPresent(TransportMode.self, forKey: .transportMode) ?? d.transportMode
        prepMinutesByType = try c.decodeIfPresent([EventType: Int].self, forKey: .prepMinutesByType) ?? d.prepMinutesByType
        alarmSoundsByType = try c.decodeIfPresent([EventType: String].self, forKey: .alarmSoundsByType) ?? [:]
        transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? d.transcriptionModel
        chatModel = try c.decodeIfPresent(String.self, forKey: .chatModel) ?? d.chatModel
        alarmCloudVoice = try c.decodeIfPresent(AlarmCloudVoice.self, forKey: .alarmCloudVoice) ?? d.alarmCloudVoice
        alarmRussianStyle = try c.decodeIfPresent(RussianSpeechStyle.self, forKey: .alarmRussianStyle) ?? d.alarmRussianStyle
        alarmSpeechEnabled = try c.decodeIfPresent(Bool.self, forKey: .alarmSpeechEnabled) ?? d.alarmSpeechEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }

    public func prepMinutes(for type: EventType) -> Int {
        prepMinutesByType[type] ?? EventType.defaultPrepMinutes[type] ?? 10
    }

    public func alarmSound(for type: EventType) -> String {
        alarmSoundsByType[type] ?? "built-in:\(type.rawValue)"
    }
}
