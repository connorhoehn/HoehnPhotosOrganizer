import Foundation
import NaturalLanguage

// MARK: - DictationChunkingService

/// Parses user messages for structured metadata: people, dates/events, equipment, and locations.
/// Runs locally using NaturalLanguage framework and pattern matching — no network calls.
actor DictationChunkingService {

    // MARK: - Output

    struct ChunkedMetadata: Sendable {
        var people: [PersonMatch]
        var dates: [DateReference]
        var equipment: EquipmentMatch?
        var locations: [String]

        var isEmpty: Bool {
            people.isEmpty && dates.isEmpty && equipment == nil && locations.isEmpty
        }

        struct PersonMatch: Sendable {
            let name: String          // canonical name from DB
            let confidence: Double    // 0.0–1.0
        }

        struct DateReference: Sendable {
            let text: String          // original text span ("Christmas", "last July")
            let date: Date?           // resolved date, if deterministic
        }

        struct EquipmentMatch: Sendable {
            var cameraBody: String?
            var lens: String?
            var filmStock: String?
        }
    }

    // MARK: - Public API

    /// Extract structured metadata from a chat message.
    func chunk(
        text: String,
        knownPeople: [PersonIdentity]
    ) -> ChunkedMetadata {
        let people = extractPeople(from: text, knownPeople: knownPeople)
        let dates = extractDates(from: text)
        let equipment = extractEquipment(from: text)
        let locations = extractLocations(from: text)

        return ChunkedMetadata(
            people: people,
            dates: dates,
            equipment: equipment,
            locations: locations
        )
    }

    // MARK: - People Extraction

    /// Uses NLTagger for person names, then fuzzy-matches against known PersonIdentity records.
    private func extractPeople(
        from text: String,
        knownPeople: [PersonIdentity]
    ) -> [ChunkedMetadata.PersonMatch] {
        var candidateNames: [String] = []

        // Use NLTagger to find person name entities
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            if tag == .personalName {
                candidateNames.append(String(text[range]))
            }
            return true
        }

        guard !candidateNames.isEmpty, !knownPeople.isEmpty else { return [] }

        // Fuzzy-match candidates against known people using the existing resolver
        let (resolved, _) = PersonNameResolver.resolve(
            queryNames: candidateNames,
            knownPeople: knownPeople,
            threshold: 0.6
        )

        // Deduplicate by person ID
        var seen = Set<String>()
        return resolved.compactMap { r in
            guard !seen.contains(r.personId) else { return nil }
            seen.insert(r.personId)
            return ChunkedMetadata.PersonMatch(name: r.personName, confidence: r.confidence)
        }
    }

    // MARK: - Date / Event Extraction

    /// Uses NSDataDetector for dates plus pattern matching for common event names.
    private func extractDates(from text: String) -> [ChunkedMetadata.DateReference] {
        var results: [ChunkedMetadata.DateReference] = []

        // NSDataDetector for date references
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, options: [], range: nsRange)
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                let span = String(text[range])
                results.append(ChunkedMetadata.DateReference(text: span, date: match.date))
            }
        }

        // Pattern-match common event/occasion names
        let eventPatterns: [(pattern: String, label: String)] = [
            ("christmas", "Christmas"),
            ("thanksgiving", "Thanksgiving"),
            ("easter", "Easter"),
            ("halloween", "Halloween"),
            ("new year", "New Year"),
            ("birthday", "birthday"),
            ("wedding", "wedding"),
            ("graduation", "graduation"),
            ("anniversary", "anniversary"),
            ("baptism", "baptism"),
            ("first communion", "first communion"),
            ("baby shower", "baby shower"),
            ("family reunion", "family reunion"),
            ("vacation", "vacation"),
            ("holiday", "holiday"),
        ]

        let lower = text.lowercased()
        for (pattern, label) in eventPatterns {
            if lower.contains(pattern) {
                // Avoid duplicates if NSDataDetector already caught it
                let isDuplicate = results.contains { $0.text.lowercased().contains(pattern) }
                if !isDuplicate {
                    results.append(ChunkedMetadata.DateReference(text: label, date: nil))
                }
            }
        }

        // Age references like "3 months old", "2 years old"
        let agePattern = #"(\d+)\s+(month|year|week|day)s?\s+old"#
        if let regex = try? NSRegularExpression(pattern: agePattern, options: .caseInsensitive) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                let span = String(text[range])
                let isDuplicate = results.contains { $0.text.lowercased() == span.lowercased() }
                if !isDuplicate {
                    results.append(ChunkedMetadata.DateReference(text: span, date: nil))
                }
            }
        }

        return results
    }

    // MARK: - Equipment Extraction

    /// Matches camera bodies, lenses, and film stocks against known lists.
    private func extractEquipment(from text: String) -> ChunkedMetadata.EquipmentMatch? {
        let lower = text.lowercased()

        let cameraBody = Self.cameraBodies.first { lower.contains($0.lowercased()) }
        let lens = Self.lenses.first { lower.contains($0.lowercased()) }
        let filmStock = Self.filmStocks.first { lower.contains($0.lowercased()) }

        guard cameraBody != nil || lens != nil || filmStock != nil else { return nil }
        return ChunkedMetadata.EquipmentMatch(
            cameraBody: cameraBody,
            lens: lens,
            filmStock: filmStock
        )
    }

    // MARK: - Location Extraction

    /// Uses NLTagger to find place name entities.
    private func extractLocations(from text: String) -> [String] {
        var locations: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            if tag == .placeName {
                locations.append(String(text[range]))
            }
            return true
        }
        return locations
    }

    // MARK: - Equipment Reference Lists

    private static let cameraBodies: [String] = [
        // Medium format
        "Hasselblad 500C", "Hasselblad 500CM", "Hasselblad 503CW",
        "Mamiya RB67", "Mamiya RZ67", "Mamiya 645", "Mamiya 7",
        "Pentax 67", "Pentax 645",
        "Bronica SQ", "Bronica ETR",
        "Rolleiflex 2.8F", "Rolleiflex 3.5F",
        "Fuji GW690", "Fuji GA645",
        // 35mm SLR
        "Nikon F3", "Nikon F4", "Nikon F5", "Nikon F100", "Nikon FM2", "Nikon FE2",
        "Canon AE-1", "Canon A-1", "Canon F-1", "Canon EOS 1V",
        "Minolta X-700", "Minolta SRT",
        "Pentax K1000", "Pentax MX",
        "Olympus OM-1", "Olympus OM-2",
        "Leica M6", "Leica M3", "Leica M4", "Leica M7", "Leica MP",
        "Contax G2", "Contax T2", "Contax T3",
        // 35mm Rangefinder / P&S
        "Yashica T4", "Olympus Stylus Epic",
        // Large format
        "Crown Graphic", "Speed Graphic", "Sinar P", "Toyo 45A",
        // Digital (common)
        "Nikon D850", "Nikon D810", "Nikon Z8", "Nikon Z9",
        "Canon R5", "Canon R6", "Canon 5D Mark IV",
        "Sony A7R V", "Sony A7 IV", "Sony A1",
        "Fuji X-T5", "Fuji X-H2", "Fuji GFX 100S",
        "Phase One IQ4",
    ]

    private static let lenses: [String] = [
        // Hasselblad
        "Planar 80mm", "Sonnar 150mm", "Distagon 50mm",
        // Nikon
        "Nikkor 50mm f/1.4", "Nikkor 85mm f/1.4", "Nikkor 105mm f/2.5",
        "Nikkor 35mm f/1.4", "Nikkor 24-70mm", "Nikkor 70-200mm",
        // Canon
        "EF 50mm f/1.2", "EF 85mm f/1.2", "RF 50mm f/1.2",
        // Generic focal lengths (broad catch)
        "50mm f/1.4", "85mm f/1.8", "35mm f/2", "105mm f/2.5",
        "24-70mm f/2.8", "70-200mm f/2.8",
    ]

    private static let filmStocks: [String] = [
        // Color negative
        "Portra 160", "Portra 400", "Portra 800",
        "Ektar 100",
        "Gold 200", "Ultramax 400", "ColorPlus 200",
        "Fuji Pro 400H", "Fuji Superia",
        "CineStill 800T", "CineStill 50D",
        // Color reversal
        "Velvia 50", "Velvia 100",
        "Provia 100F",
        "Ektachrome E100",
        // Black & white
        "Tri-X 400", "Tri-X",
        "HP5 Plus", "HP5",
        "T-Max 100", "T-Max 400",
        "Delta 100", "Delta 400", "Delta 3200",
        "FP4 Plus", "FP4",
        "Pan F Plus", "Pan F",
        "Acros 100", "Acros II",
        "Fomapan 100", "Fomapan 400",
        "Bergger Pancro 400",
        "JCH StreetPan 400",
        // Instant
        "Instax Mini", "Instax Wide",
        "Polaroid 600", "Polaroid SX-70",
    ]
}
