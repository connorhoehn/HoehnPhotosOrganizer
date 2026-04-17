// InitialSyncWizardView.swift
// HoehnPhotosOrganizer
//
// Three-step initial sync wizard presented as a .sheet from SyncSettingsView
// when the user first enables sync (UserDefaults "initialSyncCompleted" == false).
//
// Steps:
//   1. Confirm  — "Upload X photos to cloud?" with count + estimated size
//   2. Uploading — progress bar with file count, pause/resume, cancel
//   3. Complete — green checkmark, Done button

import SwiftUI

struct InitialSyncWizardView: View {
    @StateObject private var viewModel: InitialSyncWizardViewModel
    @Environment(\.dismiss) private var dismiss

    init(db: AppDatabase) {
        _viewModel = StateObject(wrappedValue: InitialSyncWizardViewModel(db: db))
    }

    var body: some View {
        VStack(spacing: 24) {
            // Step dots
            HStack(spacing: 8) {
                stepDot(active: viewModel.step == .confirm, done: stepOrdinal(viewModel.step) > 0)
                stepDot(active: viewModel.step == .uploading, done: stepOrdinal(viewModel.step) > 1)
                stepDot(active: viewModel.step == .complete, done: false)
            }
            .padding(.top, 16)

            // Step content
            switch viewModel.step {
            case .confirm:
                confirmStep
            case .uploading:
                uploadingStep
            case .complete:
                completeStep
            case .error:
                errorStep
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 440, height: 340)
        .task {
            await viewModel.loadCounts()
        }
    }

    // MARK: - Confirm Step

    private var confirmStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Upload \(viewModel.totalCount) photos to cloud?")
                .font(.title2.bold())

            Text("Estimated size: \(viewModel.estimatedSizeFormatted)")
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button("Begin") {
                    viewModel.beginUpload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.totalCount == 0)
            }
        }
    }

    // MARK: - Uploading Step

    private var uploadingStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 36))
                .foregroundStyle(.blue)

            Text("Uploading proxies (\(viewModel.completedCount)/\(viewModel.totalCount))")
                .font(.title3.bold())

            if !viewModel.currentItem.isEmpty {
                Text(viewModel.currentItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView(value: viewModel.progress)
                .frame(maxWidth: 300)

            HStack(spacing: 12) {
                Button("Cancel") {
                    viewModel.cancel()
                }
                .buttonStyle(.bordered)

                if viewModel.isPaused {
                    Button("Resume") {
                        viewModel.resume()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Pause") {
                        viewModel.pause()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Complete Step

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Initial Sync Complete")
                .font(.title2.bold())

            Text("\(viewModel.totalCount) photos uploaded to cloud.")
                .font(.body)
                .foregroundStyle(.secondary)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Error Step

    private var errorStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Upload Error")
                .font(.title2.bold())

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    viewModel.cancel()
                }
                .buttonStyle(.bordered)

                Button("Retry") {
                    viewModel.resume()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private func stepDot(active: Bool, done: Bool) -> some View {
        Circle()
            .fill(done ? .green : active ? .blue : Color.secondary.opacity(0.3))
            .frame(width: 10, height: 10)
    }

    private func stepOrdinal(_ step: InitialSyncWizardViewModel.WizardStep) -> Int {
        switch step {
        case .confirm: return 0
        case .uploading, .error: return 1
        case .complete: return 2
        }
    }
}
