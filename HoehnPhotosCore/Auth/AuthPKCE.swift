import CryptoKit
import Foundation
import Security

// MARK: - PKCE helpers

/// Generates a PKCE `(verifier, challenge)` pair.
///
/// Per RFC 7636: verifier is a high-entropy random string of unreserved
/// URL-safe characters; challenge is the base64url(SHA256(verifier)) with
/// no trailing padding.
public func makePKCE() -> (verifier: String, challenge: String) {
    let verifier = randomURLSafeString(length: 64)
    let digest = SHA256.hash(data: Data(verifier.utf8))
    let challenge = Data(digest).base64URLEncodedStringNoPadding()
    return (verifier, challenge)
}

/// Decodes a human-friendly display name from the JWT payload segment of an
/// id_token. Prefers `name` / `given_name` / `email-local-part` /
/// `preferred_username` over `cognito:username`, because for Cognito pools
/// where the sub is the username, `cognito:username` is the user's UUID and
/// is not appropriate for display.
public func decodeJWTUsername(_ idToken: String) -> String? {
    guard let payload = decodeJWTPayload(idToken) else { return nil }

    if let n = payload["name"] as? String, !n.isEmpty { return n }
    if let n = payload["given_name"] as? String, !n.isEmpty { return n }
    if let email = payload["email"] as? String, !email.isEmpty {
        // Strip the `@example.com` part — `connorhoehn@gmail.com` →
        // `connorhoehn`. Less noisy in toolbars / popovers and still
        // unambiguous for a single-user app.
        if let at = email.firstIndex(of: "@") {
            return String(email[..<at])
        }
        return email
    }
    if let u = payload["preferred_username"] as? String, !u.isEmpty { return u }
    if let u = payload["cognito:username"] as? String, !u.isEmpty { return u }
    return nil
}

/// Returns the raw JWT payload claims, or nil if the token is malformed.
public func decodeJWTPayload(_ idToken: String) -> [String: Any]? {
    let segments = idToken.split(separator: ".")
    guard segments.count >= 2 else { return nil }

    var base64 = String(segments[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    // Pad to a multiple of 4.
    let remainder = base64.count % 4
    if remainder > 0 {
        base64.append(String(repeating: "=", count: 4 - remainder))
    }

    guard
        let data = Data(base64Encoded: base64),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return payload
}

// MARK: - Private helpers

/// RFC 3986 `unreserved`: ALPHA / DIGIT / "-" / "." / "_" / "~".
private let pkceUnreservedAlphabet: [Character] = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

private func randomURLSafeString(length: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: length)
    let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
    if status != errSecSuccess {
        // Fallback: arc4random is still CSPRNG on Apple platforms.
        for i in 0..<length { bytes[i] = UInt8.random(in: 0...255) }
    }
    let alphabetCount = UInt8(pkceUnreservedAlphabet.count)
    let chars: [Character] = bytes.map { byte in
        pkceUnreservedAlphabet[Int(byte % alphabetCount)]
    }
    return String(chars)
}

private extension Data {
    /// base64url with no trailing `=` padding.
    func base64URLEncodedStringNoPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
