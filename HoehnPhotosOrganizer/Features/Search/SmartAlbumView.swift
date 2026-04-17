import SwiftUI
import GRDB

// MARK: - SmartAlbumFilterBuilder

/// Assembles state variables into a SearchFilter struct and validates them.
struct SmartAlbumFilterBuilder {
    var sceneTypeFilter: String?
    var peopleFilter: String?      // "any", "withPeople", "withoutPeople"
    var dateFromFilter: Date?
    var dateToFilter: Date?
    var curationFilter: String?
    var printStatusFilter: String? // "any", "attempted", "notAttempted"
    var locationFilter: String?

    enum ValidationError: LocalizedError {
        case dateRangeInvalid
        var errorDescription: String? {
            switch self {
            case .dateRangeInvalid:
                return "From date must be on or before To date."
            }
        }
    }

    /// Build and validate a SearchFilter from current builder state.
    func build() throws -> SearchFilter {
        // Validate date range
        if let from = dateFromFilter, let to = dateToFilter, from > to {
            throw ValidationError.dateRangeInvalid
        }

        var filter = SearchFilter()

        // Scene type
        if let sceneType = sceneTypeFilter, !sceneType.isEmpty {
            filter.sceneType = sceneType
        }

        // People
        switch peopleFilter {
        case "withPeople":    filter.peopleDetected = true
        case "withoutPeople": filter.peopleDetected = false
        default: break
        }

        // Date range — extract year components
        let calendar = Calendar.current
        if let from = dateFromFilter {
            filter.yearFrom = calendar.component(.year, from: from)
        }
        if let to = dateToFilter {
            filter.yearTo = calendar.component(.year, from: to)
        }

        // Location
        if let loc = locationFilter, !loc.trimmingCharacters(in: .whitespaces).isEmpty {
            filter.location = loc.trimmingCharacters(in: .whitespaces)
        }

        // Curation
        if let curation = curationFilter, !curation.isEmpty {
            filter.curationState = curation
        }

        // Print status
        switch printStatusFilter {
        case "attempted":    filter.printAttempted = true
        case "notAttempted": filter.printAttempted = false
        default: break
        }

        return filter
    }
}

// MARK: - SmartAlbumView

