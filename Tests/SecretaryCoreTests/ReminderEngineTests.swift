import XCTest
@testable import SecretaryCore

@MainActor
final class ReminderEngineTests: XCTestCase {
    var now = d(2026, 10, 5, 9)
    var store: AppStore!
    var presenter: FakePresenter!
    var preAlarm: FakePreAlarm!
    var estimator: FakeTravel!
    var location: FakeLocation!
    var engine: ReminderEngine!

    override func setUp() async throws {
        var state = AppState()
        state.places = [homePlace]
        store = AppStore(persistence: MemoryStore(state))
        presenter = FakePresenter()
        preAlarm = FakePreAlarm()
        estimator = FakeTravel(30 * 60)
        location = FakeLocation(nil)
        let travel = TravelUpdater(store: store, estimator: estimator, location: location)
        engine = ReminderEngine(store: store, preAlarm: preAlarm, travel: travel, presenter: presenter,
                                clock: { [unowned self] in self.now }, localZone: { moscow })
    }

    private func add(_ record: EventRecord) { store.mutate { $0.events.append(record) } }

    func testFiresOnceWithHintAndDoesNotRepeat() async {
        add(EventRecord(googleEventID: "g1", title: "Meeting with Manoj", start: d(2026, 10, 5, 10, 30),
                        end: d(2026, 10, 5, 11, 30), timeZoneID: "Europe/Moscow", locationType: .noLocation,
                        prepHint: "Open the project notes.", createdAt: now))
        now = d(2026, 10, 5, 10, 24)
        await engine.tick()
        XCTAssertTrue(presenter.presented.isEmpty)

        now = d(2026, 10, 5, 10, 25)
        await engine.tick()
        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertTrue(presenter.presented[0].spokenText.contains("Meeting with Manoj"))
        XCTAssertTrue(presenter.presented[0].spokenText.contains("Open the project notes."))

        now = d(2026, 10, 5, 10, 26)
        await engine.tick()
        XCTAssertEqual(presenter.presented.count, 1, "sound and speech are not repeated")
    }

    func testSnoozeReplaysAtChosenTime() async {
        let alarm = AlarmContent(reminderKey: "sample", eventID: UUID(), kind: .standard,
                                 heading: "Reminder", body: "Take medication", spokenText: "Take medication",
                                 soundID: "default", language: .en)
        engine.snooze(alarm, minutes: 5)
        XCTAssertEqual(store.state.snoozedAlarms.count, 1)
        now = d(2026, 10, 5, 9, 4)
        await engine.tick()
        XCTAssertTrue(presenter.presented.isEmpty)
        now = d(2026, 10, 5, 9, 5)
        await engine.tick()
        XCTAssertEqual(presenter.presented, [alarm])
        XCTAssertTrue(store.state.snoozedAlarms.isEmpty)
    }

