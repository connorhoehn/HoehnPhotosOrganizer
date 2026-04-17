//
//  TimeOfDayService.swift
//  HoehnPhotosOrganizer
//
//  Deterministic solar elevation classifier returning TimeOfDay enum.
//  No network required. Uses Julian date + solar declination formula.
//

import Foundation

enum TimeOfDay: String {
    case goldenHour = "golden_hour"
    case blueHour   = "blue_hour"
    case midday
    case night
    case unknown
}

enum TimeOfDayService {
    /// Classify time-of-day from capture date and GPS latitude using a deterministic solar elevation formula.
    /// No network required.
    nonisolated static func classify(captureDate: Date, latitude: Double) -> TimeOfDay {
        let elevation = solarElevationDegrees(date: captureDate, latitude: latitude)
        switch elevation {
        case let e where e > 45:   return .midday
        case let e where e > 6:    return .midday      // bright daylight — same bucket
        case let e where e > -4:   return .goldenHour
        case let e where e > -12:  return .blueHour
        default:                   return .night
        }
    }

    // MARK: - Solar elevation (degrees above horizon)
    nonisolated private static func solarElevationDegrees(date: Date, latitude: Double) -> Double {
        let cal = Calendar(identifier: .gregorian)
        var utcCal = cal
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let comps = utcCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day,
              let hour = comps.hour, let minute = comps.minute, let second = comps.second
        else { return 0 }

        // Julian date
        let A = (14 - month) / 12
        let Y = year + 4800 - A
        let M = month + 12 * A - 3
        let jdn = day + (153 * M + 2) / 5 + 365 * Y + Y / 4 - Y / 100 + Y / 400 - 32045
        let jd = Double(jdn) + (Double(hour) - 12.0) / 24.0 + Double(minute) / 1440.0 + Double(second) / 86400.0

        // Solar mean anomaly
        let n = jd - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)
        let lambda = L + 1.915 * sin(g * .pi / 180) + 0.020 * sin(2 * g * .pi / 180)

        // Obliquity and declination
        let epsilon = 23.439 - 0.0000004 * n
        let sinDec = sin(epsilon * .pi / 180) * sin(lambda * .pi / 180)
        let dec = asin(sinDec) * 180 / .pi

        // Hour angle (UTC — approximate; good enough for time-of-day classification)
        let utcHour = Double(hour) + Double(minute) / 60.0 + Double(second) / 3600.0
        let ha = (utcHour - 12.0) * 15.0  // degrees

        // Solar elevation
        let latR  = latitude * .pi / 180
        let decR  = dec * .pi / 180
        let haR   = ha * .pi / 180
        let elevation = asin(sin(latR) * sin(decR) + cos(latR) * cos(decR) * cos(haR))
        return elevation * 180 / .pi
    }
}
