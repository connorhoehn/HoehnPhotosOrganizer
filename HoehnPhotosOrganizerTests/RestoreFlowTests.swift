// RestoreFlowTests.swift
// HoehnPhotosOrganizerTests
//
// SYNC-8: Full restore workflow on a new Mac — sign in, download manifest,
// download proxies, restore catalog metadata, replay thread entries.
// All tests are stub skips; Wave 1 implementation will drive them RED → GREEN.

import XCTest

final class RestoreFlowTests: XCTestCase {

    /// SYNC-8: Full restore wizard happy path on a clean Mac.
    /// Steps: signIn → fetchManifest → downloadProxies → restoreMetadata → replayThreads → verify.
    /// Verifies: each step completes, final DB matches expected proxy count + thread count.
    func test_restoreWizard_flow() throws {
        throw XCTSkip("Wave 1+ implementation: full restore wizard happy path — 5 steps from sign-in to verified state")
    }

    /// SYNC-8: Proxy download fails mid-batch due to S3 timeout; retry succeeds.
    /// Verifies: RestoreService retries failed batch, eventual success with correct proxy count.
    func test_restoreWizard_proxyDownload_retryOnFailure() throws {
        throw XCTSkip("Wave 1+ implementation: S3 timeout during proxy batch → parallel retry → all proxies downloaded")
    }

    /// SYNC-8: Thread entries are replayed in chronological order.
    /// Verifies: replayed entries arrive sorted by (sortKey = ISO-8601 + entryId) ascending.
    func test_restoreWizard_threadReplay_chronological() throws {
        throw XCTSkip("Wave 1+ implementation: DynamoDB GSI query returns entries by sortKey asc → local DB reflects same order")
    }

    /// SYNC-8: Some proxies were never synced before restore (e.g., photos that existed only locally).
    /// Verifies: RestoreService marks those photos as \"partial\" — not missing, just proxy-less.
    func test_restoreWizard_incompleteSyncData() throws {
        throw XCTSkip("Wave 1+ implementation: proxies for some photos absent in S3 → restore sets syncState=\"partial\" for those entries")
    }
}
