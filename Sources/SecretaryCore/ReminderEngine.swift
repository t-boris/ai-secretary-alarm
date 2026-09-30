import Foundation

/// Computes and stores travel estimates (DEC-006, DEC-014, DEC-021).
@MainActor
public final class TravelUpdater {
    /// A Mac location fix older than this is ignored and home is used instead (DEC-014).
    public static let maxFixAge: TimeInterval = 30 * 60

    private let store: AppStore
    private let estimator: TravelEstimating
    private let location: LocationProviding

    public init(store: AppStore, estimator: TravelEstimating, location: LocationProviding) {
        self.store = store
        self.estimator = estimator
        self.location = location
    }

    public func origin(for choice: OriginChoice, now: Date) async -> Coordinate? {
        let state = store.state
        switch choice {
        case let .place(id):
            if let place = state.places.first(where: { $0.id == id }) { return place.coordinate }
        case .automatic:
            if let fix = await location.latestFix(), now.timeIntervalSince(fix.timestamp) <= Self.maxFixAge {
                return fix.coordinate
            }
        }
        return state.home?.coordinate
    }

    /// Travel seconds, or nil when origin, destination or the service is unavailable.
    public func estimate(origin choice: OriginChoice, destination: Coordinate?, departure: Date, now: Date) async -> TimeInterval? {
        guard let destination, let origin = await origin(for: choice, now: now) else { return nil }
        return try? await estimator.travelTime(from: origin, to: destination,
                                               mode: store.state.settings.transportMode, departure: departure)
    }

    /// Recomputes the estimate of one occurrence; on failure the last known estimate is kept.
    @discardableResult
    public func refresh(eventID: UUID, occurrence: Occurrence, now: Date) async -> Bool {
        guard occurrence.locationType == .offSite, let record = store.state.event(eventID) else { return false }
        let settings = store.state.settings
        let current = record.travelEstimate(for: occurrence)?.seconds ?? Double(settings.fallbackBufferMinutes) * 60
        let departure = max(now, occurrence.start.addingTimeInterval(-current))
        guard let seconds = await estimate(origin: record.origin, destination: occurrence.place?.coordinate,
                                           departure: departure, now: now) else { return false }
        store.mutate { state in
            guard var r = state.event(eventID) else { return }
            r.travel[occurrence.key] = TravelEstimate(seconds: seconds, computedAt: now)
            state.update(r)
        }
        return true
    }
}

@MainActor
private final class DeadlineFlag {
    var done = false
}

/// Runs `operation` but returns `fallback` if it takes longer than `seconds`, so a slow network call
/// never holds up an alarm.
@MainActor
public func withDeadline<T: Sendable>(_ seconds: TimeInterval, fallback: T,
                                      _ operation: @escaping @MainActor () async -> T) async -> T {
    let once = DeadlineFlag()
    return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        let work = Task { @MainActor in
            let value = await operation()
            guard !once.done else { return }
            once.done = true
            cont.resume(returning: value)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !once.done else { return }
            once.done = true
            work.cancel()
            cont.resume(returning: fallback)
        }
    }
}

@MainActor
public protocol PreAlarmChecking: AnyObject {
    func refetch(_ occurrence: Occurrence) async -> RefetchOutcome
}

extension SyncCoordinator: PreAlarmChecking {}

/// Local, offline-capable scheduler for all reminders (REQ-004, REQ-005).
@MainActor
public final class ReminderEngine {
    /// A recomputed alarm more than this far in the future is deferred instead of fired.
    static let deferTolerance: TimeInterval = 60
    static let preRefreshLead: TimeInterval = 15 * 60
    /// Upper bounds for the pre-alarm network work; on timeout the last known data is used.
    static let refetchDeadline: TimeInterval = 8
    static let travelDeadline: TimeInterval = 6

    private let store: AppStore
    private let preAlarm: PreAlarmChecking?
    private let travel: TravelUpdater
    private let presenter: AlarmPresenting
    private let clock: () -> Date
    private let localZone: () -> TimeZone
    private var running = false

    public init(store: AppStore, preAlarm: PreAlarmChecking?, travel: TravelUpdater, presenter: AlarmPresenting,
                clock: @escaping () -> Date = Date.init, localZone: @escaping () -> TimeZone = { .current }) {
        self.store = store
        self.preAlarm = preAlarm
        self.travel = travel
        self.presenter = presenter
        self.clock = clock
        self.localZone = localZone
    }

