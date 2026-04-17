// CatalogSyncClient.swift
// HoehnPhotosOrganizer
//
// Pushes and pulls catalog entities (photos, jobs, people, faces, revisions) through
// the Lambda REST API backed by DynamoDB.
// Handles 25-item batch chunking (DynamoDB BatchWriteItem hard limit) and
// DynamoDB throttle retries (503 -> 2-second backoff -> one retry).
//
// Architecture notes:
//   - Does NOT hold a reference to AppDatabase — callers update local records
//     after push/pull succeeds.
//   - pushBatch encodes CatalogSyncItem arrays as JSON and POSTs to /sync/catalog-batch.
//   - pullChanges queries /sync/catalog with optional entity-type filter and pagination.
//   - softDelete sends DELETE /sync/catalog/{entityType}/{entityId} to tombstone a record.
//   - All network calls use URLSession.shared by default; inject for testability.

import Foundation

// MARK: - CatalogSyncClient

actor CatalogSyncClient {
    private let apiEndpoint: String
    private let session: any HTTPDataProvider

    init(apiEndpoint: String, session: any HTTPDataProvider = URLSession.shared) {
        self.apiEndpoint = apiEndpoint
        self.session = session
    }

    // MARK: - Push Batch

    /// Upload catalog sync items to DynamoDB via Lambda in 25-item batches.
    ///
    /// - Parameter items: Catalog items to upload. Must not be empty.
    /// - Returns: CatalogBatchResponse with server-side sync timestamp and written count.
    /// - Throws: SyncError.uploadFailed or SyncError.invalidResponse on network/parse errors.
    func pushBatch(_ items: [CatalogSyncItem]) async throws -> CatalogBatchResponse {
        guard !items.isEmpty else {
            return CatalogBatchResponse(syncTimestamp: 0, writtenCount: 0)
        }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let batchSize = 25

        var lastResponse = CatalogBatchResponse(syncTimestamp: 0, writtenCount: 0)
        var totalWritten = 0

        for startIndex in stride(from: 0, to: items.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, items.count)
            let batch = Array(items[startIndex..<endIndex])

            let payload = ["items": batch]
            let data = try encoder.encode(payload)

            var request = URLRequest(url: URL(string: "\(apiEndpoint)/sync/catalog-batch")!)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (responseData, response) = try await _response(for: request, decoder: decoder)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 503 {
                // DynamoDB throttled — wait 2 seconds and retry once
                try await Task.sleep(for: .seconds(2))
                let (retryData, retryResponse) = try await session.data(for: request)
                guard let retryHttp = retryResponse as? HTTPURLResponse,
                      retryHttp.statusCode == 200 else {
                    throw SyncError.uploadFailed(reason: "DynamoDB throttled after retry")
                }
                let retryResult = try decoder.decode(CatalogBatchResponse.self, from: retryData)
                totalWritten += retryResult.writtenCount
                lastResponse = retryResult
            } else {
                let result = try decoder.decode(CatalogBatchResponse.self, from: responseData)
                totalWritten += result.writtenCount
                lastResponse = result
            }
        }

        return CatalogBatchResponse(syncTimestamp: lastResponse.syncTimestamp, writtenCount: totalWritten)
    }

    // MARK: - Pull Changes

    /// Pull catalog changes from DynamoDB since a given timestamp.
    ///
    /// - Parameters:
    ///   - since: Unix epoch seconds — only items updated after this timestamp are returned.
    ///   - entityType: Optional filter to pull only one entity type.
    ///   - limit: Maximum number of items per page (default 100).
    ///   - nextToken: Pagination token from a previous response. Nil for the first page.
    /// - Returns: CatalogPullResponse with items, optional nextToken, and server sync timestamp.
    /// - Throws: SyncError.queryFailed on HTTP error, SyncError.invalidResponse on parse error.
    func pullChanges(
        since: Int64,
        entityType: CatalogEntityType? = nil,
        limit: Int = 100,
        nextToken: String? = nil
    ) async throws -> CatalogPullResponse {
        var components = URLComponents(string: "\(apiEndpoint)/sync/catalog")!
        var queryItems = [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let entityType {
            queryItems.append(URLQueryItem(name: "entityType", value: entityType.rawValue))
        }
        if let nextToken {
            queryItems.append(URLQueryItem(name: "nextToken", value: nextToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        let decoder = JSONDecoder()
        let (responseData, response) = try await _response(for: request, decoder: decoder)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 503 {
            // DynamoDB throttled — wait 2 seconds and retry once
            try await Task.sleep(for: .seconds(2))
            let (retryData, retryResponse) = try await session.data(for: request)
            guard let retryHttp = retryResponse as? HTTPURLResponse,
                  retryHttp.statusCode == 200 else {
                throw SyncError.queryFailed("DynamoDB throttled after retry pulling catalog")
            }
            return try decoder.decode(CatalogPullResponse.self, from: retryData)
        }

        return try decoder.decode(CatalogPullResponse.self, from: responseData)
    }

    // MARK: - Soft Delete

    /// Tombstone a catalog entity in DynamoDB (soft delete).
    ///
    /// - Parameters:
    ///   - entityType: The type of entity to delete.
    ///   - entityId: The entity's unique identifier.
    /// - Throws: SyncError.uploadFailed on HTTP error, SyncError.invalidResponse on non-HTTP response.
    func softDelete(entityType: CatalogEntityType, entityId: String) async throws {
        let encodedId = entityId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entityId
        let url = URL(string: "\(apiEndpoint)/sync/catalog/\(entityType.rawValue)/\(encodedId)")!

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }

        if httpResponse.statusCode == 503 {
            // DynamoDB throttled — wait 2 seconds and retry once
            try await Task.sleep(for: .seconds(2))
            let (_, retryResponse) = try await session.data(for: request)
            guard let retryHttp = retryResponse as? HTTPURLResponse,
                  (200..<300).contains(retryHttp.statusCode) else {
                throw SyncError.uploadFailed(reason: "DynamoDB throttled after retry deleting \(entityType.rawValue)/\(entityId)")
            }
        } else if !(200..<300).contains(httpResponse.statusCode) {
            throw SyncError.uploadFailed(reason: "HTTP \(httpResponse.statusCode) deleting \(entityType.rawValue)/\(entityId)")
        }
    }

    // MARK: - Private Helpers

    /// Execute a URLSession request and validate the HTTP response.
    /// Returns the response data and URLResponse on success (HTTP 200).
    /// Returns the raw data and response for 503 so callers can handle throttle retry.
    /// Throws SyncError for other non-200 status codes.
    private func _response(
        for request: URLRequest,
        decoder: JSONDecoder
    ) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.invalidResponse
        }

        if httpResponse.statusCode == 503 {
            // Return to caller for throttle-retry handling
            return (data, response)
        }

        guard httpResponse.statusCode == 200 else {
            throw SyncError.uploadFailed(reason: "HTTP \(httpResponse.statusCode)")
        }

        return (data, response)
    }
}
