import XCTest
@testable import SecretaryCore

@MainActor
final class SyncTests: XCTestCase {
    func record(_ gid: String = "g1", recurring: Bool = false) -> EventRecord {
        EventRecord(googleEventID: gid, title: "Training", start: d(2026, 10, 5, 18), end: d(2026, 10, 5, 19),
                    timeZoneID: "Europe/Moscow",
                    recurrence: recurring ? Recurrence(frequency: .weekly, byWeekday: [.MO, .WE, .FR]) : nil,
                    locationType: .home, locationText: "Home street 1", createdAt: d(2026, 10, 1, 9))
    }

    func gEvent(_ id: String, start: Date, title: String = "Training", location: String? = "Home street 1") -> GoogleEvent {
        GoogleEvent(id: id, status: "confirmed", summary: title, location: location,
                    start: .init(dateTime: GoogleTime.format(start, in: moscow), timeZone: "Europe/Moscow"),
                    end: .init(dateTime: GoogleTime.format(start.addingTimeInterval(3600), in: moscow), timeZone: "Europe/Moscow"),
                    extendedProperties: .init(private: [GoogleEvent.tagKey: "1"]))
    }

    func testMovedEventUpdatesStart() {
        var state = AppState()
        state.events = [record()]
        let effects = SyncReconciler.apply([gEvent("g1", start: d(2026, 10, 5, 19))], to: &state, fullResync: false)
        XCTAssertEqual(state.events[0].start, d(2026, 10, 5, 19))
        XCTAssertTrue(effects.isEmpty)
    }

    func testDeletedEventIsRemovedAndManualEventsIgnored() {
        var state = AppState()
        state.events = [record()]
        let manual = GoogleEvent(id: "manual", status: "confirmed", summary: "Dentist",
                                 start: .init(dateTime: GoogleTime.format(d(2026, 10, 6, 9), in: moscow)))
        _ = SyncReconciler.apply([GoogleEvent(id: "g1", status: "cancelled"), manual], to: &state, fullResync: false)
        XCTAssertTrue(state.events.isEmpty)
    }

    func testSingleOccurrenceEditAndDeleteAffectOnlyThatOccurrence() {
        var state = AppState()
        state.events = [record(recurring: true)]
        var moved = gEvent("g1_wed", start: d(2026, 10, 7, 20))
        moved.recurringEventId = "g1"
        moved.originalStartTime = .init(dateTime: GoogleTime.format(d(2026, 10, 7, 18), in: moscow))
        let cancelled = GoogleEvent(id: "g1_fri", status: "cancelled", recurringEventId: "g1",
                                    originalStartTime: .init(dateTime: GoogleTime.format(d(2026, 10, 9, 18), in: moscow)))
        _ = SyncReconciler.apply([moved, cancelled], to: &state, fullResync: false)
        let starts = state.events[0].occurrences(from: d(2026, 10, 5, 0), through: d(2026, 10, 12, 23)).map(\.start)
        XCTAssertEqual(starts, [d(2026, 10, 5, 18), d(2026, 10, 7, 20), d(2026, 10, 12, 18)])
    }

    func testTitleAndLocationChangeTriggerHintAndLocationEffects() {
        var state = AppState()
        state.events = [record()]
        let effects = SyncReconciler.apply([gEvent("g1", start: d(2026, 10, 5, 18), title: "Boxing", location: "Gym street 5")],
                                           to: &state, fullResync: false)
        let id = state.events[0].id
        XCTAssertEqual(effects, [.locationChanged(eventID: id, occurrenceKey: nil, text: "Gym street 5"),
                                 .regenerateHint(eventID: id, occurrenceKey: nil)])
    }

    func testFullResyncRemovesMissingEvents() {
        var state = AppState()
        state.events = [record("g1"), record("g2")]
        _ = SyncReconciler.apply([gEvent("g1", start: d(2026, 10, 5, 18))], to: &state, fullResync: true)
        XCTAssertEqual(state.events.map(\.googleEventID), ["g1"])
    }

    func testCalendarDeletionKeepsTaskHistory() {
        var state = AppState()
        let old = record("g1")
        state.events = [old]
        state.activityHistory = [ActivityHistoryEntry(record: old)]
        _ = SyncReconciler.apply([], to: &state, fullResync: true)
        XCTAssertTrue(state.events.isEmpty)
        XCTAssertEqual(state.activityHistory.map(\.eventID), [old.id])
    }

    func testFullResyncKeepsLocalReminder() {
        var state = AppState()
        let due = d(2026, 10, 5, 18)
        let reminder = EventRecord(kind: .reminder, managesGoogleEvent: false, title: "Call Mom", start: due,
                                   end: due.addingTimeInterval(86_400), timeZoneID: "Europe/Moscow",
                                   locationType: .noLocation, createdAt: d(2026, 10, 1, 9))
        state.events = [record("g1"), reminder]
        _ = SyncReconciler.apply([], to: &state, fullResync: true)
        XCTAssertEqual(state.events.map(\.id), [reminder.id])
    }

    func testExpiredSyncTokenTriggersFullResync() async {
        var state = AppState()
        state.events = [record("g1"), record("g2")]
        state.syncToken = "old"
        let store = AppStore(persistence: MemoryStore(state))
        let calendar = FakeCalendar()
        calendar.pages.set([.failure(.syncTokenExpired),
                            .success(GoogleEventPage(items: [gEvent("g1", start: d(2026, 10, 5, 18))], nextSyncToken: "new"))])
        let sync = SyncCoordinator(store: store, calendar: calendar, geocoder: FakeGeocoder(), hints: FakeHints(),
                                   clock: { d(2026, 10, 5, 12) })
        await sync.sync()
        XCTAssertEqual(calendar.listCalls.get, ["old", nil])
        XCTAssertEqual(store.state.syncToken, "new")
        XCTAssertEqual(store.state.events.map(\.googleEventID), ["g1"])
    }

