import SwiftUI
private import MapKit
import CoreLocation
import HoehnPhotosCore

// MARK: - PhotoLocationMapTile
//
// Compact 120pt-tall map tile for photos that have a GPS coordinate. Drops
// one annotation at the capture location; tap opens Apple Maps driving to
// the coordinate via `MKMapItem.openInMaps`.
//
// Guarded at the call site by `if let coord = photo.gpsCoordinate { ... }`
// so this view always has a valid coordinate.

struct PhotoLocationMapTile: View {
    let coordinate: CLLocationCoordinate2D
    let title: String

    @State private var cameraPosition: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D, title: String) {
        self.coordinate = coordinate
        self.title = title
        _cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HPSpacing.sm) {
            HStack {
                Text("Location")
                    .font(HPFont.sectionHeader)
                Spacer()
                Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                    .font(HPFont.metaValue.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, HPSpacing.base)

            Button(action: openInMaps) {
                ZStack(alignment: .topTrailing) {
                    Map(position: $cameraPosition, interactionModes: []) {
                        Annotation(title, coordinate: coordinate) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundStyle(.red, .white)
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        }
                    }
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: HPRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HPRadius.card, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 0.5)
                    )

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Maps")
                    }
                    .font(HPFont.badgeLabel)
                    .foregroundStyle(.white)
                    .padding(.horizontal, HPSpacing.sm)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(HPSpacing.sm)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, HPSpacing.base)
            .accessibilityLabel("Photo location")
            .accessibilityHint("Opens Apple Maps at the capture location")
        }
    }

    private func openInMaps() {
        HPHaptic.light()
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = title
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        ])
    }
}
