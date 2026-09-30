import AppKit
import Observation
import SecretaryCore
import ServiceManagement

/// Owns services and background work: reminder ticks, 5-minute sync, sync on start and wake (DEC-009, DEC-005).
@MainActor
@Observable
final class AppCoordinator {
    static let syncInterval: TimeInterval = 5 * 60
    static let tickInterval: TimeInterval = 10

    let store: AppStore
    let secrets: SecretStore
    @ObservationIgnored let auth: GoogleAuth
    @ObservationIgnored let calendar: GoogleCalendarClient
    @ObservationIgnored let openAI: OpenAIClient
    @ObservationIgnored let geocoder = MapKitGeocoder()
    @ObservationIgnored let location = LocationService()
    @ObservationIgnored let panels = AlarmPanelController()
    @ObservationIgnored let travel: TravelUpdater
    @ObservationIgnored let sync: SyncCoordinator
    @ObservationIgnored let engine: ReminderEngine
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var authNoticeShown = false
    /// Keeps App Nap from throttling the reminder timer.
    @ObservationIgnored private var activity: NSObjectProtocol?

    var googleSignedIn: Bool
    var launchAtLoginError: String?
    var selectedSettingsTab = "reminders"
    @ObservationIgnored private(set) lazy var assistant = AssistantController(app: self)

    init() {
        let store = AppStore(persistence: JSONFileStore(url: JSONFileStore.defaultURL()))
        let secrets = KeychainStore()
        self.store = store
        self.secrets = secrets
        auth = GoogleAuth(secrets: secrets)
        calendar = GoogleCalendarClient(auth: auth)
        openAI = OpenAIClient(secrets: secrets, models: {
            await MainActor.run { (store.state.settings.transcriptionModel, store.state.settings.chatModel) }
        })
        travel = TravelUpdater(store: store, estimator: MapKitTravelEstimator(), location: location)
        sync = SyncCoordinator(store: store, calendar: calendar, geocoder: geocoder, hints: openAI)
        let presenter = AlarmPresenter(speech: openAI, settings: { store.state.settings }, panels: panels)
        engine = ReminderEngine(store: store, preAlarm: sync, travel: travel, presenter: presenter)
        googleSignedIn = auth.isSignedIn
        presenter.isHabit = { [weak self] id in self?.store.state.event(id)?.isHabit == true }
        presenter.onSnooze = { [weak self] alarm, minutes in self?.engine.snooze(alarm, minutes: minutes) }
        presenter.onHabitDone = { [weak self] alarm in self?.markHabitDone(key: alarm.reminderKey) }
        sync.onAuthExpired = { [weak self] in self?.handleAuthExpired() }
    }

