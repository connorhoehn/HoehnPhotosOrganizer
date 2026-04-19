import Foundation

public enum AuthConfig {
    /// Cognito hosted-UI domain, e.g. "hoehn-photos.auth.us-east-1.amazoncognito.com"
    public static let cognitoDomain: String = ProcessInfo.processInfo.environment["HOEHN_COGNITO_DOMAIN"]
        ?? Bundle.main.object(forInfoDictionaryKey: "HOEHN_COGNITO_DOMAIN") as? String
        ?? "hoehn-photos.auth.us-east-1.amazoncognito.com"

    public static let clientId: String = ProcessInfo.processInfo.environment["HOEHN_COGNITO_CLIENT_ID"]
        ?? Bundle.main.object(forInfoDictionaryKey: "HOEHN_COGNITO_CLIENT_ID") as? String
        ?? "<client-id-placeholder>"

    /// Callback URL registered with Cognito. Scheme must also be in Info.plist URL types.
    public static let callbackScheme = "hoehnphotos"
    public static var callbackURL: String { "\(callbackScheme)://callback" }

    /// Scopes requested.
    public static let scopes = ["openid", "email", "profile"]

    /// API Gateway base URL for sync endpoints.
    public static let apiBaseURL: URL = {
        let raw = ProcessInfo.processInfo.environment["HOEHN_API_BASE_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "HOEHN_API_BASE_URL") as? String
            ?? "https://api.hoehn-photos.example/v1"
        return URL(string: raw)!
    }()
}