/// SwiftUI view for creating and editing smart albums (SRCH-7).
///
/// Presents a two-page Navigation stack:
/// - Page 1: Name + description + "Add Filter" button
/// - Page 2: Filter builder with all supported filter types
///
/// On save, calls `LibraryViewModel.createSavedSearch(name:filters:)`.
struct SmartAlbumView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase

    let viewModel: LibraryViewModel

    // MARK: - State

    @State private var name: String = ""
    @State private var sceneTypeFilter: String = ""          // "" = all
    @State private var peopleFilter: String = "any"          // "any" | "withPeople" | "withoutPeople"
    @State private var dateFromFilter: Date? = nil
    @State private var dateToFilter: Date? = nil
    @State private var curationFilter: String = ""           // "" = any
    @State private var printStatusFilter: String = "any"     // "any" | "attempted" | "notAttempted"
    @State private var locationFilter: String = ""

    @State private var isSaving: Bool = false
    @State private var validationError: String? = nil
    @State private var showFilterPage: Bool = false

    // MARK: - Constants

    private let sceneTypeOptions: [(label: String, value: String)] = [
        ("All", ""),
        ("Landscape", "landscape"),
        ("Portrait", "portrait"),
        ("Architecture", "architecture"),
        ("Still Life", "stillLife"),
        ("Street", "street"),
        ("Documentary", "documentary")
    ]

    private let curationOptions: [(label: String, value: String)] = [
        ("Any", ""),
        ("Keeper", "keeper"),
        ("Archive", "archive"),
        ("Rejected", "rejected"),
        ("Needs Review", "needs_review")
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Page 1: Name + description
                Section("Smart Album Name") {
                    TextField("Name", text: $name)
                        .disableAutocorrection(true)
                }

                Section {
                    NavigationLink("Add Filters", isActive: $showFilterPage) {
                        filterBuilderPage
                    }
                } footer: {
                    if !activeFilterSummary.isEmpty {
                        Text(activeFilterSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = validationError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Smart Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 400)
    }

    // MARK: - Filter Builder Page

    @ViewBuilder
    private var filterBuilderPage: some View {
        Form {
            // Scene Type
            Section("Scene Type") {
                Picker("Scene Type", selection: $sceneTypeFilter) {
                    ForEach(sceneTypeOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }

            // People
            Section("People") {
                Picker("People", selection: $peopleFilter) {
                    Text("Any").tag("any")
                    Text("With People").tag("withPeople")
                    Text("Without People").tag("withoutPeople")
                }
                .pickerStyle(.segmented)
            }

            // Date Range
            Section("Date Range") {
                Toggle("Filter by Date", isOn: Binding(
                    get: { dateFromFilter != nil || dateToFilter != nil },
                    set: { enabled in
                        if enabled {
                            dateFromFilter = Calendar.current.date(byAdding: .year, value: -1, to: .now)
                            dateToFilter = .now
                        } else {
                            dateFromFilter = nil
                            dateToFilter = nil
                        }
                    }
                ))

                if dateFromFilter != nil || dateToFilter != nil {
                    DatePicker(
                        "From",
                        selection: Binding(
                            get: { dateFromFilter ?? Calendar.current.date(byAdding: .year, value: -1, to: .now)! },
                            set: { dateFromFilter = $0 }
                        ),
                        displayedComponents: .date
                    )
                    DatePicker(
                        "To",
                        selection: Binding(
                            get: { dateToFilter ?? .now },
                            set: { dateToFilter = $0 }
                        ),
                        displayedComponents: .date
                    )
                }
            }

            // Location
            Section("Location") {
                TextField("Location (e.g. England)", text: $locationFilter)
                    .disableAutocorrection(true)
            }

            // Curation
            Section("Curation State") {
                Picker("Curation", selection: $curationFilter) {
                    ForEach(curationOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }

            // Print Status
            Section("Print Status") {
                Picker("Print Status", selection: $printStatusFilter) {
                    Text("Any").tag("any")
                    Text("Print Attempted").tag("attempted")
                    Text("No Prints").tag("notAttempted")
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Add Filters")
    }

    // MARK: - Derived

    private var activeFilterSummary: String {
        var parts: [String] = []
        if !sceneTypeFilter.isEmpty { parts.append(sceneTypeFilter.capitalized) }
        if peopleFilter == "withPeople" { parts.append("With People") }
        if peopleFilter == "withoutPeople" { parts.append("Without People") }
        if dateFromFilter != nil || dateToFilter != nil { parts.append("Date Range") }
        if !locationFilter.isEmpty { parts.append("Location: \(locationFilter)") }
        if !curationFilter.isEmpty { parts.append(curationFilter.capitalized) }
        if printStatusFilter == "attempted" { parts.append("Print Attempted") }
        if printStatusFilter == "notAttempted" { parts.append("No Prints") }
        return parts.isEmpty ? "" : "Filters: \(parts.joined(separator: ", "))"
    }

    // MARK: - Save

    private func save() {
        validationError = nil

        let builder = SmartAlbumFilterBuilder(
            sceneTypeFilter: sceneTypeFilter.isEmpty ? nil : sceneTypeFilter,
            peopleFilter: peopleFilter,
            dateFromFilter: dateFromFilter,
            dateToFilter: dateToFilter,
            curationFilter: curationFilter.isEmpty ? nil : curationFilter,
            printStatusFilter: printStatusFilter,
            locationFilter: locationFilter.isEmpty ? nil : locationFilter
        )

        let filter: SearchFilter
        do {
            filter = try builder.build()
        } catch {
            validationError = error.localizedDescription
            return
        }

        isSaving = true
        let albumName = name.trimmingCharacters(in: .whitespaces)

        Task {
            await viewModel.createSavedSearch(name: albumName, filters: filter, db: appDatabase)
            isSaving = false
            dismiss()
        }
    }
}