    func start() {
        location.start()
        applyLaunchAtLogin(store.state.settings.launchAtLogin)
        // Sync first, then play missed reminders (DEC-009 consequences, DEC-005).
        Task { await syncThenTick() }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Firing scheduled reminders on time")
        let tick = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.engine.tick() }
        }
        tick.tolerance = 1
        timers.append(tick)
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runSync() }
        })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncThenTick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            let sleepingAt = Date()
            Task { @MainActor in self?.stopProjectTimer(now: sleepingAt) }
        }
    }

    func syncThenTick() async {
        await runSync()
        await engine.tick()
    }

    private func runSync() async {
        guard auth.isSignedIn else { return }
        await sync.sync()
    }

    // MARK: - Google account

    func signIn() async -> String? {
        do {
            try await auth.signIn()
            googleSignedIn = true
            authNoticeShown = false
            store.mutate { $0.syncToken = nil }  // fresh full sync after (re)connecting
            await syncThenTick()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signOut() async {
        await auth.signOut()
        googleSignedIn = false
    }

    private func handleAuthExpired() {
        googleSignedIn = false
        guard !authNoticeShown else { return }
        authNoticeShown = true
        // Scheduled reminders keep firing locally (DEC-012).
        panels.showNotice(heading: "Google sign-in expired",
                          body: "Calendar sync and event creation are paused. Reminders already scheduled will still fire.",
                          symbol: "person.crop.circle.badge.exclamationmark",
                          action: ("Sign in", { [weak self] in Task { _ = await self?.signIn() } }))
    }

    // MARK: - Events

    /// Reviews nearby calendar events before inserting, so an existing meeting is never duplicated silently.
    func create(_ draft: EventDraft, createSeparate: Bool = false) async throws -> EventRecord {
        var record = draft.makeRecord(createdAt: Date())
        if draft.kind != .calendarEvent {
            record.managesGoogleEvent = false
            record.end = draft.start.addingTimeInterval(24 * 3600)
            store.mutate { state in
                state.events.append(record)
                state.activityHistory.append(ActivityHistoryEntry(record: record))
            }
            return record
        }
        let created: GoogleEvent
        do {
            if !createSeparate {
                let nearby = try await calendar.nearbyEvents(around: draft.start)
                let candidates = ExistingEventMatcher.candidates(for: draft, in: nearby)
                if !candidates.isEmpty { throw ExistingEventsFound(events: candidates) }
            }
            created = try await calendar.insert(record.googleEvent())
        } catch let found as ExistingEventsFound {
            throw found
        } catch let error as CalendarError {
            if error == .authExpired { handleAuthExpired() }
            throw CreationError(error, language: draft.language)
        }
        record.googleEventID = created.id
        record.htmlLink = created.htmlLink
        if draft.savePlace, let name = draft.newPlaceName, let place = draft.place, let coordinate = place.coordinate {
            store.mutate { state in
                if !state.places.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    state.places.append(SavedPlace(name: name, address: place.address, coordinate: coordinate))
                }
            }
        }
        store.mutate { state in
            state.events.append(record)
            state.activityHistory.append(ActivityHistoryEntry(record: record))
        }
        return record
    }

    func createQuickReminder(_ request: QuickReminder) -> EventRecord {
        let record = EventRecord(kind: .reminder, managesGoogleEvent: false, title: request.title,
                                 start: request.dueAt, end: request.dueAt.addingTimeInterval(24 * 3600),
                                 timeZoneID: TimeZone.current.identifier, locationType: .noLocation,
                                 eventType: .other, language: request.language, createdAt: Date())
        store.mutate { state in
            state.events.append(record)
            state.activityHistory.append(ActivityHistoryEntry(record: record))
        }
        return record
    }

    func markHabitDone(_ record: EventRecord, _ occurrence: Occurrence) {
        guard record.isHabit else { return }
        markHabitDone(key: PlannedReminder.key(eventID: record.id, occurrenceKey: occurrence.key, kind: .standard),
                      until: occurrence.end)
    }

    private func markHabitDone(key: String, until: Date = Date().addingTimeInterval(86_400)) {
        store.mutate { state in
            state.completedHabits[key] = until
            state.handledReminders[key] = until
            state.snoozedAlarms.removeAll { $0.content.reminderKey == key }
        }
    }

    /// Tracks a calendar event already present, without writing to or taking ownership of it.
    func useExisting(_ selected: GoogleEvent, for draft: EventDraft) async throws -> (record: EventRecord, added: Bool) {
        guard let eventID = selected.recurringEventId ?? selected.id else {
            throw CreationError(.notFound, language: draft.language)
        }
        if let existing = store.state.events.first(where: { $0.googleEventID == eventID }) {
            return (existing, false)
        }
        let source: GoogleEvent
        do {
            source = try await calendar.get(eventID: eventID)
        } catch let error as CalendarError {
            throw CreationError(error, language: draft.language)
        }
        let zone = source.start?.timeZone.flatMap(TimeZone.init(identifier:)) ?? draft.timeZone
        guard let start = GoogleTime.parse(source.start, fallbackZone: zone) else {
            throw CreationError(.server(0, "The existing event has no usable start time"), language: draft.language)
        }
        var record = draft.makeRecord(createdAt: Date())
        record.googleEventID = eventID
        record.managesGoogleEvent = false
        record.htmlLink = source.htmlLink
        record.title = source.summary ?? draft.title
        record.start = start
        record.end = GoogleTime.parse(source.end, fallbackZone: zone) ?? start.addingTimeInterval(draft.end.timeIntervalSince(draft.start))
        record.timeZoneID = zone.identifier
        record.recurrence = source.recurrence.flatMap { Recurrence.parse(googleLines: $0, timeZone: zone) }
        record.locationText = source.location ?? ""
        store.mutate { state in
            state.events.append(record)
            state.activityHistory.append(ActivityHistoryEntry(record: record))
        }
        return (record, true)
    }

    // MARK: - Project time

    var activeProjectTimer: ProjectTimerSession? {
        store.state.projectTimers.last { $0.endedAt == nil }
    }

    @discardableResult
    func startProjectTimer(_ project: String, now: Date = Date()) -> ProjectTimerSession {
        let session = ProjectTimerSession(project: project.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: now)
        store.mutate { state in
            for index in state.projectTimers.indices where state.projectTimers[index].endedAt == nil {
                state.projectTimers[index].endedAt = now
            }
            state.projectTimers.append(session)
        }
        return session
    }

    @discardableResult
    func stopProjectTimer(now: Date = Date()) -> ProjectTimerSession? {
        guard let running = activeProjectTimer else { return nil }
        store.mutate { state in
            guard let index = state.projectTimers.firstIndex(where: { $0.id == running.id }) else { return }
            state.projectTimers[index].endedAt = now
        }
        return store.state.projectTimers.first { $0.id == running.id }
    }

    func delete(_ record: EventRecord) async -> String? {
        if let gid = record.googleEventID, record.managesGoogleEvent != false {
            do {
                try await calendar.delete(eventID: gid)
            } catch let error as CalendarError {
                return CreationError(error, language: .en).localizedDescription
            } catch {
                return error.localizedDescription
            }
        }
        store.mutate { state in
            state.events.removeAll { $0.id == record.id }
            state.snoozedAlarms.removeAll { $0.content.eventID == record.id }
        }
        return nil
    }

    /// Next occurrence per assistant event, soonest first.
    func upcoming(now: Date = Date()) -> [(record: EventRecord, occurrence: Occurrence)] {
        store.state.events.compactMap { record in
            record.occurrences(from: now, through: now.addingTimeInterval(400 * 86_400))
                .first(where: { occurrence in
                    let key = PlannedReminder.key(eventID: record.id, occurrenceKey: occurrence.key, kind: .standard)
                    if record.isHabit { return store.state.completedHabits[key] == nil }
                    guard record.isStandaloneReminder else { return true }
                    return store.state.handledReminders[key] == nil
                }).map { (record, $0) }
        }.sorted { $0.occurrence.start < $1.occurrence.start }
    }

    // MARK: - Settings

    func currentAddress() async -> (address: String?, error: String?) {
        do {
            let fix = try await location.currentFix()
            guard let address = try await geocoder.address(at: fix.coordinate) else {
                return (nil, "No street address was found for this location. Enter the address manually.")
            }
            return (address, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if !enabled, SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }

    /// Sets the reserved home place from an address (DEC-023).
    func setHome(address: String) async -> String? {
        guard let found = try? await geocoder.geocode(address, near: nil) else {
            return "Address not found."
        }
        store.mutate { state in
            if let i = state.places.firstIndex(where: \.isHome) {
                state.places[i].address = found.address
                state.places[i].coordinate = found.coordinate
            } else {
                state.places.insert(SavedPlace(name: "Home", address: found.address, coordinate: found.coordinate,
                                               isHome: true), at: 0)
            }
        }
        return nil
    }

    func relocate(placeID: UUID, address: String) async -> String? {
        guard let found = try? await geocoder.geocode(address, near: store.state.home?.coordinate) else {
            return "Address not found."
        }
        store.mutate { state in
            guard let i = state.places.firstIndex(where: { $0.id == placeID }) else { return }
            state.places[i].address = found.address
            state.places[i].coordinate = found.coordinate
        }
        return nil
    }
}

struct ExistingEventsFound: Error {
    let events: [GoogleEvent]
}

struct CreationError: LocalizedError {
    let underlying: CalendarError
    let language: SpeechLanguage

    init(_ underlying: CalendarError, language: SpeechLanguage) {
        self.underlying = underlying
        self.language = language
    }

    var errorDescription: String? {
        let ru = language == .ru
        switch underlying {
        case .notSignedIn:
            return ru ? "Google Calendar не подключён. Подключите его в настройках. Событие не создано."
                      : "Google Calendar is not connected. Connect it in Settings. No event was created."
        case .authExpired:
            return ru ? "Вход в Google истёк. Войдите снова. Событие не создано."
                      : "Google sign-in expired. Sign in again. No event was created."
        case .network:
            return ru ? "Нет связи с Google Calendar. Событие не создано." : "Can't reach Google Calendar. No event was created."
        case let .server(code, body):
            let detail = GoogleAPIErrorDetails(body: body)
            let explanation = [detail.message, detail.reason.map { "[\($0)]" }].compactMap { $0 }.joined(separator: " ")
            let lead = ru ? "Ошибка Google Calendar (\(code))" : "Google Calendar error (\(code))"
            return lead + (explanation.isEmpty ? "" : ": \(explanation)")
                + (ru ? ". Событие не создано." : ". No event was created.")
        case .notFound, .syncTokenExpired:
            return ru ? "Ошибка Google Calendar. Событие не создано." : "Google Calendar error. No event was created."
        }
    }
}
