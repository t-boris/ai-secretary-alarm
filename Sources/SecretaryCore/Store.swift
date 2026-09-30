import Foundation
import Observation

/// Everything the app persists locally. Contains no secrets (DEC-012).
public struct AppState: Codable, Equatable, Sendable {
    public var events: [EventRecord] = []
    public var places: [SavedPlace] = []
    public var settings = AppSettings()
    /// Reminder keys already played or dropped, with the occurrence end (for pruning).
    public var handledReminders: [String: Date] = [:]
    /// Travel refresh points already executed ("<reminderKey>|pre15").
    public var handledRefreshes: [String: Date] = [:]
    /// Each completed daily check-in, keyed by its planned alarm key.
    public var completedHabits: [String: Date] = [:]
    public var snoozedAlarms: [SnoozedAlarm] = []
    public var syncToken: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case events, places, settings, handledReminders, handledRefreshes, completedHabits, snoozedAlarms, syncToken
    }

    /// Tolerant decoding: fields added in later versions fall back to defaults instead of failing the whole load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([EventRecord].self, forKey: .events) ?? []
        places = try c.decodeIfPresent([SavedPlace].self, forKey: .places) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        handledReminders = try c.decodeIfPresent([String: Date].self, forKey: .handledReminders) ?? [:]
        handledRefreshes = try c.decodeIfPresent([String: Date].self, forKey: .handledRefreshes) ?? [:]
        completedHabits = try c.decodeIfPresent([String: Date].self, forKey: .completedHabits) ?? [:]
        snoozedAlarms = try c.decodeIfPresent([SnoozedAlarm].self, forKey: .snoozedAlarms) ?? []
        syncToken = try c.decodeIfPresent(String.self, forKey: .syncToken)
    }

    public var home: SavedPlace? { places.first(where: \.isHome) }

    public func event(_ id: UUID) -> EventRecord? { events.first { $0.id == id } }

    public mutating func update(_ record: EventRecord) {
        if let i = events.firstIndex(where: { $0.id == record.id }) { events[i] = record }
    }

    /// Drops bookkeeping for occurrences that ended more than two days ago.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-2 * 86_400)
        handledReminders = handledReminders.filter { $0.value > cutoff }
        handledRefreshes = handledRefreshes.filter { $0.value > cutoff }
        events.removeAll { $0.recurrence == nil && $0.end < cutoff }
    }
}

public protocol StatePersisting: Sendable {
    func load() throws -> AppState?
    func save(_ state: AppState) throws
    /// Moves unreadable state aside so it is not overwritten; returns where it went.
    func quarantine() throws -> String?
}

public struct JSONFileStore: StatePersisting {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AISecretaryAlarm", isDirectory: true).appendingPathComponent("state.json")
    }

    public func load() throws -> AppState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: Data(contentsOf: url))
    }

    public func quarantine() throws -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent().appendingPathComponent("state.corrupt-\(stamp).json")
        try FileManager.default.moveItem(at: url, to: target)
        return target.path
    }

    public func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

/// Observable single source of local state; every mutation is persisted.
@MainActor
@Observable
public final class AppStore {
    public private(set) var state: AppState
    @ObservationIgnored private let persistence: StatePersisting
    public private(set) var lastSaveError: String?
    /// Set when the saved state could not be read; the file was moved aside, not overwritten.
    public private(set) var loadError: String?

    public init(persistence: StatePersisting) {
        self.persistence = persistence
        do {
            state = try persistence.load() ?? AppState()
        } catch {
            state = AppState()
            let moved = (try? persistence.quarantine()) ?? nil
            loadError = "Saved data could not be read (\(error.localizedDescription))."
                + (moved.map { " It was moved to \($0)." } ?? "")
        }
    }

    public func mutate(_ body: (inout AppState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        state = next
        do {
            try persistence.save(state)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }
}

/// In-memory persistence for tests and previews.
public final class MemoryStore: StatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppState?

    public init(_ state: AppState? = nil) { stored = state }

    public func load() throws -> AppState? { lock.withLock { stored } }
    public func save(_ state: AppState) throws { lock.withLock { stored = state } }
    public func quarantine() throws -> String? { nil }
}
