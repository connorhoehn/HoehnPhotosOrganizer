// InitialSyncWizardViewModel.swift
// HoehnPhotosOrganizer
//
// ViewModel for the initial sync wizard. Manages the three-step flow:
//   1. Confirm  — show photo count + estimated size, user taps "Begin"
//   2. Uploading — upload proxies for all unsynced photos, with pause/resume
//   3. Complete — green checkmark, done
//
// Uses ProxySyncClient for uploads and SyncStateRepository to query/update status.

import Foundation
import Combine
import GRDB

@MainActor
class InitialSyncWizardViewModel: ObservableObject {

    // MARK: - Step Enum

    enum WizardStep: String, CaseIterable {
        case confirm
        case uploading
        case complete
        case error
    }

    // MARK: - Published State

    @Published var step: WizardStep = .confirm
    @Published var progress: Double = 0.0
    @Published var currentItem: String = ""
    @Published var completedCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var errorMessage: String?
    @Published var isPaused: Bool = false
    @Published var estimatedSizeBytes: Int64 = 0

    // MARK: - Dependencies

    private let db: AppDatabase
    private let proxySyncClient: ProxySyncClient?
    private let syncStateRepo: SyncStateRepository
    private let bucketName: String

    // MARK: - Internal State

    private var uploadTask: Task<Void, Never>?
    private var unsyncedPhotos: [PhotoAsset] = []

    // MARK: - Init

    init(db: AppDatabase, proxySyncClient: ProxySyncClient? = nil) {
        self.db = db
        self.proxySyncClient = proxySyncClient
        self.syncStateRepo = SyncStateRepository(db: db)
        self.bucketName = UserDefaults.standard.string(forKey: "syncS3Bucket") ?? "hoehnphotos-sync"
    }

    // MARK: - Load Counts (called on appear)

    func loadCounts() async {
        do {
            let photos = try await db.dbPool.read { db in
                try PhotoAsset
                    .filter(Column("sync_state") != "synced")
                    .fetchAll(db)
            }
            unsyncedPhotos = photos
            totalCount = photos.count
            estimatedSizeBytes = photos.reduce(into: Int64(0)) { sum, photo in
                sum += Int64(photo.fileSize)
            }
        } catch {
            errorMessage = "Failed to count photos: \(error.localizedDescription)"
        }
    }

    // MARK: - Begin Upload

    func beginUpload() {
        guard !unsyncedPhotos.isEmpty else {
            step = .complete
            return
        }
        step = .uploading
        errorMessage = nil
        isPaused = false
        startUploadTask(startingAt: completedCount)
    }

    // MARK: - Pause / Resume

    func pause() {
        isPaused = true
        uploadTask?.cancel()
        uploadTask = nil
    }

    func resume() {
        isPaused = false
        errorMessage = nil
        startUploadTask(startingAt: completedCount)
    }

    func cancel() {
        uploadTask?.cancel()
        uploadTask = nil
        step = .confirm
        completedCount = 0
        progress = 0.0
        currentItem = ""
        isPaused = false
    }

    // MARK: - Private Upload Loop

    private func startUploadTask(startingAt index: Int) {
        uploadTask = Task { [weak self] in
            guard let self else { return }

            for i in index..<self.unsyncedPhotos.count {
                guard !Task.isCancelled else { return }

                let photo = self.unsyncedPhotos[i]
                self.currentItem = photo.canonicalName
                self.completedCount = i
                self.progress = self.totalCount > 0 ? Double(i) / Double(self.totalCount) : 0

                // Load proxy data from disk
                guard let proxyPath = photo.proxyPath else {
                    // No proxy — mark as synced (metadata only) and continue
                    try? await self.syncStateRepo.updatePhotoSyncStatus(
                        canonicalId: photo.canonicalName,
                        status: "synced"
                    )
                    continue
                }

                let proxyURL = URL(fileURLWithPath: proxyPath)
                guard let proxyData = try? Data(contentsOf: proxyURL), !proxyData.isEmpty else {
                    // Proxy file missing or empty — skip
                    continue
                }

                // Upload via ProxySyncClient
                if let client = self.proxySyncClient {
                    do {
                        try await client.uploadProxy(
                            data: proxyData,
                            canonicalId: photo.canonicalName,
                            bucketName: self.bucketName
                        )
                        try? await self.syncStateRepo.updatePhotoSyncStatus(
                            canonicalId: photo.canonicalName,
                            status: "synced"
                        )
                    } catch {
                        if Task.isCancelled { return }
                        self.errorMessage = "Upload failed for \(photo.canonicalName): \(error.localizedDescription)"
                        self.step = .error
                        return
                    }
                } else {
                    // No sync client configured — mark as synced (placeholder for skip-credentials mode)
                    try? await self.syncStateRepo.updatePhotoSyncStatus(
                        canonicalId: photo.canonicalName,
                        status: "synced"
                    )
                }
            }

            guard !Task.isCancelled else { return }

            self.completedCount = self.totalCount
            self.progress = 1.0
            self.currentItem = ""
            self.step = .complete
            UserDefaults.standard.set(true, forKey: "initialSyncCompleted")
        }
    }

    /// Formatted estimated size string (e.g. "2.4 GB").
    var estimatedSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: estimatedSizeBytes, countStyle: .file)
    }
}
