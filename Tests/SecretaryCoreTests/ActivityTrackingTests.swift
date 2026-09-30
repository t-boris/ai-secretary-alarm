import XCTest
@testable import SecretaryCore

final class ActivityTrackingTests: XCTestCase {
    func testRussianProjectTimerCommands() {
        XCTAssertEqual(TimerCommandParser.parse("Запусти таймер, пока я занимаюсь проектом Секретарь"),
                       .start(project: "Секретарь"))
        XCTAssertEqual(TimerCommandParser.parse("Останови таймер"), .stop)
        XCTAssertEqual(TimerCommandParser.parse("Сколько времени я потратил на проект Секретарь?"),
                       .summary(project: "Секретарь"))
        XCTAssertEqual(TimerCommandParser.parse("Сколько я на что тратил?"), .summary(project: nil))
        XCTAssertNil(TimerCommandParser.parse("Поставь таймер на 30 минут"),
                     "a countdown is not a project stopwatch")
        XCTAssertEqual(TimerCommandParser.parse("Запусти таймер"), .startNeedsProject)
    }

    func testEnglishProjectTimerCommands() {
        XCTAssertEqual(TimerCommandParser.parse("Start a timer for project Atlas"), .start(project: "Atlas"))
        XCTAssertEqual(TimerCommandParser.parse("Stop the timer"), .stop)
    }

    func testProjectTotalsIncludeActiveTimeAndSevenDayCutoff() {
        let old = ProjectTimerSession(project: "Atlas", startedAt: d(2026, 9, 20, 9),
                                      endedAt: d(2026, 9, 20, 10))
        let current = ProjectTimerSession(project: "atlas", startedAt: d(2026, 10, 5, 9))
        let now = d(2026, 10, 5, 9, 30)
        let totals = ActivityStatistics.projectTotals([old, current], now: now)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].seconds, 5400)
        let recent = ActivityStatistics.projectTotals([old, current], from: d(2026, 9, 28, 9), now: now)
        XCTAssertEqual(recent[0].seconds, 1800)
    }

    func testPruneKeepsHistoryAndTimersAfterRemovingPastEvents() {
        var state = AppState()
        let record = EventRecord(kind: .reminder, title: "Take medication", start: d(2026, 9, 1, 9),
                                 end: d(2026, 9, 2, 9), timeZoneID: "Europe/Moscow",
                                 locationType: .noLocation, createdAt: d(2026, 9, 1, 8))
        state.events = [record]
        state.activityHistory = [ActivityHistoryEntry(record: record)]
        state.projectTimers = [ProjectTimerSession(project: "Atlas", startedAt: d(2026, 9, 1, 9),
                                                    endedAt: d(2026, 9, 1, 10))]
        state.prune(now: d(2026, 10, 5, 9))
        XCTAssertTrue(state.events.isEmpty)
        XCTAssertEqual(state.activityHistory.count, 1)
        XCTAssertEqual(state.projectTimers.count, 1)
    }

    func testVoiceDefaultsAvoidSystemSpeechAndRequestRussianAccent() {
        let settings = AppSettings()
        XCTAssertEqual(settings.alarmCloudVoice, .cedar)
        XCTAssertEqual(settings.alarmRussianStyle, .gentleJapanese)
        XCTAssertTrue(settings.alarmSpeechEnabled)
        let direction = AlarmSpeechDirection.instructions(language: .ru, russianStyle: .gentleJapanese)
        XCTAssertTrue(direction.contains("Russian"))
        XCTAssertTrue(direction.contains("Japanese accent"))
    }

    func testHistoryAndRunningTimerSurviveJSONReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var state = AppState()
        let record = EventRecord(kind: .reminder, title: "Take medication", start: d(2026, 10, 5, 10),
                                 end: d(2026, 10, 6, 10), timeZoneID: "Europe/Moscow",
                                 locationType: .noLocation, createdAt: d(2026, 10, 5, 9))
        state.activityHistory = [ActivityHistoryEntry(record: record)]
        state.projectTimers = [ProjectTimerSession(project: "Atlas", startedAt: d(2026, 10, 5, 9))]
        try JSONFileStore(url: url).save(state)
        let loaded = try XCTUnwrap(JSONFileStore(url: url).load())
        XCTAssertEqual(loaded.activityHistory, state.activityHistory)
        XCTAssertEqual(loaded.projectTimers, state.projectTimers)
        XCTAssertNil(loaded.projectTimers[0].endedAt)
    }
}
