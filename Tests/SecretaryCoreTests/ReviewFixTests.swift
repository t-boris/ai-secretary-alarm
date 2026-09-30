import XCTest
@testable import SecretaryCore

/// Regression tests for issues found in the spec-conformance review.
@MainActor
final class ReviewFixTests: XCTestCase {
    private func gEvent(_ id: String, start: Date, recurrence: [String]? = nil, localID: UUID? = nil) -> GoogleEvent {
        var props = [GoogleEvent.tagKey: "1"]
        if let localID { props[GoogleEvent.localIDKey] = localID.uuidString }
        return GoogleEvent(id: id, status: "confirmed", summary: "Training", location: "Home street 1",
                           start: .init(dateTime: GoogleTime.format(start, in: moscow), timeZone: "Europe/Moscow"),
                           end: .init(dateTime: GoogleTime.format(start.addingTimeInterval(3600), in: moscow), timeZone: "Europe/Moscow"),
                           recurrence: recurrence, extendedProperties: .init(private: props))
    }

    private func series() -> EventRecord {
        EventRecord(googleEventID: "g1", title: "Training", start: d(2026, 10, 5, 18), end: d(2026, 10, 5, 19),
                    timeZoneID: "Europe/Moscow", recurrence: Recurrence(frequency: .weekly, byWeekday: [.MO, .WE, .FR]),
                    locationType: .home, locationText: "Home street 1", prepHint: "Change clothes.", createdAt: d(2026, 10, 1, 9))
    }

    func testThisAndFollowingSplitBecomesOwnRecord() {
        var state = AppState()
        let original = series()
        state.events = [original]
        let truncated = gEvent("g1", start: d(2026, 10, 5, 18), recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261011T205959Z"],
                               localID: original.id)
        let following = gEvent("g1_R20261012", start: d(2026, 10, 12, 19), recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"],
                               localID: original.id)
        _ = SyncReconciler.apply([truncated, following], to: &state, fullResync: false)
        XCTAssertEqual(state.events.count, 2)
        let copy = state.events.first { $0.googleEventID == "g1_R20261012" }!
        XCTAssertEqual(copy.start, d(2026, 10, 12, 19))
        XCTAssertEqual(copy.prepHint, "Change clothes.")
        let starts = state.events.flatMap { $0.occurrences(from: d(2026, 10, 5, 0), through: d(2026, 10, 14, 23)) }.map(\.start).sorted()
        XCTAssertEqual(starts, [d(2026, 10, 5, 18), d(2026, 10, 7, 18), d(2026, 10, 9, 18), d(2026, 10, 12, 19), d(2026, 10, 14, 19)])
    }

    func testUnsupportedRuleUsesGoogleInstances() async {
        var state = AppState()
        state.events = [series()]
        let store = AppStore(persistence: MemoryStore(state))
        let calendar = FakeCalendar()
        calendar.pages.set([.success(GoogleEventPage(items: [gEvent("g1", start: d(2026, 10, 5, 18),
                                                                     recurrence: ["RRULE:FREQ=MONTHLY;BYDAY=1MO"])],
                                                     nextSyncToken: "t"))])
        calendar.rangeInstances.set(["g1": [
            GoogleEvent(id: "a", start: .init(dateTime: GoogleTime.format(d(2026, 10, 5, 18), in: moscow)),
                        originalStartTime: .init(dateTime: GoogleTime.format(d(2026, 10, 5, 18), in: moscow))),
            GoogleEvent(id: "b", start: .init(dateTime: GoogleTime.format(d(2026, 11, 2, 18), in: moscow)),
                        originalStartTime: .init(dateTime: GoogleTime.format(d(2026, 11, 2, 18), in: moscow))),
        ]])
        let sync = SyncCoordinator(store: store, calendar: calendar, geocoder: FakeGeocoder(), hints: FakeHints(),
                                   clock: { d(2026, 10, 5, 9) })
        await sync.sync()
        let r = store.state.events[0]
        XCTAssertEqual(r.recurrence?.needsInstances, true)
        XCTAssertEqual(r.occurrences(from: d(2026, 10, 1, 0), through: d(2026, 11, 30, 0)).map(\.start),
                       [d(2026, 10, 5, 18), d(2026, 11, 2, 18)])
    }

    func testDateOnlyUntilIncludesLastDay() {
        let r = Recurrence.parse(googleLines: ["RRULE:FREQ=DAILY;UNTIL=20261007"], timeZone: moscow)!
        XCTAssertFalse(r.needsInstances)
        XCTAssertEqual(r.originalStarts(dtstart: d(2026, 10, 5, 18), timeZone: moscow, through: d(2026, 12, 1, 0)).count, 3)
    }