    func testCompletedDailyHabitDoesNotRingAgainToday() async {
        let start = d(2026, 10, 5, 10)
        let record = EventRecord(kind: .habit, managesGoogleEvent: false, title: "Take medication",
                                 start: start, end: start.addingTimeInterval(86_400),
                                 timeZoneID: "Europe/Moscow", recurrence: Recurrence(frequency: .daily),
                                 locationType: .noLocation, createdAt: now)
        add(record)
        let key = PlannedReminder.key(eventID: record.id, occurrenceKey: OccurrenceKey.make(start), kind: .standard)
        store.mutate { $0.completedHabits[key] = start.addingTimeInterval(86_400) }
        now = start
        await engine.tick()
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testMissedReminderPlaysOnWakeOnlyIfEventHasNotEnded() async {
        add(EventRecord(googleEventID: "g1", title: "Ongoing", start: d(2026, 10, 5, 10), end: d(2026, 10, 5, 11),
                        timeZoneID: "Europe/Moscow", locationType: .home, createdAt: now))
        add(EventRecord(googleEventID: "g2", title: "Ended", start: d(2026, 10, 5, 9, 30), end: d(2026, 10, 5, 10, 15),
                        timeZoneID: "Europe/Moscow", locationType: .home, createdAt: now))
        now = d(2026, 10, 5, 10, 20)  // woke up after both reminder times
        await engine.tick()
        XCTAssertEqual(presenter.presented.map(\.heading), ["Reminder: Ongoing"])
    }

    func testBothOffSiteAlarmsMissedPlaysOnlyLeaveNow() async {
        add(offSiteRecord(start: d(2026, 10, 5, 18), createdAt: now, travel: 1800))
        now = d(2026, 10, 5, 17, 40)
        await engine.tick()
        XCTAssertEqual(presenter.presented.map(\.kind), [.leaveNow])
        now = d(2026, 10, 5, 17, 41)
        await engine.tick()
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testGetReadyAlreadyPastAtCreationIsSkipped() async {
        now = d(2026, 10, 5, 17, 20)  // get ready would be 17:15
        add(offSiteRecord(start: d(2026, 10, 5, 18), createdAt: now, travel: 1800))
        await engine.tick()
        XCTAssertTrue(presenter.presented.isEmpty)
        now = d(2026, 10, 5, 17, 30)
        await engine.tick()
        XCTAssertEqual(presenter.presented.map(\.kind), [.leaveNow])
    }

    func testTwoStageAlarmsAndRefreshPoints() async {
        add(offSiteRecord(start: d(2026, 10, 5, 18), createdAt: now, travel: 1800))
        location.fix.set(LocationFix(coordinate: gym, timestamp: d(2026, 10, 5, 17)))

        estimator.seconds.set(40 * 60)  // traffic got worse
        now = d(2026, 10, 5, 17)  // 15 minutes before 'get ready' (17:15)
        await engine.tick()
        XCTAssertEqual(estimator.calls.get.count, 1, "refresh 15 minutes before get ready")
        await engine.tick()
        XCTAssertEqual(estimator.calls.get.count, 1, "refresh point runs once")
        XCTAssertTrue(presenter.presented.isEmpty)

        now = d(2026, 10, 5, 17, 5)  // new get ready = 18:00 − 40 − 15 = 17:05
        await engine.tick()
        XCTAssertEqual(presenter.presented.map(\.kind), [.getReady])
        XCTAssertTrue(presenter.presented[0].spokenText.contains("about 40 minutes"))

        now = d(2026, 10, 5, 17, 20)
        await engine.tick()
        XCTAssertEqual(presenter.presented.map(\.kind), [.getReady, .leaveNow])
        XCTAssertEqual(estimator.calls.get.count, 3, "refreshed right before each alarm")
    }

    func testLeaveNowDeferredWhenFreshEstimateIsShorter() async {
        add(offSiteRecord(start: d(2026, 10, 5, 18), createdAt: now, travel: 1800))
        estimator.seconds.set(10 * 60)
        now = d(2026, 10, 5, 17, 30)
        await engine.tick()
        XCTAssertFalse(presenter.presented.contains { $0.kind == .leaveNow }, "leave now moves to 17:50")
        now = d(2026, 10, 5, 17, 50)
        await engine.tick()
        XCTAssertTrue(presenter.presented.contains { $0.kind == .leaveNow })
    }

    func testFailedRefreshKeepsLastEstimate() async {
        add(offSiteRecord(start: d(2026, 10, 5, 18), createdAt: now, travel: 1800))
        estimator.seconds.set(nil)
        now = d(2026, 10, 5, 17, 30)
        await engine.tick()
        let alarm = presenter.presented.first { $0.kind == .leaveNow }
        XCTAssertNotNil(alarm)
        XCTAssertFalse(alarm!.spokenText.contains("default buffer"))
    }

    func testStaleLocationFixFallsBackToHome() async {
        add(offSiteRecord(start: d(2026, 10, 5, 18), createdAt: now, travel: 1800))
        location.fix.set(LocationFix(coordinate: gym, timestamp: d(2026, 10, 5, 16)))  // 90 min old
        now = d(2026, 10, 5, 17, 30)
        await engine.tick()
        XCTAssertEqual(estimator.calls.get.last?.0, homeCoord)
    }

    func testPreAlarmRemovedSuppressesAndUnavailableFires() async {
        add(EventRecord(googleEventID: "g1", title: "Deleted", start: d(2026, 10, 5, 10), end: d(2026, 10, 5, 11),
                        timeZoneID: "Europe/Moscow", locationType: .home, createdAt: now))
        preAlarm.outcome = .removed
        now = d(2026, 10, 5, 9, 55)
        await engine.tick()
        XCTAssertTrue(presenter.presented.isEmpty)

        preAlarm.outcome = .unavailable  // offline: last known version fires
        now = d(2026, 10, 5, 9, 56)
        await engine.tick()
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testEventMovedLaterDuringPreAlarmCheckDefers() async {
        let record = EventRecord(googleEventID: "g1", title: "Moved", start: d(2026, 10, 5, 10), end: d(2026, 10, 5, 11),
                                 timeZoneID: "Europe/Moscow", locationType: .home, createdAt: now)
        add(record)
        preAlarm.onRefetch = { [unowned self] in
            self.store.mutate { s in
                var r = s.event(record.id)!
                r.start = d(2026, 10, 5, 12)
                r.end = d(2026, 10, 5, 13)
                s.update(r)
            }
        }
        now = d(2026, 10, 5, 9, 55)
        await engine.tick()
        XCTAssertTrue(presenter.presented.isEmpty)
        preAlarm.onRefetch = nil
        now = d(2026, 10, 5, 11, 55)
        await engine.tick()
        XCTAssertEqual(presenter.presented.count, 1)
    }
}
