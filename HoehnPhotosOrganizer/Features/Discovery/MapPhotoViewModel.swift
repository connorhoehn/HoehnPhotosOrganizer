import Combine
import Foundation
import MapKit
import SwiftUI

// MARK: - PhotoAnnotation

/// A single annotatable point on the map, derived from a PhotoAsset with GPS data.
struct PhotoAnnotation: Identifiable, Equatable, Hashable {
    let id: String              // PhotoAsset.id
    let displayName: String     // canonical file name
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: PhotoAnnotation, rhs: PhotoAnnotation) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - MapPhotoViewModel

/// ViewModel that loads geotagged photos from the repository and manages
/// map position, annotation selection, and region-based filtering state.
///
/// All state mutations run on the MainActor. GPS coordinate extraction
/// parses the raw_exif_json JSON blob stored by IngestionActor.
@MainActor
final class MapPhotoViewModel: ObservableObject {

    // MARK: Published state

    /// All annotations currently displayed on the map (photos with valid GPS).
    @Published var photoAnnotations: [PhotoAnnotation] = []

    /// Annotations visible within the current map region (subset of photoAnnotations).
    @Published var visibleAnnotations: [PhotoAnnotation] = []

    /// The currently selected annotation (from a tap).
    @Published var selectedAnnotation: PhotoAnnotation?

    /// The map camera position — `.automatic` centers on all annotations initially.
    @Published var mapPosition: MapCameraPosition = .automatic

    /// The region chosen by the user to filter the photo grid.
    /// Non-nil means the grid should show only photos in this region.
    @Published var selectedRegion: MKCoordinateRegion?

    /// Whether the LocationFilterSheet is showing.
    @Published var isShowingFilterSheet: Bool = false

    /// Whether an async load is in progress.
    @Published var isLoading: Bool = false

    /// Non-nil when the latest load attempt failed.
    @Published var loadError: String?

    // MARK: Polygon drawing state

    /// True while the user is actively dragging a lasso on the map.
    @Published var isDrawingPolygon: Bool = false

    /// Vertices accumulated so far during a lasso drag.
    @Published var polygonVertices: [CLLocationCoordinate2D] = []

    /// Live cursor position during drag — used to preview the closing edge.
    @Published var livePoint: CLLocationCoordinate2D? = nil

    /// The closed polygon currently used as a filter. Non-nil after the user releases a lasso.
    @Published var activePolygon: [CLLocationCoordinate2D]? = nil

    // MARK: Private

    private let photoRepo: PhotoRepository

    // MARK: Filtered photos

    /// Annotations inside the selected region and/or active polygon, or all annotations when neither is active.
    var filteredAnnotations: [PhotoAnnotation] {
        var result = photoAnnotations
        if let region = selectedRegion {
            result = result.filter { isCoordinate($0.coordinate, inRegion: region) }
        }
        if let polygon = activePolygon {
            result = result.filter { isCoordinate($0.coordinate, insidePolygon: polygon) }
        }
        return result
    }

    // MARK: Init

    init(photoRepo: PhotoRepository) {
        self.photoRepo = photoRepo
    }

    // MARK: Data loading

    /// Fetch all photos from the repo that have GPS coordinates.
    func loadPhotos() async {
        isLoading = true
        loadError = nil
        do {
            let allPhotos = try await photoRepo.fetchAll()
            applyAnnotations(from: allPhotos)
        } catch {
            loadError = "Failed to load photos: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Use a preloaded array of photos instead of fetching from the repo.
    /// Used by the search map to show only results, not the whole library.
    func loadPhotos(from photos: [PhotoAsset]) {
        applyAnnotations(from: photos)
    }

    private func applyAnnotations(from photos: [PhotoAsset]) {
        let annotations = photos.compactMap { photo -> PhotoAnnotation? in
            guard let coordinate = extractCoordinate(from: photo) else { return nil }
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return PhotoAnnotation(
                id: photo.id,
                displayName: photo.canonicalName,
                coordinate: coordinate
            )
        }
        photoAnnotations = annotations
        visibleAnnotations = annotations
        mapPosition = annotations.isEmpty ? .automatic : .automatic
    }

    // MARK: Region selection

    /// Set the selected region and close the sheet.
    /// Callers (e.g. LocationFilterSheet) pass the region to apply as a grid filter.
    func selectRegion(_ region: MKCoordinateRegion) {
        selectedRegion = region
        isShowingFilterSheet = false
    }

    /// Clear the active region filter and show all photos.
    func clearRegionFilter() {
        selectedRegion = nil
    }

    /// Update the list of visible annotations whenever the map camera changes.
    func updateVisiblePhotos(for region: MKCoordinateRegion) {
        visibleAnnotations = photoAnnotations.filter { annotation in
            isCoordinate(annotation.coordinate, inRegion: region)
        }
    }

    /// Derive a 5 km bounding region centred on the tapped annotation.
    /// Called when user taps an annotation and chooses "Filter to region".
    func regionForAnnotation(_ annotation: PhotoAnnotation) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: annotation.coordinate,
            latitudinalMeters: 5_000,
            longitudinalMeters: 5_000
        )
    }

