//
//  TimeOfDayTests.swift
//  HoehnPhotosOrganizerTests
//
//  Tests for TimeOfDayService deterministic solar elevation classifier.
//  All dates are in UTC. The formula uses UTC hour angles (no longitude correction),
//  so test inputs are chosen so UTC time == local solar time for lat=0° or are
//  adjusted to produce known solar elevation results.
//

import Testing
import Foundation
@testable import HoehnPhotosOrganizer

struct TimeOfDayTests {

    // Helper: create a UTC Date for a specific date/time
    private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    // MARK: - Golden Hour

    @Test func testGoldenHourMorning() {
        // June 21 at 05:00 UTC, latitude 40°N
        // Solar elevation at this time: approximately 1-5° (just after sunrise)
        // => classified as .goldenHour
        let date = utcDate(year: 2024, month: 6, day: 21, hour: 5, minute: 0)
        let result = TimeOfDayService.classify(captureDate: date, latitude: 40.0)
        #expect(result == .goldenHour, "June 21 05:00 UTC at lat 40° should be golden hour")
    }

    // MARK: - Blue Hour

    @Test func testBlueHourEvening() {
        // June 21 at 20:30 UTC, latitude 40°N
        // After sunset, solar elevation approximately -4 to -7° => .blueHour
        let date = utcDate(year: 2024, month: 6, day: 21, hour: 20, minute: 30)
        let result = TimeOfDayService.classify(captureDate: date, latitude: 40.0)
        #expect(result == .blueHour, "June 21 20:30 UTC at lat 40° should be blue hour")
    }

    // MARK: - Midday

    @Test func testMidday() {
        // June 21 at 12:00 UTC, latitude 0° (equator)
        // Solar elevation at solar noon on summer solstice near equator: ~66°
        // => classified as .midday
        let date = utcDate(year: 2024, month: 6, day: 21, hour: 12, minute: 0)
        let result = TimeOfDayService.classify(captureDate: date, latitude: 0.0)
        #expect(result == .midday, "June 21 12:00 UTC at equator should be midday")
    }

    // MARK: - Night

    @Test func testNight() {
        // June 21 at 02:00 UTC, latitude 40°N
        // Solar elevation at 2am UTC is deeply negative => .night
        let date = utcDate(year: 2024, month: 6, day: 21, hour: 2, minute: 0)
        let result = TimeOfDayService.classify(captureDate: date, latitude: 40.0)
        #expect(result == .night, "June 21 02:00 UTC at lat 40° should be night")
    }

}
