import Foundation

public enum DialogueStep: Equatable, Sendable {
    /// A clarifying question, shown and spoken; the next user reply answers it.
    case ask(String)
    /// Confirmation summary; awaiting yes, a correction or cancel.
    case summary(EventDraft, lines: [String])
    case confirmed(EventDraft)
    case cancelled
    case failed(String)
}

/// Clarifying dialogue and confirmation for one request (REQ-002, DEC-011, DEC-015, DEC-022, DEC-023).
@MainActor
public final class DialogueSession {
    public static let maxQuestions = 3

    private let parser: RequestParsing
    private let geocoder: Geocoding
    private let travel: TravelUpdater?
    private let store: AppStore
    private let clock: () -> Date
    private let localZone: TimeZone

    public private(set) var conversation: [ChatTurn] = []
    public private(set) var questionsAsked = 0
    public private(set) var step: DialogueStep?
    private var language: SpeechLanguage = .en
    private var lastParsed: ParsedRequest?

    public init(parser: RequestParsing, geocoder: Geocoding, travel: TravelUpdater?, store: AppStore,
                clock: @escaping () -> Date = Date.init, localZone: TimeZone = .current) {
        self.parser = parser
        self.geocoder = geocoder
        self.travel = travel
        self.store = store
        self.clock = clock
        self.localZone = localZone
    }

    /// Handles the first request or any later reply (answer, confirmation, correction, cancel).
    public func handle(_ text: String) async -> DialogueStep {
        let result = await process(text)
        step = result
        return result
    }

    /// Applies an edit made in the confirmation form and returns the refreshed summary.
    public func edit(_ draft: EventDraft) async -> DialogueStep {
        // Record the form edit so a later voice correction re-parses from the edited values.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: draft.timeZoneID) ?? localZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let place = draft.place.map { [$0.name, $0.address].compactMap { $0 }.joined(separator: ", ") } ?? "none"
        conversation.append(ChatTurn(.user, "I edited the draft in the form: title \"\(draft.title)\", start \(f.string(from: draft.start)) "
            + "(\(draft.timeZoneID)), location type \(draft.locationType.rawValue), place \(place), "
            + "preparation \(draft.prepMinutes) min. Keep these values unless I change them."))
        var d = draft
        switch d.locationType {
        case .home:
            d.place = store.state.home.map { ResolvedPlace(name: "Home", address: $0.address, coordinate: $0.coordinate) }
            d.newPlaceName = nil
        case .noLocation:
            d.place = nil
            d.newPlaceName = nil
        case .offSite:
            break
        }
        await estimateTravel(&d)
        let result = await summarize(d)
        step = result
        return result
    }

    private func process(_ text: String) async -> DialogueStep {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return step ?? .failed(language == .ru ? "Пустой запрос." : "Empty request.") }

        if case let .summary(draft, _) = step {
            switch Self.quickIntent(trimmed) {
            case .confirm: return .confirmed(draft)
            case .cancel, .no: return .cancelled
            case nil: break
            }
        } else if step != nil, Self.quickIntent(trimmed) == .cancel {
            // A plain "no" answers a clarifying question; only an explicit cancel stops the request.
            return .cancelled
        }

        conversation.append(ChatTurn(.user, trimmed))
        let parsed: ParsedRequest
        do {
            parsed = try await parser.parse(conversation: conversation, context: context())
        } catch let error as AIError {
            return .failed(error.message(language))
        } catch {
            return .failed(AIError.service(error.localizedDescription).message(language))
        }
        language = parsed.language
        lastParsed = parsed