    // MARK: Polygon drawing (freehand lasso)

    func startPolygonDraw() {
        polygonVertices = []
        livePoint = nil
        activePolygon = nil
        isDrawingPolygon = true
    }

    /// Called on every DragGesture.onChanged — appends a vertex when the cursor
    /// has moved far enough from the last recorded point, and always updates livePoint.
    func updateLasso(at coordinate: CLLocationCoordinate2D) {
        livePoint = coordinate
        let threshold = 0.00006 // ~6 m — keeps vertex count manageable
        if let last = polygonVertices.last {
            guard abs(coordinate.latitude  - last.latitude)  > threshold ||
                  abs(coordinate.longitude - last.longitude) > threshold else { return }
        }
        polygonVertices.append(coordinate)
    }

    /// Called on DragGesture.onEnded — snaps close and applies the polygon filter.
    func endLasso() {
        livePoint = nil
        guard polygonVertices.count >= 3 else {
            cancelPolygonDraw()
            return
        }
        activePolygon = polygonVertices
        polygonVertices = []
        isDrawingPolygon = false
        fitCameraToPolygon()
    }

    func cancelPolygonDraw() {
        polygonVertices = []
        livePoint = nil
        isDrawingPolygon = false
    }

    func clearPolygonFilter() {
        activePolygon = nil
        polygonVertices = []
        livePoint = nil
        isDrawingPolygon = false
    }

    private func fitCameraToPolygon() {
        guard let polygon = activePolygon, !polygon.isEmpty else { return }
        let lats = polygon.map { $0.latitude }
        let lons = polygon.map { $0.longitude }
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta:  (maxLat - minLat) * 1.4,
            longitudeDelta: (maxLon - minLon) * 1.4
        )
        withAnimation(.easeInOut(duration: 0.5)) {
            mapPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    /// Fly the map camera to centre on a specific annotation (from sidebar tap).
    func centerOn(_ annotation: PhotoAnnotation) {
        withAnimation(.easeInOut(duration: 0.4)) {
            mapPosition = .region(MKCoordinateRegion(
                center: annotation.coordinate,
                latitudinalMeters: 1_500,
                longitudinalMeters: 1_500
            ))
        }
        selectedAnnotation = annotation
    }

    // MARK: Count helper

    /// Number of photos in filteredAnnotations — shown on LocationFilterSheet.
    var filteredPhotoCount: Int { filteredAnnotations.count }

    // MARK: Internal helpers (used by LocationFilterSheet)

    /// Returns true when the annotation's coordinate falls inside `region`.
    /// Exposed internally so LocationFilterSheet can compute per-region photo counts.
    func isAnnotationVisible(_ annotation: PhotoAnnotation, in region: MKCoordinateRegion) -> Bool {
        isCoordinate(annotation.coordinate, inRegion: region)
    }

    // MARK: Private helpers

    /// Parse GPS coordinates from a PhotoAsset.
    /// Checks raw_exif_json (camera GPS) first, then user_metadata_json (workflow-assigned GPS).
    private func extractCoordinate(from photo: PhotoAsset) -> CLLocationCoordinate2D? {
        // 1. Camera EXIF GPS (most accurate)
        if let jsonString = photo.rawExifJson,
           let data = jsonString.data(using: .utf8),
           let payload = try? JSONDecoder().decode(EXIFCoordinatePayload.self, from: data),
           let lat = payload.latitude, let lon = payload.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        // 2. Workflow-assigned GPS (from Claude location/gear/editorial workflows)
        if let jsonString = photo.userMetadataJson,
           let data = jsonString.data(using: .utf8),
           let payload = try? JSONDecoder().decode(EXIFCoordinatePayload.self, from: data),
           let lat = payload.latitude, let lon = payload.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    /// Returns true when `coordinate` falls within the given `region`.
    private func isCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        inRegion region: MKCoordinateRegion
    ) -> Bool {
        let latDelta = region.span.latitudeDelta / 2.0
        let lonDelta = region.span.longitudeDelta / 2.0
        let minLat = region.center.latitude  - latDelta
        let maxLat = region.center.latitude  + latDelta
        let minLon = region.center.longitude - lonDelta
        let maxLon = region.center.longitude + lonDelta
        return coordinate.latitude  >= minLat &&
               coordinate.latitude  <= maxLat &&
               coordinate.longitude >= minLon &&
               coordinate.longitude <= maxLon
    }

    /// Ray-casting point-in-polygon test.
    /// Uses longitude as X axis and latitude as Y axis.
    private func isCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        insidePolygon polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        let x = coordinate.longitude
        let y = coordinate.latitude
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                inside = !inside
            }
            j = i
        }
        return inside
    }
}

// MARK: - EXIFCoordinatePayload

/// Minimal Codable struct for extracting GPS fields from the raw_exif_json blob.
/// Mirrors EXIFSnapshot.CodableSnapshot latitude/longitude fields only.
private struct EXIFCoordinatePayload: Codable {
    let latitude: Double?
    let longitude: Double?
}
