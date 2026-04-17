# CloudKit Sync Plan: Replace Multipeer with Background Cloud Sync

## Why CloudKit Over Alternatives

| Option | Pros | Cons |
|--------|------|------|
| **Multipeer (current)** | No server, no account | Same network required, manual trigger, slow (~1hr), fragile |
| **iCloud Drive (file sync)** | Zero code, Apple handles it | SQLite + iCloud = corruption risk, no partial sync, no conflict resolution |
| **CloudKit (records)** | Background sync, incremental, conflict resolution, free tier | More code, Apple ecosystem only |
| **Custom server (S3/DynamoDB)** | Full control | Server cost, maintenance, auth |

**CloudKit wins** because: automatic background sync, incremental (only changes), works across networks, conflict resolution built in, no server to maintain, generous free tier.

---

## Architecture Overview

```
┌─────────────┐         ┌──────────────┐         ┌─────────────┐
│   Mac App   │ ──push──▶│   CloudKit   │◀──pull── │  iOS App    │
│  (primary)  │◀──pull── │  (iCloud)    │ ──push──▶│ (companion) │
│             │          │              │          │             │
│ GRDB SQLite │          │  CKRecords   │          │ GRDB SQLite │
│ Full catalog│          │  + CKAssets  │          │ Local copy  │
└─────────────┘          └──────────────┘          └─────────────┘
```

**Key principle:** GRDB stays as the local database on both platforms. CloudKit is the **sync transport**, not the primary database. Both apps read/write to local GRDB, and a sync engine pushes/pulls changes via CloudKit.

---

## Data Model: What Gets Synced

### Tier 1: Essential (sync immediately)
| Local Table | CloudKit Record Type | Size | Direction |
|-------------|---------------------|------|-----------|
| `photo_assets` | `PhotoAsset` | ~1KB/record | Mac → iPhone, curation bidirectional |
| `person_identities` | `PersonIdentity` | ~200B/record | Mac → iPhone |
| `face_embeddings` | `FaceEmbedding` | ~2KB/record (bbox only, skip vector) | Mac → iPhone |
| `triage_jobs` | `TriageJob` | ~500B/record | Mac → iPhone |
| `triage_job_photos` | `TriageJobPhoto` | ~100B/record | Mac → iPhone |
| `activity_events` | `ActivityEvent` | ~500B/record | Mac → iPhone |

### Tier 2: Creative (sync in background)
| Local Table | CloudKit Record Type | Size | Direction |
|-------------|---------------------|------|-----------|
| `studio_revisions` | `StudioRevision` | ~500B + thumbnail asset | Mac → iPhone |
| `thread_entries` (print) | `PrintAttempt` | ~1KB | Mac → iPhone |

### Tier 3: Binary assets
| Asset | CloudKit Storage | Size | Strategy |
|-------|-----------------|------|----------|
| Proxy JPEGs | `CKAsset` on PhotoAsset record | ~100KB each | Lazy download on-demand |
| Studio thumbnails | `CKAsset` on StudioRevision record | ~50KB each | Lazy download on-demand |

### What does NOT sync
- Full-resolution originals (too large, stay on Mac drives)
- Face embedding vectors (too large, not needed on iOS)
- Adjustment snapshots (desktop editing only)
- Pipeline execution state
- Canvas sessions

---

## CloudKit Container Setup

### 1. Create Container
In Xcode → Signing & Capabilities → + CloudKit:
- Container ID: `iCloud.com.connorhoehn.HoehnPhotos`
- Add to BOTH Mac and iOS targets
- Enable "CloudKit" capability on both

### 2. Schema (CloudKit Dashboard or auto-created)

