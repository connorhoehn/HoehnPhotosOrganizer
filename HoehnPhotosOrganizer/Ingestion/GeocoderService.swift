//
//  GeocoderService.swift
//  HoehnPhotosOrganizer
//
//  CLGeocoder async wrapper returning LocationInfo.
//  Throws if CLGeocoder returns an error; caller decides whether to swallow.
//

import Foundation
import CoreLocation

struct LocationInfo {
    var country: String
    var region: String
    var city: String
}

actor GeocoderService {
    private let geocoder = CLGeocoder()
    private var cache: [String: LocationInfo] = [:]

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> LocationInfo {
        let key = "\(latitude),\(longitude)"
        if let hit = cache[key] { return hit }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        let info: LocationInfo = try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let p = placemarks?.first
                continuation.resume(returning: LocationInfo(
                    country: p?.country ?? "",
                    region: p?.administrativeArea ?? "",
                    city: p?.locality ?? ""
                ))
            }
        }
        cache[key] = info
        return info
    }

    func seedCacheForTesting(latitude: Double, longitude: Double, info: LocationInfo) {
        cache["\(latitude),\(longitude)"] = info
    }
}
