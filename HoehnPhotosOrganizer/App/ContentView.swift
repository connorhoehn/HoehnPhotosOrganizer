import SwiftUI
import UniformTypeIdentifiers

// MARK: - ContentView

/// Root view that reads AppDatabase from the environment and passes it to
/// LibraryViewModel. MockDataStore is only used in #Preview blocks.
struct ContentView: View {
    @Environment(\.appDatabase) private var appDatabase
    @AppStorage("appearance.mode") private var appearanceMode: String = "system"

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil  // system
        }
    }

    var body: some View {
        Group {
            if let db = appDatabase {
                LibraryRootView(db: db)
            } else {
                // Fallback: show mock data in previews or when db is unavailable
                LibraryRootViewMock()
            }
        }
        .preferredColorScheme(colorScheme)
    }
}

// MARK: - LibraryRootView (production path)

/// Production view that uses LibraryViewModel backed by a real AppDatabase.
private struct LibraryRootView: View {
    @StateObject private var viewModel: LibraryViewModel
    @StateObject private var peerSync = MacPeerSyncAdvertiser()
    @AppStorage("layout.inspectorVisible") private var inspectorVisible = false
    @State private var showSettings = false
    @State private var showDebugLog = false
    @State private var showCommandPalette = false
    private let db: AppDatabase
    @Environment(\.activityEventService) private var activityEventService: ActivityEventService?
    @Environment(\.eventOutboxProcessor) private var outboxProcessor: EventOutboxProcessor?
    @Environment(\.eventOutboxService) private var outboxService: EventOutboxService?

    init(db: AppDatabase) {
        self.db = db
        _viewModel = StateObject(wrappedValue: LibraryViewModel(db: db))
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail(
                selectedSection: $viewModel.selectedSection,
                showImportWizard: $viewModel.isShowingImportWizard,
                onSettings: { showSettings = true },
                smartAlbums: viewModel.smartAlbums,
                onSmartAlbumTap: { album in
                    Task { await viewModel.selectSmartAlbum(albumId: album.id, db: db) }
                },
                onCreateSmartAlbum: { viewModel.showSmartAlbumCreator = true },
                onDropToWorkflow: { ids in
                    viewModel.workflowPhotoIDs = ids
                    viewModel.selectedSection = .workflows
                },
                onDropToPrintLab: { ids in
                    for id in ids {
                        if let photo = viewModel.photos.first(where: { $0.id == id }) {
                            viewModel.sendToPrintLab(photo)
                        }
                    }
                },
                peerSync: peerSync
            )

            Divider()

            LibraryWorkspaceView(viewModel: viewModel, db: db, inspectorVisible: $inspectorVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible && viewModel.selectedPhoto != nil {
                Divider()

                InspectorPanel(
                    photo: viewModel.selectedPhoto,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            inspectorVisible = false
                        }
                    },
                    viewModel: viewModel
                )
                .frame(width: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 1060, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if showCommandPalette {
                SearchCommandPalette(isPresented: $showCommandPalette, viewModel: viewModel)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: showCommandPalette)
        .background {
            // ⌘K — open command palette from anywhere in the app
            Button("") { showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .frame(width: 0, height: 0)
                .hidden()
        }
        .animation(.easeInOut(duration: 0.2), value: inspectorVisible)
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedPhotoID)
        .onChange(of: viewModel.selectedSection) { _, newSection in
            if newSection == .search || newSection == .people || newSection == .drives {
                inspectorVisible = false
            }
            // Exit develop/review mode when switching sections
            if viewModel.showDevelopMode { viewModel.showDevelopMode = false }
            if viewModel.showReviewMode { viewModel.showReviewMode = false }
        }
        .onChange(of: viewModel.showDevelopMode) { _, isDevelop in
            if isDevelop { inspectorVisible = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .studioSendToPrintLab)) { notification in
            if let image = notification.userInfo?["image"] as? NSImage {
                viewModel.receiveStudioImage(image)
            }
        }
        .overlay {
            if viewModel.isDragOverWindow {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(
                        Text("Drop to Import")
                            .font(.title2.bold())
                            .foregroundStyle(Color.accentColor)
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $viewModel.isDragOverWindow) { _ in
            viewModel.isShowingImportWizard = true
            return false  // don't consume — let user drop into the wizard
        }
        .sheet(isPresented: $viewModel.isShowingImportWizard) {
            ImportWizardView(
                drives: viewModel.drives,
                onImportDigitalPhotos: { urls in
                    Task { await viewModel.importDigitalPhotos(urls, db: db) }
                },
                onNavigateToDrives: {
                    viewModel.selectedSection = .drives
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(gridColumns: $viewModel.gridColumns, db: db, photoRepo: viewModel.photoRepo, peerSync: peerSync) {
                Task { await viewModel.clearLibrary(db: db) }
            }
        }
        .sheet(isPresented: $viewModel.showSmartAlbumCreator) {
            SmartAlbumView(viewModel: viewModel)
                .environment(\.appDatabase, db)
        }
        .sheet(isPresented: $showDebugLog) {
            DebugLogView(db: db)
        }
        .task {
            viewModel.activityService = activityEventService
            viewModel.outboxProcessor = outboxProcessor
            viewModel.startObserving()
            outboxProcessor?.start()
        }
        .onDisappear {
            viewModel.stopObserving()
            outboxProcessor?.stop()
        }
    }
}

// MARK: - LibraryRootViewMock (preview / fallback path)

/// Preview/fallback view using MockDataStore. Only used in #Preview blocks.
private struct LibraryRootViewMock: View {
    @StateObject private var store = MockDataStore()
    @StateObject private var peerSync = MacPeerSyncAdvertiser()
    @State private var inspectorVisible = false
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail(
                selectedSection: $store.selectedSection,
                showImportWizard: $store.isShowingImportWizard,
                onSettings: { showSettings = true },
                smartAlbums: [],
                onSmartAlbumTap: { _ in },
                onCreateSmartAlbum: { },
                peerSync: peerSync
            )

            Divider()

            MainWorkspaceViewMock(store: store, inspectorVisible: $inspectorVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                Divider()

                InspectorPanelMock(
                    photo: store.selectedPhoto,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            inspectorVisible = false
                        }
                    }
                )
                .frame(width: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 1060, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: inspectorVisible)
        .sheet(isPresented: $store.isShowingImportWizard) {
            ImportWizardView(drives: [])
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(gridColumns: $store.gridColumns, peerSync: peerSync)
        }
    }
}

#Preview {
    ContentView()
}
