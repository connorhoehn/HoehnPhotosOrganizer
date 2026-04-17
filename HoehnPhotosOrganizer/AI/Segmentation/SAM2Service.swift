import AppKit
import CoreGraphics
import CoreImage
import Foundation

// MARK: - Segment (single mask from segment-everything)

struct SAM2Segment: Codable, Identifiable {
    let id: Int
    /// RLE-encoded mask: {"counts": [run_lengths], "start": 0|1, "width": N, "height": N}
    let rle: RLEMask
    let score: Float
    let area: Int
    let bbox: [Int]?          // [x, y, w, h] in working-image pixels
    let stability: Float?

    struct RLEMask: Codable {
        let counts: [Int]
        let start: Int
        let width: Int
        let height: Int
    }

    /// Decode RLE mask to raw pixel array (0 or 255).
    func decodePixels() -> [UInt8] {
        var pixels = [UInt8]()
        pixels.reserveCapacity(rle.width * rle.height)
        var currentValue: UInt8 = rle.start == 1 ? 255 : 0
        for count in rle.counts {
            pixels.append(contentsOf: repeatElement(currentValue, count: count))
            currentValue = currentValue == 0 ? 255 : 0
        }
        // Pad if needed
        let total = rle.width * rle.height
        while pixels.count < total { pixels.append(0) }
        if pixels.count > total { pixels = Array(pixels.prefix(total)) }
        return pixels
    }

