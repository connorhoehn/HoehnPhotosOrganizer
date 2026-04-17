import Foundation
import CloudKit

// MARK: - PhotoAsset ↔ CKRecord

extension PhotoAsset {

    /// Convert this local PhotoAsset to a CloudKit record for push.
    public func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: "PhotoAsset", recordID: recordID)

        record["canonicalName"]     = canonicalName as CKRecordValue
        record["role"]              = role as CKRecordValue
        record["filePath"]          = filePath as CKRecordValue
        record["fileSize"]          = fileSize as CKRecordValue
        record["dateModified"]      = dateModified as CKRecordValue?
        record["rawExifJson"]       = rawExifJson as CKRecordValue?
        record["userMetadataJson"]  = userMetadataJson as CKRecordValue?
        record["metadataEdits"]     = metadataEdits as CKRecordValue?
        record["processingState"]   = processingState as CKRecordValue
        record["errorMessage"]      = errorMessage as CKRecordValue?
        record["curationState"]     = curationState as CKRecordValue
        record["syncState"]         = syncState as CKRecordValue
        record["createdAtLocal"]    = createdAt as CKRecordValue
        record["updatedAtLocal"]    = updatedAt as CKRecordValue
        record["fileHash"]          = fileHash as CKRecordValue?
        record["colorProfile"]      = colorProfile as CKRecordValue?
        record["bitDepth"]          = (bitDepth ?? 0) as CKRecordValue
        record["dpiX"]              = (dpiX ?? 0) as CKRecordValue
        record["dpiY"]              = (dpiY ?? 0) as CKRecordValue
        record["hasAlpha"]          = (hasAlpha == true ? 1 : 0) as CKRecordValue
        record["isGrayscale"]       = (isGrayscale == true ? 1 : 0) as CKRecordValue
        record["sceneType"]         = sceneType as CKRecordValue?
        record["peopleDetected"]    = (peopleDetected == true ? 1 : 0) as CKRecordValue
        record["hiddenFromLibrary"] = (hiddenFromLibrary ? 1 : 0) as CKRecordValue
        record["importStatus"]      = importStatus as CKRecordValue

        // Proxy JPEG: just the URL mapping — asset creation deferred to Phase D
        record["proxyPath"]         = proxyPath as CKRecordValue?
        record["sourceDriveUUID"]   = sourceDriveUUID as CKRecordValue?
        record["sourceDrivePath"]   = sourceDrivePath as CKRecordValue?

        return record
    }

    /// Create a PhotoAsset from a CloudKit record pulled from iCloud.
    public static func from(record: CKRecord) -> PhotoAsset {
        PhotoAsset(
            id:                           record.recordID.recordName,
            canonicalName:                record["canonicalName"] as? String ?? "",
            role:                         record["role"] as? String ?? "original",
            filePath:                     record["filePath"] as? String ?? "",
            fileSize:                     record["fileSize"] as? Int ?? 0,
            dateModified:                 record["dateModified"] as? String,
            rawExifJson:                  record["rawExifJson"] as? String,
            userMetadataJson:             record["userMetadataJson"] as? String,
            metadataEdits:                record["metadataEdits"] as? String,
            processingState:              record["processingState"] as? String ?? "indexed",
            errorMessage:                 record["errorMessage"] as? String,
            curationState:                record["curationState"] as? String ?? "needs_review",
            syncState:                    record["syncState"] as? String ?? "synced",
            createdAt:                    record["createdAtLocal"] as? String ?? ISO8601DateFormatter().string(from: .now),
            updatedAt:                    record["updatedAtLocal"] as? String ?? ISO8601DateFormatter().string(from: .now),
            fileHash:                     record["fileHash"] as? String,
            colorProfile:                 record["colorProfile"] as? String,
            bitDepth:                     (record["bitDepth"] as? Int).flatMap { $0 == 0 ? nil : $0 },
            dpiX:                         (record["dpiX"] as? Double).flatMap { $0 == 0 ? nil : $0 },
            dpiY:                         (record["dpiY"] as? Double).flatMap { $0 == 0 ? nil : $0 },
            hasAlpha:                     (record["hasAlpha"] as? Int).map { $0 != 0 },
            isGrayscale:                  (record["isGrayscale"] as? Int).map { $0 != 0 },
            sceneType:                    record["sceneType"] as? String,
            peopleDetected:               (record["peopleDetected"] as? Int).map { $0 != 0 },
            sceneClassificationMetadata:  record["sceneClassificationMetadata"] as? String,
            hiddenFromLibrary:            (record["hiddenFromLibrary"] as? Int).map { $0 != 0 } ?? false,
            faceIndexedAt:                record["faceIndexedAt"] as? String,
            proxyPath:                    record["proxyPath"] as? String,
            sourceDriveUUID:              record["sourceDriveUUID"] as? String,
            sourceDrivePath:              record["sourceDrivePath"] as? String,
            importStatus:                 record["importStatus"] as? String ?? "staged"
        )
    }
}

