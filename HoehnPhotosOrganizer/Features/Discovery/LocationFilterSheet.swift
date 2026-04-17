import SwiftUI
import MapKit

// MARK: - LocationFilterSheet

/// A sheet that lets the user choose a map region to use as a search filter.
///
/// The sheet shows a mini-map preview of the current viewModel region, displays
/// the bounds (lat/lon extents), and a photo count for the selected area.
/// "Apply Filter" commits the region and dismisses; "Clear Filter" removes any
/// active region filter.
struct LocationFilterSheet: View {

    @ObservedObject var viewModel: MapPhotoViewModel

    /// Called when the user confirms a region. Passed back to the parent MapPhotoView.
    let onApply: (MKCoordinateRegion) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: State

    /// The region being previewed inside the sheet.
    /// Defaults to the viewModel's current selectedRegion, or the world if none.
    @State private var previewRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
    )

    @State private var hasSetInitialRegion = false

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Filter by Location")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Mini-map for region adjustment
            Map(initialPosition: MapCameraPosition.region(previewRegion)) {
                // Show annotations inside the current preview region
                ForEach(viewModel.photoAnnotations.filter { annotation in
                    viewModel.isAnnotationVisible(annotation, in: previewRegion)
                }) { annotation in
                    Annotation(annotation.displayName, coordinate: annotation.coordinate, anchor: .bottom) {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                            .padding(4)
                            .background(Circle().fill(Color.blue.opacity(0.15)))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard)
            .onMapCameraChange { context in
                previewRegion = context.region
            }
            .frame(height: 240)
            .cornerRadius(8)
            .padding(16)

            // Region bounds display
            regionBoundsView

            Divider()
                .padding(.horizontal, 16)

            // Photo count
            photoCountView

            Divider()
                .padding(.horizontal, 16)

            // Action buttons
            actionButtons
                .padding(16)
        }
        .frame(minWidth: 400, maxWidth: 520)
        .onAppear {
            if !hasSetInitialRegion {
                if let existing = viewModel.selectedRegion {
                    previewRegion = existing
                } else if !viewModel.photoAnnotations.isEmpty {
                    // Default to a region that encompasses all geotagged photos
                    previewRegion = regionEnclosingAnnotations(viewModel.photoAnnotations)
                }
                hasSetInitialRegion = true
            }
        }
    }

    // MARK: Region bounds

    private var regionBoundsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected Region")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                HStack(spacing: 16) {
                    Label("North", systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.4f°", previewRegion.center.latitude + previewRegion.span.latitudeDelta / 2))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Label("East", systemImage: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.4f°", previewRegion.center.longitude + previewRegion.span.longitudeDelta / 2))
                        .font(.caption.monospacedDigit())
                }
                HStack(spacing: 16) {
                    Label("South", systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.4f°", previewRegion.center.latitude - previewRegion.span.latitudeDelta / 2))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Label("West", systemImage: "arrow.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.4f°", previewRegion.center.longitude - previewRegion.span.longitudeDelta / 2))
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Photo count

    private var photoCountView: some View {
        let count = viewModel.photoAnnotations.filter { annotation in
            viewModel.isAnnotationVisible(annotation, in: previewRegion)
        }.count
        return HStack {
            Image(systemName: "photo.stack")
                .foregroundStyle(.blue)
            Text("\(count) photo\(count == 1 ? "" : "s") in this region")
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Action buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if viewModel.selectedRegion != nil {
                Button("Clear Filter") {
                    viewModel.clearRegionFilter()
                    onApply(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                        span: MKCoordinateSpan(latitudeDelta: 180, longitudeDelta: 360)
                    ))
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)

            Button("Apply Filter") {
                viewModel.selectRegion(previewRegion)
                onApply(previewRegion)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Helpers

    /// Compute the smallest MKCoordinateRegion that contains all annotations.
    private func regionEnclosingAnnotations(_ annotations: [PhotoAnnotation]) -> MKCoordinateRegion {
        guard !annotations.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
            )
        }
        let lats = annotations.map { $0.coordinate.latitude }
        let lons = annotations.map { $0.coordinate.longitude }
        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLon = lons.min()!
        let maxLon = lons.max()!
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta:  max((maxLat - minLat) * 1.3, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.3, 0.01)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
