import Foundation
import CoreLocation
import HoehnPhotosCore

// MARK: - PhotoAsset GPS extraction (iOS-only)

extension PhotoAsset {

    /// Parses `rawExifJson` for GPS coordinates and returns a valid `CLLocationCoordinate2D`.
    /// Accepts a handful of common EXIF key shapes, case-insensitive, and handles:
    ///   - numeric values (Double / Int / NSNumber)
    ///   - reference signs via `GPSLatitudeRef` / `GPSLongitudeRef` ("S" / "W" negate)
    ///   - nested GPS dictionary under keys like "{GPS}" or "GPS" (ImageIO convention)
    ///
    /// Returns nil if the JSON is missing, malformed, or the coordinate is invalid.
    var gpsCoordinate: CLLocationCoordinate2D? {
        guard let jsonString = rawExifJson, !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any]
        else { return nil }

        // Collect all candidate dictionaries to probe: the root, and any nested GPS dict.
        var candidates: [[String: Any]] = [root]
        for (k, v) in root {
            let lower = k.lowercased()
            if lower.contains("gps"), let nested = v as? [String: Any] {
                candidates.append(nested)
            }
        }

        for dict in candidates {
            if let coord = Self.coordinate(from: dict) {
                return coord
            }
        }
        return nil
    }

    // MARK: - Private helpers

    private static func coordinate(from dict: [String: Any]) -> CLLocationCoordinate2D? {
        // Build a lowercase-keyed lookup for case-insensitive access.
        var lower: [String: Any] = [:]
        for (k, v) in dict { lower[k.lowercased()] = v }

        let latKeys = ["gpslatitude", "latitude", "lat"]
        let lonKeys = ["gpslongitude", "longitude", "lon", "lng"]
        let latRefKeys = ["gpslatituderef", "latituderef", "latref"]
        let lonRefKeys = ["gpslongituderef", "longituderef", "lonref", "lngref"]

        guard var lat = firstDouble(lower, keys: latKeys),
              var lon = firstDouble(lower, keys: lonKeys)
        else { return nil }

        // Apply hemisphere refs when present.
        if let latRef = firstString(lower, keys: latRefKeys)?.uppercased(),
           latRef == "S" {
            lat = -abs(lat)
        }
        if let lonRef = firstString(lower, keys: lonRefKeys)?.uppercased(),
           lonRef == "W" {
            lon = -abs(lon)
        }

        // Basic sanity checks.
        guard lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
        if lat == 0 && lon == 0 { return nil }  // "Null Island" — treat as no geo.

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func firstDouble(_ dict: [String: Any], keys: [String]) -> Double? {
        for k in keys {
            if let n = dict[k] as? NSNumber { return n.doubleValue }
            if let d = dict[k] as? Double { return d }
            if let i = dict[k] as? Int { return Double(i) }
            if let s = dict[k] as? String, let parsed = Double(s) { return parsed }
        }
        return nil
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }
}
