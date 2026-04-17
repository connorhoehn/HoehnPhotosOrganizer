import SwiftUI
import MapKit

// MARK: - MapPhotoView

struct MapPhotoView: View {

    @StateObject private var viewModel: MapPhotoViewModel
    @Binding var selectedLocationFilter: MKCoordinateRegion?
    private let preloadedPhotos: [PhotoAsset]?

    @AppStorage("map.style") private var mapStyleKey: String = "standard"

    private var currentMapStyle: MapStyle {
        switch mapStyleKey {
        case "imagery": return .imagery
        case "hybrid":  return .hybrid
        default:        return .standard
        }
    }

    // MARK: Init

    init(photoRepo: PhotoRepository, selectedLocationFilter: Binding<MKCoordinateRegion?>) {
        _viewModel = StateObject(wrappedValue: MapPhotoViewModel(photoRepo: photoRepo))
        _selectedLocationFilter = selectedLocationFilter
        self.preloadedPhotos = nil
    }

    init(photos: [PhotoAsset], photoRepo: PhotoRepository, selectedLocationFilter: Binding<MKCoordinateRegion?>) {
        _viewModel = StateObject(wrappedValue: MapPhotoViewModel(photoRepo: photoRepo))
        _selectedLocationFilter = selectedLocationFilter
        self.preloadedPhotos = photos
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            // Map (left, takes remaining space)
            mapPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Photo list (right sidebar, fixed width)
            photoListPanel
                .frame(width: 260)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .task(id: preloadedPhotos?.map { $0.id }) {
            if let photos = preloadedPhotos {
                viewModel.loadPhotos(from: photos)
            } else {
                await viewModel.loadPhotos()
            }
        }
        .sheet(isPresented: $viewModel.isShowingFilterSheet) {
            LocationFilterSheet(viewModel: viewModel) { region in
                selectedLocationFilter = region
            }
        }
        .alert("Map Error", isPresented: Binding(
            get: { viewModel.loadError != nil },
            set: { if !$0 { viewModel.loadError = nil } }
        )) {
            Button("OK") { viewModel.loadError = nil }
        } message: {
            Text(viewModel.loadError ?? "")
        }
    }

    // MARK: - Map panel helpers

    /// Vertices for the live lasso preview: drawn path + current cursor position.
    private var lassoPreviewCoordinates: [CLLocationCoordinate2D] {
        let verts = viewModel.polygonVertices
        guard let lp = viewModel.livePoint, !verts.isEmpty else { return verts }
        return verts + [lp]
    }