    func testSingleOccurrenceTitleChangeRegeneratesItsHint() async {
        var state = AppState()
        state.events = [series()]
        let store = AppStore(persistence: MemoryStore(state))
        var exception = gEvent("g1_x", start: d(2026, 10, 7, 18))
        exception.summary = "Boxing"
        exception.recurringEventId = "g1"
        exception.originalStartTime = .init(dateTime: GoogleTime.format(d(2026, 10, 7, 18), in: moscow))
        let calendar = FakeCalendar()
        calendar.pages.set([.success(GoogleEventPage(items: [exception], nextSyncToken: "t"))])
        let sync = SyncCoordinator(store: store, calendar: calendar, geocoder: FakeGeocoder(), hints: FakeHints(hint: "Take gloves."))
        await sync.sync()
        let r = store.state.events[0]
        let occ = r.occurrences(from: d(2026, 10, 5, 0), through: d(2026, 10, 9, 23))
        XCTAssertEqual(occ.map(\.prepHint), ["Change clothes.", "Take gloves.", "Change clothes."])
        XCTAssertEqual(r.prepHint, "Change clothes.")
    }

    func testLeaveNowAlarmIncludesPreparationHint() {
        let r = offSiteRecord(start: d(2026, 10, 5, 18), createdAt: d(2026, 10, 5, 9), travel: 1800)
        let leave = ReminderPlanner.reminders(for: r, settings: AppSettings(), from: d(2026, 10, 5, 9), through: d(2026, 10, 6, 0))[1]
        XCTAssertTrue(SpokenText.alarm(for: leave, record: r, settings: AppSettings(), zone: moscow).spokenText.contains("Take water."))
    }

    func testPlainNoAnswersQuestionInsteadOfCancelling() async {
        let parser = ScriptedParser([.success(parsed(location: .unknown, question: "Is it at home?")),
                                     .success(parsed(location: .no_location))])
        var state = AppState()
        state.places = [homePlace]
        let store = AppStore(persistence: MemoryStore(state))
        let session = DialogueSession(parser: parser, geocoder: FakeGeocoder(), travel: nil, store: store,
                                      clock: { d(2026, 10, 5, 9) }, localZone: moscow)
        _ = await session.handle("Training at 6 pm")
        let step = await session.handle("нет")
        guard case .summary = step else { return XCTFail("expected summary, got \(step)") }
    }

    func testFormEditIsRecordedInConversation() async {
        let parser = ScriptedParser([.success(parsed(location: .home))])
        let store = AppStore(persistence: MemoryStore(AppState()))
        let session = DialogueSession(parser: parser, geocoder: FakeGeocoder(), travel: nil, store: store,
                                      clock: { d(2026, 10, 5, 9) }, localZone: moscow)
        guard case let .summary(draft, _) = await session.handle("Training at 6 pm at home") else { return XCTFail() }
        var edited = draft
        edited.title = "Yoga"
        _ = await session.edit(edited)
        XCTAssertTrue(session.conversation.contains { $0.role == .user && $0.text.contains("title \"Yoga\"") })
    }

    func testUnreadableStateIsQuarantinedNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try Data("{not json".utf8).write(to: url)
        let store = AppStore(persistence: JSONFileStore(url: url))
        XCTAssertNotNil(store.loadError)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("state.corrupt-") })
    }

    func testOldStateWithoutNewFieldsStillLoads() throws {
        let json = #"{"events":[],"places":[],"settings":{"homeLeadMinutes":7}}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        XCTAssertEqual(state.settings.homeLeadMinutes, 7)
        XCTAssertEqual(state.settings.fallbackBufferMinutes, 45)
    }

    func testDeadlineReturnsFallbackForSlowWork() async {
        let result = await withDeadline(0.05, fallback: RefetchOutcome.unavailable) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return RefetchOutcome.removed
        }
        XCTAssertEqual(result, .unavailable)
        let fast = await withDeadline(1, fallback: RefetchOutcome.unavailable) { RefetchOutcome.current }
        XCTAssertEqual(fast, .current)
    }

    func testInstanceQueryTimeIsUTC() {
        XCTAssertEqual(GoogleTime.format(d(2026, 10, 7, 18), in: TimeZone(identifier: "UTC")!), "2026-10-07T15:00:00Z")
    }
}
