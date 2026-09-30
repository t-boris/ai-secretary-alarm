import Foundation

/// Follow-up work after applying calendar changes to local records.
public enum SyncEffect: Equatable, Sendable {
    /// Location text changed; classify and geocode it. `occurrenceKey` nil means the whole event.
    case locationChanged(eventID: UUID, occurrenceKey: String?, text: String)
    /// Title or location changed; regenerate the preparation hint (DEC-016). `occurrenceKey` nil means the series.
    case regenerateHint(eventID: UUID, occurrenceKey: String?)
    case deleted(eventID: UUID)
}

/// Applies Google Calendar changes to the app's own records (DEC-003, DEC-004, DEC-009).
/// Events that do not belong to a local record are ignored, so manual events never trigger reminders.
public enum SyncReconciler {
    /// `listedAt`: when a full listing was requested; records created later may be missing from it and are kept.
    public static func apply(_ items: [GoogleEvent], to state: inout AppState, fullResync: Bool,
                             listedAt: Date = .distantFuture) -> [SyncEffect] {
        var effects: [SyncEffect] = []
        var seenMasters = Set<String>()
        // Masters first, so that exceptions see the updated series.
        let masters = items.filter { $0.recurringEventId == nil }
        let exceptions = items.filter { $0.recurringEventId != nil }

        for item in masters {
            guard let gid = item.id else { continue }
            if !state.events.contains(where: { $0.googleEventID == gid }), let copy = splitSeries(item, state: state) {
                state.events.append(copy)
            }
            guard let index = state.events.firstIndex(where: { $0.googleEventID == gid }) else { continue }
            if item.isCancelled {
                effects.append(.deleted(eventID: state.events[index].id))
                state.events.remove(at: index)
                continue
            }
            seenMasters.insert(gid)
            if fullResync { state.events[index].overrides = [:] }
            effects += applyMaster(item, to: &state.events[index])
        }

        if fullResync {
            // Tagged events missing from a full listing were deleted (DEC-009, 410 handling).
            let missing = { (r: EventRecord) in
                !r.isStandaloneReminder && r.createdAt < listedAt
                    && (r.googleEventID.map { !seenMasters.contains($0) } ?? true)
            }
            for record in state.events where missing(record) {
                effects.append(.deleted(eventID: record.id))
            }
            state.events.removeAll(where: missing)
        }

        for item in exceptions {
            guard let parent = item.recurringEventId,
                  let index = state.events.firstIndex(where: { $0.googleEventID == parent }) else { continue }
            effects += applyException(item, to: &state.events[index])
        }
        let removed = Set(effects.compactMap { effect -> UUID? in
            if case let .deleted(eventID) = effect { return eventID }
            return nil
        })
        if !removed.isEmpty {
            state.snoozedAlarms.removeAll { removed.contains($0.content.eventID) }
        }
        for record in state.events where !state.activityHistory.contains(where: { $0.eventID == record.id }) {
            state.activityHistory.append(ActivityHistoryEntry(record: record))
        }
        return effects
    }

    /// "This and following events" edits split a series in Google: the new event carries the private tag and the
    /// local ID of the original record. It becomes its own record with the original's metadata.
    private static func splitSeries(_ item: GoogleEvent, state: AppState) -> EventRecord? {
        guard item.isAssistantTagged, !item.isCancelled,
              let localID = item.extendedProperties?.private?[GoogleEvent.localIDKey],
              let source = state.events.first(where: { $0.id.uuidString == localID }) else { return nil }
        var copy = source
        copy.id = UUID()
        copy.googleEventID = item.id
        copy.overrides = [:]
        copy.travel = [:]
        return copy
    }

    private static func applyMaster(_ item: GoogleEvent, to record: inout EventRecord) -> [SyncEffect] {
        var effects: [SyncEffect] = []
        let zone = item.start?.timeZone.flatMap(TimeZone.init(identifier:)) ?? record.timeZone
        if let tz = item.start?.timeZone, TimeZone(identifier: tz) != nil { record.timeZoneID = tz }
        if let s = GoogleTime.parse(item.start, fallbackZone: zone) {
            let e = GoogleTime.parse(item.end, fallbackZone: zone) ?? s.addingTimeInterval(record.duration)
            if s != record.start || e != record.end {
                // A moved event keeps no stale travel estimate keyed by old starts.
                if s != record.start { record.travel = [:] }
                record.start = s
                record.end = e
            }
        }
        let knownStarts = record.recurrence?.explicitStarts
        record.recurrence = item.recurrence.flatMap { Recurrence.parse(googleLines: $0, timeZone: zone) }
        if record.recurrence?.needsInstances == true { record.recurrence?.explicitStarts = knownStarts }
        if let link = item.htmlLink { record.htmlLink = link }
        var hint = false
        if let title = item.summary, title != record.title {
            record.title = title
            hint = true
        }
        let location = item.location ?? ""
        if location != record.locationText {
            effects.append(.locationChanged(eventID: record.id, occurrenceKey: nil, text: location))
            hint = true
        }
        if hint { effects.append(.regenerateHint(eventID: record.id, occurrenceKey: nil)) }
        return effects
    }

