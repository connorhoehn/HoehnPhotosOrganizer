import Foundation
import MultipeerConnectivity
import Combine
#if canImport(UIKit)
import UIKit
#endif

nonisolated(unsafe) private let iosServiceType = "hoehnphoto"

@MainActor
public class PeerSyncService: NSObject, ObservableObject {

    public enum SyncState: Equatable {
        case idle, searching
        case connecting(peerName: String)
        case connected(peerName: String)
        case receiving(progress: Double, fileName: String)
        case completed(fileCount: Int)
        case failed(String)
    }

    @Published public var state: SyncState = .idle
    @Published public var discoveredPeers: [MCPeerID] = []
    @Published public var peerPINs: [String: String] = [:]  // peerDisplayName → PIN
    @Published public var lastMessage: String = ""

    // Delta queue — persisted via UserDefaults, managed here
    @Published public var pendingDeltas: [PhotoCurationDelta] = []
    private var deltaFlushTimer: Timer?

    private var coordinator: Coordinator?

    public override init() {
        super.init()
        loadPendingDeltas()
    }

    public func start() {
        let c = Coordinator(
            onState: { [weak self] s in
                DispatchQueue.main.async {
                    self?.state = s
                    if case .connected = s {
                        self?.loadPendingDeltas()
                        // Flush after a short delay to let connection stabilize
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self?.flushDeltas()
                        }
                    }
                }
            },
            onPeerFound: { [weak self] p, pin in DispatchQueue.main.async {
                if !(self?.discoveredPeers.contains(p) ?? true) { self?.discoveredPeers.append(p) }
                if let pin { self?.peerPINs[p.displayName] = pin }
            }},
            onPeerLost: { [weak self] p in DispatchQueue.main.async {
                self?.discoveredPeers.removeAll { $0 == p }
                self?.peerPINs.removeValue(forKey: p.displayName)
            }},
            onMessage: { [weak self] m in DispatchQueue.main.async { self?.lastMessage = m } }
        )
        c.onManifestReceived = { [weak self] json, peer in
            DispatchQueue.main.async {
                self?.handleManifest(json: json, peer: peer)
            }
        }
        c.onDeltaAcknowledged = { [weak self] count in
            DispatchQueue.main.async {
                self?.clearPendingDeltas()
            }
        }
        coordinator = c
        c.startBrowsing()
        state = .searching
    }

    public func stop() {
        coordinator?.stop()
        coordinator = nil
        discoveredPeers.removeAll()
        state = .idle
    }

    public func connect(to peer: MCPeerID) {
        coordinator?.invite(peer: peer)
        state = .connecting(peerName: peer.displayName)
    }

    // MARK: - Delta Queue

    /// Call this when user changes curation on iOS. Adds to queue and auto-flushes if connected.
    public func enqueueDelta(_ delta: PhotoCurationDelta) {
        // Remove any existing delta for same photo (latest wins)
        pendingDeltas.removeAll { $0.id == delta.id }
        pendingDeltas.append(delta)
        savePendingDeltas()

        // Auto-flush 3 seconds after change if connected (D-32)
        deltaFlushTimer?.invalidate()
        if case .connected = state {
            deltaFlushTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.flushDeltas() }
            }
        }
    }

    /// Send all pending deltas to connected Mac as DELTA_V1:{json}
    public func flushDeltas() {
        guard !pendingDeltas.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(pendingDeltas),
              let json = String(data: data, encoding: .utf8) else { return }
        let msg = "DELTA_V1:\(json)"
        coordinator?.sendMessage(msg)
    }

    /// Persistence helpers using UserDefaults
    private func savePendingDeltas() {
        if let data = try? JSONEncoder().encode(pendingDeltas),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: "pendingCurationDeltas")
        }
    }

    public func loadPendingDeltas() {
        if let json = UserDefaults.standard.string(forKey: "pendingCurationDeltas"),
           let data = json.data(using: .utf8),
           let deltas = try? JSONDecoder().decode([PhotoCurationDelta].self, from: data) {
            pendingDeltas = deltas
        }
    }

    private func clearPendingDeltas() {
        pendingDeltas.removeAll()
        UserDefaults.standard.removeObject(forKey: "pendingCurationDeltas")
    }

    // MARK: - Manifest Handling

    private func handleManifest(json: String, peer: MCPeerID) {
        guard let data = json.data(using: .utf8),
              let manifest = try? JSONDecoder().decode([ProxyManifestEntry].self, from: data)
        else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let proxiesDir = appSupport.appendingPathComponent("HoehnPhotos/proxies")
        let localFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: proxiesDir.path)) ?? [])

        let needed = manifest.filter { !localFiles.contains($0.filename) }.map(\.filename)

        if let needData = try? JSONEncoder().encode(needed),
           let needJSON = String(data: needData, encoding: .utf8) {
            coordinator?.sendMessage("NEED_PROXIES:\(needJSON)")
        }
    }
}

// MARK: - Coordinator

private class Coordinator: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, @unchecked Sendable {

