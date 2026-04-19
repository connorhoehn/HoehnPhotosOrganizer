// Features/Auth/LoginView.swift
//
// macOS Cognito Hosted UI sign-in via OAuth2 + PKCE.
// Mirrors the iOS flow (ASWebAuthenticationSession + manual POST /oauth2/token)
// but swaps the UIKit presentation anchor for an AppKit NSWindow and drops the
// iOS-only design-system tokens in favor of plain SwiftUI primitives.

import SwiftUI
import AuthenticationServices
import Foundation
import HoehnPhotosCore
#if canImport(AppKit)
import AppKit
#endif

// MARK: - LoginView

struct LoginView: View {
    @EnvironmentObject var auth: AuthEnvironment
    @State private var coordinator = LoginCoordinator()

    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("HoehnPhotos")
                    .font(.system(size: 36, weight: .bold, design: .rounded))

                Text("Your library, organized beautifully.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                primaryButton

                if let errorMessage {
                    errorBanner(errorMessage)
                }

                #if DEBUG
                debugSkipButton
                #endif
            }
            .frame(maxWidth: 360)
            .padding(.bottom, 32)
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: Subviews

    private var primaryButton: some View {
        Button {
            Task { await startSignIn() }
        } label: {
            HStack(spacing: 8) {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(isSigningIn ? "Signing in…" : "Sign in")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(isSigningIn)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 2)
            Text(msg)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.red.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.3), lineWidth: 0.5)
        )
    }

    #if DEBUG
    private var debugSkipButton: some View {
        Button {
            Task {
                await auth.setSession(
                    idToken: "demo",
                    refreshToken: "demo",
                    username: "demo@local"
                )
            }
        } label: {
            Text("Skip sign-in (demo)")
                .frame(maxWidth: .infinity)
                .frame(height: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isSigningIn)
    }
    #endif

    // MARK: - Sign-in flow

    @MainActor
    private func startSignIn() async {
        guard !isSigningIn else { return }
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }

        let pkce = makePKCE()

        let scopeString = AuthConfig.scopes.joined(separator: "+")
        let urlString =
            "\(AuthConfig.cognitoDomain)/oauth2/authorize" +
            "?response_type=code" +
            "&client_id=\(AuthConfig.clientId)" +
            "&redirect_uri=\(AuthConfig.callbackURL)" +
            "&scope=\(scopeString)" +
            "&code_challenge=\(pkce.challenge)" +
            "&code_challenge_method=S256"

        guard let authorizeURL = URL(string: urlString) else {
            errorMessage = "Invalid auth configuration"
            return
        }

        let code: String
        do {
            code = try await coordinator.authorize(
                url: authorizeURL,
                callbackScheme: AuthConfig.callbackScheme
            )
        } catch LoginError.userCancelled {
            // User dismissed the sheet — stay silent.
            return
        } catch {
            let ns = error as NSError
            errorMessage = ns.localizedDescription
            return
        }

        do {
            try await exchangeCodeForTokens(code: code, verifier: pkce.verifier)
        } catch let err as LoginError {
            errorMessage = err.userMessage
        } catch {
            let ns = error as NSError
            errorMessage = ns.localizedDescription
        }
    }

    @MainActor
    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        guard let tokenURL = URL(string: "\(AuthConfig.cognitoDomain)/oauth2/token") else {
            throw LoginError.invalidConfig
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        let bodyPairs: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", AuthConfig.clientId),
            ("code", code),
            ("redirect_uri", AuthConfig.callbackURL),
            ("code_verifier", verifier)
        ]
        request.httpBody = encodeFormBody(bodyPairs).data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LoginError.network(underlying: error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let serverMsg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw LoginError.tokenExchangeFailed(status: http.statusCode, body: serverMsg)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LoginError.malformedResponse
        }

        guard let idToken = json["id_token"] as? String else {
            throw LoginError.missingField("id_token")
        }
        guard let refreshToken = json["refresh_token"] as? String else {
            throw LoginError.missingField("refresh_token")
        }

        let username = decodeJWTUsername(idToken) ?? "User"

        await auth.setSession(
            idToken: idToken,
            refreshToken: refreshToken,
            username: username
        )
    }
}

// MARK: - Errors

private enum LoginError: Error {
    case userCancelled
    case invalidConfig
    case noAuthorizationCode
    case network(underlying: Error)
    case tokenExchangeFailed(status: Int, body: String)
    case malformedResponse
    case missingField(String)

    var userMessage: String {
        switch self {
        case .userCancelled: return "Sign-in cancelled."
        case .invalidConfig: return "Invalid authentication configuration."
        case .noAuthorizationCode: return "No authorization code received."
        case .network(let err): return "Network error: \(err.localizedDescription)"
        case .tokenExchangeFailed(let status, _): return "Token exchange failed (HTTP \(status))."
        case .malformedResponse: return "Unexpected response from identity provider."
        case .missingField(let name): return "Missing '\(name)' in token response."
        }
    }
}

// MARK: - Coordinator

@MainActor
final class LoginCoordinator: NSObject,
    ASWebAuthenticationPresentationContextProviding {

    /// Keep a strong reference during the session lifetime; ASWebAuthenticationSession
    /// does not retain its presentation context provider.
    private var activeSession: ASWebAuthenticationSession?

    /// Presents Cognito Hosted UI and resolves with the `code` query param.
    func authorize(url: URL, callbackScheme: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                // Always free the session after the callback fires.
                defer { self?.activeSession = nil }

                if let error {
                    let ns = error as NSError
                    if ns.domain == ASWebAuthenticationSessionErrorDomain,
                       ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: LoginError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard
                    let callbackURL,
                    let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first(where: { $0.name == "code" })?
                        .value,
                    !code.isEmpty
                else {
                    continuation.resume(throwing: LoginError.noAuthorizationCode)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.activeSession = session

            if !session.start() {
                self.activeSession = nil
                continuation.resume(throwing: LoginError.invalidConfig)
            }
        }
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        #if canImport(AppKit)
        // On macOS `ASPresentationAnchor` is a typealias for `NSWindow`.
        return MainActor.assumeIsolated {
            let keyWindow = NSApplication.shared.windows.first { $0.isKeyWindow }
                ?? NSApplication.shared.windows.first
            return keyWindow ?? ASPresentationAnchor()
        }
        #else
        return ASPresentationAnchor()
        #endif
    }
}

// MARK: - Private helpers

private func encodeFormBody(_ pairs: [(String, String)]) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=?")
    return pairs
        .map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
}
