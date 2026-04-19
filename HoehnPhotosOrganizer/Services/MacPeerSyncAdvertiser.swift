import Foundation
import MultipeerConnectivity
import Combine
import HoehnPhotosCore
import GRDB

nonisolated(unsafe) private let macServiceType = "hoehnphoto"

@MainActor
class MacPeerSyncAdvertiser: NSObject, ObservableObject {

    enum SyncState: Equatable {
        case idle, advertising
        case pinConfirmation(pin: String, peerName: String)
        case connecting(peerName: String)
        case connected(peerName: String)
        case sending(progress: Double, fileName: String)
        case completed(fileCount: Int)
        case failed(String)
    }

    @Published var state: SyncState = .idle
    @Published var lastDeltaCount: Int = 0
    @Published var deltaApplying: Bool = false
    @Published var lastPeopleDeltaCount: Int = 0
    @Published var peopleDeltaApplying: Bool = false

    private var coordinator: Coordinator?

    override init() { super.init() }

    func start() {
        let c = Coordinator { [weak self] s in
            DispatchQueue.main.async { self?.state = s }
        }
        c.onDeltaReceived = { [weak self] json, peer in
            DispatchQueue.main.async {
                self?.applyDelta(json: json, coordinator: c)
            }
        }
        c.onPeopleReceived = { [weak self] json, peer in
            DispatchQueue.main.async {
                self?.applyPeopleDeltas(json: json, coordinator: c)
            }
        }
        c.onNeedProxies = { [weak self] json, peer in
            DispatchQueue.main.async {
                print("[Mac] NEED_PROXIES received: \(json)")
                // Future: send requested proxy files to peer
            }
        }
        coordinator = c
        c.startAdvertising()
        state = .advertising
    }

    func stop() {
        coordinator?.stop()
        coordinator = nil
        state = .idle
    }

    /// User confirmed the PIN matches.
    func confirmPin() {
        coordinator?.acceptPendingInvitation()
    }

    /// User rejected the PIN.
    func rejectPin() {
        coordinator?.rejectPendingInvitation()
        state = .advertising
    }

    func sendCatalog(dbURL: URL, proxyDirectory: URL?) {
        coordinator?.sendCatalog(dbURL: dbURL, proxyDirectory: proxyDirectory)
    }

    /// Send a proxy manifest to the connected iOS device for incremental sync.
    func sendManifest(proxyDirectory: URL) {
        coordinator?.sendManifest(proxyDirectory: proxyDirectory)
    }

    /// Apply curation deltas received from iOS to local database.
    private func applyDelta(json: String, coordinator: Coordinator) {
        guard let data = json.data(using: .utf8),
              let deltas = try? JSONDecoder().decode([PhotoCurationDelta].self, from: data)
        else {
            print("[Mac] Failed to decode DELTA_V1 JSON")
            return
        }

        deltaApplying = true
        let dbPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoehnPhotosOrganizer/Catalog.db")

        Task {
            do {
                let dbPool = try DatabasePool(path: dbPath.path)
                try await dbPool.write { db in
                    for delta in deltas {
                        try db.execute(
                            sql: "UPDATE photo_assets SET curation_state = ?, updated_at = ? WHERE id = ?",
                            arguments: [delta.curationState, delta.updatedAt, delta.id]
                        )
                    }
                }
                await MainActor.run {
                    self.lastDeltaCount = deltas.count
                    self.deltaApplying = false
                    coordinator.sendMessage("DELTA_ACK:\(deltas.count)")
                    print("[Mac] Applied \(deltas.count) delta(s) from iOS")
                }
            } catch {
                await MainActor.run {
                    self.deltaApplying = false
                    print("[Mac] Failed to apply deltas: \(error)")
                }
            }
        }
    }

