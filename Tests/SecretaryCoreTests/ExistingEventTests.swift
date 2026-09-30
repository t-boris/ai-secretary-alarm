import XCTest
@testable import SecretaryCore

final class ExistingEventTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func draft() -> EventDraft {
        let start = d(2026, 9, 30, 18, zone: chicago)
        return EventDraft(title: "Gym with Vitaliy", start: start, end: start.addingTimeInterval(3600),
                          timeZoneID: chicago.identifier, recurrence: nil, participants: [], locationType: .home,
                          place: nil, newPlaceName: nil, savePlace: false, eventType: .training,
                          alarmSoundID: nil, prepMinutes: 15, prepHint: nil, origin: .automatic,
                          language: .en, travelSeconds: nil)
    }

    func testExistingRecurringInstanceIsOfferedInsteadOfSilentInsert() {
        let proposed = draft()
        let same = GoogleEvent(id: "instance", summary: "Gym with Vitaliy",
                               start: .init(dateTime: GoogleTime.format(proposed.start, in: chicago)),
                               recurringEventId: "series")
        let other = GoogleEvent(id: "other", summary: "Dinner",
                                start: .init(dateTime: GoogleTime.format(proposed.start.addingTimeInterval(7200), in: chicago)))
        XCTAssertEqual(ExistingEventMatcher.candidates(for: proposed, in: [other, same]).map(\.id), ["instance"])
    }

    func testSameTitleAtEditedTimeAndDifferentMeetingAtSameTimeAreShownForReview() {
        let proposed = draft()
        let shifted = GoogleEvent(id: "shifted", summary: "Gym with Vitaliy",
                                  start: .init(dateTime: GoogleTime.format(proposed.start.addingTimeInterval(3600), in: chicago)))
        let collision = GoogleEvent(id: "collision", summary: "Another meeting",
                                    start: .init(dateTime: GoogleTime.format(proposed.start, in: chicago)))
        XCTAssertEqual(Set(ExistingEventMatcher.candidates(for: proposed, in: [shifted, collision]).compactMap(\.id)),
                       Set(["shifted", "collision"]))
    }

    func testGoogleErrorRetainsMessageAndReason() {
        let body = """
        {"error":{"code":403,"message":"Google Calendar API is disabled for this project.",
        "errors":[{"reason":"accessNotConfigured"}]}}
        """
        let detail = GoogleAPIErrorDetails(body: body)
        XCTAssertEqual(detail.message, "Google Calendar API is disabled for this project.")
        XCTAssertEqual(detail.reason, "accessNotConfigured")
    }

    func testTypeMelodyAndPersonalOverride() {
        let proposed = draft()
        var record = proposed.makeRecord(createdAt: proposed.start.addingTimeInterval(-3600))
        var settings = AppSettings()
        XCTAssertEqual(settings.alarmSound(for: .training), "built-in:training")
        settings.alarmSoundsByType[.training] = "custom:team.wav"
        let occurrence = record.occurrences(from: proposed.start.addingTimeInterval(-1), through: proposed.start).first!
        let reminder = ReminderPlanner.reminders(for: occurrence, record: record, settings: settings).first!
        XCTAssertEqual(SpokenText.alarm(for: reminder, record: record, settings: settings, zone: chicago).soundID,
                       "custom:team.wav")
        record.alarmSoundID = "custom:personal.wav"
        XCTAssertEqual(SpokenText.alarm(for: reminder, record: record, settings: settings, zone: chicago).soundID,
                       "custom:personal.wav")
    }
}
