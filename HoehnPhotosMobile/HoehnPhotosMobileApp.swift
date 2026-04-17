import SwiftUI
import HoehnPhotosCore

@main
struct HoehnPhotosMobileApp: App {

    let appDatabase: AppDatabase
    @StateObject private var syncService = PeerSyncService()
    @StateObject private var cloudSyncEngine: CloudSyncEngine

    init() {
        let db: AppDatabase
        do {
            db = try AppDatabase.makeShared()
        } catch {
            fatalError("Failed to open database: \(error)")
        }
        appDatabase = db
        _cloudSyncEngine = StateObject(wrappedValue: CloudSyncEngine(appDatabase: db))
    }

    var body: some Scene {
        WindowGroup {
            MobileTabView()
                .environment(\.appDatabase, appDatabase)
                .environmentObject(syncService)
                .environmentObject(cloudSyncEngine)
                .task {
                    cloudSyncEngine.startAutoSync()
                }
        }
    }
}
