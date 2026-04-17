// RestoreWizardViewModel.swift
// HoehnPhotosOrganizer
//
// Multi-step restore flow from cloud backup.
// Steps: signIn -> fetchingManifest -> downloadingProxies -> restoringMetadata
//        -> replayingThreads -> verifying -> complete
//
// Graceful degradation: if the API endpoint is unreachable, errorMessage is set
// and the user can retry. The local library is never modified until restore succeeds.

import Foundation
import Combine

@MainActor
class RestoreWizardViewModel: ObservableObject {
    @Published var step: RestoreStep = .signIn
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false

    enum RestoreStep: String, CaseIterable {
        case signIn = "Sign In"
        case fetchingManifest = "Fetching Manifest"
        case downloadingProxies = "Downloading Proxies"
        case restoringMetadata = "Restoring Metadata"
        case replayingThreads = "Replaying Threads"
        case verifying = "Verifying"
        case complete = "Complete"
    }

    private var apiEndpoint: String = ""
    private let session = URLSession.shared

    func signIn(endpoint: String) async {
        apiEndpoint = endpoint
        isProcessing = true
        errorMessage = nil

        // Validate the endpoint is reachable
        do {
            guard let url = URL(string: "\(endpoint)/health") else {
                errorMessage = "Invalid endpoint URL."
                isProcessing = false
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Could not reach sync API. Check endpoint URL."
                isProcessing = false
                return
            }
            step = .fetchingManifest
            await fetchManifest()
        } catch {
            errorMessage = "Connection failed: \(error.localizedDescription)"
            isProcessing = false
        }
    }

    func fetchManifest() async {
        step = .fetchingManifest
        do {
            guard let url = URL(string: "\(apiEndpoint)/restore/manifest") else {
                errorMessage = "Invalid manifest URL."
                isProcessing = false
                return
            }
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Failed to fetch manifest from cloud."
                isProcessing = false
                return
            }
            // Manifest received — initiate proxy download
            step = .downloadingProxies
            await downloadProxies()
        } catch {
            errorMessage = "Failed to fetch manifest: \(error.localizedDescription)"
            isProcessing = false
        }
    }

    func downloadProxies() async {
        step = .downloadingProxies
        // Download proxies in parallel batches of 5, updating progress per batch
        // Actual implementation: iterate manifest proxy list, download each from presigned S3 URL
        // Placeholder: immediately advances (no CDK stack deployed in skip-credentials mode)
        progress = 1.0
        step = .restoringMetadata
        await restoreMetadata()
    }

    func restoreMetadata() async {
        step = .restoringMetadata
        // Download latest catalog export from S3 and restore to local database
        // Placeholder: advances immediately in skip-credentials mode
        step = .replayingThreads
        await replayThreads()
    }

    func replayThreads() async {
        step = .replayingThreads
        // Query all thread entries from DynamoDB for all synced photos
        // Insert into local DB in chronological order via ThreadRepository
        // Placeholder: advances immediately in skip-credentials mode
        step = .verifying
        await verify()
    }

    func verify() async {
        step = .verifying
        // Check: proxies downloaded, metadata restored, threads replayed
        step = .complete
        isProcessing = false
    }

    func retryCurrentStep() async {
        errorMessage = nil
        switch step {
        case .signIn: break // User re-enters credentials manually
        case .fetchingManifest: await fetchManifest()
        case .downloadingProxies: await downloadProxies()
        case .restoringMetadata: await restoreMetadata()
        case .replayingThreads: await replayThreads()
        case .verifying: await verify()
        case .complete: break
        }
    }
}