        switch parsed.intent {
        case .cancel: return .cancelled
        case .confirm:
            if case let .summary(draft, _) = step { return .confirmed(draft) }
        case .create_event:
            break
        case .other:
            return .failed(phrase("I didn't hear a reminder, daily check-in, or calendar request. Nothing was created.",
                                  "Не услышал просьбу о напоминании, ежедневной проверке или встрече. Ничего не создано."))
        }
        return await resolve(parsed)
    }

    private func context() -> ParseContext {
        let state = store.state
        return ParseContext(now: clock(), localZone: localZone,
                            savedPlaceNames: state.places.filter { !$0.isHome }.map(\.name),
                            prepMinutesByType: state.settings.prepMinutesByType)
    }

    private var canAsk: Bool { questionsAsked < Self.maxQuestions }

    private func ask(_ question: String) -> DialogueStep {
        questionsAsked += 1
        conversation.append(ChatTurn(.assistant, question))
        return .ask(question)
    }

    private func phrase(_ en: String, _ ru: String) -> String { language == .ru ? ru : en }

    // MARK: - Resolution rules

    private func resolve(_ parsed: ParsedRequest) async -> DialogueStep {
        let e = parsed.event
        let settings = store.state.settings
        let kind = e.kind ?? .calendarEvent

        // Required fields: title and start (DEC-015).
        let zone = LocalTimeParser.zone(named: e.time_zone, fallback: localZone)
        let parsedStart = e.start_local.flatMap { LocalTimeParser.date($0, zone: zone) }
        let start: Date? = {
            guard kind == .habit, let parsedStart, parsedStart <= clock() else { return parsedStart }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let time = calendar.dateComponents([.hour, .minute], from: parsedStart)
            return calendar.nextDate(after: clock(), matching: time, matchingPolicy: .nextTime)
        }()
        let statedTitle = e.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = statedTitle.isEmpty && kind != .calendarEvent
            ? phrase("Reminder", "Напоминание") : statedTitle
        guard !title.isEmpty, let start else {
            if canAsk {
                return ask(parsed.question ?? phrase("What is the event and when does it start?",
                                                      "Что за событие и когда оно начинается?"))
            }
            return .failed(phrase("I couldn't get the event title and start time, so no event was created.",
                                  "Не удалось понять название и время начала, событие не создано."))
        }
        if kind == .reminder, start <= clock() {
            return canAsk ? ask(phrase("When should I remind you?", "Когда вам напомнить?"))
                          : .failed(phrase("The reminder time has passed.", "Время напоминания уже прошло."))
        }

        var draft = EventDraft(
            title: title, start: start,
            end: start.addingTimeInterval(Double(max(5, e.duration_minutes ?? 60)) * 60),
            timeZoneID: zone.identifier,
            recurrence: kind == .habit ? Recurrence(frequency: .daily) : LocalTimeParser.recurrence(e.recurrence, zone: zone),
            participants: e.participants, locationType: .noLocation, place: nil, newPlaceName: nil,
            savePlace: false, eventType: e.event_type,
            alarmSoundID: nil,
            prepMinutes: e.prep_minutes ?? settings.prepMinutes(for: e.event_type),
            prepHint: e.prep_hint.map { String($0.prefix(300)) }, origin: .automatic, language: language,
            travelSeconds: nil)
        draft.kind = kind
        let previousOrigin: OriginChoice? = {
            if case let .summary(old, _) = step { return old.origin }
            return nil
        }()
        if let previousOrigin { draft.origin = previousOrigin }
        if case let .summary(old, _) = step { draft.alarmSoundID = old.alarmSoundID }

        if kind != .calendarEvent {
            draft.locationType = .noLocation
            draft.prepHint = nil
            return await summarize(draft)
        }

        // Location type (DEC-011).
        switch e.location_type {
        case .unknown:
            if canAsk {
                return ask(parsed.question ?? phrase("Where does it take place?", "Где это будет проходить?"))
            }
            draft.locationType = .noLocation
        case .no_location:
            draft.locationType = .noLocation
        case .home:
            draft.locationType = .home
            if let home = store.state.home {
                draft.place = ResolvedPlace(name: "Home", address: home.address, coordinate: home.coordinate)
            }
        case .off_site:
            draft.locationType = .offSite
            if let question = await resolvePlace(e, into: &draft) { return question }
        }

        // Preparation time for type 'other' when unclear (DEC-022).
        if draft.locationType == .offSite, e.prep_minutes == nil, e.event_type == .other, canAsk {
            return ask(phrase("How many minutes do you need to get ready before leaving?",
                              "Сколько минут нужно на сборы перед выходом?"))
        }

        await estimateTravel(&draft)
        return await summarize(draft)
    }

    /// Resolves an off-site place; returns a question step when one is needed.
    private func resolvePlace(_ e: ParsedRequest.ParsedEvent, into draft: inout EventDraft) async -> DialogueStep? {
        let places = store.state.places.filter { !$0.isHome }
        if let name = e.place_name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let matches = PlaceMatcher.matches(name, in: places)
            if matches.count == 1, let p = matches.first {
                draft.place = ResolvedPlace(name: p.name, address: p.address, coordinate: p.coordinate)
                return nil
            }
            if matches.count > 1 {
                if canAsk {
                    let names = matches.map { "\($0.name) (\($0.address))" }.joined(separator: phrase(" or ", " или "))
                    return ask(phrase("Which place do you mean: \(names)?", "Какое место имеется в виду: \(names)?"))
                }
                let p = matches[0]
                draft.place = ResolvedPlace(name: p.name, address: p.address, coordinate: p.coordinate)
                return nil
            }
        }
        guard let query = (e.address ?? e.place_name)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            if canAsk { return ask(phrase("What is the address?", "Какой адрес?")) }
            return nil
        }
        let found = try? await geocoder.geocode(query, near: store.state.home?.coordinate)
        guard let found else {
            if canAsk {
                return ask(phrase("I couldn't find \"\(query)\" on the map. What is the address?",
                                  "Не нашёл «\(query)» на карте. Какой адрес?"))
            }
            // Out of questions: keep the text; the fallback buffer will be used (REQ-005).
            draft.place = ResolvedPlace(name: e.place_name, address: query, coordinate: nil)
            return nil
        }
        draft.place = ResolvedPlace(name: e.place_name, address: found.address, coordinate: found.coordinate)
        if let name = e.place_name, !name.isEmpty {
            draft.newPlaceName = name
            draft.savePlace = true  // Asked in the summary (DEC-023).
        }
        return nil
    }

    private func estimateTravel(_ draft: inout EventDraft) async {
        guard draft.locationType == .offSite, let travel else {
            draft.travelSeconds = nil
            return
        }
        let buffer = Double(store.state.settings.fallbackBufferMinutes) * 60
        let departure = max(clock(), draft.start.addingTimeInterval(-(draft.travelSeconds ?? buffer)))
        draft.travelSeconds = await travel.estimate(origin: draft.origin, destination: draft.place?.coordinate,
                                                    departure: departure, now: clock())
    }

    private func summarize(_ draft: EventDraft) async -> DialogueStep {
        let now = clock()
        let record = draft.makeRecord(createdAt: now)
        let settings = store.state.settings
        let first = record.occurrences(from: now, through: now.addingTimeInterval(400 * 86_400)).first
        var reminders = first.map { ReminderPlanner.reminders(for: $0, record: record, settings: settings) } ?? []
        let skipped = reminders.contains { ReminderPlanner.isSkippedAtCreation($0, createdAt: now) }
        reminders.removeAll { ReminderPlanner.isSkippedAtCreation($0, createdAt: now) }
        let lines = SpokenText.summary(for: draft, reminders: reminders, skippedGetReady: skipped,
                                       originLabel: await originLabel(draft.origin), localZone: localZone)
        conversation.append(ChatTurn(.assistant, "Draft summary: " + lines.joined(separator: " | ")))
        return .summary(draft, lines: lines)
    }

    private func originLabel(_ origin: OriginChoice) async -> String? {
        switch origin {
        case let .place(id):
            return store.state.places.first { $0.id == id }.map { $0.isHome ? phrase("home", "дом") : $0.name }
        case .automatic:
            return phrase("current Mac location (home if unavailable)", "текущее местоположение Mac (или дом)")
        }
    }

    // MARK: - Quick intents

    enum QuickIntent { case confirm, cancel, no }

    /// Local yes/cancel detection so confirming needs no extra AI round trip.
    static func quickIntent(_ text: String) -> QuickIntent? {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let yes: Set<String> = ["yes", "yeah", "yep", "ok", "okay", "confirm", "sure", "да", "ок", "окей",
                                "подтверждаю", "да, создай", "создай", "yes please", "да, давай", "давай"]
        let cancel: Set<String> = ["cancel", "stop", "отмена", "отмени", "стоп", "не надо"]
        let no: Set<String> = ["no", "nope", "нет"]
        if yes.contains(normalized) { return .confirm }
        if cancel.contains(normalized) { return .cancel }
        if no.contains(normalized) { return .no }
        return nil
    }
}

public enum PlaceMatcher {
    /// Exact name match wins; otherwise places whose name contains the query or vice versa.
    public static func matches(_ name: String, in places: [SavedPlace]) -> [SavedPlace] {
        let q = name.lowercased()
        let exact = places.filter { $0.name.lowercased() == q }
        if !exact.isEmpty { return exact }
        return places.filter {
            let n = $0.name.lowercased()
            return n.contains(q) || q.contains(n)
        }
    }
}
