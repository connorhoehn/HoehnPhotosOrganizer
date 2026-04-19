import Combine
import Foundation

/// Observable Cognito session manager.
///
/// Loads tokens from ``AuthKeychain`` on launch, inspects the id-token's
/// JWT `exp` claim, and schedules a background refresh five minutes before
/// expiry. Exposes Combine-friendly publishers for UI binding and an
/// async accessor (`currentIdToken`) for networking code that needs a
/// guaranteed-fresh token.
///
/// All published state mutates on the main actor. HTTP work runs on a
/// detached `Task` so UI scrolling is never blocked by token refresh.
@MainActor
public final class AuthEnvironment: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var idToken: String?
    @Published public private(set) var refreshToken: String?
    @Published public private(set) var username: String?
    @Published public private(set) var isAuthenticated: Bool = false

    /// Expiry date parsed from the current ``idToken``'s JWT payload.
    /// `nil` when no session exists or the token could not be decoded.
    @Published public private(set) var tokenExpiresAt: Date?

    // MARK: - Private state

    /// Handle to the scheduled refresh task so it can be cancelled.
    private var refreshTask: Task<Void, Never>?

    /// Refresh 5 minutes before expiry.
    private static let refreshLeadTime: TimeInterval = 5 * 60

    /// Treat tokens expiring in the next 60s as already stale.
    private static let proactiveRefreshWindow: TimeInterval = 60

    /// Minimum delay before a scheduled refresh fires (guards against
    /// negative / near-zero intervals from clock skew).
    private static let minimumScheduleDelay: TimeInterval = 10

    // MARK: - Init

    public init() {
        restoreSession()
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Public API

    /// Called by `LoginView` after a successful PKCE code exchange.
    ///
    /// Persists the tokens in the Keychain, flips `isAuthenticated`, and
    /// schedules the next refresh. Persistence errors are logged in DEBUG
    /// builds but do not block the in-memory session.
    public func setSession(idToken: String, refreshToken: String, username: String) async {
        do {
            try AuthKeychain.save(
                idToken: idToken,
                refreshToken: refreshToken,
                username: username
            )
        } catch {
            #if DEBUG
            print("[AuthEnvironment] Keychain save failed: \(error)")
            #endif
        }

        self.idToken = idToken
        self.refreshToken = refreshToken
        self.username = username
        self.tokenExpiresAt = Self.jwtExpiry(idToken)
        self.isAuthenticated = true

        scheduleRefresh()
    }

    /// Forces a refresh immediately.
    ///
    /// Returns the freshly-minted id-token on success or `nil` on failure.
    /// On failure after retries, the session is cleared via ``signOut()``.
    @discardableResult
    public func refreshTokenNow() async -> String? {
        guard let refresh = refreshToken ?? AuthKeychain.loadRefreshToken() else {
            signOut()
            return nil
        }

        // Cancel any already-scheduled refresh; we're doing it now.
        refreshTask?.cancel()
        refreshTask = nil

        do {
            let result = try await Self.performRefresh(refreshToken: refresh)

            let newId = result.idToken
            let newRefresh = result.refreshToken ?? refresh

            do {
                try AuthKeychain.save(
                    idToken: newId,
                    refreshToken: newRefresh,
                    username: username ?? AuthKeychain.loadUsername() ?? ""
                )
            } catch {
                #if DEBUG
                print("[AuthEnvironment] Keychain save after refresh failed: \(error)")
                #endif
            }

            self.idToken = newId
            self.refreshToken = newRefresh
            self.tokenExpiresAt = Self.jwtExpiry(newId)
            self.isAuthenticated = true

            scheduleRefresh()
            return newId
        } catch {
            #if DEBUG
            print("[AuthEnvironment] Token refresh failed: \(error)")
            #endif
            signOut()
            return nil
        }
    }

    /// Clears the Keychain and wipes in-memory session state.
    public func signOut() {
        refreshTask?.cancel()
        refreshTask = nil

        AuthKeychain.clear()

        idToken = nil
        refreshToken = nil
        username = nil
        tokenExpiresAt = nil
        isAuthenticated = false
    }

    /// Returns a valid id-token, refreshing first if the current one is
    /// expired or within ``proactiveRefreshWindow`` of expiry.
    public func currentIdToken() async -> String? {
        if let expires = tokenExpiresAt {
            if expires.timeIntervalSinceNow <= Self.proactiveRefreshWindow {
                return await refreshTokenNow()
            }
        } else if idToken != nil {
            // We have a token but couldn't parse expiry — try to refresh.
            return await refreshTokenNow()
        }
        return idToken
    }

    // MARK: - Session restoration

    /// Reads tokens from the Keychain on launch and reconciles state.
    private func restoreSession() {
        let storedId = AuthKeychain.loadIdToken()
        let storedRefresh = AuthKeychain.loadRefreshToken()
        let storedUser = AuthKeychain.loadUsername()

        self.username = storedUser
        self.refreshToken = storedRefresh

        guard let token = storedId else {
            // No id-token. If we still have a refresh token, attempt a
            // background refresh; otherwise stay signed out.
            if storedRefresh != nil {
                Task { await self.refreshTokenNow() }
            }
            return
        }

        let expiry = Self.jwtExpiry(token)
        self.tokenExpiresAt = expiry

        let isExpired: Bool
        if let expiry {
            isExpired = expiry <= Date()
        } else {
            // Can't decode — assume stale and try refresh if possible.
            isExpired = true
        }

        if !isExpired {
            self.idToken = token
            self.isAuthenticated = true
            scheduleRefresh()
        } else if storedRefresh != nil {
            Task { await self.refreshTokenNow() }
        } else {
            // Expired and no refresh token — drop any stale artifacts.
            signOut()
        }
    }

    // MARK: - Refresh scheduling

    /// Cancels any pending refresh and schedules a new one for
    /// `tokenExpiresAt - refreshLeadTime`.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = nil

        guard let expires = tokenExpiresAt else { return }

        let delay = max(
            expires.timeIntervalSinceNow - Self.refreshLeadTime,
            Self.minimumScheduleDelay
        )

        let nanos = UInt64(delay * 1_000_000_000)

        refreshTask = Task.detached { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return // cancelled
            }
            guard !Task.isCancelled else { return }
            await self?.refreshTokenNow()
        }
    }

    // MARK: - JWT helper

    /// Decodes the JWT payload (segment 1) and returns the `exp` claim as a
    /// `Date`. Does **not** verify the signature — that is the server's job.
    public static func jwtExpiry(_ token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        let payload = String(segments[1])
        guard let data = base64URLDecode(payload) else { return nil }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = json["exp"] as? TimeInterval
        else {
            return nil
        }

        return Date(timeIntervalSince1970: exp)
    }

    /// Base64URL → `Data` (JWT uses URL-safe base64 without padding).
    private static func base64URLDecode(_ input: String) -> Data? {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    // MARK: - HTTP refresh (detached)

    private struct RefreshResult {
        let idToken: String
        let refreshToken: String?
    }

    private enum RefreshError: Error {
        case badURL
        case invalidResponse
        case unauthorized
        case server(Int)
        case transport(Error)
        case decoding
        case exhaustedRetries
    }

    /// Executes the refresh-token grant against the Cognito OAuth endpoint.
    ///
    /// Runs on a detached, non-isolated context. Retries transient network
    /// failures up to 3 times with exponential backoff (1s / 2s / 4s).
    /// Returns immediately on HTTP 401 (refresh token revoked).
    private static func performRefresh(refreshToken: String) async throws -> RefreshResult {
        let domain = AuthConfig.cognitoDomain
        let clientId = AuthConfig.clientId

        // Accept either a bare domain or a fully-qualified URL in config.
        let urlString: String
        if domain.hasPrefix("http://") || domain.hasPrefix("https://") {
            urlString = "\(domain)/oauth2/token"
        } else {
            urlString = "https://\(domain)/oauth2/token"
        }

        guard let url = URL(string: urlString) else {
            throw RefreshError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        let body = "grant_type=refresh_token"
            + "&client_id=\(clientId)"
            + "&refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)

        let backoffs: [UInt64] = [
            1_000_000_000, // 1s
            2_000_000_000, // 2s
            4_000_000_000, // 4s
        ]

        var lastError: RefreshError = .exhaustedRetries

        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw RefreshError.invalidResponse
                }

                if http.statusCode == 401 {
                    throw RefreshError.unauthorized
                }

                guard (200..<300).contains(http.statusCode) else {
                    lastError = .server(http.statusCode)
                    try await Task.sleep(nanoseconds: backoffs[attempt])
                    continue
                }

                guard
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let newId = json["id_token"] as? String
                else {
                    throw RefreshError.decoding
                }

                let newRefresh = json["refresh_token"] as? String
                return RefreshResult(idToken: newId, refreshToken: newRefresh)
            } catch let error as RefreshError {
                if case .unauthorized = error { throw error }
                if case .decoding = error { throw error }
                if case .badURL = error { throw error }
                lastError = error
                if attempt < backoffs.count - 1 {
                    try? await Task.sleep(nanoseconds: backoffs[attempt])
                }
            } catch {
                lastError = .transport(error)
                if attempt < backoffs.count - 1 {
                    try? await Task.sleep(nanoseconds: backoffs[attempt])
                }
            }
        }

        throw lastError
    }
}
