import SwiftUI
private import MapKit
import CoreLocation
import HoehnPhotosCore

// MARK: - MapResultsView

/// Map view for the Places search scope. Drops an annotation for each photo in `photos`
/// that has GPS in its EXIF. Tapping a thumb opens the shared detail sheet at that photo.
struct MapResultsView: View {

    let photos: [PhotoAsset]
    var onSelect: (Int) -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic

    // Precomputed annotation rows so we don't re-parse EXIF on every redraw.
    private var geoPoints: [GeoPoint] {
        photos.enumerated().compactMap { (index, photo) in
            guard let coord = photo.gpsCoordinate else { return nil }
            return GeoPoint(photoId: photo.id, photoIndex: index, coordinate: coord, photo: photo)
        }
    }

    var body: some View {
        Group {
            if geoPoints.isEmpty {
                emptyState
            } else {
                Map(position: $cameraPosition) {
                    ForEach(geoPoints) { point in
                        Annotation(point.photo.canonicalName, coordinate: point.coordinate) {
                            MapThumb(photo: point.photo)
                                .onTapGesture {
                                    HPHaptic.light()
                                    onSelect(point.photoIndex)
                                }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onAppear {
                    fitToAnnotations()
                }
                .onChange(of: geoPoints.count) { _, _ in
                    fitToAnnotations()
                }
            }
        }
    }

    private func fitToAnnotations() {
        guard !geoPoints.isEmpty else { return }
        let lats = geoPoints.map { $0.coordinate.latitude }
        let lons = geoPoints.map { $0.coordinate.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max()
        else { return }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.01, (maxLon - minLon) * 1.4)
        )
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }

    private var emptyState: some View {
        ZStack {
            MeshBackdrop(palette: .cool)
            VStack(spacing: HPSpacing.sm) {
                Image(systemName: "mappin.slash")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                Text("No geotagged photos match")
                    .font(HPFont.sectionHeader)
                    .foregroundStyle(.white)
                Text("Try a broader query or clear filters.")
                    .font(HPFont.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, HPSpacing.xxl)
            }
        }
    }

    private struct GeoPoint: Identifiable {
        let photoId: String
        let photoIndex: Int
        let coordinate: CLLocationCoordinate2D
        let photo: PhotoAsset
        var id: String { photoId }
    }
}

// MARK: - MapThumb

/// 48pt map annotation thumbnail — loads the same proxy JPEG the grid tiles use.
private struct MapThumb: View {
    let photo: PhotoAsset
    @State private var image: UIImage?

    var body: some View {
        PhotoTile(image: image, cornerRadius: HPRadius.small)
            .frame(width: 48, height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: HPRadius.small, style: .continuous)
                    .stroke(.white, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .task(id: photo.id) {
                let url = proxyURL
                let loaded = await Task.detached(priority: .utility) {
                    guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                    return UIImage(data: data)
                }.value
                if let loaded { self.image = loaded }
            }
    }

    private var proxyURL: URL {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")
    }
}
