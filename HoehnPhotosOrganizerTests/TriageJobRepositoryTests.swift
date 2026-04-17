import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class TriageJobRepositoryTests: XCTestCase {
    var db: AppDatabase!
    var repo: TriageJobRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = TriageJobRepository(db: db)
    }

    func testInsertAndFetchById() async throws {
        let job = TriageJob.newImportJob(title: "Test Import", photoCount: 5)
        try await repo.insert(job)
        let fetched = try await repo.fetchById(job.id)
        XCTAssertEqual(fetched?.id, job.id)
        XCTAssertEqual(fetched?.title, "Test Import")
    }

    func testFetchRootJobsExcludesChildren() async throws {
        let root = TriageJob.newImportJob(title: "Root", photoCount: 0)
        try await repo.insert(root)
        let child = TriageJob.newChildJob(parentId: root.id, title: "Child", photoCount: 0)
        try await repo.insert(child)
        let roots = try await repo.fetchRootJobs()
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots.first?.id, root.id)
    }

    func testFetchChildJobs() async throws {
        let parent = TriageJob.newImportJob(title: "Parent", photoCount: 0)
        try await repo.insert(parent)
        let c1 = TriageJob.newChildJob(parentId: parent.id, title: "C1", photoCount: 0)
        let c2 = TriageJob.newChildJob(parentId: parent.id, title: "C2", photoCount: 0)
        try await repo.insert(c1)
        try await repo.insert(c2)
        let children = try await repo.fetchChildJobs(parentId: parent.id)
        XCTAssertEqual(children.count, 2)
    }

    func testCreateImportJobLinksPhotos() async throws {
        let photoRepo = PhotoRepository(db: db)
        let photo = PhotoAsset.new(
            canonicalName: "img001.ARW",
            role: .original,
            filePath: "/tmp/img001.ARW",
            fileSize: 1000
        )
        try await photoRepo.upsert(photo)
        let job = try await repo.createImportJob(title: "Batch 1", photoIds: [photo.id])
        XCTAssertEqual(job.photoCount, 1)
        let photos = try await repo.fetchPhotos(jobId: job.id)
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.id, photo.id)
    }

    func testMarkCompleteAndReopen() async throws {
        let job = TriageJob.newImportJob(title: "Status Test", photoCount: 0)
        try await repo.insert(job)
        try await repo.markComplete(jobId: job.id)
        let completed = try await repo.fetchById(job.id)
        XCTAssertEqual(completed?.status, .complete)
        try await repo.reopen(jobId: job.id)
        let reopened = try await repo.fetchById(job.id)
        XCTAssertEqual(reopened?.status, .open)
    }

    func testUpdateCompleteness() async throws {
        let job = TriageJob.newImportJob(title: "Score Test", photoCount: 0)
        try await repo.insert(job)
        try await repo.updateCompleteness(jobId: job.id, score: 0.75)
        let fetched = try await repo.fetchById(job.id)
        XCTAssertEqual(fetched?.completenessScore, 0.75)
    }
}