    /// Render mask as blue-tinted RGBA NSImage for overlay display.
    func renderOverlay(isSelected: Bool, color: (UInt8, UInt8, UInt8)? = nil) -> NSImage? {
        let pixels = decodePixels()
        let w = rle.width
        let h = rle.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let alpha: UInt8 = isSelected ? 150 : 90
        let c = color ?? (60, 120, 255)  // default blue

        for i in 0..<(w * h) {
            if pixels[i] > 0 {
                rgba[i * 4 + 0] = c.0
                rgba[i * 4 + 1] = c.1
                rgba[i * 4 + 2] = c.2
                rgba[i * 4 + 3] = alpha
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
    }

    /// Convert to a MaskSourceType bitmap for the adjustment layer pipeline.
    func toMaskSourceType() -> MaskSourceType {
        let pixels = decodePixels()
        return .bitmap(rle: Data(pixels), width: rle.width, height: rle.height)
    }
}

// MARK: - SAM2Service (Python Sidecar)

/// Actor that manages a Python SAM2 subprocess for segmentation.
///
/// Protocol: JSON over stdin/stdout.
/// - Launch Python process → wait for {"status": "ready"}
/// - Encode image → {"action": "encode", "image_path": "..."}
/// - Segment everything → {"action": "segment_all"} → get all masks
/// - Segment at point → {"action": "segment_point", "x": 0.5, "y": 0.3}
actor SAM2Service {

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var isReady = false
    private var encodedImageSize: CGSize = .zero

    // MARK: - Python Environment

    private static let venvDir = "/Users/connorhoehn/Projects/segment-anything-2/.venv"
    private static let scriptPath = "/Users/connorhoehn/Projects/filmstrip_yolov8/sam2_service.py"

    /// Resolve the venv Python to a real binary that Process() can execute.
    /// Uses shell `realpath` to follow ALL symlinks to the actual Mach-O binary.
    private static func resolveVenvPython() -> String {
        // Use realpath via shell to resolve the full symlink chain
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/readlink")
        // Note: macOS readlink doesn't have -f, but python3 -c works
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        // Try /usr/bin/stat -f to get real path, or fall back to known Cellar path
        let knownPaths = [
            "/opt/homebrew/Cellar/python@3.12/3.12.11/Frameworks/Python.framework/Versions/3.12/bin/python3.12",
            "/opt/homebrew/Cellar/python@3.12/3.12.11/bin/python3.12",
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        for path in knownPaths {
            let url = URL(fileURLWithPath: path)
            // Check if this is a real file (not a broken symlink)
            if let reachable = try? url.checkResourceIsReachable(), reachable {
                return path
            }
        }

        return "/opt/homebrew/bin/python3.12"  // fallback
    }

    // MARK: - Lifecycle

    /// Launch the Python SAM2 process. Blocks until "ready" is received (~5-10s model load).
    func launch() async throws {
        guard process == nil else { return }

        // Resolve the real Python binary by following venv symlinks
        let resolvedPython = Self.resolveVenvPython()
        print("[SAM2Service] Resolved Python: \(resolvedPython)")
        print("[SAM2Service] Script: \(Self.scriptPath)")
        print("[SAM2Service] File exists: \(FileManager.default.fileExists(atPath: resolvedPython))")

        let proc = Process()
        // Use launchPath (legacy API) which handles symlinks better than executableURL
        proc.launchPath = resolvedPython
        proc.arguments = [Self.scriptPath]

        // Set up environment so the venv packages are found
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = Self.venvDir
        env["PATH"] = Self.venvDir + "/bin:" + (env["PATH"] ?? "/usr/bin")
        // Python needs site-packages from the venv + editable SAM2 source
        let sitePackages = Self.venvDir + "/lib/python3.12/site-packages"
        let sam2Source = "/Users/connorhoehn/Projects/segment-anything-2"
        env["PYTHONPATH"] = sitePackages + ":" + sam2Source
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Log stderr to console
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if let str = String(data: handle.availableData, encoding: .utf8), !str.isEmpty {
                print("[SAM2-py] \(str)", terminator: "")
            }
        }

        // Verify Python binary is executable before launch (sandbox may block)
        guard FileManager.default.isExecutableFile(atPath: resolvedPython) else {
            throw SAM2Error.launchFailed("Python at \(resolvedPython) is not executable (sandbox?). Use Auto-Segment (Apple Vision) instead.")
        }

        proc.launch()
        process = proc
        stdin = stdinPipe.fileHandleForWriting
        stdout = stdoutPipe.fileHandleForReading

        print("[SAM2Service] Python process launched (PID \(proc.processIdentifier))")

        // Wait for "ready"
        let response = try readResponse()
        guard response["status"] as? String == "ready" else {
            throw SAM2Error.launchFailed("Expected 'ready', got: \(response)")
        }
        isReady = true
        let device = response["device"] as? String ?? "unknown"
        print("[SAM2Service] Ready on \(device)")
    }

    /// Terminate the Python process.
    func shutdown() {
        if let stdin = stdin {
            sendCommand(["action": "quit"])
        }
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
        isReady = false
        print("[SAM2Service] Shutdown")
    }

    var isAvailable: Bool { isReady }

    // MARK: - Public API

    /// Encode an image for segmentation. Call before segment_all or segment_point.
    func encodeImage(at path: String, maxSize: Int = 2000) throws -> CGSize {
        guard isReady else { throw SAM2Error.notReady }

        sendCommand([
            "action": "encode",
            "image_path": path,
            "max_size": maxSize
        ])

        let response = try readResponse()
        guard response["status"] as? String == "encoded" else {
            let msg = response["message"] as? String ?? "unknown"
            throw SAM2Error.encodingFailed(msg)
        }

        let w = response["width"] as? Int ?? 0
        let h = response["height"] as? Int ?? 0
        encodedImageSize = CGSize(width: w, height: h)
        print("[SAM2Service] Image encoded: \(w)×\(h)")
        return encodedImageSize
    }

    /// Run "segment everything" on the encoded image.
    /// Returns all detected segments sorted by area (largest first).
    func segmentAll(
        pointsPerSide: Int = 64,
        iouThreshold: Float = 0.5,
        stabilityThreshold: Float = 0.75,
        minArea: Int = 100
    ) throws -> [SAM2Segment] {
        guard isReady else { throw SAM2Error.notReady }

        sendCommand([
            "action": "segment_all",
            "points_per_side": pointsPerSide,
            "pred_iou_thresh": iouThreshold,
            "stability_score_thresh": stabilityThreshold,
            "min_mask_region_area": minArea
        ])

        let response = try readResponse(timeout: 120)  // segment_all can take 15-60s
        guard response["status"] as? String == "masks_all" else {
            let msg = response["message"] as? String ?? "unknown"
            throw SAM2Error.segmentationFailed(msg)
        }

        let count = response["count"] as? Int ?? 0
        guard let masksArray = response["masks"] as? [[String: Any]] else {
            throw SAM2Error.segmentationFailed("No masks array in response")
        }

        var segments = [SAM2Segment]()
        for (i, maskDict) in masksArray.enumerated() {
            guard let rleDict = maskDict["rle"] as? [String: Any],
                  let counts = rleDict["counts"] as? [Int],
                  let start = rleDict["start"] as? Int,
                  let width = rleDict["width"] as? Int,
                  let height = rleDict["height"] as? Int else { continue }

            let segment = SAM2Segment(
                id: i,
                rle: SAM2Segment.RLEMask(counts: counts, start: start, width: width, height: height),
                score: (maskDict["score"] as? Double).map { Float($0) } ?? 0,
                area: maskDict["area"] as? Int ?? 0,
                bbox: maskDict["bbox"] as? [Int],
                stability: (maskDict["stability"] as? Double).map { Float($0) }
            )
            segments.append(segment)
        }

        print("[SAM2Service] Segment everything: \(count) masks")
        return segments
    }

    /// Segment at a specific point (normalized 0–1 coordinates).
    func segmentPoint(x: Double, y: Double, label: Int = 1) throws -> [SAM2Segment] {
        guard isReady else { throw SAM2Error.notReady }

        sendCommand([
            "action": "segment_point",
            "x": x,
            "y": y,
            "label": label
        ])

        let response = try readResponse()
        guard response["status"] as? String == "mask" else {
            let msg = response["message"] as? String ?? "unknown"
            throw SAM2Error.segmentationFailed(msg)
        }

        guard let masksArray = response["masks"] as? [[String: Any]] else {
            throw SAM2Error.segmentationFailed("No masks in response")
        }

        var segments = [SAM2Segment]()
        for (i, maskDict) in masksArray.enumerated() {
            guard let rleDict = maskDict["rle"] as? [String: Any],
                  let counts = rleDict["counts"] as? [Int],
                  let start = rleDict["start"] as? Int,
                  let width = rleDict["width"] as? Int,
                  let height = rleDict["height"] as? Int else { continue }

            segments.append(SAM2Segment(
                id: i,
                rle: SAM2Segment.RLEMask(counts: counts, start: start, width: width, height: height),
                score: (maskDict["score"] as? Double).map { Float($0) } ?? 0,
                area: maskDict["area"] as? Int ?? 0,
                bbox: nil,
                stability: nil
            ))
        }

        return segments
    }

    // MARK: - IPC Helpers

    private func sendCommand(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = json + "\n"
        stdin?.write(line.data(using: .utf8)!)
    }

    private func readResponse(timeout: Int = 30) throws -> [String: Any] {
        guard let stdout = stdout else { throw SAM2Error.notReady }

        // Read line from stdout (blocking)
        var lineData = Data()
        while true {
            let byte = stdout.readData(ofLength: 1)
            if byte.isEmpty { throw SAM2Error.processExited }
            if byte[0] == UInt8(ascii: "\n") { break }
            lineData.append(byte)
        }

        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            let raw = String(data: lineData, encoding: .utf8) ?? "<binary>"
            throw SAM2Error.invalidResponse(raw)
        }

        return json
    }
}

// MARK: - SAM2Error

enum SAM2Error: LocalizedError {
    case notReady
    case launchFailed(String)
    case processExited
    case encodingFailed(String)
    case segmentationFailed(String)
    case invalidResponse(String)

    // Legacy (unused, kept for compatibility)
    case modelNotLoaded(String)
    case imageNotEncoded
    case decodingFailed(String)
    case pixelBufferCreationFailed
    case maskExtractionFailed

    var errorDescription: String? {
        switch self {
        case .notReady:                     return "SAM2 Python process not ready"
        case .launchFailed(let d):          return "SAM2 launch failed: \(d)"
        case .processExited:                return "SAM2 Python process exited unexpectedly"
        case .encodingFailed(let d):        return "SAM2 encoding failed: \(d)"
        case .segmentationFailed(let d):    return "SAM2 segmentation failed: \(d)"
        case .invalidResponse(let d):       return "SAM2 invalid response: \(d)"
        case .modelNotLoaded(let d):        return "SAM2 model not loaded: \(d)"
        case .imageNotEncoded:              return "Call encodeImage() first"
        case .decodingFailed(let d):        return "SAM2 decoding failed: \(d)"
        case .pixelBufferCreationFailed:    return "Failed to create pixel buffer"
        case .maskExtractionFailed:         return "Failed to extract mask"
        }
    }
}