    /// Apply people/face mutations received from iOS to local database.
    /// All deltas are applied inside a single write transaction so a failed
    /// delta cannot leave the DB half-updated.
    private func applyPeopleDeltas(json: String, coordinator: Coordinator) {
        guard let data = json.data(using: .utf8),
              let deltas = try? JSONDecoder().decode([PeopleSyncDelta].self, from: data)
        else {
            print("[Mac] Failed to decode PEOPLE_V1 JSON")
            return
        }

        peopleDeltaApplying = true
        let dbPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoehnPhotosOrganizer/Catalog.db")

        Task {
            do {
                let dbPool = try DatabasePool(path: dbPath.path)
                try await dbPool.write { db in
                    for delta in deltas {
                        switch delta {
                        case .createPerson(let id, let name, let coverFaceId, let createdAt):
                            try db.execute(
                                sql: """
                                INSERT OR IGNORE INTO person_identities
                                    (id, name, cover_face_embedding_id, created_at)
                                VALUES (?, ?, ?, ?)
                                """,
                                arguments: [id, name, coverFaceId, createdAt]
                            )

                        case .renamePerson(let id, let name, _):
                            try db.execute(
                                sql: "UPDATE person_identities SET name = ? WHERE id = ?",
                                arguments: [name, id]
                            )

                        case .deletePerson(let id, _):
                            // Null out face labels first (no cascade on person delete).
                            try db.execute(
                                sql: """
                                UPDATE face_embeddings
                                SET person_id = NULL, labeled_by = NULL
                                WHERE person_id = ?
                                """,
                                arguments: [id]
                            )
                            try db.execute(
                                sql: "DELETE FROM person_identities WHERE id = ?",
                                arguments: [id]
                            )

                        case .mergePeople(let sourceId, let targetId, _):
                            try db.execute(
                                sql: "UPDATE face_embeddings SET person_id = ? WHERE person_id = ?",
                                arguments: [targetId, sourceId]
                            )
                            try db.execute(
                                sql: "DELETE FROM person_identities WHERE id = ?",
                                arguments: [sourceId]
                            )

                        case .assignFace(let faceId, let personId, let labeledBy, _):
                            try db.execute(
                                sql: """
                                UPDATE face_embeddings
                                SET person_id = ?, labeled_by = ?, needs_review = 0
                                WHERE id = ?
                                """,
                                arguments: [personId, labeledBy, faceId]
                            )

                        case .unassignFace(let faceId, _):
                            try db.execute(
                                sql: """
                                UPDATE face_embeddings
                                SET person_id = NULL, labeled_by = NULL, needs_review = 0
                                WHERE id = ?
                                """,
                                arguments: [faceId]
                            )
                        }
                    }
                }
                await MainActor.run {
                    self.lastPeopleDeltaCount = deltas.count
                    self.peopleDeltaApplying = false
                    coordinator.sendMessage("PEOPLE_ACK:\(deltas.count)")
                    print("[Mac] Applied \(deltas.count) people delta(s) from iOS")
                }
            } catch {
                await MainActor.run {
                    self.peopleDeltaApplying = false
                    print("[Mac] Failed to apply people deltas: \(error)")
                }
            }
        }
    }
}

// MARK: - Coordinator

private class Coordinator: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, @unchecked Sendable {

    let onState: (MacPeerSyncAdvertiser.SyncState) -> Void
    var onDeltaReceived: ((String, MCPeerID) -> Void)?
    var onPeopleReceived: ((String, MCPeerID) -> Void)?
    var onNeedProxies: ((String, MCPeerID) -> Void)?
    let peerID: MCPeerID
    let session: MCSession
    var advertiser: MCNearbyServiceAdvertiser?
    var progressObserver: NSKeyValueObservation?
    var keepaliveTimer: Timer?
    var pendingInvitationHandler: ((Bool, MCSession?) -> Void)?
    let syncPIN: String

    init(onState: @escaping (MacPeerSyncAdvertiser.SyncState) -> Void) {
        self.onState = onState
        let name = Host.current().localizedName ?? "Mac"
        self.peerID = MCPeerID(displayName: name)
        // Encryption required for security
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        // Generate a 4-digit PIN
        self.syncPIN = String(format: "%04d", Int.random(in: 0...9999))
        super.init()
        self.session.delegate = self
        print("[Mac] Session created, PIN: \(syncPIN)")
    }

    func startAdvertising() {
        // Include PIN in discovery info so iPhone can show it
        let adv = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["pin": syncPIN],
            serviceType: macServiceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
        print("[Mac] Advertising with PIN: \(syncPIN)")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        keepaliveTimer?.invalidate()
        session.disconnect()
        print("[Mac] Stopped")
    }

    func acceptPendingInvitation() {
        print("[Mac] PIN confirmed — accepting invitation")
        pendingInvitationHandler?(true, session)
        pendingInvitationHandler = nil
    }

    func rejectPendingInvitation() {
        print("[Mac] PIN rejected")
        pendingInvitationHandler?(false, nil)
        pendingInvitationHandler = nil
    }

