import Foundation
import SecretaryCore

/// Cloud transcription and parsing with the user's own OpenAI key (DEC-007, DEC-019).
struct OpenAIClient: RequestParsing, HintGenerating {
    let secrets: SecretStore
    /// Current model names from settings (transcription, chat).
    let models: @Sendable () async -> (transcription: String, chat: String)
    var session: URLSession = .shared

    private static let base = URL(string: "https://api.openai.com/v1/")!

    private func apiKey() throws -> String {
        guard let key = secrets.read(.openAIAPIKey), !key.isEmpty else { throw AIError.missingAPIKey }
        return key
    }

    /// Fetches the models available to the entered key for each picker opening.
    func availableModelIDs(using key: String) async throws -> [String] {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.missingAPIKey }
        var request = URLRequest(url: Self.base.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let data = try await send(request)
        struct ModelList: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let models = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw AIError.badResponse("unreadable model list")
        }
        return models.data.map(\.id)
    }

    func transcribe(audioFile: URL) async throws -> String {
        let key = try apiKey()
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", await models().transcription)
        field("response_format", "json")
        field("prompt", "The speaker may mix Russian and English in one sentence. Keep proper names exactly as spoken.")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"request.m4a\"\r\nContent-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audioFile))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: Self.base.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60
        let data = try await send(request)
        struct Transcript: Decodable { var text: String }
        guard let text = try? JSONDecoder().decode(Transcript.self, from: data).text else {
            throw AIError.badResponse("unreadable transcription")
        }
        return text
    }

    func parse(conversation: [ChatTurn], context: ParseContext) async throws -> ParsedRequest {
        let body = try ParserPrompt.requestBody(model: await models().chat, conversation: conversation, context: context)
        let data = try await send(chatRequest(body: body, key: try apiKey()))
        return try ParserPrompt.decodeResponse(data)
    }

    func preparationHint(title: String, eventType: EventType, locationType: LocationType, place: String?,
                         language: SpeechLanguage) async throws -> String? {
        let instruction = """
        Write a preparation hint of at most 2 short sentences for this event, in \(language == .ru ? "Russian" : "English"), \
        or null if nothing useful. Event: "\(title)", type \(eventType.rawValue), location \(place ?? locationType.rawValue).
        """
        let body: [String: Any] = [
            "model": await models().chat,
            "messages": [["role": "user", "content": instruction]],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "hint", "strict": true,
                    "schema": ["type": "object", "additionalProperties": false, "required": ["hint"],
                               "properties": ["hint": ["type": ["string", "null"]]]],
                ],
            ],
        ]
        let data = try await send(chatRequest(body: try JSONSerialization.data(withJSONObject: body), key: try apiKey()))
        struct Response: Decodable {
            struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }
            var choices: [Choice]
        }
        struct Hint: Decodable { var hint: String? }
        guard let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content,
              let hint = try? JSONDecoder().decode(Hint.self, from: Data(content.utf8)) else {
            throw AIError.badResponse("unreadable hint")
        }
        return hint.hint
    }

    private func chatRequest(body: Data, key: String) -> URLRequest {
        var request = URLRequest(url: Self.base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 45
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .timedOut, .dnsLookupFailed, .dataNotAllowed:
                throw AIError.offline
            default:
                throw AIError.service(error.localizedDescription)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw AIError.invalidAPIKey
        default:
            struct APIError: Decodable { struct Inner: Decodable { var message: String }; var error: Inner }
            let message = (try? JSONDecoder().decode(APIError.self, from: data).error.message) ?? "HTTP \(status)"
            throw AIError.service(message)
        }
    }
}