    let onState: (PeerSyncService.SyncState) -> Void
    let onPeerFound: (MCPeerID, String?) -> Void  // peer + optional PIN
    let onPeerLost: (MCPeerID) -> Void
    let onMessage: (String) -> Void

    var onManifestReceived: ((String, MCPeerID) -> Void)?
    var onDeltaAcknowledged: ((Int) -> Void)?

    let peerID: MCPeerID
    let session: MCSession
    var browser: MCNearbyServiceBrowser?
    var progressObserver: NSKeyValueObservation?
    var receivedCount = 0
    var keepaliveTimer: Timer?

    init(onState: @escaping (PeerSyncService.SyncState) -> Void,
         onPeerFound: @escaping (MCPeerID, String?) -> Void,
         onPeerLost: @escaping (MCPeerID) -> Void,
         onMessage: @escaping (String) -> Void) {
        self.onState = onState
        self.onPeerFound = onPeerFound
        self.onPeerLost = onPeerLost
        self.onMessage = onMessage
        #if os(macOS)
        let name = Host.current().localizedName ?? "Device"
        #else
        let name = UIDevice.current.name
        #endif
        self.peerID = MCPeerID(displayName: name)
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        super.init()
        self.session.delegate = self
        print("[iOS] Session created for: \(name)")
    }

    func startBrowsing() {
        let br = MCNearbyServiceBrowser(peer: peerID, serviceType: iosServiceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
        print("[iOS] Browsing for: \(iosServiceType)")
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        session.disconnect()
        print("[iOS] Stopped")
    }

    func invite(peer: MCPeerID) {
        print("[iOS] Inviting: \(peer.displayName)")
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
    }

    // MARK: MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            print("[iOS] CONNECTED to \(peerID.displayName)")
            let reply = "HELLO_FROM_IPHONE".data(using: .utf8)!
            try? session.send(reply, toPeers: [peerID], with: .reliable)
            print("[iOS] Sent hello back")
            // Start keepalive pings
            keepaliveTimer?.invalidate()
            keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self, !self.session.connectedPeers.isEmpty else { return }
                try? self.session.send("PING".data(using: .utf8)!, toPeers: self.session.connectedPeers, with: .reliable)
            }
            onState(.connected(peerName: peerID.displayName))
        case .connecting:
            print("[iOS] CONNECTING to \(peerID.displayName)")
            onState(.connecting(peerName: peerID.displayName))
        case .notConnected:
            print("[iOS] DISCONNECTED from \(peerID.displayName)")
            keepaliveTimer?.invalidate()
            onState(.idle)
        @unknown default: break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let msg = String(data: data, encoding: .utf8) ?? "(binary)"
        print("[iOS] Data from \(peerID.displayName): \(msg)")
        onMessage(msg)

        if msg.hasPrefix("SYNC_COMPLETE:") {
            let count = Int(msg.replacingOccurrences(of: "SYNC_COMPLETE:", with: "")) ?? 0
            onState(.completed(fileCount: count))
        } else if msg.hasPrefix("MANIFEST_V1:") {
            let json = String(msg.dropFirst("MANIFEST_V1:".count))
            onManifestReceived?(json, peerID)
        } else if msg.hasPrefix("DELTA_ACK:") {
            let count = Int(String(msg.dropFirst("DELTA_ACK:".count))) ?? 0
            onDeltaAcknowledged?(count)
        }
    }

    func sendMessage(_ msg: String) {
        guard !session.connectedPeers.isEmpty,
              let data = msg.data(using: .utf8) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func session(_ session: MCSession, didReceive: InputStream, withName: String, fromPeer: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer: MCPeerID, with progress: Progress) {
        print("[iOS] Receiving: \(name)")
        progressObserver?.invalidate()
        progressObserver = progress.observe(\.fractionCompleted) { [weak self] p, _ in
            self?.onState(.receiving(progress: p.fractionCompleted, fileName: name))
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let error {
            print("[iOS] Receive ERROR \(name): \(error)")
            onState(.failed("\(name): \(error.localizedDescription)"))
            return
        }
        guard let localURL else { return }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoehnPhotos")
        let dest: URL
        if name == "Catalog.db" {
            // Stage the DB to a separate file — don't overwrite the live one
            // AppDatabase.reload() will swap to this file
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            dest = base.appendingPathComponent("Catalog-synced.db")
        } else if name.hasPrefix("proxies/") {
            let dir = base.appendingPathComponent("proxies")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            dest = dir.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        } else {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            dest = base.appendingPathComponent(name)
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: localURL, to: dest)
            receivedCount += 1
            print("[iOS] Saved \(receivedCount): \(name)")
        } catch {
            print("[iOS] Move failed \(name): \(error)")
        }
    }

    // MARK: MCNearbyServiceBrowserDelegate

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let pin = info?["pin"]
        print("[iOS] FOUND: \(peerID.displayName) (PIN: \(pin ?? "none"))")
        onPeerFound(peerID, pin)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("[iOS] LOST: \(peerID.displayName)")
        onPeerLost(peerID)
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[iOS] Browse FAILED: \(error)")
        onState(.failed(error.localizedDescription))
    }
}