```
RecordType: PhotoAsset
  Fields:
    canonicalName    String (queryable, sortable)
    filePath         String
    curationState    String (queryable)
    processingState  String
    importStatus     String (queryable)  // "staged" or "library"
    isGrayscale      Int64
    rawExifJson      String (or Asset for large EXIF)
    userMetadataJson String
    dateModified     Date/Time (sortable)
    proxyAsset       Asset (the proxy JPEG)
    localUpdatedAt   Date/Time (sortable) // for change tracking

RecordType: PersonIdentity
  Fields:
    name             String (queryable)
    coverFaceId      String
    localUpdatedAt   Date/Time

RecordType: FaceEmbedding
  Fields:
    photoRef         Reference (→ PhotoAsset)
    personRef        Reference (→ PersonIdentity, optional)
    faceIndex        Int64
    bboxX/Y/W/H     Double
    labeledBy        String
    needsReview      Int64
    localUpdatedAt   Date/Time

RecordType: TriageJob
  Fields:
    title            String
    parentJobRef     Reference (→ TriageJob, optional)
    source           String
    status           String (queryable)
    completenessScore Double
    photoCount       Int64
    currentMilestone String
    inheritedMetadata String
    localUpdatedAt   Date/Time

RecordType: TriageJobPhoto
  Fields:
    jobRef           Reference (→ TriageJob)
    photoRef         Reference (→ PhotoAsset)
    sortOrder        Int64
    localUpdatedAt   Date/Time

RecordType: ActivityEvent
  Fields:
    kind             String (queryable)
    photoRef         Reference (→ PhotoAsset, optional)
    title            String
    detail           String
    metadata         String (JSON)
    occurredAt       Date/Time (sortable)
    localUpdatedAt   Date/Time

RecordType: StudioRevision
  Fields:
    photoRef         Reference (→ PhotoAsset)
    name             String
    medium           String (queryable)
    paramsJson       String
    thumbnailAsset   Asset
    localUpdatedAt   Date/Time
```

### 3. Zone Setup

Use a **custom zone** in the **private database** (not the default zone):
- Zone name: `HoehnPhotosZone`
- Custom zones support: `CKFetchRecordZoneChangesOperation` (incremental sync), `CKSubscription` (push notifications), atomic commits

```swift
let zoneID = CKRecordZone.ID(zoneName: "HoehnPhotosZone", ownerName: CKCurrentUserDefaultName)
```

---

## Sync Engine Design

### Core Class: `CloudSyncEngine`

```swift
// HoehnPhotosCore/Sync/CloudSyncEngine.swift

@MainActor
final class CloudSyncEngine: ObservableObject {
    
    let container: CKContainer
    let database: CKDatabase          // .privateCloudDatabase
    let zoneID: CKRecordZone.ID
    let localDB: AppDatabase          // GRDB
    
    @Published var syncState: SyncState = .idle
    @Published var lastSyncDate: Date?
    
    // Change tokens — persist to UserDefaults
    @AppStorage("ck_serverChangeToken") private var savedTokenData: Data?
    
    enum SyncState: Equatable {
        case idle
        case pushing(progress: Double)
        case pulling(progress: Double)
        case error(String)
    }
    
    init(appDatabase: AppDatabase) {
        self.container = CKContainer(identifier: "iCloud.com.connorhoehn.HoehnPhotos")
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: "HoehnPhotosZone")
        self.localDB = appDatabase
    }
}
```

### Sync Flow

```
                    ┌──────────────┐
                    │  App Launch  │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Ensure Zone  │  (create HoehnPhotosZone if needed)
                    └──────┬───────┘
                           │
              ┌────────────▼────────────┐
              │  Pull Remote Changes    │  (CKFetchRecordZoneChangesOperation)
              │  using saved changeToken│
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  Apply to local GRDB    │  (upsert records, download assets)
              │  Skip if local is newer │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  Push Local Changes     │  (query local DB for updatedAt > lastPush)
              │  CKModifyRecordsOp      │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  Save new changeToken   │
              │  Update lastSyncDate    │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  Subscribe to pushes    │  (CKRecordZoneSubscription)
              │  for real-time updates  │
              └────────────────────────┘
```

### Change Tracking (Local Side)

Add a column to every synced table:

```sql
ALTER TABLE photo_assets ADD COLUMN ck_synced_at TIMESTAMP;
ALTER TABLE photo_assets ADD COLUMN ck_record_name TEXT;  -- CKRecord.ID.recordName
```

**Dirty records query:**
```swift
// Find records that changed since last sync
func dirtyPhotos() throws -> [PhotoAsset] {
    try localDB.dbPool.read { db in
        try PhotoAsset
            .filter(Column("updated_at") > Column("ck_synced_at") || Column("ck_synced_at") == nil)
            .fetchAll(db)
    }
}
```

