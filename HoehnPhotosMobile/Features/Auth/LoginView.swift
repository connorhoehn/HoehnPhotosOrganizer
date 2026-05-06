// Features/Auth/LoginView.swift
//
// Native Cognito sign-in via direct InitiateAuth (USER_PASSWORD_AUTH) against
// `cognito-idp.<region>.amazonaws.com`. No browser, no hosted-UI domain
// required. NEW_PASSWORD_REQUIRED is handled inline as a second stage.

import SwiftUI
import Foundation
import HoehnPhotosCore

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
                        .accessibilityHidden(true)

                    Text("HoehnPhotos")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(-0.8)
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                        .accessibilityAddTraits(.isHeader)

                    Text("Your library, organized beautifully.")
                        .font(HPFont.cardSubtitle)
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer(minLength: 0)

                // Panel: form + error + (debug) skip
                GlassPanel(tone: .overlay) {
                    VStack(spacing: HPSpacing.md) {
                        switch stage {
                        case .credentials:
                            credentialsForm
                        case .newPassword:
                            newPasswordForm
                        }

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

    private var credentialsForm: some View {
        VStack(spacing: HPSpacing.sm) {
            inputField(
                placeholder: "Email",
                text: $email,
                isSecure: false,
                contentType: .username,
                keyboard: .emailAddress
            )

            inputField(
                placeholder: "Password",
                text: $password,
                isSecure: true,
                contentType: .password
            )

            primaryButton(
                title: isSigningIn ? "Signing in…" : "Sign in",
                icon: "lock.shield.fill",
                disabled: isSigningIn || email.isEmpty || password.isEmpty
            ) {
                HPHaptic.medium()
                Task { await submitCredentials() }
            }
        }
    }

    private var newPasswordForm: some View {
        VStack(spacing: HPSpacing.sm) {
            Text("Set a new password")
                .font(HPFont.bodyStrong)
                .foregroundStyle(.white)

            Text("Cognito requires a permanent password before continuing.")
                .font(HPFont.cardSubtitle)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            inputField(
                placeholder: "New password (8+ chars)",
                text: $newPassword,
                isSecure: true,
                contentType: .newPassword
            )

            primaryButton(
                title: isSigningIn ? "Updating…" : "Update password",
                icon: "checkmark.shield.fill",
                disabled: isSigningIn || newPassword.count < 8
            ) {
                HPHaptic.medium()
                Task { await submitNewPassword() }
            }
        }
    }

    private func inputField(
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool,
        contentType: UITextContentType,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
                    .textContentType(contentType)
            } else {
                TextField(placeholder, text: text)
                    .textContentType(contentType)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, HPSpacing.md)
        .frame(height: 48)
        .background(
            Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: HPRadius.large, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HPRadius.large, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .disabled(isSigningIn)
    }

    private func primaryButton(
        title: String,
        icon: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HPSpacing.sm) {
                if isSigningIn {
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
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
            .opacity(disabled ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .scaleEffect(isSigningIn ? 0.98 : 1.0)
        .animation(HPAnimation.cardSpring, value: isSigningIn)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: HPSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HPColor.reject)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 2)
                .accessibilityHidden(true)
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
            HPHaptic.light()
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
            toast = ToastMessage(.error, "Sign-in failed", subtitle: err.userMessage)
        } catch {
            let msg = (error as NSError).localizedDescription
            errorMessage = msg
            toast = ToastMessage(.error, "Sign-in failed", subtitle: msg)
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
            toast = ToastMessage(.error, "Update failed", subtitle: err.userMessage)
        } catch {
            let msg = (error as NSError).localizedDescription
            errorMessage = msg
            toast = ToastMessage(.error, "Update failed", subtitle: msg)
        }
    }
}
