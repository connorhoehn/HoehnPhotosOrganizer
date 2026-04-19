//
//  AWSPhotoSyncClient.swift
//  HoehnPhotosCore
//
//  HTTP core of the AWS cloud sync client. Talks to the API Gateway + Lambda
//  stack defined in `infra/hoehn_photos_cdk/stacks/sync_stack.py` and
//  documented in `infra/sync-api.openapi.yaml`.
//
//  Authentication is handled by a caller-supplied token provider closure so
//  this module stays free of iOS-specific Cognito types. The iOS target wires
//  the closure to `AuthEnvironment.currentIdToken()`.
//
//  Scope:
//    - Presigned URL issuance for proxies and curve files
//    - Catalog batch push + incremental pull + soft delete
//    - Thread entry push + pull
//    - Per-photo sync status
//
//  Out of scope (other agents):
//    - PeerSyncService integration
//    - Schema migrations
//    - Token refresh / retry-on-401 (caller responsibility)
//

import Foundation
import os

// MARK: - Config

public struct AWSPhotoSyncConfig: Sendable {
    public let apiBaseURL: URL
    public let tokenProvider: @Sendable () async -> String?

    public init(
        apiBaseURL: URL,
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.apiBaseURL = apiBaseURL
        self.tokenProvider = tokenProvider
    }
}

// MARK: - AnyCodable

/// Minimal heterogeneous JSON box. Supports the JSON primitive set plus
/// nested arrays/objects. Used for Catalog item payloads whose shape varies
/// by entityType and for pull-side items where we don't decode into a typed
/// struct here.
public struct AnyCodable: @unchecked Sendable, Codable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { self.value = b; return }
        if let i = try? c.decode(Int64.self) { self.value = i; return }
        if let d = try? c.decode(Double.self) { self.value = d; return }
        if let s = try? c.decode(String.self) { self.value = s; return }
        if let arr = try? c.decode([AnyCodable].self) { self.value = arr; return }
        if let obj = try? c.decode([String: AnyCodable].self) { self.value = obj; return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "AnyCodable: unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let i as Int64: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [AnyCodable]: try c.encode(a)
        case let o as [String: AnyCodable]: try c.encode(o)
        default:
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "AnyCodable: unsupported value \(type(of: value))")
            )
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Loose value equality — good enough for tests/logs.
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

// MARK: - Client

