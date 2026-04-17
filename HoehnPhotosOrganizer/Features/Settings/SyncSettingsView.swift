// SyncSettingsView.swift
// HoehnPhotosOrganizer
//
// Settings pane for cloud sync configuration.
// Wired into SettingsSheet replacing the cloudSyncContent placeholder.
//
// UserDefaults keys:
//   syncEnabled         (Bool, default false)
//   syncOnWifiOnly      (Bool, default true)
//   syncIntervalMinutes (Int, default 15)
//   syncAPIEndpoint     (String, default "")
//
// Posts Notification.Name.syncNowRequested when "Sync Now" is tapped.
// The BackgroundSyncCoordinator observes this notification in HoehnPhotosOrganizerApp.

import SwiftUI

struct SyncSettingsView: View {
    let db: AppDatabase?

    @State private var syncEnabled: Bool = UserDefaults.standard.bool(forKey: "syncEnabled")
    @State private var wifiOnly: Bool = (UserDefaults.standard.object(forKey: "syncOnWifiOnly") as? Bool) ?? true
    @State private var intervalMinutes: Double = {
        let stored = UserDefaults.standard.integer(forKey: "syncIntervalMinutes")
        return Double(stored > 0 ? stored : 15)
    }()
    @State private var showRestoreWizard: Bool = false
    @State private var showInitialSyncWizard: Bool = false
    @State private var syncCounts: [String: Int] = [:]

    // MARK: - AWS Configuration State

    private let configManager = AWSConfigurationManager.shared

    @State private var apiEndpoint: String = UserDefaults.standard.string(forKey: "syncAPIEndpoint") ?? ""
    @State private var userPoolId: String = UserDefaults.standard.string(forKey: "cognito.userPoolId") ?? ""
    @State private var clientId: String = UserDefaults.standard.string(forKey: "cognito.clientId") ?? ""
    @State private var region: String = UserDefaults.standard.string(forKey: "cognito.region") ?? "us-east-1"
    @State private var s3Bucket: String = UserDefaults.standard.string(forKey: "syncS3Bucket") ?? ""
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""
    @State private var configSaved: Bool = false

    // MARK: - Auth State

    private enum AuthState {
        case signedOut
        case newPasswordRequired(session: String)
        case signedIn(email: String)
    }

    @State private var authState: AuthState = {
        if let email = UserDefaults.standard.string(forKey: "cognito.userEmail"),
           UserDefaults.standard.string(forKey: "cognito.accessToken") != nil {
            return .signedIn(email: email)
        }
        return .signedOut
    }()

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var authError: String = ""
    @State private var isAuthLoading: Bool = false

    private let authManager = CognitoAuthManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable Cloud Sync", isOn: $syncEnabled)
                .onChange(of: syncEnabled) { _, newValue in
                    configManager.setSyncEnabled(newValue)
                    if newValue && !UserDefaults.standard.bool(forKey: "initialSyncCompleted") {
                        showInitialSyncWizard = true
                    }
                }

