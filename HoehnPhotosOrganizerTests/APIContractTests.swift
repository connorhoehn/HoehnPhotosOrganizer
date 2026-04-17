// APIContractTests.swift
// HoehnPhotosOrganizerTests
//
// SYNC-7: OpenAPI spec defines all sync and restore endpoints.
// All tests are stub skips; Wave 2 implementation will drive them RED → GREEN.
//
// Note: These tests verify the OpenAPI spec file exists and contains required endpoints.
// Full integration tests (hitting actual Lambda) are out of scope for Wave 0.

import XCTest

final class APIContractTests: XCTestCase {

    /// SYNC-7: OpenAPI spec includes POST /sync/proxies endpoint with request/response schema.
    /// Verifies: openapi.yaml contains path /sync/proxies with POST operation defined.
    func test_openAPISpec_defines_proxySyncEndpoint() throws {
        throw XCTSkip("Wave 2+ implementation: openapi.yaml → /sync/proxies POST → requestBody and responses schemas present")
    }

    /// SYNC-7: OpenAPI spec includes POST /sync/threads for thread entry sync.
    /// Verifies: openapi.yaml contains /sync/threads POST with ThreadEntry request/response schemas.
    func test_openAPISpec_defines_threadSyncEndpoint() throws {
        throw XCTSkip("Wave 2+ implementation: openapi.yaml → /sync/threads POST → ThreadEntry requestBody + 200 response schema")
    }

    /// SYNC-7: OpenAPI spec includes GET /restore/manifest for restore wizard.
    /// Verifies: openapi.yaml contains /restore/manifest GET with RestoreManifest response schema.
    func test_openAPISpec_defines_restoreEndpoint() throws {
        throw XCTSkip("Wave 2+ implementation: openapi.yaml → /restore/manifest GET → RestoreManifest response schema defined")
    }

    /// SYNC-7: Example payloads in the spec validate against their defined schemas.
    /// Verifies: spec examples are syntactically valid JSON and match their referenced schemas.
    func test_requestPayloads_matchOpenAPI() throws {
        throw XCTSkip("Wave 2+ implementation: spec examples are valid JSON and conform to their schemas (no schema violations)")
    }
}
