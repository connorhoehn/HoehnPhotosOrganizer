import Foundation
import CoreGraphics
import ImageIO
import GRDB

// MARK: - DriveWorkflowRunner

/// Actor that runs selected analysis workflows on a batch of `DrivePhotoRecord`s.
/// Works against the pre-generated 300px thumbnail JPEGs so no RAW decoding is needed.
/// Film-strip detection falls back to the full original image when available.
actor DriveWorkflowRunner {

    private(set) var isRunning:       Bool   = false
    private(set) var progress:        Double = 0
    private(set) var currentFilename: String = ""
    private(set) var processedCount:  Int    = 0
    private(set) var totalCount:      Int    = 0

    // Services — lazy so the actors are only created when first workflow runs
    private lazy var orientationService = OrientationClassificationService()
    private lazy var sceneService       = SceneClassificationService()
    private lazy var personService      = PersonDetectionService()

    // MARK: - Public API

    func run(
        photos: [DrivePhotoRecord],
        workflows: Set<DriveWorkflow>,
        mountPoint: URL,
        database: DrivePreviewDatabase,
        cancelToken: DriveScanCancellationToken
    ) async {
        guard !isRunning, !photos.isEmpty, !workflows.isEmpty else { return }
        isRunning      = true
        progress       = 0
        processedCount = 0
        totalCount     = photos.count
        currentFilename = ""

        for photo in photos {
            guard !cancelToken.isCancelled else { break }  // nonisolated property on @unchecked Sendable
            currentFilename = photo.filename

            // Only process photos that have a thumbnail; thumbnailless records have no proxy
            guard let thumbPath = photo.thumbnailPath else {
                processedCount += 1
                progress = Double(processedCount) / Double(totalCount)
                continue
            }
            let thumbURL = URL(fileURLWithPath: thumbPath)

            var updated  = photo
            var ran      = updated.completedWorkflows   // preserve already-run workflows

            if workflows.contains(.orientation) {
                let result = await orientationService.classify(proxyURL: thumbURL)
                updated.orientationDegrees = result.rotationDegrees
                ran.insert(DriveWorkflow.orientation.rawValue)
            }

            if workflows.contains(.scene) {
                if let sceneType = try? await sceneService.classifyScene(proxyImageURL: thumbURL) {
                    updated.sceneLabel = sceneType.rawValue
                }
                ran.insert(DriveWorkflow.scene.rawValue)
            }

            if workflows.contains(.faces) {
                if let result = try? await personService.detectPeople(proxyImageURL: thumbURL) {
                    updated.faceCount = result.detectedFaceCount
                }
                ran.insert(DriveWorkflow.faces.rawValue)
            }

            if workflows.contains(.filmStrip) {
                // Prefer original file for film-strip detection (more reliable than a 300px thumb)
                // but fall back to thumbnail if the drive isn't accessible.
                let origURL = photo.absoluteURL(mountPoint: mountPoint)
                let detectURL = FileManager.default.fileExists(atPath: origURL.path)
                    ? origURL : thumbURL
                let (frameCount, rectsJSON) = await detectFilmFrames(at: detectURL)
                updated.filmFrameCount = frameCount
                updated.filmFrameRectsJSON = rectsJSON
                ran.insert(DriveWorkflow.filmStrip.rawValue)
            }

            updated.workflowsRun = ran.sorted().joined(separator: ",")
            let snapshot = updated
            try? await database.dbPool.write { db in try snapshot.upsert(db) }

            processedCount += 1
            progress = Double(processedCount) / Double(totalCount)
        }

        currentFilename = ""
        isRunning = false
        progress  = 1.0
    }

    // MARK: - Film strip detection

    private nonisolated func detectFilmFrames(at url: URL) async -> (count: Int, rectsJSON: String?) {
        // Check model availability off the main actor via the nonisolated bundle check
        let modelAvailable =
            Bundle.main.url(forResource: YOLOFrameDetector.modelName, withExtension: "mlmodelc") != nil ||
            Bundle.main.url(forResource: YOLOFrameDetector.modelName, withExtension: "mlpackage") != nil
        guard modelAvailable,
              let src     = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return (0, nil) }
        let rects = (try? await YOLOFrameDetector().detectFrames(in: cgImage)) ?? []
        let json = Self.encodeRectsJSON(rects)
        return (rects.count, json)
    }

    /// Encodes an array of CGRect as a JSON string: [[x,y,w,h], ...]
    private nonisolated static func encodeRectsJSON(_ rects: [CGRect]) -> String? {
        guard !rects.isEmpty else { return nil }
        let arrays = rects.map { r in [r.origin.x, r.origin.y, r.size.width, r.size.height] }
        guard let data = try? JSONSerialization.data(withJSONObject: arrays),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Decodes a JSON string produced by `encodeRectsJSON` back to [CGRect].
    nonisolated static func decodeRectsJSON(_ json: String) -> [CGRect] {
        guard let data = json.data(using: .utf8),
              let arrays = try? JSONSerialization.jsonObject(with: data) as? [[Double]],
              !arrays.isEmpty else { return [] }
        return arrays.compactMap { a -> CGRect? in
            guard a.count == 4 else { return nil }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
    }
}
