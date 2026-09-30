import XCTest
@testable import SecretaryCore

@MainActor
final class DialogueTests: XCTestCase {
    let now = d(2026, 10, 5, 9)

    func makeSession(_ parser: ScriptedParser, places: [SavedPlace] = [homePlace],
                     geocoder: FakeGeocoder = FakeGeocoder(), travel seconds: TimeInterval? = 1800) -> (DialogueSession, AppStore) {
        var state = AppState()
        state.places = places
        let store = AppStore(persistence: MemoryStore(state))
        let travel = TravelUpdater(store: store, estimator: FakeTravel(seconds), location: FakeLocation(nil))
        return (DialogueSession(parser: parser, geocoder: geocoder, travel: travel, store: store,
                                clock: { d(2026, 10, 5, 9) }, localZone: moscow), store)
    }

    func testTrainingWithoutLocationAsksWhere() async {
        let parser = ScriptedParser([.success(parsed(location: .unknown, question: "Where is your training?"))])
        let (session, _) = makeSession(parser)
        let step = await session.handle("Training every Monday, Wednesday and Friday at 6 pm")
        XCTAssertEqual(step, .ask("Where is your training?"))
    }

    func testReminderDoesNotAskForTitleOrLocation() async {
        let parser = ScriptedParser([.success(parsed(title: nil, kind: .reminder, location: .unknown,
                                                     question: "Where?"))])
        let (session, _) = makeSession(parser)
        let step = await session.handle("Remind me at 6 pm")
        guard case let .summary(draft, _) = step else { return XCTFail("expected reminder summary") }
        XCTAssertEqual(draft.kind, .reminder)
        XCTAssertEqual(draft.title, "Reminder")
        XCTAssertEqual(draft.locationType, .noLocation)
        XCTAssertEqual(session.questionsAsked, 0)
    }

    func testDailyHabitIsLocalAndNeedsNoLocationQuestion() async {
        let parser = ScriptedParser([.success(parsed(title: "Принять таблетки", kind: .habit,
                                                     location: .unknown, language: .ru))])
        let (session, _) = makeSession(parser)
        let step = await session.handle("Проверяй каждый день в шесть, принял ли я таблетки")
        guard case let .summary(draft, _) = step else { return XCTFail("expected habit summary") }
        XCTAssertEqual(draft.kind, .habit)
        XCTAssertEqual(draft.recurrence?.frequency, .daily)
        XCTAssertEqual(draft.locationType, .noLocation)
        XCTAssertEqual(session.questionsAsked, 0)
    }

    func testUnrelatedQuestionDoesNotBecomeCalendarEvent() async {
        let parser = ScriptedParser([.success(parsed(title: "What time it is", intent: .other))])
        let (session, _) = makeSession(parser)
        guard case .failed = await session.handle("What time is it?") else {
            return XCTFail("an unrelated question must not create an event")
        }
    }

