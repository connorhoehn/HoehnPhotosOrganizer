import Foundation
import HoehnPhotosCore

// MARK: - PhotoAsset + camera helper (Phase 4)
//
// NOTE: `gpsCoordinate` lives in `PhotoAsset+GPS.swift` (owned by another
// agent). Keep this file narrowly scoped to the camera-model helper used by
// SimilarPhotoFinder.

extension PhotoAsset {
    /// EXIF camera make + model, joined, if available.
    /// Used for similarity grouping and any UI that wants a single camera
    /// label.
    var cameraMakeModel: String? {
        guard let json = rawExifJson,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func str(_ keys: [String]) -> String? {
            for key in keys {
                if let v = dict[key] as? String, !v.isEmpty { return v }
                if let n = dict[key] as? NSNumber { return n.stringValue }
            }
            return nil
        }

        let make = str(["Make", "cameraMake", "LensMake"])
        let model = str(["Model", "cameraModel"])
        switch (make, model) {
        case let (m?, md?): return "\(m) \(md)"
        case let (m?, nil): return m
        case let (nil, md?): return md
        default: return nil
        }
    }
}
