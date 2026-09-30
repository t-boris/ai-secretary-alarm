import AppKit
import CryptoKit
import Foundation
import Network
import SecretaryCore

/// Google OAuth for installed apps: loopback redirect + PKCE, calendar.events scope only (DEC-012, DEC-024).
actor GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/calendar.events"

    private let secrets: SecretStore
    private var accessToken: String?
    private var expiresAt = Date.distantPast

    init(secrets: SecretStore) { self.secrets = secrets }

    nonisolated var isSignedIn: Bool { secrets.read(.googleRefreshToken) != nil }

    func signOut() {
        try? secrets.write(nil, for: .googleRefreshToken)
        accessToken = nil
    }

    /// Opens the consent page in the browser and waits for the loopback redirect.
    func signIn() async throws {
        guard let clientID = secrets.read(.googleClientID), !clientID.isEmpty else {
            throw AuthError.message("Enter the Google OAuth client ID in Settings first.")
        }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(24)

        let server = try LoopbackServer()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        let authURL = components.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let query = try await server.waitForRedirect(timeout: 300)
        guard query["state"] == state else { throw AuthError.message("Sign-in state mismatch.") }
        guard let code = query["code"] else {
            throw AuthError.message("Google sign-in was not completed: \(query["error"] ?? "no code").")
        }
        let token = try await tokenRequest([
            "code": code, "client_id": clientID, "client_secret": secrets.read(.googleClientSecret) ?? "",
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = token.refresh_token else {
            throw AuthError.message("Google returned no refresh token.")
        }
        try secrets.write(refresh, for: .googleRefreshToken)
        accessToken = token.access_token
        expiresAt = Date().addingTimeInterval(Double(token.expires_in ?? 3600) - 60)
    }

    /// A valid access token; refreshes as needed. Throws `CalendarError.authExpired` if the refresh token is revoked.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, Date() < expiresAt { return accessToken }
        guard let refresh = secrets.read(.googleRefreshToken),
              let clientID = secrets.read(.googleClientID) else { throw CalendarError.notSignedIn }
        let token: TokenResponse
        do {
            token = try await tokenRequest([
                "refresh_token": refresh, "client_id": clientID,
                "client_secret": secrets.read(.googleClientSecret) ?? "", "grant_type": "refresh_token",
            ])
        } catch AuthError.invalidGrant {
            try? secrets.write(nil, for: .googleRefreshToken)
            throw CalendarError.authExpired
        }
        accessToken = token.access_token
        expiresAt = Date().addingTimeInterval(Double(token.expires_in ?? 3600) - 60)
        return token.access_token
    }

    // MARK: - Helpers

    enum AuthError: LocalizedError {
        case message(String)
        case invalidGrant

        var errorDescription: String? {
            switch self {
            case let .message(m): return m
            case .invalidGrant: return "Google sign-in failed, expired or was revoked. Check the client ID and sign in again."
            }
        }
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int?
        var refresh_token: String?
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CalendarError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 {
            // invalid_grant (revoked/expired) and invalid_client (credentials changed) both need a new sign-in.
            throw AuthError.invalidGrant
        }
        guard (200..<300).contains(status) else {
            throw CalendarError.server(status, "Google token request failed")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect query.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oauth.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// Continuation for `start()`; touched only on `queue`.
    private var ready: CheckedContinuation<UInt16, Error>?

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                self.ready = cont
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let ready = self.ready else { return }
                    switch state {
                    case .ready:
                        self.ready = nil
                        ready.resume(returning: self.listener.port?.rawValue ?? 0)
                    case let .failed(error):
                        self.ready = nil
                        ready.resume(throwing: error)
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(GoogleAuth.AuthError.message("Google sign-in timed out.")))
                }
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard query["code"] != nil || query["error"] != nil else {
                connection.cancel()  // e.g. favicon request
                return
            }
            let html = "<html><body style='font-family:-apple-system'><h3>AI Secretary Alarm</h3>"
                + "<p>You can close this tab and return to the app.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.finish(.success(query))
        }
    }
}
