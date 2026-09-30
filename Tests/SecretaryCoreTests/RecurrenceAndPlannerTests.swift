import XCTest
@testable import SecretaryCore

final class RecurrenceTests: XCTestCase {
    func testMonWedFriExpansionAnchoredToLocalTime() {
        // Monday 2026-10-05 18:00 Moscow.
        let rule = Recurrence(frequency: .weekly, byWeekday: [.MO, .WE, .FR])
        let starts = rule.originalStarts(dtstart: d(2026, 10, 5, 18), timeZone: moscow, through: d(2026, 10, 12, 23))
        XCTAssertEqual(starts, [d(2026, 10, 5, 18), d(2026, 10, 7, 18), d(2026, 10, 9, 18), d(2026, 10, 12, 18)])
    }

    func testRRuleRoundTripWithExdate() {
        var rule = Recurrence(frequency: .weekly, byWeekday: [.MO, .WE, .FR], until: d(2026, 12, 31, 23, 59))
        rule.exceptionDates = [d(2026, 10, 7, 18)]
        let lines = rule.googleLines(timeZone: moscow)
        XCTAssertEqual(lines[0], "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261231T205900Z")
        XCTAssertEqual(lines[1], "EXDATE;TZID=Europe/Moscow:20261007T180000")
        XCTAssertEqual(Recurrence.parse(googleLines: lines, timeZone: moscow), rule)

        let starts = rule.originalStarts(dtstart: d(2026, 10, 5, 18), timeZone: moscow, through: d(2026, 10, 9, 23))
        XCTAssertEqual(starts, [d(2026, 10, 5, 18), d(2026, 10, 9, 18)])
    }

    func testCountAndMonthlySkipsShortMonths() {
        let count = Recurrence(frequency: .daily, count: 3)
        XCTAssertEqual(count.originalStarts(dtstart: d(2026, 10, 1, 9), timeZone: moscow, through: d(2027, 1, 1, 0)).count, 3)

        let monthly = Recurrence(frequency: .monthly)
        let starts = monthly.originalStarts(dtstart: d(2026, 10, 31, 9), timeZone: moscow, through: d(2027, 1, 31, 23))
        XCTAssertEqual(starts, [d(2026, 10, 31, 9), d(2026, 12, 31, 9), d(2027, 1, 31, 9)])
    }

    func testUnsupportedRuleSwitchesToGoogleInstances() {
        XCTAssertEqual(Recurrence.parse(googleLines: ["RRULE:FREQ=HOURLY"], timeZone: moscow)?.needsInstances, true)
        XCTAssertEqual(Recurrence.parse(googleLines: ["RRULE:FREQ=MONTHLY;BYMONTHDAY=15"], timeZone: moscow)?.needsInstances, true)
        XCTAssertEqual(Recurrence.parse(googleLines: ["RRULE:FREQ=WEEKLY;BYDAY=MO;WKST=SU"], timeZone: moscow)?.needsInstances, false)
        XCTAssertNil(Recurrence.parse(googleLines: ["EXDATE:20261007T150000Z"], timeZone: moscow))
    }
}

final class ReminderPlannerTests: XCTestCase {
    let settings = AppSettings()

    func testDefaultsFromDecisions() {
        XCTAssertEqual(settings.homeLeadMinutes, 5)
        XCTAssertEqual(settings.fallbackBufferMinutes, 45)
        XCTAssertEqual(settings.transportMode, .driving)
        XCTAssertEqual(settings.prepMinutes(for: .training), 15)
    }

    func testHomeAndOnlineEventsGetOneAlarmAtHomeLeadTime() {
        for type in [LocationType.home, .noLocation] {
            let r = EventRecord(title: "Call", start: d(2026, 10, 5, 10, 30), end: d(2026, 10, 5, 11, 30),
                                timeZoneID: "Europe/Moscow", locationType: type, createdAt: d(2026, 10, 5, 9))
            let reminders = ReminderPlanner.reminders(for: r, settings: settings, from: d(2026, 10, 5, 9), through: d(2026, 10, 6, 0))
            XCTAssertEqual(reminders.map(\.kind), [.standard])
            XCTAssertEqual(reminders.first?.fireDate, d(2026, 10, 5, 10, 25))
        }
    }

    func testStandaloneReminderFiresAtRequestedTime() {
        let due = d(2026, 10, 5, 10, 30)
        let record = EventRecord(kind: .reminder, managesGoogleEvent: false, title: "Call Mom", start: due,
                                 end: due.addingTimeInterval(86_400), timeZoneID: "Europe/Moscow",
                                 locationType: .noLocation, createdAt: d(2026, 10, 5, 9))
        let alarms = ReminderPlanner.reminders(for: record, settings: settings,
                                               from: d(2026, 10, 5, 9), through: d(2026, 10, 6, 0))
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms.first?.fireDate, due)
    }

    func testOffSiteGetsGetReadyAndLeaveNow() {
        let r = offSiteRecord(start: d(2026, 10, 5, 18), createdAt: d(2026, 10, 5, 9), travel: 30 * 60, prep: 15)
        let reminders = ReminderPlanner.reminders(for: r, settings: settings, from: d(2026, 10, 5, 9), through: d(2026, 10, 6, 0))
        XCTAssertEqual(reminders.map(\.kind), [.getReady, .leaveNow])
        XCTAssertEqual(reminders[0].fireDate, d(2026, 10, 5, 17, 15))
        XCTAssertEqual(reminders[1].fireDate, d(2026, 10, 5, 17, 30))
        XCTAssertFalse(reminders[1].usedFallbackBuffer)
    }

    func testFallbackBufferWhenNoEstimate() {
        let r = offSiteRecord(start: d(2026, 10, 5, 18), createdAt: d(2026, 10, 5, 9))
        let reminders = ReminderPlanner.reminders(for: r, settings: settings, from: d(2026, 10, 5, 9), through: d(2026, 10, 6, 0))
        XCTAssertEqual(reminders[1].fireDate, d(2026, 10, 5, 17, 15))  // 45-minute buffer
        XCTAssertTrue(reminders[1].usedFallbackBuffer)
        let text = SpokenText.alarm(for: reminders[1], record: r, settings: settings, zone: moscow)
        XCTAssertTrue(text.spokenText.contains("default buffer of 45 minutes"))
    }

    func testOverridesMoveAndCancelSingleOccurrence() {
        var r = offSiteRecord(start: d(2026, 10, 5, 18), createdAt: d(2026, 10, 5, 9), travel: 1800)
        r.recurrence = Recurrence(frequency: .weekly, byWeekday: [.MO, .WE, .FR])
        r.overrides[OccurrenceKey.make(d(2026, 10, 7, 18))] = OccurrenceOverride(cancelled: true)
        r.overrides[OccurrenceKey.make(d(2026, 10, 9, 18))] = OccurrenceOverride(start: d(2026, 10, 9, 19), end: d(2026, 10, 9, 20))
        let occ = r.occurrences(from: d(2026, 10, 5, 0), through: d(2026, 10, 10, 0))
        XCTAssertEqual(occ.map(\.start), [d(2026, 10, 5, 18), d(2026, 10, 9, 19)])
    }
}