    private var mapPanel: some View {
        ZStack(alignment: .topTrailing) {
            MapReader { proxy in
                ZStack {
                    Map(position: $viewModel.mapPosition,
                        selection: $viewModel.selectedAnnotation) {

                        // Photo annotations
                        ForEach(viewModel.photoAnnotations) { annotation in
                            Annotation(annotation.displayName, coordinate: annotation.coordinate, anchor: .bottom) {
                                PhotoAnnotationMarker(
                                    annotation: annotation,
                                    isSelected: viewModel.selectedAnnotation?.id == annotation.id
                                )
                            }
                            .annotationTitles(.hidden)
                            .tag(annotation)
                        }

                        // Closed polygon filter overlay
                        if let polygon = viewModel.activePolygon, polygon.count >= 3 {
                            MapPolygon(coordinates: polygon)
                                .foregroundStyle(Color.orange.opacity(0.15))
                                .stroke(.orange, lineWidth: 2)
                        }

                        // In-progress freehand lasso
                        if viewModel.isDrawingPolygon {
                            let preview = lassoPreviewCoordinates

                            // Filled area preview
                            if preview.count >= 3 {
                                MapPolygon(coordinates: preview)
                                    .foregroundStyle(Color.orange.opacity(0.12))
                                    .stroke(.orange, lineWidth: 0)
                            }

                            // Solid path the user has drawn
                            if preview.count >= 2 {
                                MapPolyline(coordinates: preview)
                                    .stroke(.orange, lineWidth: 2.5)
                            }

                            // Dashed closing edge: livePoint → first vertex
                            if let lp = viewModel.livePoint,
                               let first = viewModel.polygonVertices.first {
                                MapPolyline(coordinates: [lp, first])
                                    .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            }
                        }
                    }
                    .mapStyle(currentMapStyle)
                    .onMapCameraChange { context in
                        viewModel.updateVisiblePhotos(for: context.region)
                    }

                    // Transparent drag-capture overlay — active only while drawing.
                    // Placed above Map so it blocks map panning exclusively during lasso.
                    if viewModel.isDrawingPolygon {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                    .onChanged { value in
                                        if let coord = proxy.convert(value.location, from: .local) {
                                            viewModel.updateLasso(at: coord)
                                        }
                                    }
                                    .onEnded { _ in
                                        viewModel.endLasso()
                                    }
                            )
                            .onHover { inside in
                                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                            }
                    }
                }
            }
            .overlay {
                if !viewModel.isLoading && viewModel.photoAnnotations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No geotagged photos")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if preloadedPhotos != nil {
                            Text("Run the Location or Gear workflow to add GPS.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                // Drawing instruction banner
                if viewModel.isDrawingPolygon {
                    VStack {
                        Text(viewModel.polygonVertices.isEmpty
                             ? "Click and drag to draw your search area"
                             : "Release to apply — or press Esc to cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .padding(.top, 14)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }
            }

            // Controls column
            VStack(spacing: 6) {
                if viewModel.isDrawingPolygon {
                    mapControlButton(icon: "xmark.circle", tint: .primary, help: "Cancel lasso draw") {
                        viewModel.cancelPolygonDraw()
                    }
                } else {
                    mapControlButton(
                        icon: "lasso",
                        tint: viewModel.activePolygon != nil ? .orange : .primary,
                        size: 44,
                        help: viewModel.activePolygon != nil ? "Redraw lasso filter" : "Drag to draw a search area"
                    ) {
                        viewModel.startPolygonDraw()
                    }

                    if viewModel.activePolygon != nil {
                        mapControlButton(icon: "xmark.circle.fill", tint: .orange, help: "Clear lasso filter") {
                            viewModel.clearPolygonFilter()
                        }
                    }

                    mapControlButton(icon: "rectangle.and.arrow.up.right.and.arrow.down.left",
                                     tint: .primary, help: "Filter by rectangular region") {
                        viewModel.isShowingFilterSheet = true
                    }

                    if viewModel.selectedRegion != nil {
                        mapControlButton(icon: "xmark.circle.fill", tint: .red, help: "Clear region filter") {
                            viewModel.clearRegionFilter()
                            selectedLocationFilter = nil
                        }
                    }

                    // Map style picker
                    Menu {
                        Button("Standard")  { mapStyleKey = "standard" }
                        Button("Satellite") { mapStyleKey = "imagery" }
                        Button("Hybrid")    { mapStyleKey = "hybrid" }
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 36, height: 36)
                    .help("Map style")
                }
            }
            .padding(12)
        }
    }

    private func mapControlButton(icon: String, tint: Color, size: CGFloat = 36, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: size * 0.25))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Photo list panel

    private var photoListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                let count = viewModel.filteredAnnotations.count
                let total = viewModel.photoAnnotations.count
                let isFiltered = viewModel.activePolygon != nil || viewModel.selectedRegion != nil
                Text(isFiltered
                     ? "\(count) of \(total) photo\(total == 1 ? "" : "s")"
                     : (total == 0 ? "Photos" : "\(total) photo\(total == 1 ? "" : "s")"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if viewModel.isLoading {
                Spacer()
                ProgressView().padding()
                Spacer()
            } else if viewModel.filteredAnnotations.isEmpty {
                Spacer()
                Text(viewModel.photoAnnotations.isEmpty ? "No photos" : "No photos in selection")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.filteredAnnotations) { annotation in
                                MapPhotoRow(
                                    annotation: annotation,
                                    isSelected: viewModel.selectedAnnotation?.id == annotation.id
                                ) {
                                    viewModel.centerOn(annotation)
                                }
                                .id(annotation.id)

                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                    .onChange(of: viewModel.selectedAnnotation?.id) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }
}

// MARK: - MapPhotoRow

private struct MapPhotoRow: View {
    let annotation: PhotoAnnotation
    let isSelected: Bool
    let onTap: () -> Void

    @State private var proxyImage: NSImage?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Thumbnail
                Group {
                    if let img = proxyImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(annotation.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text(String(format: "%.4f, %.4f",
                                annotation.coordinate.latitude,
                                annotation.coordinate.longitude))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            let baseName = (annotation.displayName as NSString).deletingPathExtension
            let url = ProxyGenerationActor.proxiesDirectory()
                .appendingPathComponent(baseName + ".jpg")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            proxyImage = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
        }
    }
}

// MARK: - PhotoAnnotationMarker

private struct PhotoAnnotationMarker: View {
    let annotation: PhotoAnnotation
    let isSelected: Bool

    var body: some View {
        Image(systemName: "photo.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isSelected ? Color.orange : Color.blue)
            .padding(6)
            .background(
                Circle()
                    .fill(isSelected ? Color.orange.opacity(0.2) : Color.blue.opacity(0.15))
            )
            .overlay(
                Circle().stroke(isSelected ? Color.orange : Color.blue, lineWidth: 1.5)
            )
            .scaleEffect(isSelected ? 1.2 : 1.0)
            .animation(.spring(duration: 0.2), value: isSelected)
    }
}
