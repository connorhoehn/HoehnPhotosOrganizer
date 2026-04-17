//
//  EXIFExtractor.swift
//  HoehnPhotosOrganizer
//
//  ImageIO-based EXIF extraction returning EXIFSnapshot.
//  extract(url:) never throws — returns empty snapshot on any failure.
//

import Foundation
import ImageIO

struct EXIFSnapshot {
    var captureDate: Date?
    var latitude: Double?
    var longitude: Double?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var shutterSpeed: Double?     // in seconds
    var focalLength: Double?      // in mm
}

// MARK: - EXIFSnapshot Codable bridge

extension EXIFSnapshot {
    struct CodableSnapshot: Codable {
        var captureDate: String?
        var latitude: Double?
        var longitude: Double?
        var cameraMake: String?
        var cameraModel: String?
        var lens: String?
        var iso: Int?
        var aperture: Double?
        var shutterSpeed: Double?
        var focalLength: Double?
    }

    nonisolated func asCodable() -> CodableSnapshot {
        let fmt = ISO8601DateFormatter()
        return CodableSnapshot(
            captureDate: captureDate.map { fmt.string(from: $0) },
            latitude: latitude,
            longitude: longitude,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            lens: lens,
            iso: iso,
            aperture: aperture,
            shutterSpeed: shutterSpeed,
            focalLength: focalLength
        )
    }
}

// MARK: - EXIFExtractor

enum EXIFExtractor {
    nonisolated static func extract(url: URL) -> EXIFSnapshot {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return EXIFSnapshot() }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps  = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        var snapshot = EXIFSnapshot()

        // Capture date
        if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
            snapshot.captureDate = fmt.date(from: dateStr)
        }

        // GPS
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String {
            snapshot.latitude = latRef == "S" ? -lat : lat
        }
        if let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
            snapshot.longitude = lonRef == "W" ? -lon : lon
        }

        // Camera
        snapshot.cameraMake  = tiff[kCGImagePropertyTIFFMake] as? String
        snapshot.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        snapshot.lens = exif[kCGImagePropertyExifLensModel] as? String

        // Exposure
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
            snapshot.iso = isos.first
        }
        snapshot.aperture     = exif[kCGImagePropertyExifFNumber] as? Double
        snapshot.shutterSpeed = exif[kCGImagePropertyExifExposureTime] as? Double
        snapshot.focalLength  = exif[kCGImagePropertyExifFocalLength] as? Double

        return snapshot
    }
}