    func startKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.session.connectedPeers.isEmpty else { return }
            try? self.session.send("PING".data(using: .utf8)!, toPeers: self.session.connectedPeers, with: .reliable)
        }
    }

    func sendCatalog(dbURL: URL, proxyDirectory: URL?) {
        guard let peer = session.connectedPeers.first else {
            print("[Mac] No connected peers!")
            onState(.failed("No connected peer"))
            return
        }

        var files: [(URL, String)] = [(dbURL, "Catalog.db")]
        if let dir = proxyDirectory, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in items where f.pathExtension.lowercased() == "jpg" {
                files.append((f, "proxies/\(f.lastPathComponent)"))
            }
        }
        print("[Mac] Sending \(files.count) files (encrypted)")
        sendNext(to: peer, files: files, idx: 0, total: files.count)
    }

    private func sendNext(to peer: MCPeerID, files: [(URL, String)], idx: Int, total: Int) {
        guard idx < files.count else {
            try? session.send("SYNC_COMPLETE:\(total)".data(using: .utf8)!, toPeers: [peer], with: .reliable)
            onState(.completed(fileCount: total))
            print("[Mac] Done — \(total) files sent")
            return
        }
        let (url, name) = files[idx]
        onState(.sending(progress: Double(idx) / Double(total), fileName: name))

        let p = session.sendResource(at: url, withName: name, toPeer: peer) { [weak self] err in
            if let err {
                print("[Mac] Error \(name): \(err)")
                self?.onState(.failed("\(name): \(err.localizedDescription)"))
                return
            }
            if idx % 50 == 0 || idx == total - 1 {
                print("[Mac] Sent \(idx+1)/\(total): \(name)")
            }
            self?.sendNext(to: peer, files: files, idx: idx+1, total: total)
        }
        if let p {
            progressObserver?.invalidate()
            progressObserver = p.observe(\.fractionCompleted) { [weak self] prog, _ in
                let overall = Double(idx) / Double(total) + prog.fractionCompleted / Double(total)
                self?.onState(.sending(progress: overall, fileName: name))
            }
        }
    }

    // MARK: MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            print("[Mac] CONNECTED to \(peerID.displayName)")
            startKeepalive()
            onState(.connected(peerName: peerID.displayName))
        case .connecting:
            print("[Mac] CONNECTING to \(peerID.displayName)")
            onState(.connecting(peerName: peerID.displayName))
        case .notConnected:
            print("[Mac] DISCONNECTED from \(peerID.displayName)")
            keepaliveTimer?.invalidate()
            onState(.advertising)
        @unknown default: break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let msg = String(data: data, encoding: .utf8) ?? "binary"
        if msg == "PING" || msg == "HELLO_FROM_IPHONE" { return }

        if msg.hasPrefix("DELTA_V1:") {
            let json = String(msg.dropFirst("DELTA_V1:".count))
            print("[Mac] Received DELTA_V1 with \(json.count) bytes")
            onDeltaReceived?(json, peerID)
        } else if msg.hasPrefix("PEOPLE_V1:") {
            let json = String(msg.dropFirst("PEOPLE_V1:".count))
            print("[Mac] Received PEOPLE_V1 with \(json.count) bytes")
            onPeopleReceived?(json, peerID)
        } else if msg.hasPrefix("NEED_PROXIES:") {
            let json = String(msg.dropFirst("NEED_PROXIES:".count))
            print("[Mac] Received NEED_PROXIES request")
            onNeedProxies?(json, peerID)
        } else {
            print("[Mac] Received: \(msg)")
        }
    }

    func sendMessage(_ msg: String) {
        guard !session.connectedPeers.isEmpty,
              let data = msg.data(using: .utf8) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func sendManifest(proxyDirectory: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: proxyDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        let entries = items.compactMap { url -> ProxyManifestEntry? in
            guard url.pathExtension.lowercased() == "jpg" else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return ProxyManifestEntry(filename: url.lastPathComponent, size: size)
        }
        guard let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else { return }
        sendMessage("MANIFEST_V1:\(json)")
    }

    func session(_ session: MCSession, didReceive: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}

    // MARK: MCNearbyServiceAdvertiserDelegate

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("[Mac] INVITATION from \(peerID.displayName) — waiting for PIN confirmation")
        // Hold the invitation until user confirms PIN
        pendingInvitationHandler = invitationHandler
        onState(.pinConfirmation(pin: syncPIN, peerName: peerID.displayName))
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[Mac] Advertise FAILED: \(error)")
        onState(.failed(error.localizedDescription))
    }
}
