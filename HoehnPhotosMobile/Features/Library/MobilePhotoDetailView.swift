import SwiftUI
import HoehnPhotosCore

// MARK: - FilmstripThumbnail

private struct FilmstripThumbnail: View {
    let photo: PhotoAsset
    let proxyURL: URL
    let isSelected: Bool

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray6)
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white, lineWidth: isSelected ? 2 : 0)
        )
        .accessibilityLabel("\(photo.canonicalName)\(isSelected ? ", current" : "")")
        .accessibilityAddTraits(.isButton)
        .task {
            let url = proxyURL
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                self.image = img
            }
        }
    }
}

// MARK: - MetadataSectionDivider
//
// Thin, inset row separator used between `MetadataRow` entries in the EXIF
// sheet. Matches the reference look in the primitive's preview.
private struct MetadataSectionDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 22) // approximate lead-in past the icon gutter
    }
}

// MARK: - MobilePhotoDetailView

struct MobilePhotoDetailView: View {
    let photos: [PhotoAsset]
    /// Optional shared namespace so the opening tile can zoom into this view
    /// via iOS 18's `.navigationTransition(.zoom(sourceID:in:))`. When nil,
    /// the view presents with the default sheet animation (backwards compat).
    var heroNamespace: Namespace.ID? = nil
    @State private var currentIndex: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Image state
    @State private var image: UIImage?

    // Phase 4 — Face strip toast (placeholder actions until face-naming ships)
    @State private var facesToast: ToastMessage?

    // Phase 4 — Similar photos push target. When the user taps a similar
    // tile that isn't already in `photos`, push a new detail onto the
    // existing NavigationStack.
    @State private var pushedSimilarPhoto: PhotoAsset? = nil

    // Zoom state (D-10)
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // Zoom indicator
    @State private var showZoomBadge = false
    @State private var zoomBadgeTask: Task<Void, Never>? = nil

    // Metadata sheet (D-09)
    @State private var showMetadata = false

    // Swipe-up hint
    @State private var showInfoHint = false
    @State private var hasShownInfoHint = false

    // Curation state
    @State private var currentState: CurationState

    // Curation feedback overlay
    @State private var lastCurationFeedback: String? = nil

    // Image load error
    @State private var imageLoadFailed = false

    /// Captured at init so the hero zoom transition always anchors on the
    /// originally-tapped source tile even if the user swipes the filmstrip.
    private let initialPhotoID: String

    init(photos: [PhotoAsset], initialIndex: Int, heroNamespace: Namespace.ID? = nil) {
        self.photos = photos
        self.heroNamespace = heroNamespace
        _currentIndex = State(initialValue: initialIndex)
        let photo = photos[initialIndex]
        self.initialPhotoID = photo.id
        _currentState = State(initialValue: CurationState(rawValue: photo.curationState) ?? .needsReview)
    }

    private var photo: PhotoAsset { photos[currentIndex] }

    private var filmstripPhotos: [(offset: Int, photo: PhotoAsset)] {
        let range = max(0, currentIndex - 5)...min(photos.count - 1, currentIndex + 5)
        return range.map { (offset: $0, photo: photos[$0]) }
    }