    func testLocationChangeIsGeocodedAndHintRegenerated() async {
        var state = AppState()
        state.events = [record()]
        let store = AppStore(persistence: MemoryStore(state))
        let calendar = FakeCalendar()
        calendar.pages.set([.success(GoogleEventPage(items: [gEvent("g1", start: d(2026, 10, 5, 18), location: "Gym street 5")],
                                                     nextSyncToken: "t"))])
        let geocoder = FakeGeocoder(results: ["gym street 5": GeocodedAddress(address: "Gym street 5, Moscow", coordinate: gym)])
        let sync = SyncCoordinator(store: store, calendar: calendar, geocoder: geocoder, hints: FakeHints(hint: "Take shoes."))
        await sync.sync()
        let r = store.state.events[0]
        XCTAssertEqual(r.locationType, .offSite)
        XCTAssertEqual(r.place?.coordinate, gym)
        XCTAssertEqual(r.prepHint, "Take shoes.")
    }

    func testHintRegenerationFailureKeepsPreviousHint() async {
        var state = AppState()
        var rec = record()
        rec.prepHint = "Old hint."
        state.events = [rec]
        let store = AppStore(persistence: MemoryStore(state))
        let calendar = FakeCalendar()
        calendar.pages.set([.success(GoogleEventPage(items: [gEvent("g1", start: d(2026, 10, 5, 18), title: "Boxing")],
                                                     nextSyncToken: "t"))])
        let sync = SyncCoordinator(store: store, calendar: calendar, geocoder: FakeGeocoder(), hints: FakeHints(fail: true))
        await sync.sync()
        XCTAssertEqual(store.state.events[0].title, "Boxing")
        XCTAssertEqual(store.state.events[0].prepHint, "Old hint.")
    }

    func testAuthExpiredNotifies() async {
        let store = AppStore(persistence: MemoryStore(AppState()))
        let calendar = FakeCalendar()
        calendar.pages.set([.failure(.authExpired)])
        let sync = SyncCoordinator(store: store, calendar: calendar, geocoder: FakeGeocoder(), hints: FakeHints())
        var notified = false
        sync.onAuthExpired = { notified = true }
        await sync.sync()
        XCTAssertTrue(notified)
    }

    func testPreAlarmRefetchDetectsDeletedOccurrence() async {
        var state = AppState()
        state.events = [record(recurring: true)]
        let store = AppStore(persistence: MemoryStore(state))
        let calendar = FakeCalendar()
        var master = gEvent("g1", start: d(2026, 10, 5, 18))
        master.recurrence = ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"]
        calendar.events.set(["g1": master])
        calendar.instances.set(["g1|\(OccurrenceKey.make(d(2026, 10, 7, 18)))":
            GoogleEvent(id: "g1_x", status: "cancelled", recurringEventId: "g1",
                        originalStartTime: .init(dateTime: GoogleTime.format(d(2026, 10, 7, 18), in: moscow)))])
        let sync = SyncCoordinator(store: store, calendar: calendar, geocoder: FakeGeocoder(), hints: FakeHints())
        let occ = store.state.events[0].occurrences(from: d(2026, 10, 7, 0), through: d(2026, 10, 7, 23))[0]
        let outcome = await sync.refetch(occ)
        XCTAssertEqual(outcome, .removed)

        calendar.failure.set(.network("offline"))
        let monday = store.state.events[0].occurrences(from: d(2026, 10, 5, 0), through: d(2026, 10, 5, 23))[0]
        let offline = await sync.refetch(monday)
        XCTAssertEqual(offline, .unavailable)
    }

    func testGoogleEventBodyIsTaggedWithExplicitZone() {
        var r = record(recurring: true)
        r.prepHint = "Take water."
        r.participants = ["Manoj"]
        let g = r.googleEvent()
        XCTAssertEqual(g.extendedProperties?.private?[GoogleEvent.tagKey], "1")
        XCTAssertEqual(g.start?.timeZone, "Europe/Moscow")
        XCTAssertEqual(g.start?.dateTime, "2026-10-05T18:00:00+03:00")
        XCTAssertEqual(g.recurrence, ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"])
        XCTAssertTrue(g.description!.contains("Take water."))
        XCTAssertTrue(g.description!.contains("Manoj"))
    }

    func testStateRoundTripsThroughJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var state = AppState()
        state.events = [record(recurring: true)]
        state.settings.prepMinutesByType[.meeting] = 7
        state.completedHabits["habit|today|standard"] = d(2026, 10, 6, 9)
        let alarm = AlarmContent(reminderKey: "snooze", eventID: UUID(), kind: .standard,
                                 heading: "Reminder", body: "Take medication", spokenText: "Take medication",
                                 soundID: "default", language: .en)
        state.snoozedAlarms = [SnoozedAlarm(content: alarm, fireDate: d(2026, 10, 5, 10))]
        try JSONFileStore(url: url).save(state)
        XCTAssertEqual(try JSONFileStore(url: url).load(), state)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.lowercased().contains("api"), "no secrets in the state file")
    }
}

extension SyncTests {
    func testFullResyncKeepsRecordsCreatedDuringListing() {
        var state = AppState()
        var fresh = record("g9")
        fresh.createdAt = d(2026, 10, 5, 12, 1)
        state.events = [record("g1"), fresh]
        _ = SyncReconciler.apply([gEvent("g1", start: d(2026, 10, 5, 18))], to: &state, fullResync: true,
                                 listedAt: d(2026, 10, 5, 12))
        XCTAssertEqual(state.events.map(\.googleEventID), ["g1", "g9"])
    }
}