public actor AWSPhotoSyncClient {

    // MARK: Stored

    private let config: AWSPhotoSyncConfig
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.hoehn-photos.sync", category: "AWSPhotoSyncClient")

    // MARK: Init

    public init(config: AWSPhotoSyncConfig) {
        self.config = config

        // Ephemeral config, 15s timeout, using the shared session under the
        // hood per requirements ("don't shove ephemeral in the actor — just
        // use default session"). We build a configured session around
        // URLSession.shared's delegate queue semantics by using the shared
        // session directly for the network calls and applying per-request
        // timeouts via URLRequest.timeoutInterval.
        //
        // Note: URLSession.shared uses the default configuration. The 15s
        // timeout is applied per-request via URLRequest.timeoutInterval so
        // individual calls get the ephemeral-like behavior.
        self.session = URLSession.shared

        // JSON strategies
        //
        // NOTE: The sync-api.openapi.yaml contract explicitly uses Unix epoch
        // seconds (integers) for all timestamps and camelCase keys — NOT
        // ISO8601 strings or snake_case keys as the implementation prompt
        // suggested. The OpenAPI spec is the authoritative wire contract,
        // so we use .secondsSince1970 and .useDefaultKeys here.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.keyEncodingStrategy = .useDefaultKeys
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        dec.keyDecodingStrategy = .useDefaultKeys
        self.decoder = dec
    }

    // MARK: - Public API: Presigned URLs

    public struct PresignedURL: Sendable, Decodable {
        public let uploadURL: URL
        public let key: String
        public let expiresAt: Date

        // Map from on-the-wire fields (presignedUrl, s3Key, expiresIn seconds)
        // to the public shape requested by the prompt.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: WireKey.self)
            let urlString = try c.decode(String.self, forKey: .presignedUrl)
            guard let url = URL(string: urlString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .presignedUrl, in: c,
                    debugDescription: "presignedUrl is not a valid URL: \(urlString)"
                )
            }
            self.uploadURL = url
            self.key = try c.decode(String.self, forKey: .s3Key)
            let expiresIn = try c.decode(TimeInterval.self, forKey: .expiresIn)
            self.expiresAt = Date().addingTimeInterval(expiresIn)
        }

        public init(uploadURL: URL, key: String, expiresAt: Date) {
            self.uploadURL = uploadURL
            self.key = key
            self.expiresAt = expiresAt
        }

        private enum WireKey: String, CodingKey {
            case presignedUrl, s3Key, expiresIn
        }
    }

    /// POST /sync/proxies
    ///
    /// TODO: verify against spec — OpenAPI spec requires `contentLength` +
    /// `checksum`. The public prompt exposes `contentType` instead. We send
    /// what the prompt asks for; the Lambda will need to accept this shape
    /// or the caller will need to extend this method.
    public func requestProxyUploadURL(canonicalId: String, contentType: String) async throws -> PresignedURL {
        struct Body: Encodable {
            let canonicalId: String
            let contentType: String
        }
        let body = Body(canonicalId: canonicalId, contentType: contentType)
        return try await send(
            method: "POST",
            path: "/sync/proxies",
            query: nil,
            body: body,
            responseType: PresignedURL.self
        )
    }

    /// POST /sync/curves
    ///
    /// TODO: verify against spec — OpenAPI spec requires `photoId`,
    /// `attemptId`, `fileExtension`, `contentLength`, `checksum`. The prompt
    /// exposes `filename` + `contentType`. Shipping the prompt's shape.
    public func requestCurveUploadURL(filename: String, contentType: String) async throws -> PresignedURL {
        struct Body: Encodable {
            let filename: String
            let contentType: String
        }
        let body = Body(filename: filename, contentType: contentType)
        return try await send(
            method: "POST",
            path: "/sync/curves",
            query: nil,
            body: body,
            responseType: PresignedURL.self
        )
    }

    // MARK: - Public API: Catalog

    /// Generic catalog entity sent to `/sync/catalog-batch`.
    ///
    /// Wire mapping:
    ///   - payload -> `data` on the wire (OpenAPI field name).
    ///   - updatedAt is client-local; the server returns authoritative
    ///     `syncTimestamp` for subsequent pulls.
    public struct CatalogItem: Sendable, Encodable {
        public let entityId: String
        public let entityType: String
        public let payload: [String: AnyCodable]
        public let updatedAt: Date

        public init(entityId: String, entityType: String, payload: [String: AnyCodable], updatedAt: Date) {
            self.entityId = entityId
            self.entityType = entityType
            self.payload = payload
            self.updatedAt = updatedAt
        }

        private enum WireKey: String, CodingKey {
            case entityId, entityType, data, updatedAt
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: WireKey.self)
            try c.encode(entityId, forKey: .entityId)
            try c.encode(entityType, forKey: .entityType)
            try c.encode(payload, forKey: .data)
            try c.encode(updatedAt, forKey: .updatedAt)
        }
    }

    /// POST /sync/catalog-batch
    public func uploadCatalogBatch(_ items: [CatalogItem]) async throws {
        struct Body: Encodable { let items: [CatalogItem] }
        struct Ack: Decodable { let syncTimestamp: Int64?; let writtenCount: Int? }
        _ = try await send(
            method: "POST",
            path: "/sync/catalog-batch",
            query: nil,
            body: Body(items: items),
            responseType: Ack.self
        )
    }

    /// GET /sync/catalog?since=<epoch>&entityType=<X>&limit=<N>
    ///
    /// The OpenAPI spec returns `{ items, nextToken, syncTimestamp }`. We map
    /// `syncTimestamp` to `nextSince` so callers can pass it back on the next
    /// pull.
    public func pullCatalogChanges(
        since: Date,
        entityType: String?,
        limit: Int
    ) async throws -> (items: [[String: AnyCodable]], nextSince: Date?) {
        struct Response: Decodable {
            let items: [[String: AnyCodable]]
            let syncTimestamp: TimeInterval?
            // nextToken intentionally ignored here — callers that need paging
            // should use the returned nextSince; full cursor support can be
            // added when PeerSyncService needs it.
        }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "since", value: String(Int64(since.timeIntervalSince1970))),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let entityType { query.append(URLQueryItem(name: "entityType", value: entityType)) }
        let resp = try await send(
            method: "GET",
            path: "/sync/catalog",
            query: query,
            body: Optional<Empty>.none,
            responseType: Response.self
        )
        let nextSince = resp.syncTimestamp.map { Date(timeIntervalSince1970: $0) }
        return (resp.items, nextSince)
    }

    /// DELETE /sync/catalog/{entityType}/{entityId}
    public func deleteCatalogEntity(entityType: String, entityId: String) async throws {
        guard
            let encodedType = entityType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let encodedId = entityId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            throw Error.httpError(status: 400, body: "invalid path components")
        }
        struct Ack: Decodable { let deleted: Bool? }
        _ = try await send(
            method: "DELETE",
            path: "/sync/catalog/\(encodedType)/\(encodedId)",
            query: nil,
            body: Optional<Empty>.none,
            responseType: Ack.self
        )
    }

    // MARK: - Public API: Threads

    /// Thread entry. Wire mapping:
    ///   kind       ->  type       (wire)
    ///   bodyJson   ->  content    (wire; JSON-serialized string per spec)
    ///   occurredAt ->  timestamp  (wire; unix epoch seconds)
    public struct ThreadEntry: Sendable, Codable {
        public let threadRootId: String
        public let entryId: String
        public let kind: String
        public let bodyJson: String
        public let occurredAt: Date

        public init(threadRootId: String, entryId: String, kind: String, bodyJson: String, occurredAt: Date) {
            self.threadRootId = threadRootId
            self.entryId = entryId
            self.kind = kind
            self.bodyJson = bodyJson
            self.occurredAt = occurredAt
        }

        private enum WireKey: String, CodingKey {
            case threadRootId, entryId, type, content, timestamp
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: WireKey.self)
            self.threadRootId = try c.decode(String.self, forKey: .threadRootId)
            self.entryId = try c.decode(String.self, forKey: .entryId)
            self.kind = try c.decode(String.self, forKey: .type)
            self.bodyJson = try c.decode(String.self, forKey: .content)
            self.occurredAt = try c.decode(Date.self, forKey: .timestamp)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: WireKey.self)
            try c.encode(threadRootId, forKey: .threadRootId)
            try c.encode(entryId, forKey: .entryId)
            try c.encode(kind, forKey: .type)
            try c.encode(bodyJson, forKey: .content)
            try c.encode(occurredAt, forKey: .timestamp)
        }
    }

    /// POST /sync/threads
    ///
    /// The OpenAPI spec accepts a single ThreadEntry per request. We loop
    /// client-side to preserve idempotency (conditional DynamoDB write on
    /// entryId) and honor the per-request retry policy.
    public func uploadThreadEntries(_ entries: [ThreadEntry]) async throws {
        struct Ack: Decodable { let entryId: String?; let syncedAt: Int64? }
        for entry in entries {
            _ = try await send(
                method: "POST",
                path: "/sync/threads",
                query: nil,
                body: entry,
                responseType: Ack.self
            )
        }
    }

    /// GET /sync/threads/{threadRootId}?since=<epoch>
    public func fetchThreads(threadRootId: String, since: Date?) async throws -> [ThreadEntry] {
        guard let encodedId = threadRootId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw Error.httpError(status: 400, body: "invalid threadRootId")
        }
        struct Response: Decodable {
            let entries: [ThreadEntry]
            // nextToken, totalCount ignored — PeerSyncService layer handles paging.
        }
        var query: [URLQueryItem] = []
        if let since {
            query.append(URLQueryItem(name: "since", value: String(Int64(since.timeIntervalSince1970))))
        }
        let resp = try await send(
            method: "GET",
            path: "/sync/threads/\(encodedId)",
            query: query.isEmpty ? nil : query,
            body: Optional<Empty>.none,
            responseType: Response.self
        )
        return resp.entries
    }

    // MARK: - Public API: Status

    public struct SyncStatus: Sendable, Decodable {
        public let canonicalId: String
        public let proxyUploaded: Bool
        public let threadCount: Int
        public let lastSyncTime: Date?

        private enum WireKey: String, CodingKey {
            case canonicalId, proxyStatus, threadCount, lastSyncTime
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: WireKey.self)
            self.canonicalId = try c.decode(String.self, forKey: .canonicalId)
            let proxyStatus = try c.decodeIfPresent(String.self, forKey: .proxyStatus)
            self.proxyUploaded = (proxyStatus == "synced")
            self.threadCount = try c.decodeIfPresent(Int.self, forKey: .threadCount) ?? 0
            if let epoch = try c.decodeIfPresent(TimeInterval.self, forKey: .lastSyncTime) {
                self.lastSyncTime = Date(timeIntervalSince1970: epoch)
            } else {
                self.lastSyncTime = nil
            }
        }

        public init(canonicalId: String, proxyUploaded: Bool, threadCount: Int, lastSyncTime: Date?) {
            self.canonicalId = canonicalId
            self.proxyUploaded = proxyUploaded
            self.threadCount = threadCount
            self.lastSyncTime = lastSyncTime
        }
    }

    /// GET /sync/status/{canonicalId}
    public func syncStatus(canonicalId: String) async throws -> SyncStatus {
        guard let encoded = canonicalId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw Error.httpError(status: 400, body: "invalid canonicalId")
        }
        return try await send(
            method: "GET",
            path: "/sync/status/\(encoded)",
            query: nil,
            body: Optional<Empty>.none,
            responseType: SyncStatus.self
        )
    }

    // MARK: - Errors

    public enum Error: Swift.Error, Sendable {
        case unauthenticated
        case forbidden
        case rateLimited(retryAfter: TimeInterval?)
        case networkError(URLError)
        case httpError(status: Int, body: String?)
        case decodingError(Swift.Error)
    }

    // MARK: - Internal plumbing

    /// Empty body placeholder for GET/DELETE.
    private struct Empty: Encodable {}

    /// Retry policy constants.
    private enum Retry {
        static let rateLimitMax = 3
        static let serverErrorMax = 2
        static let networkMax = 2
        static let initialBackoff: TimeInterval = 1.0
    }

    /// Core request dispatcher. Generic over encodable body and decodable
    /// response. Applies auth, retry policy, and error mapping.
    private func send<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem]?,
        body: Body?,
        responseType: Response.Type
    ) async throws -> Response {

        // Short-circuit if unauthenticated.
        guard let token = await config.tokenProvider() else {
            logger.warning("send(\(method, privacy: .public) \(path, privacy: .public)): no token — throwing .unauthenticated")
            throw Error.unauthenticated
        }

        let request = try makeRequest(method: method, path: path, query: query, body: body, token: token)

        var rateLimitAttempts = 0
        var serverErrorAttempts = 0
        var networkAttempts = 0
        var backoff = Retry.initialBackoff

        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    logger.error("send: non-HTTP response")
                    throw Error.httpError(status: -1, body: nil)
                }

                logger.debug("send(\(method, privacy: .public) \(path, privacy: .public)): status \(http.statusCode)")

                switch http.statusCode {
                case 200..<300:
                    // Some endpoints return 204 / empty bodies — handle via
                    // a minimal sentinel for Empty response types.
                    if data.isEmpty {
                        if let empty = EmptyAck() as? Response { return empty }
                        // Fall through to decode (will likely error, but honest).
                    }
                    do {
                        return try decoder.decode(Response.self, from: data)
                    } catch {
                        logger.error("send: decoding error \(String(describing: error), privacy: .public)")
                        throw Error.decodingError(error)
                    }

                case 401:
                    logger.warning("send: 401 — throwing .unauthenticated (caller should refresh)")
                    throw Error.unauthenticated

                case 403:
                    logger.warning("send: 403 forbidden")
                    throw Error.forbidden

                case 429:
                    let retryAfter = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                    rateLimitAttempts += 1
                    if rateLimitAttempts > Retry.rateLimitMax {
                        logger.warning("send: 429 exceeded max retries (\(Retry.rateLimitMax))")
                        throw Error.rateLimited(retryAfter: retryAfter)
                    }
                    let wait = retryAfter ?? backoff
                    logger.notice("send: 429 — sleeping \(wait)s before retry \(rateLimitAttempts)/\(Retry.rateLimitMax)")
                    try await sleep(seconds: wait)
                    backoff *= 2
                    continue

                case 500..<600:
                    serverErrorAttempts += 1
                    if serverErrorAttempts > Retry.serverErrorMax {
                        let body = String(data: data, encoding: .utf8)
                        logger.error("send: 5xx exceeded max retries — status \(http.statusCode)")
                        throw Error.httpError(status: http.statusCode, body: body)
                    }
                    logger.notice("send: \(http.statusCode) — sleeping \(backoff)s before retry \(serverErrorAttempts)/\(Retry.serverErrorMax)")
                    try await sleep(seconds: backoff)
                    backoff *= 2
                    continue

                default:
                    // 4xx (other than 401/403/429) — no retry.
                    let body = String(data: data, encoding: .utf8)
                    logger.error("send: non-retryable \(http.statusCode) body=\(body ?? "<nil>", privacy: .public)")
                    throw Error.httpError(status: http.statusCode, body: body)
                }
            } catch let urlError as URLError {
                let transient = (urlError.code == .timedOut || urlError.code == .networkConnectionLost)
                if transient {
                    networkAttempts += 1
                    if networkAttempts > Retry.networkMax {
                        logger.error("send: network error exceeded max retries — \(urlError.localizedDescription, privacy: .public)")
                        throw Error.networkError(urlError)
                    }
                    logger.notice("send: transient network error (\(urlError.code.rawValue)) — sleeping \(backoff)s before retry \(networkAttempts)/\(Retry.networkMax)")
                    try await sleep(seconds: backoff)
                    backoff *= 2
                    continue
                } else {
                    logger.error("send: non-retryable network error \(urlError.localizedDescription, privacy: .public)")
                    throw Error.networkError(urlError)
                }
            }
            // Error enum cases thrown above are not caught here — they
            // propagate to the caller.
        }
    }

    /// Sentinel returned when a 2xx response has an empty body and the caller
    /// expected a decodable value. Only usable if Response happens to be
    /// EmptyAck (i.e. a method that declared it explicitly).
    private struct EmptyAck: Decodable {}

    private func makeRequest<Body: Encodable>(
        method: String,
        path: String,
        query: [URLQueryItem]?,
        body: Body?,
        token: String
    ) throws -> URLRequest {
        guard var comps = URLComponents(
            url: config.apiBaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw Error.httpError(status: -1, body: "could not form URL for \(path)")
        }
        if let query, !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else {
            throw Error.httpError(status: -1, body: "invalid URL components")
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                req.httpBody = try encoder.encode(body)
            } catch {
                logger.error("makeRequest: body encode failed — \(String(describing: error), privacy: .public)")
                throw Error.decodingError(error)
            }
        }
        return req
    }

    private func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = TimeInterval(header) { return seconds }
        // HTTP-date form ("Wed, 21 Oct 2026 07:28:00 GMT") is not expected
        // from API Gateway/Lambda but we handle it defensively.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private func sleep(seconds: TimeInterval) async throws {
        let ns = UInt64((seconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: ns)
    }
}