    func testHomeAnswerLeadsToSummaryAndOnlyConfirmationCreates() async {
        let weekly = ParsedRequest.ParsedRecurrence(frequency: .weekly, interval: 1, by_weekday: [.MO, .WE, .FR],
                                                    count: nil, until_local: nil)
        let parser = ScriptedParser([.success(parsed(recurrence: weekly, location: .unknown, question: "Where?")),
                                     .success(parsed(recurrence: weekly, location: .home))])
        let (session, _) = makeSession(parser)
        _ = await session.handle("Training every Mon/Wed/Fri at 6 pm")
        let step = await session.handle("At home")
        guard case let .summary(draft, lines) = step else { return XCTFail("expected summary, got \(step)") }
        XCTAssertEqual(draft.locationType, .home)
        XCTAssertEqual(draft.recurrence?.byWeekday, [.MO, .WE, .FR])
        XCTAssertEqual(draft.start, d(2026, 10, 5, 18))
        XCTAssertTrue(lines.contains("Reminder at 5:55 PM"))
        XCTAssertTrue(lines.contains { $0.contains("Europe/Moscow") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Repeats every week (Mon/Wed/Fri)") })

        let confirmed = await session.handle("yes")
        XCTAssertEqual(confirmed, .confirmed(draft))
        XCTAssertEqual(parser.conversations.get.count, 2, "'yes' needs no AI round trip")
    }

    func testCancelAtSummary() async {
        let parser = ScriptedParser([.success(parsed(location: .home))])
        let (session, _) = makeSession(parser)
        _ = await session.handle("Training today at 6 pm at home")
        let step = await session.handle("отмена")
        XCTAssertEqual(step, .cancelled)
    }

    func testCorrectionReparsesAndShowsNewSummary() async {
        let parser = ScriptedParser([.success(parsed(location: .home)),
                                     .success(parsed(start: "2026-10-05T19:00", location: .home))])
        let (session, _) = makeSession(parser)
        _ = await session.handle("Training today at 6 pm at home")
        let step = await session.handle("No, make it 7 pm")
        guard case let .summary(draft, _) = step else { return XCTFail("expected summary") }
        XCTAssertEqual(draft.start, d(2026, 10, 5, 19))
        XCTAssertTrue(parser.conversations.get[1].contains { $0.text.hasPrefix("Draft summary:") })
    }

    func testAtMostThreeQuestionsThenDefaults() async {
        let unknown = parsed(location: .unknown, question: "Where?")
        let parser = ScriptedParser([.success(unknown), .success(unknown), .success(unknown), .success(unknown)])
        let (session, _) = makeSession(parser)
        var step = await session.handle("Training at 6 pm")
        for _ in 0..<2 { step = await session.handle("hmm") }
        XCTAssertEqual(session.questionsAsked, 3)
        step = await session.handle("not sure")
        guard case let .summary(draft, _) = step else { return XCTFail("expected summary after 3 questions") }
        XCTAssertEqual(draft.locationType, .noLocation)
    }

    func testMissingTimeAfterThreeQuestionsFails() async {
        let noTime = parsed(start: nil, question: "When?")
        let parser = ScriptedParser(Array(repeating: .success(noTime), count: 4))
        let (session, _) = makeSession(parser)
        _ = await session.handle("Training")
        _ = await session.handle("soon")
        _ = await session.handle("later")
        let step = await session.handle("don't know")
        guard case .failed = step else { return XCTFail("expected failure") }
    }

    func testOfflineAndMissingKeyCreateNothing() async {
        let (session, _) = makeSession(ScriptedParser([.failure(.offline)]))
        let step = await session.handle("Meeting at 10:30")
        XCTAssertEqual(step, .failed(AIError.offline.message(.en)))
        let (session2, _) = makeSession(ScriptedParser([.failure(.missingAPIKey)]))
        let step2 = await session2.handle("Meeting at 10:30")
        XCTAssertEqual(step2, .failed(AIError.missingAPIKey.message(.en)))
    }

    func testKnownSavedPlaceNeedsNoQuestion() async {
        let gymPlace = SavedPlace(name: "gym", address: "Gym street 5", coordinate: gym)
        let parser = ScriptedParser([.success(parsed(location: .off_site, placeName: "Gym"))])
        let (session, _) = makeSession(parser, places: [homePlace, gymPlace])
        let step = await session.handle("Training at the gym at 6 pm")
        guard case let .summary(draft, lines) = step else { return XCTFail("expected summary") }
        XCTAssertEqual(draft.place?.coordinate, gym)
        XCTAssertNil(draft.newPlaceName)
        XCTAssertTrue(lines.contains("'Get ready' at 5:15 PM"))
        XCTAssertTrue(lines.contains("'Leave now' at 5:30 PM"))
    }

    func testAmbiguousSavedPlaceAsks() async {
        let places = [homePlace, SavedPlace(name: "gym downtown", address: "A", coordinate: gym),
                      SavedPlace(name: "gym north", address: "B", coordinate: gym)]
        let parser = ScriptedParser([.success(parsed(location: .off_site, placeName: "gym"))])
        let (session, _) = makeSession(parser, places: places)
        let step = await session.handle("Training at the gym at 6 pm")
        guard case let .ask(q) = step else { return XCTFail("expected question") }
        XCTAssertTrue(q.contains("gym downtown") && q.contains("gym north"))
    }

    func testNewPlaceIsGeocodedReadBackAndOfferedForSaving() async {
        let geocoder = FakeGeocoder(results: ["fitness club, lenina 1": GeocodedAddress(address: "Fitness Club, Lenina St 1, Moscow", coordinate: gym)])
        let parser = ScriptedParser([.success(parsed(location: .off_site, placeName: "fitness club", address: "Fitness club, Lenina 1"))])
        let (session, _) = makeSession(parser, geocoder: geocoder)
        let step = await session.handle("Training at the fitness club on Lenina 1 at 6 pm")
        guard case let .summary(draft, lines) = step else { return XCTFail("expected summary") }
        XCTAssertEqual(draft.newPlaceName, "fitness club")
        XCTAssertTrue(draft.savePlace)
        XCTAssertTrue(lines.contains { $0.contains("Lenina St 1, Moscow") }, "resolved address is read back")
        XCTAssertTrue(lines.contains("Save as 'fitness club'?"))
    }

    func testGeocodingFailureAsks() async {
        let parser = ScriptedParser([.success(parsed(location: .off_site, placeName: "Zzz"))])
        let (session, _) = makeSession(parser)
        let step = await session.handle("Training at Zzz at 6 pm")
        guard case let .ask(q) = step else { return XCTFail("expected question") }
        XCTAssertTrue(q.contains("couldn't find"))
    }

    func testOtherTypeOffSiteAsksPrepTime() async {
        let gymPlace = SavedPlace(name: "gym", address: "Gym street 5", coordinate: gym)
        let parser = ScriptedParser([.success(parsed(location: .off_site, placeName: "gym", type: .other))])
        let (session, _) = makeSession(parser, places: [homePlace, gymPlace])
        let step = await session.handle("Something at the gym at 6 pm")
        guard case let .ask(q) = step else { return XCTFail("expected prep question") }
        XCTAssertTrue(q.contains("get ready"))
    }

    func testTravelUnavailableShowsFallbackInSummary() async {
        let gymPlace = SavedPlace(name: "gym", address: "Gym street 5", coordinate: gym)
        let parser = ScriptedParser([.success(parsed(location: .off_site, placeName: "gym"))])
        let (session, _) = makeSession(parser, places: [homePlace, gymPlace], travel: nil)
        guard case let .summary(_, lines) = await session.handle("Training at gym at 6 pm") else { return XCTFail() }
        XCTAssertTrue(lines.contains("'Leave now' at 5:15 PM (no travel estimate, default buffer)"))
    }

    func testGetReadyPastAtCreationIsAnnounced() async {
        let gymPlace = SavedPlace(name: "gym", address: "Gym street 5", coordinate: gym)
        let parser = ScriptedParser([.success(parsed(start: "2026-10-05T09:40", location: .off_site, placeName: "gym"))])
        let (session, _) = makeSession(parser, places: [homePlace, gymPlace])
        guard case let .summary(_, lines) = await session.handle("Training at gym at 9:40") else { return XCTFail() }
        XCTAssertTrue(lines.contains("The 'get ready' time has already passed; only 'leave now' is scheduled."))
        XCTAssertFalse(lines.contains { $0.hasPrefix("'Get ready'") })
    }

    func testMacTimeZoneByDefaultAndNamedZoneHonored() async {
        let parser = ScriptedParser([.success(parsed(title: "Meeting with Manoj", start: "2026-10-05T10:30", location: .no_location)),
                                     .success(parsed(title: "Call", start: "2026-10-05T10:30", zone: "Europe/London", location: .no_location))])
        let (s1, _) = makeSession(parser)
        guard case let .summary(d1, _) = await s1.handle("meeting with Manoj at 10:30 today") else { return XCTFail() }
        XCTAssertEqual(d1.start, d(2026, 10, 5, 10, 30))
        XCTAssertEqual(d1.timeZoneID, "Europe/Moscow")
        XCTAssertEqual(d1.title, "Meeting with Manoj")

        let (s2, _) = makeSession(parser)
        guard case let .summary(d2, lines) = await s2.handle("call at 10:30 London time") else { return XCTFail() }
        XCTAssertEqual(d2.timeZoneID, "Europe/London")
        XCTAssertEqual(d2.start, d(2026, 10, 5, 12, 30))  // 10:30 BST = 12:30 MSK
        XCTAssertTrue(lines.contains { $0.contains("your time 12:30 PM") })
    }

    func testContextCarriesLocalZoneAndSavedPlaces() async {
        let parser = ScriptedParser([.success(parsed(location: .home))])
        let (session, _) = makeSession(parser, places: [homePlace, SavedPlace(name: "office", address: "X", coordinate: gym)])
        _ = await session.handle("x")
        let ctx = parser.contexts.get[0]
        XCTAssertEqual(ctx.localZone, moscow)
        XCTAssertEqual(ctx.savedPlaceNames, ["office"])
        XCTAssertTrue(ParserPrompt.system(ctx).contains("2026-10-05T09:00, Monday"))
    }

    func testRussianSummary() async {
        let parser = ScriptedParser([.success(parsed(title: "Тренировка", location: .home, hint: "Переоденься.", language: .ru))])
        let (session, _) = makeSession(parser)
        guard case let .summary(_, lines) = await session.handle("тренировка сегодня в 6 вечера дома") else { return XCTFail() }
        XCTAssertTrue(lines.contains("Напоминание в 17:55"))
        XCTAssertTrue(lines.contains("Место: дома"))
    }
}

final class ParserContractTests: XCTestCase {
    func testRequestBodyUsesStrictSchema() throws {
        let ctx = ParseContext(now: d(2026, 10, 5, 9), localZone: moscow, savedPlaceNames: [], prepMinutesByType: EventType.defaultPrepMinutes)
        let data = try ParserPrompt.requestBody(model: "m", conversation: [ChatTurn(.user, "hi")], context: ctx)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let format = json["response_format"] as! [String: Any]
        let schema = format["json_schema"] as! [String: Any]
        XCTAssertEqual(schema["strict"] as? Bool, true)
        XCTAssertEqual((json["messages"] as! [[String: String]]).map { $0["role"]! }, ["system", "user"])
    }

    func testDecodeResponse() throws {
        let content = """
        {"intent":"create_event","language":"ru","question":null,"event":{"title":"Митинг с Manoj","start_local":"2026-10-05T10:30",\
        "time_zone":null,"duration_minutes":null,"recurrence":null,"participants":["Manoj"],"location_type":"no_location",\
        "place_name":null,"address":null,"event_type":"meeting","prep_minutes":null,"prep_hint":null}}
        """
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let p = try ParserPrompt.decodeResponse(response)
        XCTAssertEqual(p.event.title, "Митинг с Manoj")
        XCTAssertEqual(p.event.participants, ["Manoj"])
        XCTAssertEqual(p.language, .ru)
    }

    func testInvalidZoneFallsBackToMacZone() {
        XCTAssertEqual(LocalTimeParser.zone(named: "Mars/Olympus", fallback: moscow), moscow)
    }
}
