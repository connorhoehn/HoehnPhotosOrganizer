// RestoreWizardView.swift
// HoehnPhotosOrganizer
//
// Multi-step restore sheet. Presented from SyncSettingsView ("Restore from Cloud...").
// Steps: signIn -> fetchingManifest -> downloadingProxies -> restoringMetadata
//        -> replayingThreads -> verifying -> complete
//
// In skip-credentials mode the restore is a placeholder flow — the UI is complete
// and will work end-to-end once AWS credentials are configured.

import SwiftUI

struct RestoreWizardView: View {
    @StateObject private var viewModel = RestoreWizardViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint: String = UserDefaults.standard.string(forKey: "syncAPIEndpoint") ?? ""

    var body: some View {
        VStack(spacing: 24) {
            // Progress step dots
            HStack(spacing: 8) {
                ForEach(RestoreWizardViewModel.RestoreStep.allCases, id: \.self) { s in
                    Circle()
                        .fill(stepColor(s))
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.top, 16)

            // Step content
            switch viewModel.step {
            case .signIn:
                signInStep
            case .fetchingManifest:
                progressStep(title: "Fetching sync manifest...", subtitle: "Reading backup inventory from cloud")
            case .downloadingProxies:
                progressStep(title: "Downloading proxies...", subtitle: "Restoring photo previews")
            case .restoringMetadata:
                progressStep(title: "Restoring metadata...", subtitle: "Rebuilding local catalog")
            case .replayingThreads:
                progressStep(title: "Replaying threads...", subtitle: "Restoring notes, AI conversations, print history")
            case .verifying:
                progressStep(title: "Verifying restore...", subtitle: "Checking data integrity")
            case .complete:
                completeStep
            }

            // Error banner
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Retry") {
                        Task { await viewModel.retryCurrentStep() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 480, height: 400)
    }

    private var signInStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Restore from Cloud")
                .font(.title2.bold())

            Text("Enter your sync API endpoint to begin restoring your photo library from cloud backup.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("API Endpoint URL", text: $endpoint)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

            Button("Begin Restore") {
                UserDefaults.standard.set(endpoint, forKey: "syncAPIEndpoint")
                Task { await viewModel.signIn(endpoint: endpoint) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(endpoint.isEmpty || viewModel.isProcessing)
        }
    }

    private func progressStep(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title3.bold())
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
            if viewModel.progress > 0 && viewModel.progress < 1 {
                ProgressView(value: viewModel.progress)
                    .frame(maxWidth: 300)
            }
        }
    }

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Restore Complete")
                .font(.title2.bold())
            Text("Your photo library has been restored from cloud backup.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func stepColor(_ step: RestoreWizardViewModel.RestoreStep) -> Color {
        let allSteps = RestoreWizardViewModel.RestoreStep.allCases
        guard let currentIndex = allSteps.firstIndex(of: viewModel.step),
              let stepIndex = allSteps.firstIndex(of: step) else { return .secondary }
        if stepIndex < currentIndex { return .green }
        if stepIndex == currentIndex { return .blue }
        return Color.secondary.opacity(0.3)
    }
}
