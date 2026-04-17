import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import Vision

// MARK: - FaceChipGrid

/// Detects faces in a photo's proxy image on-demand and displays cropped
/// circular thumbnails. Tapping any chip calls `onSearchFaces` to navigate
/// to the Search page filtered by `peopleDetected = true`.
struct FaceChipGrid: View {

    let photo: PhotoAsset
    let db: AppDatabase?
    /// Called when the user taps a specific face chip. Arguments: 0-based face index + the cropped NSImage.
    let onSearchByFace: (Int, NSImage) -> Void

    @State private var faceImages: [NSImage] = []
    @State private var faceNames: [Int: String] = [:]  // faceIndex → person name
    @State private var isDetecting = false
    @State private var detectionDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isDetecting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Detecting faces…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if detectionDone && faceImages.isEmpty {
                Text("No faces detected in this photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !faceImages.isEmpty {
                Text("\(faceImages.count) face\(faceImages.count == 1 ? "" : "s") detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(faceImages.enumerated()), id: \.offset) { index, img in
                            Button {
                                onSearchByFace(index, img)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(Circle())
                                        .overlay(
                                            Circle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                                        )
                                    Text(faceNames[index] ?? "Find")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(faceNames[index] != nil ? .primary : .secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(faceNames[index].map { "Find all photos of \($0)" } ?? "Find all photos with this person")
                        }
                    }
                }
            }
        }
        .task(id: photo.id) {
            await runDetection()
        }
    }

    // MARK: - Detection

    private func runDetection() async {
        guard !isDetecting else { return }
        isDetecting = true
        faceImages = []

        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")

        guard FileManager.default.fileExists(atPath: proxyURL.path) else {
            isDetecting = false
            detectionDone = true
            return
        }

        let images = await Task.detached(priority: .userInitiated) {
            Self.detectAndCrop(from: proxyURL)
        }.value

        faceImages = images
        isDetecting = false
        detectionDone = true

        // Look up person names for each detected face
        await loadFaceNames()
    }

    private func loadFaceNames() async {
        guard let db else { return }
        do {
            let faceRepo = FaceEmbeddingRepository(db: db)
            let embeddings = try await faceRepo.fetchByPhotoId(photo.id)
            let personRepo = PersonRepository(db: db)
            let people = try await personRepo.fetchAll()
            let personMap = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })

            var names: [Int: String] = [:]
            for emb in embeddings {
                if let personId = emb.personId, let name = personMap[personId] {
                    names[emb.faceIndex] = name
                }
            }
            faceNames = names
        } catch {
            print("[FaceChipGrid] Failed to load person names: \(error)")
        }
    }

    // MARK: - Static helpers

    /// Returns cropped face images only (for display use).
    static func detectAndCrop(from url: URL) -> [NSImage] {
        detectAndCropWithBounds(from: url).map(\.0)
    }

    /// Returns cropped face images paired with their normalized Vision bounding boxes (origin bottom-left, 0–1).
    /// Use this when you need to persist bbox coordinates alongside the image.
    static func detectAndCropWithBounds(from url: URL) -> [(NSImage, CGRect)] {
        guard let cgImage = loadCGImage(from: url) else { return [] }

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])

        do {
            try handler.perform([request])
        } catch {
            print("[FaceChipGrid] Vision request failed: \(error.localizedDescription)")
            return []
        }

        let observations = request.results ?? []
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        return observations.compactMap { obs in
            // Vision bbox is normalized with origin at bottom-left.
            let faceBounds = VNImageRectForNormalizedRect(obs.boundingBox, cgImage.width, cgImage.height)

            // Flip Y to match CGImage's top-left origin.
            let flippedY = imgH - faceBounds.maxY

            // Add 30% padding so we capture hair/chin rather than just the face oval.
            let padX = faceBounds.width * 0.30
            let padY = faceBounds.height * 0.30
            let padded = CGRect(
                x: faceBounds.minX - padX,
                y: flippedY - padY,
                width: faceBounds.width + padX * 2,
                height: faceBounds.height + padY * 2
            ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

            guard padded.width > 0, padded.height > 0,
                  let cropped = cgImage.cropping(to: padded) else { return nil }

            let image = NSImage(cgImage: cropped, size: NSSize(width: padded.width, height: padded.height))
            return (image, obs.boundingBox)
        }
    }

    private static func loadCGImage(from url: URL) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
