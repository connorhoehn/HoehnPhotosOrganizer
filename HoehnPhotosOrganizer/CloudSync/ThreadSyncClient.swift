// ThreadSyncClient.swift
// HoehnPhotosOrganizer
//
// Uploads and downloads thread entries through the Lambda REST API backed by DynamoDB.
// Handles 25-item batch chunking (DynamoDB BatchWriteItem hard limit) and
// DynamoDB throttle retries (503 -> 2-second backoff -> one retry).
//
// Architecture notes:
//   - Does NOT hold a reference to AppDatabase — callers update ThreadEntry.syncState
//     via ThreadRepository after upload succeeds.
//   - Upload payload uses "kind" key (Lambda/DynamoDB schema) mapped from
//     SyncThreadEntry.type.rawValue.
//   - Download response uses a wire struct (ThreadEntryWireResponse) to decouple
//     the Lambda JSON field name "kind" from SyncThreadEntry's "type" field.
//   - All network calls use URLSession.shared by default; inject for testability.

import Foundation

// MARK: - ThreadSyncClient

actor ThreadSyncClient {
    private let apiEndpoint: String
    private let session: any HTTPDataProvider

    init(apiEndpoint: String, session: any HTTPDataProvider = URLSession.shared) {
        self.apiEndpoint = apiEndpoint
        self.session = session
    }

    // MARK: - Upload

    /// Upload thread entries to DynamoDB via Lambda in 25-item batches.
    ///
    /// - Parameter entries: Thread entries to upload. Must not be empty.
    /// - Returns: Server-side sync timestamp (Unix epoch seconds) after all batches complete.
    /// - Throws: SyncError.uploadFailed or SyncError.invalidResponse on network/parse errors.
    func uploadThreadEntries(_ entries: [SyncThreadEntry]) async throws -> Int64 {
        guard !entries.isEmpty else { return 0 }

        var lastSyncTimestamp: Int64 = 0
        let batchSize = 25

        for startIndex in stride(from: 0, to: entries.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, entries.count)
            let batch = Array(entries[startIndex..<endIndex])

            let batchPayload: [[String: Any]] = batch.map { entry in
                [
                    "entryId": entry.entryId,
                    "threadRootId": entry.threadRootId,
                    "timestamp": entry.timestamp,
                    "kind": entry.type.rawValue,
                    "content": entry.content,
                ] as [String: Any]
            }

            let payload: [String: Any] = ["entries": batchPayload]
            let data = try JSONSerialization.data(withJSONObject: payload)

            var request = URLRequest(url: URL(string: "\(apiEndpoint)/sync/threads")!)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SyncError.invalidResponse
            }

            if httpResponse.statusCode == 503 {
                // DynamoDB throttled — wait 2 seconds and retry once
                try await Task.sleep(for: .seconds(2))
                let (retryData, retryResponse) = try await session.data(for: request)
                guard let retryHttp = retryResponse as? HTTPURLResponse,
                      retryHttp.statusCode == 200 else {
                    throw SyncError.uploadFailed(reason: "DynamoDB throttled after retry")
                }
                let retryResult = try JSONDecoder().decode(SyncUploadResponse.self, from: retryData)
                lastSyncTimestamp = retryResult.syncTimestamp
            } else if httpResponse.statusCode == 200 {
                let result = try JSONDecoder().decode(SyncUploadResponse.self, from: responseData)
                lastSyncTimestamp = result.syncTimestamp
            } else {
                throw SyncError.uploadFailed(reason: "HTTP \(httpResponse.statusCode)")
            }
        }

        return lastSyncTimestamp
    }

    // MARK: - Query

    /// Query thread entries for a photo from DynamoDB in chronological order.
    ///
    /// - Parameter photoId: Photo canonical ID (e.g. "IMG_1234.CR3").
    /// - Returns: Array of SyncThreadEntry sorted by ascending timestamp.
    /// - Throws: SyncError.queryFailed on HTTP error, SyncError.invalidResponse on parse error.
    func queryThreadHistory(for photoId: String) async throws -> [SyncThreadEntry] {
        let encodedId = photoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? photoId
        var request = URLRequest(url: URL(string: "\(apiEndpoint)/sync/threads/\(encodedId)")!)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw SyncError.queryFailed("HTTP \(httpResponse.statusCode) querying threads for \(photoId)")
        }

        let wireResponse = try JSONDecoder().decode(SyncQueryWireResponse.self, from: data)
        return wireResponse.entries.compactMap { wire in
            // Map Lambda "kind" string to SyncThreadEntry.EntryType
            let entryType = SyncThreadEntry.EntryType(rawValue: wire.kind) ?? .note
            return SyncThreadEntry(
                threadRootId: wire.threadRootId,
                entryId: wire.entryId,
                timestamp: Int64(wire.timestamp),
                type: entryType,
                content: wire.content,
                syncedAt: nil
            )
        }
    }
}

// MARK: - Private Response Types

/// Decoded response from POST /sync/threads.
private struct SyncUploadResponse: Codable, Sendable {
    let syncTimestamp: Int64
    let writtenCount: Int
}

/// Wire format returned by GET /sync/threads/{photoId}.
/// Uses "kind" field name matching the Lambda/DynamoDB schema.
private struct ThreadEntryWire: Codable, Sendable {
    let entryId: String
    let threadRootId: String
    let kind: String
    let content: String
    let timestamp: Int
}

private struct SyncQueryWireResponse: Codable, Sendable {
    let entries: [ThreadEntryWire]
}