    /// Reminders of occurrences that have not ended, within the next 36 hours.
    public func upcomingReminders(now: Date) -> [PlannedReminder] {
        let state = store.state
        return state.events.flatMap {
            ReminderPlanner.reminders(for: $0, settings: state.settings, from: now, through: now.addingTimeInterval(36 * 3600))
        }.sorted { $0.fireDate < $1.fireDate }
    }

    /// Runs refresh points and plays every due reminder. Called periodically, on start and on wake (after sync).
    public func tick() async {
        guard !running else { return }
        running = true
        defer { running = false }

        let now = clock()
        store.mutate { $0.prune(now: now) }
        let planned = upcomingReminders(now: now)

        // Refresh 15 minutes before 'get ready' (DEC-021).
        for r in planned where r.kind == .getReady && r.fireDate > now
            && r.fireDate.addingTimeInterval(-Self.preRefreshLead) <= now {
            let refreshKey = r.key + "|pre15"
            guard store.state.handledRefreshes[refreshKey] == nil else { continue }
            let travel = self.travel
            _ = await withDeadline(Self.travelDeadline, fallback: false) {
                await travel.refresh(eventID: r.eventID, occurrence: r.occurrence, now: now)
            }
            store.mutate { $0.handledRefreshes[refreshKey] = r.occurrence.end }
        }

        let due = dueReminders(in: planned, now: now)
        for r in due {
            await fire(r)
        }
        let snoozes = store.state.snoozedAlarms.filter { $0.fireDate <= now }
        for snooze in snoozes {
            guard store.state.snoozedAlarms.contains(where: { $0.id == snooze.id }) else { continue }
            store.mutate { $0.snoozedAlarms.removeAll { $0.id == snooze.id } }
            await presenter.present(snooze.content)
        }
    }

    public func snooze(_ content: AlarmContent, minutes: Int) {
        guard [5, 10, 60].contains(minutes) else { return }
        store.mutate { $0.snoozedAlarms.append(SnoozedAlarm(content: content,
                                                               fireDate: clock().addingTimeInterval(Double(minutes) * 60))) }
    }

    /// Due, not yet handled reminders for occurrences that have not ended (DEC-005), after DEC-022 drops.
    func dueReminders(in planned: [PlannedReminder], now: Date) -> [PlannedReminder] {
        let handled = store.state.handledReminders
        let due = planned.filter { $0.fireDate <= now && handled[$0.key] == nil
            && store.state.completedHabits[$0.key] == nil && $0.occurrence.end > now }
        var drop: [PlannedReminder] = []
        for r in due where r.kind == .getReady {
            let createdAt = store.state.event(r.eventID)?.createdAt ?? .distantPast
            let leaveDue = due.contains { $0.kind == .leaveNow && $0.occurrence.key == r.occurrence.key && $0.eventID == r.eventID }
            if ReminderPlanner.isSkippedAtCreation(r, createdAt: createdAt) || leaveDue { drop.append(r) }
        }
        if !drop.isEmpty {
            store.mutate { state in
                for r in drop { state.handledReminders[r.key] = r.occurrence.end }
            }
        }
        let dropped = Set(drop.map(\.key))
        return due.filter { !dropped.contains($0.key) }
    }

    private func fire(_ reminder: PlannedReminder) async {
        // Re-check the event right before the alarm; offline uses the last known version (DEC-009).
        if store.state.event(reminder.eventID)?.isStandaloneReminder != true, let preAlarm {
            let outcome = await withDeadline(Self.refetchDeadline, fallback: RefetchOutcome.unavailable) {
                await preAlarm.refetch(reminder.occurrence)
            }
            if outcome == .removed { return }
        }
        if reminder.kind != .standard {
            let travel = self.travel
            let now = clock()
            _ = await withDeadline(Self.travelDeadline, fallback: false) {
                await travel.refresh(eventID: reminder.eventID, occurrence: reminder.occurrence, now: now)
            }
        }

        let now = clock()
        let state = store.state
        guard let record = state.event(reminder.eventID),
              let occurrence = record.occurrences(from: now, through: now.addingTimeInterval(2 * 86_400))
                .first(where: { $0.originalStart == reminder.occurrence.originalStart }),
              let fresh = ReminderPlanner.reminders(for: occurrence, record: record, settings: state.settings)
                .first(where: { $0.kind == reminder.kind }),
              state.handledReminders[fresh.key] == nil
        else { return }
        // Moved later or travel got shorter: fire at the new time instead.
        if fresh.fireDate.timeIntervalSince(now) > Self.deferTolerance { return }

        store.mutate { $0.handledReminders[fresh.key] = occurrence.end }
        let content = SpokenText.alarm(for: fresh, record: record, settings: state.settings, zone: localZone())
        await presenter.present(content)
    }
}
