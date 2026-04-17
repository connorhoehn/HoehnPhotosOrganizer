import CoreGraphics
import Foundation
import ImageIO
import Vision

// MARK: - FaceEmbeddingService

/// Generates per-face feature vectors using VNGenerateImageFeaturePrintRequest and
/// compares them using Apple's calibrated computeDistance metric.
///
/// Stores the full VNFeaturePrintObservation as NSKeyedArchiver Data so that
/// computeDistance(_:to:) can be used — Apple's metric is far more discriminative
/// than raw cosine similarity on face crops.
///
/// Empirical thresholds for face crops (smaller = more similar):
///   same person:      distance ≈ 0.0 – 0.35
///   different people: distance ≈ 0.55 – 1.5
struct FaceEmbeddingService: Sendable {

    /// Maximum distance considered "same person".
    /// Reads from UserDefaults key "face.distanceThreshold" so it can be tuned live
    /// via the Settings slider without rebuilding. Defaults to 0.65.
    ///   same person:      ≈ 0.0 – 0.45
    ///   borderline:       ≈ 0.45 – 0.65
    ///   different people: ≈ 0.65 – 1.5
    static var distanceThreshold: Float {
        let stored = Float(UserDefaults.standard.double(forKey: "face.distanceThreshold"))
        return stored > 0.1 ? stored : 0.65
    }

    // MARK: - Feature print generation

    /// Runs VNGenerateImageFeaturePrintRequest on a face crop and returns the
    /// archived VNFeaturePrintObservation as Data for DB storage.
    static func generateFeaturePrint(for faceImage: CGImage) -> Data? {
        let handler = VNImageRequestHandler(cgImage: faceImage, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill

        do {
            try handler.perform([request])
        } catch {
            print("[FaceEmbeddingService] Feature print request failed: \(error.localizedDescription)")
            return nil
        }

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            return nil
        }

        return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    // MARK: - Similarity

    /// Returns true if two archived VNFeaturePrintObservations are close enough to be the same person.
    static func isSamePerson(_ a: Data, _ b: Data) -> Bool {
        distance(a, b).map { $0 <= distanceThreshold } ?? false
    }

    /// Returns the Apple-calibrated distance between two archived observations.
    /// Returns nil if either observation can't be deserialized.
    static func distance(_ a: Data, _ b: Data) -> Float? {
        guard let obsA = deserialize(a), let obsB = deserialize(b) else { return nil }
        var dist: Float = 0
        guard (try? obsA.computeDistance(&dist, to: obsB)) != nil else { return nil }
        return dist
    }

    // MARK: - Crop helper

    /// Crops a face bounding box from a CGImage.
    /// `bbox` is in Vision normalized space (origin bottom-left).
    static func cropFace(from cgImage: CGImage, bbox: CGRect) -> CGImage? {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        let pixelRect = VNImageRectForNormalizedRect(bbox, cgImage.width, cgImage.height)
        let flippedY = imgH - pixelRect.maxY
        let padX = pixelRect.width * 0.25
        let padY = pixelRect.height * 0.25
        let padded = CGRect(
            x: pixelRect.minX - padX,
            y: flippedY - padY,
            width: pixelRect.width + padX * 2,
            height: pixelRect.height + padY * 2
        ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard padded.width > 0, padded.height > 0 else { return nil }
        return cgImage.cropping(to: padded)
    }

    // MARK: - Image loading

    static func loadCGImage(from url: URL) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Private

    private static func deserialize(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }
}