// MARK: - PersonIdentity ↔ CKRecord

extension PersonIdentity {

    public func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: "PersonIdentity", recordID: recordID)

        record["name"]                = name as CKRecordValue
        record["coverFaceEmbeddingId"] = coverFaceEmbeddingId as CKRecordValue?
        record["createdAtLocal"]      = createdAt as CKRecordValue

        return record
    }

    public static func from(record: CKRecord) -> PersonIdentity {
        PersonIdentity(
            id:                   record.recordID.recordName,
            name:                 record["name"] as? String ?? "",
            coverFaceEmbeddingId: record["coverFaceEmbeddingId"] as? String,
            createdAt:            record["createdAtLocal"] as? String ?? ISO8601DateFormatter().string(from: .now)
        )
    }
}

// MARK: - FaceEmbedding ↔ CKRecord

extension FaceEmbedding {

    /// Convert to CKRecord. Note: `featureData` (embedding vector) is intentionally omitted
    /// per the sync plan — too large, not needed on iOS.
    public func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: "FaceEmbedding", recordID: recordID)

        record["photoId"]     = photoId as CKRecordValue
        record["faceIndex"]   = faceIndex as CKRecordValue
        record["bboxX"]       = bboxX as CKRecordValue
        record["bboxY"]       = bboxY as CKRecordValue
        record["bboxWidth"]   = bboxWidth as CKRecordValue
        record["bboxHeight"]  = bboxHeight as CKRecordValue
        record["createdAtLocal"] = createdAt as CKRecordValue
        record["personId"]    = personId as CKRecordValue?
        record["labeledBy"]   = labeledBy as CKRecordValue?
        record["needsReview"] = (needsReview ? 1 : 0) as CKRecordValue

        // CKReference for parent photo
        let photoRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: photoId, zoneID: zoneID),
            action: .deleteSelf
        )
        record["photoRef"] = photoRef

        // Optional person reference
        if let pid = personId {
            let personRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: pid, zoneID: zoneID),
                action: .none
            )
            record["personRef"] = personRef
        }

        return record
    }

    public static func from(record: CKRecord) -> FaceEmbedding {
        FaceEmbedding(
            id:         record.recordID.recordName,
            photoId:    record["photoId"] as? String ?? "",
            faceIndex:  record["faceIndex"] as? Int ?? 0,
            bboxX:      record["bboxX"] as? Double ?? 0,
            bboxY:      record["bboxY"] as? Double ?? 0,
            bboxWidth:  record["bboxWidth"] as? Double ?? 0,
            bboxHeight: record["bboxHeight"] as? Double ?? 0,
            featureData: nil,  // intentionally not synced
            createdAt:  record["createdAtLocal"] as? String ?? ISO8601DateFormatter().string(from: .now),
            personId:   record["personId"] as? String,
            labeledBy:  record["labeledBy"] as? String,
            needsReview: (record["needsReview"] as? Int).map { $0 != 0 } ?? false
        )
    }
}

// MARK: - TriageJob ↔ CKRecord

extension TriageJob {

