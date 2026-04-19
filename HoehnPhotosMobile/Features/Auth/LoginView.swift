// Features/Auth/LoginView.swift
//
// Cognito Hosted UI sign-in via OAuth2 + PKCE, ported from VideoNowAndLater.
// Uses ASWebAuthenticationSession for the authorize step, then a manual
// POST /oauth2/token exchange. Tokens are handed to AuthEnvironment which
// owns Keychain persistence + session state.

import SwiftUI
import AuthenticationServices
import Foundation
import HoehnPhotosCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - LoginView

struct LoginView: View {
    @EnvironmentObject var auth: AuthEnvironment
    @State private var coordinator = LoginCoordinator()

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var toast: ToastMessage?
    @State private var appeared = false

    var body: some View {
        ZStack {
            MeshBackdrop(palette: .dusk)

            VStack(spacing: HPSpacing.xxl) {
                Spacer(minLength: 0)

                // Headline
                VStack(spacing: HPSpacing.sm) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                        .padding(.bottom, HPSpacing.sm)

                    Text("HoehnPhotos")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(-0.8)
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)

                    Text("Your library, organized beautifully.")
                        .font(HPFont.cardSubtitle)
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer(minLength: 0)

                // Panel: primary button + error + (debug) skip
                GlassPanel(tone: .overlay) {
                    VStack(spacing: HPSpacing.md) {
                        primaryButton

                        if let errorMessage {
                            errorBanner(errorMessage)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        #if DEBUG
                        debugSkipButton
                        #endif
                    }
                    .padding(HPSpacing.base)
                }
                .padding(.horizontal, HPSpacing.lg)
                .padding(.bottom, HPSpacing.xxl)
            }
            .padding(.top, HPSpacing.xxxl)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(.easeOut(duration: 0.45), value: appeared)
        }
        .preferredColorScheme(.dark)
        .hapticToast($toast)
        .onAppear { appeared = true }
    }

    // MARK: Subviews

    private var primaryButton: some View {
        Button {
            Task { await startSignIn() }
        } label: {
            HStack(spacing: HPSpacing.sm) {
                if isSigningIn {
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(isSigningIn ? "Signing in…" : "Sign in")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(
                    colors: [.purple, .indigo, .blue],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: HPRadius.card, style: .continuous)
            )
            .shadow(color: .purple.opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
        .scaleEffect(isSigningIn ? 0.98 : 1.0)
        .animation(HPAnimation.cardSpring, value: isSigningIn)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: HPSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HPColor.reject)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)
            Text(msg)
                .font(HPFont.cardSubtitle)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HPSpacing.md)
        .padding(.vertical, HPSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HPColor.reject.opacity(0.14),
            in: RoundedRectangle(cornerRadius: HPRadius.large, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HPRadius.large, style: .continuous)
                .stroke(HPColor.reject.opacity(0.3), lineWidth: 0.5)
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
                .font(HPFont.bodyStrong)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: HPRadius.large, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HPRadius.large, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
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
            toast = ToastMessage(.error, "Sign-in failed", subtitle: ns.localizedDescription)
            return
        }

        do {
            try await exchangeCodeForTokens(code: code, verifier: pkce.verifier)
        } catch let err as LoginError {
            errorMessage = err.userMessage
            toast = ToastMessage(.error, "Sign-in failed", subtitle: err.userMessage)
        } catch {
            let ns = error as NSError
            errorMessage = ns.localizedDescription
            toast = ToastMessage(.error, "Sign-in failed", subtitle: ns.localizedDescription)
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
        #if canImport(UIKit)
        return MainActor.assumeIsolated {
            let keyWindow = UIApplication.shared.connectedScenes
                .first { $0.activationState == .foregroundActive }
                .flatMap { $0 as? UIWindowScene }
                .flatMap { $0.keyWindow }
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