### Pull (Remote → Local)

```swift
func pullChanges() async throws {
    let operation = CKFetchRecordZoneChangesOperation(
        recordZoneIDs: [zoneID],
        configurationsByRecordZoneID: [
            zoneID: .init(previousServerChangeToken: savedChangeToken)
        ]
    )
    
    var changedRecords: [CKRecord] = []
    var deletedRecordIDs: [CKRecord.ID] = []
    
    operation.recordWasChangedBlock = { _, result in
        if case .success(let record) = result {
            changedRecords.append(record)
        }
    }
    
    operation.recordWithIDWasDeletedBlock = { recordID, _ in
        deletedRecordIDs.append(recordID)
    }
    
    operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
        self.savedChangeToken = token
    }
    
    operation.fetchRecordZoneChangesResultBlock = { result in
        // Apply changedRecords to local GRDB
        // Delete deletedRecordIDs from local GRDB
    }
    
    database.add(operation)
}
```

### Push (Local → Remote)

```swift
func pushChanges() async throws {
    let dirtyPhotos = try dirtyPhotos()
    
    // Convert to CKRecords
    let records = dirtyPhotos.map { photo -> CKRecord in
        let recordID = CKRecord.ID(
            recordName: photo.id,  // use local UUID as record name
            zoneID: zoneID
        )
        let record = CKRecord(recordType: "PhotoAsset", recordID: recordID)
        record["canonicalName"] = photo.canonicalName
        record["curationState"] = photo.curationState
        record["dateModified"] = photo.dateModified
        // ... map all fields
        
        // Attach proxy as CKAsset
        if let proxyURL = proxyURL(for: photo) {
            record["proxyAsset"] = CKAsset(fileURL: proxyURL)
        }
        
        return record
    }
    
    // Batch upload (max 400 records per operation)
    for batch in records.chunked(into: 400) {
        let op = CKModifyRecordsOperation(
            recordsToSave: batch,
            recordIDsToDelete: nil
        )
        op.savePolicy = .ifServerRecordUnchanged  // conflict detection
        op.perRecordSaveBlock = { recordID, result in
            switch result {
            case .success:
                // Mark ck_synced_at = now in local DB
            case .failure(let error):
                if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
                    // Conflict: server has newer version
                    // Strategy: last-write-wins on most fields
                    // But MERGE curation state (prefer user intent)
                }
            }
        }
        database.add(op)
    }
}
```

### Proxy Image Lazy Download

Don't download all proxies upfront. Download on-demand when the UI needs them:

```swift
// In any view that needs a proxy image:
func loadProxy(for photo: PhotoAsset) async -> UIImage? {
    let localURL = proxyDirectory.appendingPathComponent("\(photo.canonicalName).jpg")
    
    // Check local cache first
    if FileManager.default.fileExists(atPath: localURL.path) {
        return UIImage(contentsOfFile: localURL.path)
    }
    
    // Download from CloudKit
    guard let recordName = photo.ckRecordName else { return nil }
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    
    do {
        let record = try await database.record(for: recordID)
        guard let asset = record["proxyAsset"] as? CKAsset,
              let assetURL = asset.fileURL else { return nil }
        
        // Cache locally
        try FileManager.default.copyItem(at: assetURL, to: localURL)
        return UIImage(contentsOfFile: localURL.path)
    } catch {
        return nil
    }
}
```

### Real-Time Push Notifications

```swift
func subscribeToChanges() async throws {
    let subscription = CKRecordZoneSubscription(
        zoneID: zoneID,
        subscriptionID: "zone-changes"
    )
    
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true  // silent push → triggers background fetch
    subscription.notificationInfo = info
    
    try await database.save(subscription)
}
```

In `AppDelegate` or app entry:
```swift
func application(_ application: UIApplication, 
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
    try? await syncEngine.pullChanges()
    return .newData
}
```

---

## Conflict Resolution Strategy

