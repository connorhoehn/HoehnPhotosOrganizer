import Foundation

/// Minimal Cognito IDP REST client. Talks to
/// `https://cognito-idp.<region>.amazonaws.com/` using JSON-1.1 with the
/// `X-Amz-Target` action header. Avoids the AWS SDK to keep the binary
/// small and the dependency surface clean.
///
/// Used by both the macOS and iOS sign-in flows so neither target needs the
/// Cognito hosted-UI domain (which we do not provision in the CDK stack).
public enum CognitoAuthClient {

    public enum InitiateAuthResult {
        case tokens(idToken: String, refreshToken: String)
        case newPasswordRequired(session: String)
    }

    public enum AuthError: Error {
        case invalidConfig
        case network(Error)
        case server(status: Int, type: String?, message: String?)
        case malformedResponse
        case missingField(String)

        public var userMessage: String {
            switch self {
            case .invalidConfig:
                return "Invalid Cognito configuration."
            case .network(let err):
                return "Network error: \(err.localizedDescription)"
            case .server(_, let type, let message):
                if let message, !message.isEmpty { return message }
                if let type { return "Sign-in failed: \(type)" }
                return "Sign-in failed."
            case .malformedResponse:
                return "Unexpected response from Cognito."
            case .missingField(let name):
                return "Cognito response missing '\(name)'."
            }
        }
    }

    public static func initiateUserPasswordAuth(
        username: String,
        password: String
    ) async throws -> InitiateAuthResult {
        let payload: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": AuthConfig.clientId,
            "AuthParameters": [
                "USERNAME": username,
                "PASSWORD": password,
            ],
        ]
        let json = try await post(target: "InitiateAuth", payload: payload)

        if let challenge = json["ChallengeName"] as? String {
            switch challenge {
            case "NEW_PASSWORD_REQUIRED":
                guard let session = json["Session"] as? String else {
                    throw AuthError.missingField("Session")
                }
                return .newPasswordRequired(session: session)
            default:
                throw AuthError.server(
                    status: 200,
                    type: challenge,
                    message: "Unsupported challenge: \(challenge)"
                )
            }
        }

        guard let result = json["AuthenticationResult"] as? [String: Any] else {
            throw AuthError.missingField("AuthenticationResult")
        }
        guard let idToken = result["IdToken"] as? String else {
            throw AuthError.missingField("IdToken")
        }
        guard let refreshToken = result["RefreshToken"] as? String else {
            throw AuthError.missingField("RefreshToken")
        }
        return .tokens(idToken: idToken, refreshToken: refreshToken)
    }

    public static func respondToNewPasswordChallenge(
        username: String,
        newPassword: String,
        session: String
    ) async throws -> (idToken: String, refreshToken: String) {
        let payload: [String: Any] = [
            "ChallengeName": "NEW_PASSWORD_REQUIRED",
            "ClientId": AuthConfig.clientId,
            "Session": session,
            "ChallengeResponses": [
                "USERNAME": username,
                "NEW_PASSWORD": newPassword,
            ],
        ]
        let json = try await post(target: "RespondToAuthChallenge", payload: payload)

        guard let result = json["AuthenticationResult"] as? [String: Any] else {
            throw AuthError.missingField("AuthenticationResult")
        }
        guard let idToken = result["IdToken"] as? String else {
            throw AuthError.missingField("IdToken")
        }
        guard let refreshToken = result["RefreshToken"] as? String else {
            throw AuthError.missingField("RefreshToken")
        }
        return (idToken, refreshToken)
    }

    // MARK: - Internal HTTP

    /// Seam for unit tests. Production code leaves this as `.shared`.
    static var _session: URLSession = .shared

    private static func post(
        target: String,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        let region = AuthConfig.cognitoRegion
        guard let url = URL(string: "https://cognito-idp.\(region).amazonaws.com/") else {
            throw AuthError.invalidConfig
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "AWSCognitoIdentityProviderService.\(target)",
            forHTTPHeaderField: "X-Amz-Target"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self._session.data(for: request)
        } catch {
            throw AuthError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.malformedResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.malformedResponse
        }

        if !(200..<300).contains(http.statusCode) {
            let type = (json["__type"] as? String).map {
                String($0.split(separator: "#").last ?? Substring($0))
            }
            let message = json["message"] as? String ?? json["Message"] as? String
            throw AuthError.server(status: http.statusCode, type: type, message: message)
        }

        return json
    }
}
