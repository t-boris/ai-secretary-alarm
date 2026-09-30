import Foundation

/// One concrete occurrence of an event, after per-occurrence overrides.
public struct Occurrence: Equatable, Sendable {
    public var eventID: UUID
    public var originalStart: Date
    public var start: Date
    public var end: Date
    public var title: String
    public var locationType: LocationType
    public var place: ResolvedPlace?
    public var prepHint: String?

    public var key: String { OccurrenceKey.make(originalStart) }
}

extension EventRecord {
    /// Occurrences whose end is after `from` and whose start is at or before `through`.
    public func occurrences(from: Date, through: Date) -> [Occurrence] {
        let originals: [Date]
        if let recurrence {
            // Moved occurrences may start later than their original start; widen the window by a day.
            originals = recurrence.originalStarts(dtstart: start, timeZone: timeZone,
                                                  through: through.addingTimeInterval(86_400))
        } else {
            originals = [start]
        }
        return originals.compactMap { original in
            let o = overrides[OccurrenceKey.make(original)]
            if o?.cancelled == true { return nil }
            let s = o?.start ?? original
            let e = o?.end ?? s.addingTimeInterval(duration)
            guard e > from, s <= through else { return nil }
            return Occurrence(eventID: id, originalStart: original, start: s, end: e,
                              title: o?.title ?? title,
                              locationType: o?.locationType ?? locationType,
                              place: o?.place ?? place, prepHint: o?.prepHint ?? prepHint)
        }
    }

    /// Latest estimate for this occurrence, else the newest estimate of any occurrence (same route).
    public func travelEstimate(for occurrence: Occurrence) -> TravelEstimate? {
        travel[occurrence.key] ?? travel.values.max(by: { $0.computedAt < $1.computedAt })
    }
}

public enum ReminderKind: String, Codable, Sendable {
    /// Home and no-location events: start − home lead time.
    case standard
    /// Off-site: start − (travel + preparation).
    case getReady
    /// Off-site: start − travel.
    case leaveNow
}

public struct PlannedReminder: Equatable, Sendable {
    public var eventID: UUID
    public var occurrence: Occurrence
    public var kind: ReminderKind
    public var fireDate: Date
    public var travelSeconds: TimeInterval?
    /// True when no travel estimate exists and the fallback buffer was used (REQ-005).
    public var usedFallbackBuffer: Bool
    public var prepMinutes: Int

    public var key: String { Self.key(eventID: eventID, occurrenceKey: occurrence.key, kind: kind) }

    public static func key(eventID: UUID, occurrenceKey: String, kind: ReminderKind) -> String {
        "\(eventID.uuidString)|\(occurrenceKey)|\(kind.rawValue)"
    }
}

/// Computes alarm times for one occurrence (REQ-005, DEC-010, DEC-022).
public enum ReminderPlanner {
    public static func reminders(for occurrence: Occurrence, record: EventRecord, settings: AppSettings) -> [PlannedReminder] {
        if record.isStandaloneReminder {
            return [PlannedReminder(eventID: record.id, occurrence: occurrence, kind: .standard,
                                    fireDate: occurrence.start, travelSeconds: nil,
                                    usedFallbackBuffer: false, prepMinutes: 0)]
        }
        switch occurrence.locationType {
        case .home, .noLocation:
            let fire = occurrence.start.addingTimeInterval(-Double(settings.homeLeadMinutes) * 60)
            return [PlannedReminder(eventID: record.id, occurrence: occurrence, kind: .standard, fireDate: fire,
                                    travelSeconds: nil, usedFallbackBuffer: false, prepMinutes: 0)]
        case .offSite:
            let estimate = record.travelEstimate(for: occurrence)
            let travel = estimate?.seconds ?? Double(settings.fallbackBufferMinutes) * 60
            let prep = record.prepMinutes
            let leave = occurrence.start.addingTimeInterval(-travel)
            let ready = leave.addingTimeInterval(-Double(prep) * 60)
            let fallback = estimate == nil
            return [
                PlannedReminder(eventID: record.id, occurrence: occurrence, kind: .getReady, fireDate: ready,
                                travelSeconds: travel, usedFallbackBuffer: fallback, prepMinutes: prep),
                PlannedReminder(eventID: record.id, occurrence: occurrence, kind: .leaveNow, fireDate: leave,
                                travelSeconds: travel, usedFallbackBuffer: fallback, prepMinutes: prep),
            ]
        }
    }

    /// All reminders for occurrences overlapping the window.
    public static func reminders(for record: EventRecord, settings: AppSettings, from: Date, through: Date) -> [PlannedReminder] {
        record.occurrences(from: from, through: through).flatMap { reminders(for: $0, record: record, settings: settings) }
    }

    /// Reminders that should actually be scheduled for the first occurrence at creation time:
    /// a 'get ready' alarm already in the past is dropped (DEC-022).
    public static func isSkippedAtCreation(_ reminder: PlannedReminder, createdAt: Date) -> Bool {
        reminder.kind == .getReady && reminder.fireDate < createdAt
    }
}