    private static func applyException(_ item: GoogleEvent, to record: inout EventRecord) -> [SyncEffect] {
        let zone = record.timeZone
        guard let original = GoogleTime.parse(item.originalStartTime, fallbackZone: zone) else { return [] }
        let key = OccurrenceKey.make(original)
        if item.isCancelled {
            record.overrides[key] = OccurrenceOverride(cancelled: true)
            return []
        }
        var o = record.overrides[key] ?? OccurrenceOverride()
        o.cancelled = false
        if let s = GoogleTime.parse(item.start, fallbackZone: zone) {
            if s != (o.start ?? original) { record.travel[key] = nil }
            o.start = s
            o.end = GoogleTime.parse(item.end, fallbackZone: zone) ?? s.addingTimeInterval(record.duration)
        }
        let previousTitle = o.title
        o.title = item.summary.flatMap { $0 == record.title ? nil : $0 }
        let location = item.location ?? ""
        var effects: [SyncEffect] = []
        var hint = o.title != previousTitle
        if location == record.locationText {
            // Same location as the series: drop any per-occurrence location.
            if o.locationText != nil { record.travel[key] = nil }
            if o.locationText != nil { hint = true }
            o.locationText = nil
            o.locationType = nil
            o.place = nil
        } else if location != o.locationText {
            effects.append(.locationChanged(eventID: record.id, occurrenceKey: key, text: location))
            hint = true
        }
        if hint {
            if o.title == nil && o.locationText == nil && location == record.locationText {
                o.prepHint = nil  // back to the series: use the series hint
            } else {
                effects.append(.regenerateHint(eventID: record.id, occurrenceKey: key))
            }
        }
        record.overrides[key] = o
        return effects
    }
}

/// Classifies a location text from the calendar against home and saved places (DEC-011, DEC-023).
public enum LocationClassifier {
    public enum Result: Equatable {
        case resolved(LocationType, ResolvedPlace?)
        case needsGeocoding(String)
    }

    public static func classify(_ text: String, places: [SavedPlace]) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .resolved(.noLocation, nil) }
        let lower = trimmed.lowercased()
        if ["home", "дом", "дома"].contains(lower) {
            let home = places.first(where: \.isHome)
            return .resolved(.home, home.map { ResolvedPlace(name: "Home", address: $0.address, coordinate: $0.coordinate) })
        }
        for place in places {
            let written = EventRecord.locationText(type: .offSite, place: ResolvedPlace(name: place.name, address: place.address, coordinate: nil))
            if lower == written.lowercased() || lower == place.address.lowercased() || lower == place.name.lowercased() {
                if place.isHome {
                    return .resolved(.home, ResolvedPlace(name: "Home", address: place.address, coordinate: place.coordinate))
                }
                return .resolved(.offSite, ResolvedPlace(name: place.name, address: place.address, coordinate: place.coordinate))
            }
        }
        return .needsGeocoding(trimmed)
    }
}

/// Outcome of re-fetching an event right before its alarm (DEC-009).
public enum RefetchOutcome: Equatable, Sendable {
    case current
    case removed
    /// Network or auth failure: fire with the last known version.
    case unavailable
}

/// Runs incremental sync and pre-alarm re-checks against Google Calendar.
@MainActor
public final class SyncCoordinator {
    private let store: AppStore
    private let calendar: CalendarService
    private let geocoder: Geocoding
    private let hints: HintGenerating
    private let clock: () -> Date
    private var syncing = false
    public private(set) var lastError: CalendarError?
    public var onAuthExpired: (() -> Void)?

    public init(store: AppStore, calendar: CalendarService, geocoder: Geocoding, hints: HintGenerating,
                clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.calendar = calendar
        self.geocoder = geocoder
        self.hints = hints
        self.clock = clock
    }

