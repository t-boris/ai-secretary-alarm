import Foundation

/// Finds calendar events that warrant review before inserting a new event.
public enum ExistingEventMatcher {
    public static func candidates(for draft: EventDraft, in events: [GoogleEvent]) -> [GoogleEvent] {
        let title = normalized(draft.title)
        return events.filter { event in
            guard !event.isCancelled, event.id != nil, event.start?.dateTime != nil,
                  let start = GoogleTime.parse(event.start, fallbackZone: draft.timeZone) else { return false }
            let sameStart = abs(start.timeIntervalSince(draft.start)) <= 90
            let sameTitle = !title.isEmpty && normalized(event.summary ?? "") == title
            return sameStart || sameTitle
        }.sorted { left, right in
            let l = GoogleTime.parse(left.start, fallbackZone: draft.timeZone) ?? .distantFuture
            let r = GoogleTime.parse(right.start, fallbackZone: draft.timeZone) ?? .distantFuture
            return abs(l.timeIntervalSince(draft.start)) < abs(r.timeIntervalSince(draft.start))
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .punctuationCharacters.union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// A safe, short explanation from a Google API error response.
public struct GoogleAPIErrorDetails: Equatable, Sendable {
    public let message: String?
    public let reason: String?

    public init(body: String) {
        struct Response: Decodable {
            struct Failure: Decodable {
                struct Detail: Decodable { let reason: String? }
                let message: String?
                let errors: [Detail]?
                let details: [Detail]?
            }
            let error: Failure
        }
        let failure = body.data(using: .utf8).flatMap { try? JSONDecoder().decode(Response.self, from: $0).error }
        let clean = failure?.message?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        message = clean.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
        reason = failure?.errors?.first?.reason ?? failure?.details?.first?.reason
    }
}
