import Foundation
@testable import SecretaryCore

let moscow = TimeZone(identifier: "Europe/Moscow")!

/// Wall-clock date in Moscow, e.g. d(2026, 10, 5, 18, 0).
func d(_ y: Int, _ mo: Int, _ day: Int, _ h: Int, _ mi: Int = 0, zone: TimeZone = moscow) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = zone
    return c.date(from: DateComponents(year: y, month: mo, day: day, hour: h, minute: mi))!
}

let gym = Coordinate(latitude: 55.75, longitude: 37.61)
let homeCoord = Coordinate(latitude: 55.70, longitude: 37.50)
let homePlace = SavedPlace(name: "Home", address: "Home street 1", coordinate: homeCoord, isHome: true)

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}

final class FakeCalendar: CalendarService, @unchecked Sendable {
    let inserted = Box<[GoogleEvent]>([])
    let events = Box<[String: GoogleEvent]>([:])
    let instances = Box<[String: GoogleEvent]>([:])
    let pages = Box<[Result<GoogleEventPage, CalendarError>]>([])
    let listCalls = Box<[String?]>([])
    let failure = Box<CalendarError?>(nil)
    let nearby = Box<[GoogleEvent]>([])

    func insert(_ event: GoogleEvent) async throws -> GoogleEvent {
        if let f = failure.get { throw f }
        var e = event
        e.id = "g\(inserted.get.count + 1)"
        e.htmlLink = "https://calendar.google.com/event?eid=\(e.id!)"
        inserted.mutate { $0.append(e) }
        return e
    }

    func delete(eventID: String) async throws {}

    func get(eventID: String) async throws -> GoogleEvent {
        if let f = failure.get { throw f }
        guard let e = events.get[eventID] else { throw CalendarError.notFound }
        return e
    }

    func instance(eventID: String, originalStart: Date, timeZone: TimeZone) async throws -> GoogleEvent? {
        if let f = failure.get { throw f }
        return instances.get["\(eventID)|\(OccurrenceKey.make(originalStart))"]
    }

    let rangeInstances = Box<[String: [GoogleEvent]]>([:])

    func instances(eventID: String, timeMin: Date, timeMax: Date) async throws -> [GoogleEvent] {
        if let f = failure.get { throw f }
        return rangeInstances.get[eventID] ?? []
    }

    func list(syncToken: String?) async throws -> GoogleEventPage {
        listCalls.mutate { $0.append(syncToken) }
        var next: Result<GoogleEventPage, CalendarError> = .success(GoogleEventPage(items: [], nextSyncToken: "t"))
        pages.mutate { if !$0.isEmpty { next = $0.removeFirst() } }
        return try next.get()
    }

    func nearbyEvents(around start: Date) async throws -> [GoogleEvent] {
        if let f = failure.get { throw f }
        return nearby.get
    }
}

struct FakeTravel: TravelEstimating {
    let seconds: Box<TimeInterval?>
    let calls = Box<[(Coordinate, Date)]>([])

    init(_ seconds: TimeInterval?) { self.seconds = Box(seconds) }

    func travelTime(from: Coordinate, to: Coordinate, mode: TransportMode, departure: Date) async throws -> TimeInterval {
        calls.mutate { $0.append((from, departure)) }
        guard let s = seconds.get else { throw URLError(.notConnectedToInternet) }
        return s
    }
}

struct FakeGeocoder: Geocoding {
    var results: [String: GeocodedAddress] = [:]

    func geocode(_ query: String, near: Coordinate?) async throws -> GeocodedAddress? {
        results[query.lowercased()]
    }
}

struct FakeLocation: LocationProviding {
    let fix: Box<LocationFix?>
    init(_ fix: LocationFix?) { self.fix = Box(fix) }
    func latestFix() async -> LocationFix? { fix.get }
}

struct FakeHints: HintGenerating {
    var hint: String? = "New hint."
    var fail = false

    func preparationHint(title: String, eventType: EventType, locationType: LocationType, place: String?,
                         language: SpeechLanguage) async throws -> String? {
        if fail { throw AIError.offline }
        return hint
    }
}

@MainActor
final class FakePresenter: AlarmPresenting {
    var presented: [AlarmContent] = []
    func present(_ alarm: AlarmContent) async { presented.append(alarm) }
}

@MainActor
final class FakePreAlarm: PreAlarmChecking {
    var outcome: RefetchOutcome = .current
    var onRefetch: (() -> Void)?
    var calls = 0
    func refetch(_ occurrence: Occurrence) async -> RefetchOutcome {
        calls += 1
        onRefetch?()
        return outcome
    }
}

/// Parser that returns scripted results and records the conversation it received.
final class ScriptedParser: RequestParsing, @unchecked Sendable {
    let script = Box<[Result<ParsedRequest, AIError>]>([])
    let conversations = Box<[[ChatTurn]]>([])
    let contexts = Box<[ParseContext]>([])

    init(_ items: [Result<ParsedRequest, AIError>]) { script.set(items) }

    func parse(conversation: [ChatTurn], context: ParseContext) async throws -> ParsedRequest {
        conversations.mutate { $0.append(conversation) }
        contexts.mutate { $0.append(context) }
        var next: Result<ParsedRequest, AIError> = .failure(.badResponse("script exhausted"))
        script.mutate { if !$0.isEmpty { next = $0.removeFirst() } }
        return try next.get()
    }
}

func parsed(title: String? = "Training", start: String? = "2026-10-05T18:00", zone: String? = nil,
            kind: RequestKind? = nil,
            recurrence: ParsedRequest.ParsedRecurrence? = nil, location: ParsedRequest.ParsedLocationType = .home,
            placeName: String? = nil, address: String? = nil, type: EventType = .training, prep: Int? = nil,
            hint: String? = "Change into sports clothes.", question: String? = nil,
            intent: ParsedRequest.Intent = .create_event, language: SpeechLanguage = .en) -> ParsedRequest {
    ParsedRequest(intent: intent, language: language, question: question,
                  event: .init(kind: kind, title: title, start_local: start, time_zone: zone, duration_minutes: nil,
                               recurrence: recurrence, participants: [], location_type: location,
                               place_name: placeName, address: address, event_type: type,
                               prep_minutes: prep, prep_hint: hint))
}

func offSiteRecord(start: Date, createdAt: Date, travel: TimeInterval? = nil, prep: Int = 15) -> EventRecord {
    var r = EventRecord(googleEventID: "g1", title: "Training", start: start, end: start.addingTimeInterval(3600),
                        timeZoneID: "Europe/Moscow", locationType: .offSite,
                        place: ResolvedPlace(name: "gym", address: "Gym street 5", coordinate: gym),
                        locationText: "gym, Gym street 5", eventType: .training, prepMinutes: prep,
                        prepHint: "Take water.", createdAt: createdAt)
    if let travel { r.travel[OccurrenceKey.make(start)] = TravelEstimate(seconds: travel, computedAt: createdAt) }
    return r
}
