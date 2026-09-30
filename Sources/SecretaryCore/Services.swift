import Foundation

// Protocols for every external dependency, so the domain logic is testable offline.

public enum CalendarError: Error, Equatable, Sendable {
    case notSignedIn
    /// Refresh token revoked or invalid: user must sign in again (DEC-012).
    case authExpired
    case notFound
    /// HTTP 410 on incremental sync: full resync required (DEC-009).
    case syncTokenExpired
    case network(String)
    case server(Int, String)
}

public struct GoogleEventPage: Sendable {
    public var items: [GoogleEvent]
    public var nextSyncToken: String?

    public init(items: [GoogleEvent], nextSyncToken: String?) {
        self.items = items
        self.nextSyncToken = nextSyncToken
    }
}

public protocol CalendarService: Sendable {
    func insert(_ event: GoogleEvent) async throws -> GoogleEvent
    func delete(eventID: String) async throws
    func get(eventID: String) async throws -> GoogleEvent
    /// The instance of a recurring event with this original start, including a cancelled one.
    func instance(eventID: String, originalStart: Date, timeZone: TimeZone) async throws -> GoogleEvent?
    /// Instances of a recurring event starting in a time range (used for rules the app cannot expand).
    func instances(eventID: String, timeMin: Date, timeMax: Date) async throws -> [GoogleEvent]
    /// Full list (syncToken nil) or incremental changes; follows pagination.
    func list(syncToken: String?) async throws -> GoogleEventPage
    /// Timed events and expanded recurring instances near a proposed start.
    func nearbyEvents(around start: Date) async throws -> [GoogleEvent]
}

public protocol TravelEstimating: Sendable {
    func travelTime(from: Coordinate, to: Coordinate, mode: TransportMode, departure: Date) async throws -> TimeInterval
}

public struct GeocodedAddress: Equatable, Sendable {
    public var address: String
    public var coordinate: Coordinate

    public init(address: String, coordinate: Coordinate) {
        self.address = address
        self.coordinate = coordinate
    }
}

public protocol Geocoding: Sendable {
    /// Nil when nothing was found.
    func geocode(_ query: String, near: Coordinate?) async throws -> GeocodedAddress?
}

public struct LocationFix: Equatable, Sendable {
    public var coordinate: Coordinate
    public var timestamp: Date

    public init(coordinate: Coordinate, timestamp: Date) {
        self.coordinate = coordinate
        self.timestamp = timestamp
    }
}

public protocol LocationProviding: Sendable {
    func latestFix() async -> LocationFix?
}

/// Regenerates the preparation hint after a synced title/location change (DEC-016).
public protocol HintGenerating: Sendable {
    func preparationHint(title: String, eventType: EventType, locationType: LocationType,
                         place: String?, language: SpeechLanguage) async throws -> String?
}

public struct AlarmContent: Codable, Equatable, Sendable {
    public var reminderKey: String
    public var eventID: UUID
    public var kind: ReminderKind
    public var heading: String
    public var body: String
    public var spokenText: String
    public var soundID: String
    public var language: SpeechLanguage
}

public struct SnoozedAlarm: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var content: AlarmContent
    public var fireDate: Date

    public init(id: UUID = UUID(), content: AlarmContent, fireDate: Date) {
        self.id = id
        self.content = content
        self.fireDate = fireDate
    }
}

/// Presents alarm music, optional speech, and the persistent panel.
@MainActor
public protocol AlarmPresenting: AnyObject {
    func present(_ alarm: AlarmContent) async
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) -> String?
    func write(_ value: String?, for key: SecretKey) throws
}

public enum SecretKey: String, CaseIterable, Sendable {
    case openAIAPIKey = "openai-api-key"
    case googleClientID = "google-client-id"
    case googleClientSecret = "google-client-secret"
    case googleRefreshToken = "google-refresh-token"
}
