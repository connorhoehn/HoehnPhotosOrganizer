import Testing
import GRDB
@testable import HoehnPhotosOrganizer

@MainActor
struct ReviewModeViewModelTests {

    @Test
    func testAdvanceIncrementsIndex() async throws {
        // CUR-6: ReviewModeViewModel.advance() must increment currentIndex by 1
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let viewModel = ReviewModeViewModel(photoRepo: photoRepo)

        // Create 3 mock photos
        let photos = [
            PhotoAsset.new(canonicalName: "photo1.jpg", role: .original, filePath: "/tmp/1", fileSize: 100),
            PhotoAsset.new(canonicalName: "photo2.jpg", role: .original, filePath: "/tmp/2", fileSize: 100),
            PhotoAsset.new(canonicalName: "photo3.jpg", role: .original, filePath: "/tmp/3", fileSize: 100)
        ]

        viewModel.loadPhotos(photos)
        #expect(viewModel.currentIndex == 0)

        viewModel.advance()
        #expect(viewModel.currentIndex == 1)

        viewModel.advance()
        #expect(viewModel.currentIndex == 2)

        // At end, should not increment further
        viewModel.advance()
        #expect(viewModel.currentIndex == 2)
    }

    @Test
    func testRetreatDecrementsIndex() async throws {
        // CUR-6: ReviewModeViewModel.retreat() must decrease currentIndex by 1 (minimum 0)
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let viewModel = ReviewModeViewModel(photoRepo: photoRepo)

        // Create 3 mock photos
        let photos = [
            PhotoAsset.new(canonicalName: "photo1.jpg", role: .original, filePath: "/tmp/1", fileSize: 100),
            PhotoAsset.new(canonicalName: "photo2.jpg", role: .original, filePath: "/tmp/2", fileSize: 100),
            PhotoAsset.new(canonicalName: "photo3.jpg", role: .original, filePath: "/tmp/3", fileSize: 100)
        ]

        viewModel.loadPhotos(photos)
        viewModel.advance() // Move to index 1
        viewModel.advance() // Move to index 2
        #expect(viewModel.currentIndex == 2)

        viewModel.retreat()
        #expect(viewModel.currentIndex == 1)

        viewModel.retreat()
        #expect(viewModel.currentIndex == 0)

        // At start, should not decrement further
        viewModel.retreat()
        #expect(viewModel.currentIndex == 0)
    }
}
