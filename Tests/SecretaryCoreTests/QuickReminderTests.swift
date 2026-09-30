import XCTest
@testable import SecretaryCore

final class QuickReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlainRussianReminderNeedsNoSubject() {
        let reminder = QuickReminderParser.parse("Сделай мне напоминание через час", now: now)
        XCTAssertEqual(reminder?.title, "Напоминание")
        XCTAssertEqual(reminder?.dueAt, now.addingTimeInterval(3600))
        XCTAssertEqual(reminder?.language, .ru)
    }

    func testEnglishReminderKeepsSubject() {
        let reminder = QuickReminderParser.parse("Remind me in 30 minutes to call Mom", now: now)
        XCTAssertEqual(reminder?.title, "Call Mom")
        XCTAssertEqual(reminder?.dueAt, now.addingTimeInterval(1800))
    }

    func testColloquialHourAndFillerBecomeShortAction() {
        let reminder = QuickReminderParser.parse("Напомни мне через часик, что мне пора принять таблетки", now: now)
        XCTAssertEqual(reminder?.title, "Принять таблетки")
        XCTAssertEqual(reminder?.dueAt, now.addingTimeInterval(3600))
    }

    func testRecurringReminderUsesFullParser() {
        XCTAssertNil(QuickReminderParser.parse("Напоминай мне каждый день через час принять таблетки", now: now))
    }

    func testConversationalPhraseUsesModelForTitleCleanup() {
        XCTAssertNil(QuickReminderParser.parse("Я бы хотел, чтобы ты напомнил мне через час принять таблетки", now: now))
    }

    func testMeetingRequestIsNotLocalReminder() {
        XCTAssertNil(QuickReminderParser.parse("Schedule a meeting in an hour", now: now))
    }
}
