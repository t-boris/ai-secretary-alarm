import Foundation
import SecretaryCore

/// Google Calendar v3 REST client for the primary calendar (REQ-003, DEC-009).
struct GoogleCalendarClient: CalendarService {
    let auth: GoogleAuth
    var session: URLSession = .shared

    private static let events = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!

    func insert(_ event: GoogleEvent) async throws -> GoogleEvent {
        let body = try JSONEncoder().encode(event)
        let data = try await send(method: "POST", url: Self.events, body: body)
        return try decode(GoogleEvent.self, data)
    }

    func delete(eventID: String) async throws {
        do {
            _ = try await send(method: "DELETE", url: Self.events.appendingPathComponent(eventID))
        } catch CalendarError.notFound {
            // Already gone.
        }
    }

    func get(eventID: String) async throws -> GoogleEvent {
        let data = try await send(method: "GET", url: Self.events.appendingPathComponent(eventID))
        return try decode(GoogleEvent.self, data)
    }

    func instance(eventID: String, originalStart: Date, timeZone: TimeZone) async throws -> GoogleEvent? {
        var c = URLComponents(url: Self.events.appendingPathComponent(eventID).appendingPathComponent("instances"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [
            // UTC form: a "+03:00" offset would be read as a space in the query string.
            .init(name: "originalStart", value: GoogleTime.format(originalStart, in: TimeZone(identifier: "UTC")!)),
            .init(name: "showDeleted", value: "true"),
        ]
        struct Page: Decodable { var items: [GoogleEvent]? }
        let data = try await send(method: "GET", url: c.url!)
        return try decode(Page.self, data).items?.first
    }

    func instances(eventID: String, timeMin: Date, timeMax: Date) async throws -> [GoogleEvent] {
        let utc = TimeZone(identifier: "UTC")!
        var c = URLComponents(url: Self.events.appendingPathComponent(eventID).appendingPathComponent("instances"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "timeMin", value: GoogleTime.format(timeMin, in: utc)),
            .init(name: "timeMax", value: GoogleTime.format(timeMax, in: utc)),
            .init(name: "maxResults", value: "250"),
        ]
        struct Page: Decodable { var items: [GoogleEvent]? }
        return try decode(Page.self, try await send(method: "GET", url: c.url!)).items ?? []
    }

    func list(syncToken: String?) async throws -> GoogleEventPage {
        var items: [GoogleEvent] = []
        var pageToken: String?
        struct Page: Decodable {
            var items: [GoogleEvent]?
            var nextPageToken: String?
            var nextSyncToken: String?
        }
        repeat {
            var c = URLComponents(url: Self.events, resolvingAgainstBaseURL: false)!
            // syncToken cannot be combined with privateExtendedProperty, so filtering by the tag happens locally.
            var query: [URLQueryItem] = [.init(name: "showDeleted", value: "true"),
                                         .init(name: "maxResults", value: "2500")]
            if let syncToken { query.append(.init(name: "syncToken", value: syncToken)) }
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            c.queryItems = query
            let page = try decode(Page.self, try await send(method: "GET", url: c.url!))
            items += page.items ?? []
            pageToken = page.nextPageToken
            if pageToken == nil { return GoogleEventPage(items: items, nextSyncToken: page.nextSyncToken) }
        } while true
    }

    func nearbyEvents(around start: Date) async throws -> [GoogleEvent] {
        // A wider window also catches the same titled meeting after a manual time edit.
        let utc = TimeZone(identifier: "UTC")!
        var items: [GoogleEvent] = []
        var pageToken: String?
        struct Page: Decodable {
            var items: [GoogleEvent]?
            var nextPageToken: String?
        }
        repeat {
            var c = URLComponents(url: Self.events, resolvingAgainstBaseURL: false)!
            c.queryItems = [
                .init(name: "timeMin", value: GoogleTime.format(start.addingTimeInterval(-12 * 3600), in: utc)),
                .init(name: "timeMax", value: GoogleTime.format(start.addingTimeInterval(12 * 3600), in: utc)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "showDeleted", value: "false"),
                .init(name: "maxResults", value: "250"),
            ]
            if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let page = try decode(Page.self, try await send(method: "GET", url: c.url!))
            items += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return items
    }

    // MARK: - Transport

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CalendarError.server(0, "Unreadable Google Calendar response")
        }
    }

    private func send(method: String, url: URL, body: Data? = nil, retried: Bool = false) async throws -> Data {
        let token = try await auth.validAccessToken(forceRefresh: retried)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CalendarError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401 where !retried: return try await send(method: method, url: url, body: body, retried: true)
        case 401: throw CalendarError.authExpired
        case 404: throw CalendarError.notFound
        case 410:
            // 410 on list means the sync token expired; on a single event it means deleted.
            throw url.query?.contains("syncToken") == true ? CalendarError.syncTokenExpired : CalendarError.notFound
        default:
            throw CalendarError.server(status, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
