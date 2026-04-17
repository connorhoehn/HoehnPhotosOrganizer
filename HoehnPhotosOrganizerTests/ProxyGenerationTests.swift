import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import HoehnPhotosOrganizer

struct ProxyGenerationTests {

    // MARK: - PRX-1: Longest edge ≤ 1600 px

    @Test(.disabled("requires Fixtures/sample.jpg — see Fixtures/README.md"))
    func testProxyLongestEdgeAtMost1600px() async throws {
        // PRX-1: generated proxy from Fixtures/sample.jpg has longest edge <= 1600
        let fixtureURL = fixturesURL().appendingPathComponent("sample.jpg")
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let proxyRepo = ProxyAssetRepository(db: db)
        let actor = ProxyGenerationActor(photoRepo: photoRepo, proxyRepo: proxyRepo)

        // Insert a proxyPending photo asset
        var asset = PhotoAsset.new(canonicalName: "sample.jpg", role: .original,
                                   filePath: "sample.jpg", fileSize: 0)
        asset.processingState = ProcessingState.proxyPending.rawValue
        try await photoRepo.upsert(asset)

        // Run proxy generation with fixtures dir as mount
        let mountURL = fixtureURL.deletingLastPathComponent()
        var progress: ProxyGenerationProgress?
        for await p in actor.processQueue(driveMount: mountURL) {
            progress = p
        }

        #expect(progress != nil)
        #expect(progress?.completed == 1)
        #expect(progress?.failed == 0)

        // Verify proxy dimensions
        let proxy = try await proxyRepo.fetchByPhotoId(asset.id)
        #expect(proxy != nil)
        if let proxy {
            let longestEdge = max(proxy.width, proxy.height)
            #expect(longestEdge <= 1600, "Longest edge \(longestEdge) exceeds 1600 px (PRX-1)")
        }
    }

    // MARK: - PRX-3: Proxy path under Application Support