    public func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: "TriageJob", recordID: recordID)

        record["title"]              = title as CKRecordValue
        record["source"]             = source.rawValue as CKRecordValue
        record["status"]             = status.rawValue as CKRecordValue
        record["inheritedMetadata"]  = inheritedMetadata as CKRecordValue?
        record["completenessScore"]  = completenessScore as CKRecordValue
        record["photoCount"]         = photoCount as CKRecordValue
        record["currentMilestone"]   = currentMilestone.rawValue as CKRecordValue
        record["triageCompletedAt"]  = triageCompletedAt as CKRecordValue?
        record["developCompletedAt"] = developCompletedAt as CKRecordValue?
        record["createdAtLocal"]     = createdAt as CKRecordValue
        record["updatedAtLocal"]     = updatedAt as CKRecordValue
        record["completedAt"]        = completedAt as CKRecordValue?

        // Parent job reference
        if let parentId = parentJobId {
            let parentRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: parentId, zoneID: zoneID),
                action: .none
            )
            record["parentJobRef"] = parentRef
        }

        return record
    }

    public static func from(record: CKRecord) -> TriageJob {
        let formatter = ISO8601DateFormatter()
        return TriageJob(
            id:                 record.recordID.recordName,
            parentJobId:        (record["parentJobRef"] as? CKRecord.Reference)?.recordID.recordName,
            title:              record["title"] as? String ?? "",
            source:             TriageJobSource(rawValue: record["source"] as? String ?? "manual") ?? .manual,
            status:             TriageJobStatus(rawValue: record["status"] as? String ?? "open") ?? .open,
            inheritedMetadata:  record["inheritedMetadata"] as? String,
            completenessScore:  record["completenessScore"] as? Double ?? 0,
            photoCount:         record["photoCount"] as? Int ?? 0,
            currentMilestone:   JobMilestone(rawValue: record["currentMilestone"] as? String ?? "triage") ?? .triage,
            triageCompletedAt:  record["triageCompletedAt"] as? Date,
            developCompletedAt: record["developCompletedAt"] as? Date,
            createdAt:          record["createdAtLocal"] as? Date ?? Date(),
            updatedAt:          record["updatedAtLocal"] as? Date ?? Date(),
            completedAt:        record["completedAt"] as? Date
        )
    }
}

// MARK: - ActivityEvent ↔ CKRecord

extension ActivityEvent {

    public func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: "ActivityEvent", recordID: recordID)

        record["kind"]             = kind.rawValue as CKRecordValue
        record["parentEventId"]    = parentEventId as CKRecordValue?
        record["title"]            = title as CKRecordValue
        record["detail"]           = detail as CKRecordValue?
        record["metadata"]         = metadata as CKRecordValue?
        record["occurredAt"]       = occurredAt as CKRecordValue
        record["createdAtLocal"]   = createdAt as CKRecordValue
        record["savedSearchRuleId"] = savedSearchRuleId as CKRecordValue?

        // Photo reference
        if let photoId = photoAssetId {
            let photoRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: photoId, zoneID: zoneID),
                action: .none
            )
            record["photoRef"] = photoRef
        }

        return record
    }

    public static func from(record: CKRecord) -> ActivityEvent {
        ActivityEvent(
            id:                record.recordID.recordName,
            kind:              ActivityEventKind(rawValue: record["kind"] as? String ?? "note") ?? .note,
            parentEventId:     record["parentEventId"] as? String,
            photoAssetId:      (record["photoRef"] as? CKRecord.Reference)?.recordID.recordName,
            title:             record["title"] as? String ?? "",
            detail:            record["detail"] as? String,
            metadata:          record["metadata"] as? String,
            occurredAt:        record["occurredAt"] as? Date ?? Date(),
            createdAt:         record["createdAtLocal"] as? Date ?? Date(),
            savedSearchRuleId: record["savedSearchRuleId"] as? String
        )
    }
}

// MARK: - StudioRevision ↔ CKRecord

extension StudioRevision {

    public func toCKRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: "StudioRevision", recordID: recordID)

        record["name"]          = name as CKRecordValue
        record["medium"]        = medium as CKRecordValue
        record["paramsJson"]    = paramsJson as CKRecordValue
        record["createdAtLocal"] = createdAt as CKRecordValue

        // Thumbnail: URL mapping only — CKAsset creation deferred to Phase D
        record["thumbnailPath"] = thumbnailPath as CKRecordValue?
        record["fullResPath"]   = fullResPath as CKRecordValue?

        // Photo reference
        let photoRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: photoId, zoneID: zoneID),
            action: .deleteSelf
        )
        record["photoRef"] = photoRef

        return record
    }

    public static func from(record: CKRecord) -> StudioRevision {
        StudioRevision(
            id:             record.recordID.recordName,
            photoId:        (record["photoRef"] as? CKRecord.Reference)?.recordID.recordName ?? "",
            name:           record["name"] as? String ?? "",
            medium:         record["medium"] as? String ?? "Oil Painting",
            paramsJson:     record["paramsJson"] as? String ?? "{}",
            createdAt:      record["createdAtLocal"] as? String ?? ISO8601DateFormatter().string(from: .now),
            thumbnailPath:  record["thumbnailPath"] as? String,
            fullResPath:    record["fullResPath"] as? String
        )
    }
}