    private func proxyURL(for p: PhotoAsset) -> URL {
        let baseName = (p.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                imageContent

                VStack {
                    Spacer()
                    filmstripView
                    ratingBar
                }

                // Curation success badge overlay
                if let feedback = lastCurationFeedback {
                    VStack {
                        Text(feedback)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 16)
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityHidden(true)
                }

                // Swipe-up info hint
                if showInfoHint {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Label("Swipe up for info", systemImage: "chevron.up")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(12)
                            Spacer()
                        }
                        .padding(.bottom, 80)
                    }
                    .accessibilityHidden(true)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation(.easeOut(duration: 0.5)) { showInfoHint = false }
                        }
                    }
                }

                // Zoom scale badge
                if showZoomBadge {
                    Text("\(Int(scale * 100))%")
                        .font(.caption.monospaced().bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .cornerRadius(8)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .navigationTitle("\(currentIndex + 1) of \(photos.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMetadata = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Photo info")
                    .accessibilityHint("Shows EXIF metadata and classification")
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showMetadata) {
                metadataSheet
            }
            .navigationDestination(isPresented: Binding(
                get: { pushedSimilarPhoto != nil },
                set: { if !$0 { pushedSimilarPhoto = nil } }
            )) {
                // When the user taps a similar-photos tile for a photo that
                // isn't already in the filmstrip, push a fresh detail for it.
                if let p = pushedSimilarPhoto {
                    MobilePhotoDetailView(photos: [p], initialIndex: 0)
                        .environmentObject(syncService)
                }
            }
        }
        .modifier(HeroZoomModifier(heroNamespace: heroNamespace, photoID: initialPhotoID))
    }

    // MARK: - Filmstrip

    private var filmstripView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(filmstripPhotos, id: \.offset) { item in
                        FilmstripThumbnail(
                            photo: item.photo,
                            proxyURL: proxyURL(for: item.photo),
                            isSelected: item.offset == currentIndex
                        )
                        .id(item.offset)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                currentIndex = item.offset
                            }
                            scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero
                            imageLoadFailed = false
                            currentState = CurationState(rawValue: photos[item.offset].curationState) ?? .needsReview
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .background(Color.black)
            .onChange(of: currentIndex) { newIndex in
                withAnimation { scrollProxy.scrollTo(newIndex, anchor: .center) }
            }
            .onAppear {
                scrollProxy.scrollTo(currentIndex, anchor: .center)
            }
        }
    }

    // MARK: - Image Content

    @ViewBuilder
    private var imageContent: some View {
        GeometryReader { geo in
            Group {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if imageLoadFailed {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Proxy not available")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .gesture(swipeGesture)
            .gesture(panGesture)
            .highPriorityGesture(pinchGesture)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.35)) {
                    if scale > 1.0 {
                        // Reset to fit
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    } else {
                        // Zoom to 2x
                        scale = 2.0
                        lastScale = 2.0
                    }
                }
                flashZoomBadge()
            }
        }
        .accessibilityAction(named: "Toggle zoom") {
            withAnimation(.spring(response: 0.35)) {
                if scale > 1.0 {
                    scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero
                } else {
                    scale = 2.0; lastScale = 2.0
                }
            }
        }
        .accessibilityAction(named: "Show photo info") { showMetadata = true }
        .accessibilityAction(named: "Next photo") {
            if currentIndex < photos.count - 1 { advanceIndex(by: 1) }
        }
        .accessibilityAction(named: "Previous photo") {
            if currentIndex > 0 { advanceIndex(by: -1) }
        }
        .task(id: photo.id) {
            image = nil
            imageLoadFailed = false
            // Only show hint once per session
            if !hasShownInfoHint {
                showInfoHint = true
                hasShownInfoHint = true
            }
            let url = proxyURL(for: photo)
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                image = img
            } else {
                imageLoadFailed = true
            }
        }
    }

    // MARK: - Zoom Badge

    private func flashZoomBadge() {
        zoomBadgeTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { showZoomBadge = true }
        zoomBadgeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { showZoomBadge = false }
            }
        }
    }

    // MARK: - Gestures

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                scale = min(max(newScale, 1.0), 5.0)
            }
            .onEnded { _ in
                lastScale = scale
                flashZoomBadge()
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                guard scale > 1.0 else { return }
                lastOffset = offset
            }
    }

    /// Unified swipe gesture: left/right for navigation, up for metadata.
    /// Uses a single DragGesture so horizontal and vertical are mutually exclusive per drag.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard scale == 1.0 else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                // Determine dominant axis
                if abs(dy) > abs(dx) {
                    // Vertical swipe
                    if dy < -60 {
                        showMetadata = true
                    }
                    // Swipe down has no action from full-screen; navigation is via Done button
                } else {
                    // Horizontal swipe — navigation
                    if dx < -50 && currentIndex < photos.count - 1 {
                        advanceIndex(by: 1)
                    } else if dx > 50 && currentIndex > 0 {
                        advanceIndex(by: -1)
                    }
                }
            }
    }

    private func advanceIndex(by delta: Int) {
        withAnimation(.easeInOut(duration: 0.15)) {
            currentIndex += delta
        }
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
        imageLoadFailed = false
        currentState = CurationState(rawValue: photos[currentIndex].curationState) ?? .needsReview
    }

    // MARK: - Rating Bar

    private var ratingBar: some View {
        HStack(spacing: 20) {
            ratingButton(.rejected, icon: "xmark", label: "Reject", feedbackLabel: "Rejected", color: .red)
            ratingButton(.archive, icon: "archivebox", label: "Archive", feedbackLabel: "Archived", color: .blue)
            ratingButton(.keeper, icon: "star.fill", label: "Keep", feedbackLabel: "Kept", color: .green)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.bottom, 20)
    }

    private func ratingButton(_ state: CurationState, icon: String, label: String, feedbackLabel: String, color: Color) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(reduceMotion ? .default : .spring(response: 0.25, dampingFraction: 0.6)) {
                currentState = state
            }
            // Show success badge
            withAnimation(.easeIn(duration: 0.3)) {
                lastCurationFeedback = feedbackLabel
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                withAnimation { lastCurationFeedback = nil }
            }
            let photoID = photo.id
            Task {
                guard let db = appDatabase else { return }
                try? await MobilePhotoRepository(db: db).updateCurationState(id: photoID, state: state)
                syncService.enqueueDelta(PhotoCurationDelta(photoId: photoID, curationState: state.rawValue))
            }
            // Auto-advance to next photo after curation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if currentIndex < photos.count - 1 {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentIndex += 1
                    }
                    scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero
                    imageLoadFailed = false
                    currentState = CurationState(rawValue: photos[currentIndex].curationState) ?? .needsReview
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .symbolEffect(.bounce, value: reduceMotion ? false : (currentState == state))
                Text(label)
                    .font(.caption2)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(currentState == state ? color : .white.opacity(0.7))
            .frame(width: 60)
            .scaleEffect(currentState == state && !reduceMotion ? 1.1 : 1.0)
            .animation(reduceMotion ? .default : .spring(response: 0.25, dampingFraction: 0.6), value: currentState)
            .accessibilityElement(children: .combine)
        }
        .accessibilityLabel(label)
        .accessibilityHint("Double tap to mark this photo as \(label)")
    }

    // MARK: - Metadata Sheet

    private var metadataSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Phase 4 — Face chips strip (above the EXIF grid)
                    PhotoFacesStrip(photo: photo, toast: $facesToast)

                    // EXIF rows
                    let exif = parseExif(photo.rawExifJson) ?? [:]

                    VStack(spacing: 0) {
                        Group {
                            MetadataRow(
                                label: "Date",
                                value: formatDate(photo.createdAt),
                                systemImage: "calendar"
                            )
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "Camera",
                                value: exifString(exif, keys: ["Make", "cameraMake", "LensMake"]),
                                systemImage: "camera"
                            )
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "Shutter",
                                value: exifString(exif, keys: ["ExposureTime", "shutterSpeed", "ShutterSpeedValue"]),
                                systemImage: "timer",
                                valueStyle: .mono
                            )
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "Aperture",
                                value: exifAperture(exif),
                                systemImage: "camera.aperture",
                                valueStyle: .mono
                            )
                            MetadataSectionDivider()
                        }
                        Group {
                            MetadataRow(
                                label: "ISO",
                                value: exifString(exif, keys: ["ISOSpeedRatings", "ISO", "iso"]),
                                systemImage: "sun.max",
                                valueStyle: .mono
                            )
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "Focal",
                                value: exifFocalLength(exif),
                                systemImage: "arrow.left.and.right",
                                valueStyle: .mono
                            )
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "File",
                                value: photo.canonicalName,
                                systemImage: "doc"
                            )
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "Size",
                                value: formatFileSize(photo.fileSize),
                                systemImage: "internaldrive",
                                valueStyle: .mono
                            )
                        }
                        Group {
                            if let dims = imageDimensions {
                                MetadataSectionDivider()
                                MetadataRow(
                                    label: "Dimensions",
                                    value: dims,
                                    systemImage: "square.resize",
                                    valueStyle: .mono
                                )
                            }
                            if let profile = photo.colorProfile {
                                MetadataSectionDivider()
                                MetadataRow(
                                    label: "Color",
                                    value: profile,
                                    systemImage: "paintpalette"
                                )
                            }
                            if let depth = photo.bitDepth {
                                MetadataSectionDivider()
                                MetadataRow(
                                    label: "Bit Depth",
                                    value: "\(depth)-bit",
                                    systemImage: "waveform",
                                    valueStyle: .mono
                                )
                            }
                            if let model = exifString(exif, keys: ["Model", "cameraModel"]) {
                                MetadataSectionDivider()
                                MetadataRow(
                                    label: "Model",
                                    value: model,
                                    systemImage: "camera.badge.ellipsis"
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // Location section
                    if hasLocationData(exif) {
                        Divider().padding(.horizontal, 16)
                        Text("Location")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        // Phase 4 — Inline map tile for photos with GPS.
                        if let coord = photo.gpsCoordinate {
                            PhotoLocationMapTile(coordinate: coord, title: photo.canonicalName)
                        }

                        VStack(spacing: 0) {
                            // TODO: consider consolidating city/country into a
                            // single "Place" row once we have a canonical
                            // formatted-address field.
                            MetadataRow(
                                label: "City",
                                value: exifString(exif, keys: ["locationCity"]),
                                systemImage: "building.2"
                            )
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "Country",
                                value: exifString(exif, keys: ["locationCountry"]),
                                systemImage: "globe"
                            )
                            if let lat = exifDouble(exif, keys: ["GPSLatitude", "latitude"]),
                               let lon = exifDouble(exif, keys: ["GPSLongitude", "longitude"]) {
                                MetadataSectionDivider()
                                MetadataRow(
                                    label: "GPS",
                                    value: String(format: "%.4f, %.4f", lat, lon),
                                    systemImage: "location",
                                    valueStyle: .mono
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Classification section
                    Divider().padding(.horizontal, 16)
                    Text("Classification")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    VStack(spacing: 0) {
                        // TODO: Curation is an app-state value, not a raw EXIF
                        // field — copying it is allowed but slightly odd.
                        MetadataRow(
                            label: "Curation",
                            value: currentState.title,
                            systemImage: "tag"
                        )
                        if let scene = photo.sceneType {
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "Scene",
                                value: scene,
                                systemImage: "sparkles"
                            )
                        }
                        if let modified = photo.dateModified {
                            MetadataSectionDivider()
                            MetadataRow(
                                label: "Modified",
                                value: formatDate(modified),
                                systemImage: "pencil"
                            )
                        }
                    }
                    .padding(.horizontal, 16)

                    // Phase 4 — Similar photos carousel (below EXIF rows)
                    Divider().padding(.horizontal, 16)
                    SimilarPhotosCarousel(photo: photo) { sibling in
                        handleSimilarPhotoTap(sibling)
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("Photo Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showMetadata = false }
                }
            }
            .hapticToast($facesToast)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - EXIF Extraction Helpers

    private func exifString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let val = dict[key] {
                return "\(val)"
            }
        }
        return nil
    }

    private func exifDouble(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let val = dict[key] as? Double { return val }
            if let val = dict[key] as? NSNumber { return val.doubleValue }
        }
        return nil
    }

    private func exifAperture(_ dict: [String: Any]) -> String? {
        for key in ["FNumber", "aperture", "ApertureValue"] {
            if let val = dict[key] as? Double {
                return String(format: "f/%.1f", val)
            }
            if let val = dict[key] as? NSNumber {
                return String(format: "f/%.1f", val.doubleValue)
            }
            if let val = dict[key] as? String {
                return val.hasPrefix("f/") ? val : "f/\(val)"
            }
        }
        return nil
    }

    private func exifFocalLength(_ dict: [String: Any]) -> String? {
        for key in ["FocalLength", "focalLength", "FocalLengthIn35mmFilm"] {
            if let val = dict[key] as? Double {
                return String(format: "%.0fmm", val)
            }
            if let val = dict[key] as? NSNumber {
                return String(format: "%.0fmm", val.doubleValue)
            }
            if let val = dict[key] as? String {
                return val.hasSuffix("mm") ? val : "\(val)mm"
            }
        }
        return nil
    }

    private var imageDimensions: String? {
        guard let img = image else { return nil }
        let w = Int(img.size.width * img.scale)
        let h = Int(img.size.height * img.scale)
        return "\(w) × \(h)"
    }

    // MARK: - Helpers

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatFileSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }

    private func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        return isoString
    }

    private func parseExif(_ json: String?) -> [String: Any]? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    private func hasLocationData(_ dict: [String: Any]) -> Bool {
        dict["locationCity"] != nil ||
        dict["locationCountry"] != nil ||
        dict["GPSLatitude"] != nil ||
        dict["latitude"] != nil
    }

    // MARK: - Similar photo tap (Phase 4)

    private func handleSimilarPhotoTap(_ sibling: PhotoAsset) {
        // If this sibling is already in the filmstrip, jump there inline so
        // the user keeps context. Otherwise push a new detail.
        if let idx = photos.firstIndex(where: { $0.id == sibling.id }) {
            withAnimation(.easeInOut(duration: 0.15)) {
                currentIndex = idx
            }
            scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero
            imageLoadFailed = false
            currentState = CurationState(rawValue: sibling.curationState) ?? .needsReview
            showMetadata = false
        } else {
            showMetadata = false
            pushedSimilarPhoto = sibling
        }
    }
}

// MARK: - HeroZoomModifier (Phase 4)

/// Applies iOS 18's `.navigationTransition(.zoom(sourceID:in:))` when a
/// hero namespace has been threaded through from the caller. No-op if
/// the caller did not opt in.
private struct HeroZoomModifier: ViewModifier {
    let heroNamespace: Namespace.ID?
    let photoID: String

    func body(content: Content) -> some View {
        if let ns = heroNamespace {
            content.navigationTransition(.zoom(sourceID: "\(HPNamespaceID.photoHero)-\(photoID)", in: ns))
        } else {
            content
        }
    }
}
