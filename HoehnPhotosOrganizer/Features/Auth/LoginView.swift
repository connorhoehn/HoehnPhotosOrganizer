// Features/Auth/LoginView.swift
//
// macOS Cognito sign-in via direct InitiateAuth (USER_PASSWORD_AUTH) against
// `cognito-idp.<region>.amazonaws.com`. No browser, no hosted-UI domain
// required. If Cognito returns NEW_PASSWORD_REQUIRED, the same view collects
// the new password and calls RespondToAuthChallenge.

import SwiftUI
import Foundation
import HoehnPhotosCore

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
            .frame(maxWidth: 360)
            .padding(.bottom, 32)
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 460)
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