    @Test(.disabled("requires Fixtures/sample.jpg — see Fixtures/README.md"))
    func testProxySavedUnderApplicationSupport() async throws {
        // PRX-3: saved proxy path contains ~/Library/Application Support/HoehnPhotosOrganizer/proxies/
        let fixtureURL = fixturesURL().appendingPathComponent("sample.jpg")
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let proxyRepo = ProxyAssetRepository(db: db)
        let actor = ProxyGenerationActor(photoRepo: photoRepo, proxyRepo: proxyRepo)

        var asset = PhotoAsset.new(canonicalName: "sample.jpg", role: .original,
                                   filePath: "sample.jpg", fileSize: 0)
        asset.processingState = ProcessingState.proxyPending.rawValue
        try await photoRepo.upsert(asset)

        let mountURL = fixtureURL.deletingLastPathComponent()
        for await _ in actor.processQueue(driveMount: mountURL) {}

        let proxy = try await proxyRepo.fetchByPhotoId(asset.id)
        #expect(proxy != nil)

        if let proxy {
            let expectedDir = ProxyGenerationActor.proxiesDirectory().path
            #expect(proxy.filePath.hasPrefix(expectedDir),
                    "Proxy path '\(proxy.filePath)' not under '\(expectedDir)' (PRX-3)")
        }
    }

    // MARK: - PRX-5: Embedded preview used when available

    @Test(.disabled("requires Fixtures/sample.dng — see Fixtures/README.md"))
    func testEmbeddedPreviewUsedWhenAvailable() async throws {
        // PRX-5: when sample.dng contains an embedded thumbnail, proxy generation
        // uses CGImageSourceCreateThumbnailAtIndex (fast path) instead of full CIRAWFilter decode.
        // Verified by confirming the embedded thumbnail is accessible and has correct longest edge.
        let fixtureURL = fixturesURL().appendingPathComponent("sample.dng")
        guard let source = CGImageSourceCreateWithURL(fixtureURL as CFURL, nil) else {
            Issue.record("Could not open sample.dng fixture")
            return
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ]
        let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        #expect(thumb != nil,
                "sample.dng should contain an embedded thumbnail accessible via CGImageSourceCreateThumbnailAtIndex (PRX-5)")

        if let thumb {
            let longestEdge = max(thumb.width, thumb.height)
            #expect(longestEdge <= 1600, "Embedded thumbnail longest edge \(longestEdge) > 1600 (PRX-5)")
        }
    }

    // MARK: - PRX-10: thumbnailPath / thumbnailByteSize round-trip

    @Test("ProxyAsset with nil thumbnailPath round-trips through upsert + fetch")
    func testProxyAssetNilThumbnailPathRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        let proxyRepo = ProxyAssetRepository(db: db)

        // Insert a parent photo_asset so the FK constraint is satisfied
        let photoRepo = PhotoRepository(db: db)
        let asset = PhotoAsset.new(canonicalName: "test.jpg", role: .original,
                                   filePath: "/test.jpg", fileSize: 0)
        try await photoRepo.upsert(asset)

        let proxy = ProxyAsset(
            id: "test-id-1",
            photoId: asset.id,
            filePath: "/proxies/test.jpg",
            width: 1600,
            height: 1200,
            byteSize: 200000,
            thumbnailPath: nil,
            thumbnailByteSize: nil,
            createdAt: "2026-03-16T00:00:00Z"
        )
        try await proxyRepo.upsert(proxy)

        let fetched = try await proxyRepo.fetchByPhotoId(asset.id)
        #expect(fetched != nil)
        #expect(fetched?.thumbnailPath == nil, "thumbnailPath should be nil (PRX-10)")
    }

    @Test("ProxyAsset with thumbnailPath round-trips with path preserved")
    func testProxyAssetThumbnailPathPreserved() async throws {
        let db = try AppDatabase.makeInMemory()
        let proxyRepo = ProxyAssetRepository(db: db)

        let photoRepo = PhotoRepository(db: db)
        let asset = PhotoAsset.new(canonicalName: "test2.jpg", role: .original,
                                   filePath: "/test2.jpg", fileSize: 0)
        try await photoRepo.upsert(asset)

        let expectedPath = "/proxies/thumbs/test2.jpg"
        let proxy = ProxyAsset(
            id: "test-id-2",
            photoId: asset.id,
            filePath: "/proxies/test2.jpg",
            width: 1600,
            height: 1200,
            byteSize: 200000,
            thumbnailPath: expectedPath,
            thumbnailByteSize: nil,
            createdAt: "2026-03-16T00:00:00Z"
        )
        try await proxyRepo.upsert(proxy)

        let fetched = try await proxyRepo.fetchByPhotoId(asset.id)
        #expect(fetched?.thumbnailPath == expectedPath, "thumbnailPath should round-trip (PRX-10)")
    }

    @Test("ProxyAsset with thumbnailByteSize round-trips with size preserved")
    func testProxyAssetThumbnailByteSizePreserved() async throws {
        let db = try AppDatabase.makeInMemory()
        let proxyRepo = ProxyAssetRepository(db: db)

        let photoRepo = PhotoRepository(db: db)
        let asset = PhotoAsset.new(canonicalName: "test3.jpg", role: .original,
                                   filePath: "/test3.jpg", fileSize: 0)
        try await photoRepo.upsert(asset)

        let proxy = ProxyAsset(
            id: "test-id-3",
            photoId: asset.id,
            filePath: "/proxies/test3.jpg",
            width: 1600,
            height: 1200,
            byteSize: 200000,
            thumbnailPath: "/proxies/thumbs/test3.jpg",
            thumbnailByteSize: 18000,
            createdAt: "2026-03-16T00:00:00Z"
        )
        try await proxyRepo.upsert(proxy)

        let fetched = try await proxyRepo.fetchByPhotoId(asset.id)
        #expect(fetched?.thumbnailByteSize == 18000, "thumbnailByteSize should round-trip (PRX-10)")
    }

    // MARK: - PRX-10: Thumbnail directory separation

    @Test("thumbsDirectory is separate from proxiesDirectory")
    func testThumbnailDirectoryIsSeparateFromProxiesDirectory() throws {
        let proxiesDir = ProxyGenerationActor.proxiesDirectory()
        let thumbsDir = ProxyGenerationActor.thumbsDirectory()
        #expect(proxiesDir.path != thumbsDir.path,
                "Thumbnails must be in a separate subdirectory to prevent filename collisions")
        #expect(thumbsDir.path.hasSuffix("/thumbs"),
                "Thumbs directory must end with /thumbs")
    }

    @Test("PRX-10: thumbnail path in proxy asset after processing",
          .disabled("requires real image files — covered by manual verification during M8.5"))
    func testThumbnailPathInProxyAssetAfterProcessing() async throws {
        // Integration test: covered by manual verification with real proxied images
    }

    // MARK: - Helpers

    private func fixturesURL() -> URL {
        // Resolve Fixtures directory relative to this source file at compile time.
        // #filePath gives the absolute path of this test file on disk.
        let thisFile = URL(fileURLWithPath: #filePath)
        // .../HoehnPhotosOrganizerTests/ProxyGenerationTests.swift
        // -> .../HoehnPhotosOrganizer/Fixtures
        return thisFile
            .deletingLastPathComponent()           // HoehnPhotosOrganizerTests/
            .deletingLastPathComponent()           // project root
            .appendingPathComponent("HoehnPhotosOrganizer")
            .appendingPathComponent("Fixtures")
    }
}
