// Features/Auth/LoginView.swift
//
// macOS Cognito sign-in via direct InitiateAuth (USER_PASSWORD_AUTH) against
// `cognito-idp.<region>.amazonaws.com`. No browser, no hosted-UI domain
// required. If Cognito returns NEW_PASSWORD_REQUIRED, the same view collects
// the new password and calls RespondToAuthChallenge.

import SwiftUI
import Foundation
import HoehnPhotosCore

// MARK: - Login hero graphic

private struct LoginHeroView: View {
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        ZStack {
            // Layered photo stack
            ForEach(Array([Color(hue: 0.62, saturation: 0.18, brightness: 0.92),
                           Color(hue: 0.55, saturation: 0.22, brightness: 0.88),
                           Color(hue: 0.60, saturation: 0.26, brightness: 0.82)].enumerated()), id: \.offset) { index, fill in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill)
                    .frame(width: 100, height: 80)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    .rotationEffect(.degrees(Double(index - 1) * 10))
                    .offset(x: CGFloat(index - 1) * 4, y: CGFloat(index - 1) * -4)
            }

            // Top card: aperture-style icon
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.96))
                .frame(width: 100, height: 80)
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
                .overlay {
                    ZStack {
                        // Shimmer sweep
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: shimmerPhase - 0.3),
                                .init(color: .white.opacity(0.5), location: shimmerPhase),
                                .init(color: .clear, location: shimmerPhase + 0.3),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        // Aperture blades
                        ForEach(0..<6, id: \.self) { i in
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hue: 0.58, saturation: 0.6, brightness: 0.65),
                                                 Color(hue: 0.62, saturation: 0.5, brightness: 0.55)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .frame(width: 6, height: 20)
                                .offset(y: -14)
                                .rotationEffect(.degrees(Double(i) * 60))
                        }

                        // Lens circle
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color(hue: 0.60, saturation: 0.55, brightness: 0.72),
                                             Color(hue: 0.62, saturation: 0.65, brightness: 0.45)],
                                    center: .init(x: 0.35, y: 0.3),
                                    startRadius: 2, endRadius: 16
                                )
                            )
                            .frame(width: 28, height: 28)

                        // Lens glint
                        Circle()
                            .fill(.white.opacity(0.55))
                            .frame(width: 7, height: 7)
                            .offset(x: -5, y: -5)
                    }
                }
        }
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.6
            }
        }
    }
}

// MARK: - Mesh gradient background

private struct LoginBackgroundView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color(hue: 0.60, saturation: 0.06, brightness: 0.97)

            // Soft blobs
            ForEach([
                (x: 0.15, y: 0.2, hue: 0.58, sat: 0.28, size: 340.0),
                (x: 0.85, y: 0.75, hue: 0.62, sat: 0.22, size: 280.0),
                (x: 0.5,  y: 0.5, hue: 0.60, sat: 0.15, size: 220.0),
            ], id: \.x) { blob in
                Circle()
                    .fill(Color(hue: blob.hue, saturation: blob.sat, brightness: 0.92))
                    .frame(width: blob.size, height: blob.size)
                    .position(x: blob.x * 480, y: blob.y * 460)
                    .blur(radius: 80)
                    .opacity(animate ? 0.7 : 0.5)
                    .animation(
                        .easeInOut(duration: 4).repeatForever(autoreverses: true),
                        value: animate
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear { animate = true }
    }
}

// MARK: - LoginView

struct LoginView: View {
    @EnvironmentObject var auth: AuthEnvironment

    private enum Stage {
        case credentials
        case newPassword(session: String, username: String)
    }

    @State private var stage: Stage = .credentials
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var newPassword: String = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LoginBackgroundView()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // Hero
                VStack(spacing: 16) {
                    LoginHeroView()
                        .frame(height: 120)

                    VStack(spacing: 4) {
                        Text("HoehnPhotos")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(hue: 0.60, saturation: 0.7, brightness: 0.45),
                                             Color(hue: 0.62, saturation: 0.6, brightness: 0.35)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )

                        Text("Your library, organized beautifully.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                // Form card
                VStack(spacing: 12) {
                    switch stage {
                    case .credentials:
                        credentialsForm
                    case .newPassword:
                        newPasswordForm
                    }

                    if let errorMessage {
                        errorBanner(errorMessage)
                    }

                    #if DEBUG
                    debugSkipButton
                    #endif
                }
                .frame(maxWidth: 340)
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 32)
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    // MARK: Subviews

    private var credentialsForm: some View {
        VStack(spacing: 10) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .disableAutocorrection(true)
                .disabled(isSigningIn)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .disabled(isSigningIn)

            Button {
                Task { await submitCredentials() }
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn { ProgressView().controlSize(.small) }
                    Text(isSigningIn ? "Signing in…" : "Sign in")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn || email.isEmpty || password.isEmpty)
        }
    }

    private var newPasswordForm: some View {
        VStack(spacing: 10) {
            Text("Set a new password")
                .font(.headline)

            Text("Cognito requires you to set a permanent password before continuing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("New password", text: $newPassword)
                .textFieldStyle(.roundedBorder)
                .textContentType(.newPassword)
                .disabled(isSigningIn)

            Button {
                Task { await submitNewPassword() }
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn { ProgressView().controlSize(.small) }
                    Text(isSigningIn ? "Updating…" : "Update password")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn || newPassword.count < 8)
        }
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
    private func submitCredentials() async {
        guard !isSigningIn else { return }
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let result = try await CognitoAuthClient.initiateUserPasswordAuth(
                username: email,
                password: password
            )
            switch result {
            case .tokens(let idToken, let refreshToken):
                let username = decodeJWTUsername(idToken) ?? email
                await auth.setSession(
                    idToken: idToken,
                    refreshToken: refreshToken,
                    username: username
                )
            case .newPasswordRequired(let session):
                stage = .newPassword(session: session, username: email)
            }
        } catch let err as CognitoAuthClient.AuthError {
            errorMessage = err.userMessage
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    @MainActor
    private func submitNewPassword() async {
        guard case let .newPassword(session, username) = stage, !isSigningIn else { return }
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let (idToken, refreshToken) = try await CognitoAuthClient.respondToNewPasswordChallenge(
                username: username,
                newPassword: newPassword,
                session: session
            )
            let resolved = decodeJWTUsername(idToken) ?? username
            await auth.setSession(
                idToken: idToken,
                refreshToken: refreshToken,
                username: resolved
            )
        } catch let err as CognitoAuthClient.AuthError {
            errorMessage = err.userMessage
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}

// `CognitoAuthClient` lives in HoehnPhotosCore so both targets share it.