            if syncEnabled {
                // MARK: - AWS Configuration Section
                awsConfigSection

                Divider()

                // MARK: - Sign-in Section
                authSection

                Divider()

                Toggle("Sync on WiFi Only", isOn: $wifiOnly)
                    .onChange(of: wifiOnly) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "syncOnWifiOnly")
                    }

                HStack {
                    Text("Sync every")
                    Slider(value: $intervalMinutes, in: 5...60, step: 5)
                        .frame(width: 150)
                    Text("\(Int(intervalMinutes)) min")
                        .monospacedDigit()
                }
                .onChange(of: intervalMinutes) { _, newValue in
                    UserDefaults.standard.set(Int(newValue), forKey: "syncIntervalMinutes")
                }

                Divider()

                // Status summary
                HStack {
                    Label("\(syncCounts["synced", default: 0]) synced", systemImage: "cloud.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Label("\(syncCounts["localOnly", default: 0]) local only", systemImage: "minus.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("\(syncCounts["error", default: 0]) errors", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .font(.caption)

                Divider()

                HStack {
                    Button("Sync Now") {
                        NotificationCenter.default.post(name: .syncNowRequested, object: nil)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Restore from Cloud...") {
                        showRestoreWizard = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showRestoreWizard) {
            RestoreWizardView()
        }
        .sheet(isPresented: $showInitialSyncWizard) {
            if let db {
                InitialSyncWizardView(db: db)
            }
        }
        .sheet(isPresented: $showImportSheet) {
            importDeployOutputSheet
        }
        .task {
            await loadSyncCounts()
        }
    }

    // MARK: - AWS Configuration Section

    @ViewBuilder
    private var awsConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AWS Configuration")
                    .font(.headline)
                Spacer()
                Button("Import from Deploy Output") {
                    showImportSheet = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            LabeledContent("API Endpoint") {
                TextField("https://xyz.execute-api.us-east-1.amazonaws.com/prod", text: $apiEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiEndpoint) { _, newValue in
                        configManager.setAPIEndpoint(newValue)
                        configSaved = false
                    }
            }

            LabeledContent("User Pool ID") {
                TextField("us-east-1_AbCdEfGh", text: $userPoolId)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: userPoolId) { _, newValue in
                        configManager.setUserPoolId(newValue)
                        configSaved = false
                    }
            }

            LabeledContent("Client ID") {
                TextField("1a2b3c4d5e6f7g8h9i0j", text: $clientId)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: clientId) { _, newValue in
                        configManager.setClientId(newValue)
                        configSaved = false
                    }
            }

            HStack(spacing: 16) {
                LabeledContent("Region") {
                    TextField("us-east-1", text: $region)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: region) { _, newValue in
                            configManager.setRegion(newValue)
                            configSaved = false
                        }
                }

                LabeledContent("S3 Bucket") {
                    TextField("hoehnphotos-sync", text: $s3Bucket)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: s3Bucket) { _, newValue in
                            configManager.setS3BucketName(newValue)
                            configSaved = false
                        }
                }
            }

            // Configuration status indicator
            HStack(spacing: 6) {
                if configManager.current.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Configuration complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text("Fill in all fields above (from deploy.sh output)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Import Deploy Output Sheet

    private var importDeployOutputSheet: some View {
        VStack(spacing: 16) {
            Text("Paste Deploy Output")
                .font(.title3.bold())

            Text("Paste the output from deploy.sh below:")
                .font(.body)
                .foregroundStyle(.secondary)

            TextEditor(text: $importText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 160)
                .border(Color.secondary.opacity(0.3))

            HStack {
                Button("Cancel") {
                    showImportSheet = false
                    importText = ""
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Import") {
                    configManager.importFromDeployText(importText)
                    // Refresh local state from UserDefaults
                    let config = configManager.current
                    apiEndpoint = config.apiEndpoint
                    userPoolId = config.userPoolId
                    clientId = config.clientId
                    region = config.region
                    s3Bucket = config.s3BucketName
                    showImportSheet = false
                    importText = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 340)
    }

    // MARK: - Auth Section

    @ViewBuilder
    private var authSection: some View {
        switch authState {
        case .signedOut:
            signedOutView
        case .newPasswordRequired:
            newPasswordView
        case .signedIn(let email):
            signedInView(email: email)
        }
    }

    private var signedOutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { signIn() }
            HStack {
                Button("Sign In") { signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(email.isEmpty || password.isEmpty || isAuthLoading)
                if isAuthLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !authError.isEmpty {
                Text(authError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var newPasswordView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set New Password")
                .font(.headline)
            SecureField("New password", text: $newPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { setNewPassword() }
            HStack {
                Button("Set Password") { setNewPassword() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPassword.isEmpty || newPassword != confirmPassword || isAuthLoading)
                if isAuthLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !authError.isEmpty {
                Text(authError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func signedInView(email: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(email)
                .font(.body)
            Spacer()
            Button("Sign Out") { signOut() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Auth Actions

    private func signIn() {
        authError = ""
        isAuthLoading = true
        Task {
            do {
                try await authManager.signIn(email: email, password: password)
                authState = .signedIn(email: email)
                password = ""
            } catch let error as CognitoAuthError {
                switch error {
                case .newPasswordRequired(let session):
                    authState = .newPasswordRequired(session: session)
                default:
                    authError = error.localizedDescription
                }
            } catch {
                authError = error.localizedDescription
            }
            isAuthLoading = false
        }
    }

    private func setNewPassword() {
        guard case .newPasswordRequired(let session) = authState else { return }
        guard newPassword == confirmPassword else {
            authError = "Passwords do not match."
            return
        }
        authError = ""
        isAuthLoading = true
        Task {
            do {
                try await authManager.respondToNewPasswordChallenge(
                    session: session,
                    email: email,
                    newPassword: newPassword
                )
                authState = .signedIn(email: email)
                newPassword = ""
                confirmPassword = ""
            } catch {
                authError = error.localizedDescription
            }
            isAuthLoading = false
        }
    }

    private func signOut() {
        Task {
            await authManager.signOut()
            authState = .signedOut
            email = ""
        }
    }

    private func loadSyncCounts() async {
        guard let db else { return }
        let repo = SyncStateRepository(db: db)
        syncCounts = (try? await repo.syncStatusCounts()) ?? [:]
    }
}

extension Notification.Name {
    static let syncNowRequested = Notification.Name("syncNowRequested")
}
