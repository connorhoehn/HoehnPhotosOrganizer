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

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> LocationInfo {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        return try await withCheckedThrowingContinuation { continuation in
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
    }
}