| Field | Strategy | Rationale |
|-------|----------|-----------|
| `curationState` | **Last write wins** | User intent is clear — most recent rating is correct |
| `userMetadataJson` | **Merge keys** | Different devices may edit different fields |
| `title` | **Last write wins** | Simple string, no merge needed |
| `status` (jobs) | **Higher state wins** | open → complete → archived only goes forward |
| `face labels` | **Last write wins** | Only labeled on Mac anyway |
| Everything else | **Mac wins** | Mac is the primary editor |

---

## Migration Plan

### Phase A: Infrastructure (1 session)
1. Add CloudKit capability to both targets
2. Create `CloudSyncEngine.swift` in HoehnPhotosCore
3. Add `ck_synced_at` and `ck_record_name` columns via GRDB migration
4. Create the custom zone on first launch
5. Add `CloudSyncEngine` as environment object in both apps

### Phase B: Push from Mac (1 session)  
1. Implement `pushChanges()` for PhotoAsset records (metadata only, no proxy yet)
2. Implement `pushChanges()` for PersonIdentity, FaceEmbedding, TriageJob
3. Wire to Mac app: push after import, after curation, after job changes
4. Add background push timer (every 5 minutes)

### Phase C: Pull on iPhone (1 session)
1. Implement `pullChanges()` with change token tracking
2. Apply remote records to local GRDB (upsert logic)
3. Replace `PeerSyncService` usage in iOS views with `CloudSyncEngine`
4. Subscribe to push notifications for real-time updates
5. Update sync status bar in `MobileTabView`

### Phase D: Proxy Images (1 session)
1. Attach proxy JPEGs as CKAssets when pushing PhotoAssets from Mac
2. Implement lazy proxy download on iOS (download when thumbnail needed)
3. Add download progress indicator on photo cells
4. LRU cache eviction for proxy images (keep most recent 2000)

### Phase E: Bidirectional Curation (1 session)
1. Push curation deltas from iPhone → CloudKit
2. Pull curation changes on Mac from CloudKit
3. Conflict resolution for simultaneous edits
4. Remove Multipeer Connectivity code (or keep as fallback for no-internet)

### Phase F: Background Sync + Polish (1 session)
1. `BGAppRefreshTask` for periodic background sync on iOS
2. `BGProcessingTask` for bulk proxy downloads when plugged in
3. Sync indicators in both apps (last sync time, pending changes count)
4. Error handling and retry logic
5. Test with airplane mode, poor connectivity, large libraries

---

## Files to Create

```
HoehnPhotosCore/Sync/
  CloudSyncEngine.swift         <- Core sync logic (both platforms)
  CloudSyncModels.swift         <- CKRecord ↔ GRDB model mappers
  ProxyCacheManager.swift       <- Lazy download + LRU eviction

HoehnPhotosOrganizer/Services/
  MacCloudSyncCoordinator.swift <- Mac-specific: triggers push after changes

HoehnPhotosMobile/
  Features/Settings/MobileCloudSyncView.swift  <- Replaces MobileSyncView
```

## Files to Modify

```
HoehnPhotosCore/Database/AppDatabase.swift     <- New migration: ck_synced_at columns
HoehnPhotosOrganizer/App/HoehnPhotosOrganizerApp.swift  <- Inject CloudSyncEngine
HoehnPhotosMobile/HoehnPhotosMobileApp.swift   <- Inject CloudSyncEngine
HoehnPhotosMobile/MobileTabView.swift          <- Update sync status bar
HoehnPhotosMobile/Features/Settings/MobileSettingsView.swift <- CloudKit settings
```

## CloudKit Quotas (Free Tier)

| Resource | Limit | Your Estimate |
|----------|-------|---------------|
| Asset storage | 10 GB | ~3 GB (30K photos × 100KB proxy) |
| Database storage | 100 MB | ~30 MB (30K records × 1KB) |
| Daily transfers | 2 GB | ~500 MB peak (initial sync) |
| Records/request | 400 | Batched automatically |

Plenty of headroom for a personal library of 30K+ photos.

---

## Keep Multipeer as Fallback?

**Recommendation:** Keep it for now, disable by default. CloudKit needs internet; Multipeer works offline on local network. Some scenarios where Multipeer is still useful:
- No internet (cabin, airplane)
- Initial bulk sync is faster over local WiFi than CloudKit
- Debugging sync issues

Long term: remove Multipeer once CloudKit is proven reliable.