    /// Incremental sync; an expired token (410) or a missing one triggers a full resync.
    public func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let token = store.state.syncToken
            var listedAt = clock()
            do {
                let page = try await calendar.list(syncToken: token)
                await apply(page, fullResync: token == nil, listedAt: listedAt)
            } catch CalendarError.syncTokenExpired {
                listedAt = clock()
                let page = try await calendar.list(syncToken: nil)
                await apply(page, fullResync: true, listedAt: listedAt)
            }
            lastError = nil
        } catch let error as CalendarError {
            noteError(error)
        } catch {
            noteError(.network(error.localizedDescription))
        }
    }

    /// Re-fetches one occurrence right before its alarm and applies any change.
    public func refetch(_ occurrence: Occurrence) async -> RefetchOutcome {
        guard let record = store.state.event(occurrence.eventID), let gid = record.googleEventID else { return .removed }
        do {
            var items: [GoogleEvent]
            do {
                items = [try await calendar.get(eventID: gid)]
            } catch CalendarError.notFound {
                items = [GoogleEvent(id: gid, status: "cancelled")]
            }
            if record.recurrence != nil, items.first?.isCancelled == false {
                let instance = try await calendar.instance(eventID: gid, originalStart: occurrence.originalStart,
                                                           timeZone: record.timeZone)
                items.append(instance ?? GoogleEvent(status: "cancelled", recurringEventId: gid,
                                                     originalStartTime: .init(dateTime: GoogleTime.format(occurrence.originalStart, in: record.timeZone))))
            }
            await apply(GoogleEventPage(items: items, nextSyncToken: nil), fullResync: false)
            guard let updated = store.state.event(occurrence.eventID) else { return .removed }
            if updated.overrides[occurrence.key]?.cancelled == true { return .removed }
            return .current
        } catch let error as CalendarError {
            noteError(error)
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    private func noteError(_ error: CalendarError) {
        lastError = error
        if error == .authExpired { onAuthExpired?() }
    }

    private func apply(_ page: GoogleEventPage, fullResync: Bool, listedAt: Date = .distantFuture) async {
        var effects: [SyncEffect] = []
        store.mutate { state in
            effects = SyncReconciler.apply(page.items, to: &state, fullResync: fullResync, listedAt: listedAt)
            if let token = page.nextSyncToken { state.syncToken = token }
        }
        for effect in effects {
            switch effect {
            case let .locationChanged(id, key, text):
                await applyLocation(text, eventID: id, occurrenceKey: key)
            case .regenerateHint, .deleted:
                break
            }
        }
        for case let .regenerateHint(id, key) in effects {
            await regenerateHint(id, occurrenceKey: key)
        }
        await refreshExplicitInstances()
    }

    /// Horizon of Google-listed occurrences for rules the app cannot expand itself.
    static let instancesHorizon: TimeInterval = 35 * 86_400

    private func refreshExplicitInstances() async {
        let now = clock()
        for record in store.state.events where record.recurrence?.needsInstances == true {
            guard let gid = record.googleEventID,
                  let items = try? await calendar.instances(eventID: gid, timeMin: now.addingTimeInterval(-86_400),
                                                            timeMax: now.addingTimeInterval(Self.instancesHorizon))
            else { continue }  // keep the previous list when offline
            let starts = items.compactMap { GoogleTime.parse($0.originalStartTime ?? $0.start, fallbackZone: record.timeZone) }
            store.mutate { state in
                guard var r = state.event(record.id) else { return }
                r.recurrence?.explicitStarts = starts.sorted()
                state.update(r)
            }
        }
    }

    private func applyLocation(_ text: String, eventID: UUID, occurrenceKey: String?) async {
        var type: LocationType
        var place: ResolvedPlace?
        switch LocationClassifier.classify(text, places: store.state.places) {
        case let .resolved(t, p):
            type = t
            place = p
        case let .needsGeocoding(query):
            type = .offSite
            let found = try? await geocoder.geocode(query, near: store.state.home?.coordinate)
            place = ResolvedPlace(name: nil, address: found?.address ?? query, coordinate: found?.coordinate)
        }
        store.mutate { state in
            guard var record = state.event(eventID) else { return }
            if let key = occurrenceKey {
                var o = record.overrides[key] ?? OccurrenceOverride()
                o.locationType = type
                o.place = place
                o.locationText = text
                record.overrides[key] = o
                record.travel[key] = nil
            } else {
                record.locationType = type
                record.place = place
                record.locationText = text
                record.travel = [:]
            }
            state.update(record)
        }
    }

    private func regenerateHint(_ id: UUID, occurrenceKey key: String?) async {
        guard let record = store.state.event(id) else { return }
        let o = key.flatMap { record.overrides[$0] }
        let place = o?.place ?? record.place
        // On failure the previous hint is kept (DEC-016).
        guard let hint = try? await hints.preparationHint(title: o?.title ?? record.title, eventType: record.eventType,
                                                          locationType: o?.locationType ?? record.locationType,
                                                          place: place?.name ?? place?.address,
                                                          language: record.language) else { return }
        store.mutate { state in
            guard var r = state.event(id) else { return }
            if let key {
                r.overrides[key]?.prepHint = hint
            } else {
                r.prepHint = hint
            }
            state.update(r)
        }
    }
}
