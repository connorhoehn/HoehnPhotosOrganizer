import Foundation
import CoreGraphics
import CoreImage
import CoreML

// MARK: - AdjustmentLayer

/// An adjustment layer owns a set of PhotoAdjustments and one or more MaskSources
/// that combine to define where the adjustments apply.
struct AdjustmentLayer: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var label: String
    var adjustments: PhotoAdjustments
    var sources: [MaskSource]
    var isActive: Bool = true
    var opacity: Double = 1.0
    var createdAt: String

    init(id: String = UUID().uuidString,
         label: String,
         adjustments: PhotoAdjustments = PhotoAdjustments(),
         sources: [MaskSource] = [],
         isActive: Bool = true,
         opacity: Double = 1.0,
         createdAt: String = ISO8601DateFormatter().string(from: .now)) {
        self.id = id
        self.label = label
        self.adjustments = adjustments
        self.sources = sources
        self.isActive = isActive
        self.opacity = opacity
        self.createdAt = createdAt
    }

    /// True when this layer has no mask sources (global adjustment layer).
    var isGlobal: Bool { sources.isEmpty }

    /// Summary of the adjustments for display in the layer list.
    var adjustmentSummary: String {
        var parts: [String] = []
        let a = adjustments
        if abs(a.exposure) > 0.01 { parts.append("Exp \(a.exposure > 0 ? "+" : "")\(String(format: "%.1f", a.exposure))") }
        if a.contrast != 0 { parts.append("Con \(a.contrast > 0 ? "+" : "")\(a.contrast)") }
        if a.highlights != 0 { parts.append("Hi \(a.highlights > 0 ? "+" : "")\(a.highlights)") }
        if a.shadows != 0 { parts.append("Sh \(a.shadows > 0 ? "+" : "")\(a.shadows)") }
        if a.saturation != 0 { parts.append("Sat \(a.saturation > 0 ? "+" : "")\(a.saturation)") }
        if a.vibrance != 0 { parts.append("Vib \(a.vibrance > 0 ? "+" : "")\(a.vibrance)") }
        return parts.isEmpty ? "No adjustments" : parts.prefix(3).joined(separator: " · ")
    }
}

// MARK: - MaskSource

/// A single mask source within an AdjustmentLayer.
/// Multiple sources combine via `combineMode` to define the composite mask.
struct MaskSource: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var sourceType: MaskSourceType
    var combineMode: MaskCombineMode = .add
    var isInverted: Bool = false
    var feather: Double = 3.0
    var erode: Double = 0
    var dilate: Double = 0
    var sourcePoint: CGPoint?  // For SAM2 re-prompting

    init(id: String = UUID().uuidString,
         sourceType: MaskSourceType,
         combineMode: MaskCombineMode = .add,
         isInverted: Bool = false,
         feather: Double = 3.0,
         erode: Double = 0,
         dilate: Double = 0,
         sourcePoint: CGPoint? = nil) {
        self.id = id
        self.sourceType = sourceType
        self.combineMode = combineMode
        self.isInverted = isInverted
        self.feather = feather
        self.erode = erode
        self.dilate = dilate
        self.sourcePoint = sourcePoint
    }

    var typeLabel: String { sourceType.label }
    var typeIcon: String { sourceType.icon }
}

// MARK: - MaskCombineMode

enum MaskCombineMode: String, Codable, CaseIterable {
    case add         // Union: white where either mask is white
    case subtract    // Remove: black where new mask is white
    case intersect   // Overlap only: white where both are white
}

// MARK: - MaskSourceType

enum MaskSourceType: Codable, Equatable {
    case bitmap(rle: Data, width: Int, height: Int)
    case ellipse(normalizedRect: CGRect)
    case rectangle(normalizedRect: CGRect)
    case linearGradient(startPoint: CGPoint, endPoint: CGPoint)
    case radialGradient(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat)

    var label: String {
        switch self {
        case .bitmap: return "Selection"
        case .ellipse: return "Ellipse"
        case .rectangle: return "Rectangle"
        case .linearGradient: return "Linear Gradient"
        case .radialGradient: return "Radial Gradient"
        }
    }

    var icon: String {
        switch self {
        case .bitmap: return "sparkles"
        case .ellipse: return "circle.dashed"
        case .rectangle: return "rectangle.dashed"
        case .linearGradient: return "arrow.down.right"
        case .radialGradient: return "circle.and.line.horizontal"
        }
    }
}

// MARK: - MaskSourceType CIImage Helpers

extension MaskSourceType {
    var isEllipse: Bool {
        if case .ellipse = self { return true }
        return false
    }

    /// Decode bitmap to a CIImage mask.
    func toCIImage() -> CIImage? {
        guard case .bitmap(let data, let width, let height) = self else { return nil }
        let pixels: [UInt8]
        if data.count == width * height {
            pixels = Array(data)
        } else {
            pixels = rleDecode(data, count: width * height)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// The bounding rect in normalized coordinates (0-1).
    var normalizedBounds: CGRect {
        switch self {
        case .ellipse(let r), .rectangle(let r):
            return r
        case .bitmap, .linearGradient, .radialGradient:
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    /// Create a bitmap source from SAM2's low_res_masks MLMultiArray.
    static func fromSAM2Output(lowResMasks: MLMultiArray, bestIndex: Int) -> MaskSourceType {
        let maskSize = 256
        var pixels = [UInt8](repeating: 0, count: maskSize * maskSize)

        let strides = lowResMasks.strides.map { $0.intValue }
        let ptr = lowResMasks.dataPointer.bindMemory(to: UInt16.self, capacity: lowResMasks.count)

        let batchStride = strides[0]
        let maskStride = strides[1]
        let rowStride = strides[2]
        let colStride = strides[3]

        let baseOffset = batchStride * 0 + maskStride * bestIndex

        var positiveCount = 0
        for y in 0..<maskSize {
            for x in 0..<maskSize {
                let offset = baseOffset + rowStride * y + colStride * x
                let raw = ptr[offset]
                let value = float16ToFloat32(raw)
                if value > 0 {
                    pixels[y * maskSize + x] = 255
                    positiveCount += 1
                }
            }
        }

        print("[MaskSourceType] SAM2 direct read: \(positiveCount)/\(maskSize*maskSize) positive (\(positiveCount * 100 / (maskSize*maskSize))%)")

        let rawData = Data(pixels)
        return .bitmap(rle: rawData, width: maskSize, height: maskSize)
    }

    private static func float16ToFloat32(_ h: UInt16) -> Float {
        let sign = (h >> 15) & 1
        let exp = (h >> 10) & 0x1F
        let frac = h & 0x3FF
        if exp == 0 {
            if frac == 0 { return sign == 1 ? -0.0 : 0.0 }
            let f = Float(frac) / 1024.0 * pow(2.0, -14.0)
            return sign == 1 ? -f : f
        } else if exp == 31 {
            return frac == 0 ? (sign == 1 ? -Float.infinity : Float.infinity) : Float.nan
        }
        let f = (1.0 + Float(frac) / 1024.0) * pow(2.0, Float(Int(exp) - 15))
        return sign == 1 ? -f : f
    }

    /// Create a bitmap source from a grayscale CIImage mask.
    static func fromCIImage(_ ciMask: CIImage, context: CIContext = CIContext()) -> MaskSourceType? {
        let extent = ciMask.extent
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        context.render(ciMask, toBitmap: &pixels, rowBytes: w, bounds: extent,
                       format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        let rle = rleEncode(pixels)
        return .bitmap(rle: rle, width: w, height: h)
    }
}

// MARK: - Legacy MaskLayer (backward-compatible decoding only)

/// Old MaskLayer format — used only for decoding existing masks_json.
/// Automatically converted to AdjustmentLayer on load.
struct MaskLayer: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var label: String
    var geometry: MaskGeometry
    var adjustments: PhotoAdjustments
    var isActive: Bool = true
    var isInverted: Bool = false
    var opacity: Double = 1.0
    var feather: Double = 3.0
    var erode: Double = 0
    var dilate: Double = 0
    var createdAt: String
    var sourcePoint: CGPoint?

    enum CodingKeys: String, CodingKey {
        case id, label, geometry, adjustments, isActive, isInverted, opacity
        case feather, erode, dilate, createdAt, sourcePoint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        geometry = try c.decode(MaskGeometry.self, forKey: .geometry)
        adjustments = try c.decode(PhotoAdjustments.self, forKey: .adjustments)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        isInverted = try c.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 3.0
        erode = try c.decodeIfPresent(Double.self, forKey: .erode) ?? 0
        dilate = try c.decodeIfPresent(Double.self, forKey: .dilate) ?? 0
        createdAt = try c.decode(String.self, forKey: .createdAt)
        sourcePoint = try c.decodeIfPresent(CGPoint.self, forKey: .sourcePoint)
    }

    func encode(to encoder: Encoder) throws {
        fatalError("Legacy MaskLayer should not be encoded — use AdjustmentLayer")
    }

    /// Convert legacy MaskLayer to new AdjustmentLayer format.
    func toAdjustmentLayer() -> AdjustmentLayer {
        let sourceType: MaskSourceType
        switch geometry {
        case .ellipse(let r): sourceType = .ellipse(normalizedRect: r)
        case .rectangle(let r): sourceType = .rectangle(normalizedRect: r)
        case .bitmap(let rle, let w, let h): sourceType = .bitmap(rle: rle, width: w, height: h)
        }
        let source = MaskSource(
            sourceType: sourceType,
            isInverted: isInverted,
            feather: feather,
            erode: erode,
            dilate: dilate,
            sourcePoint: sourcePoint
        )
        return AdjustmentLayer(
            id: id,
            label: label,
            adjustments: adjustments,
            sources: [source],
            isActive: isActive,
            opacity: opacity,
            createdAt: createdAt
        )
    }
}

/// Legacy geometry enum — used only for backward-compatible decoding.
enum MaskGeometry: Codable, Equatable {
    case ellipse(normalizedRect: CGRect)
    case rectangle(normalizedRect: CGRect)
    case bitmap(rle: Data, width: Int, height: Int)

    // Keep toCIImage for backward compat
    func toCIImage() -> CIImage? {
        guard case .bitmap(let data, let width, let height) = self else { return nil }
        let pixels: [UInt8]
        if data.count == width * height {
            pixels = Array(data)
        } else {
            pixels = rleDecode(data, count: width * height)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

extension MaskGeometry {
    var isEllipse: Bool {
        if case .ellipse = self { return true }
        return false
    }
}

// MARK: - MaskLayerStore

struct MaskLayerStore {
    /// Decode from JSON — tries new AdjustmentLayer format first, falls back to legacy MaskLayer.
    static func decode(from json: String?) -> [AdjustmentLayer] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        // Try new format first
        if let layers = try? JSONDecoder().decode([AdjustmentLayer].self, from: data) {
            return layers
        }
        // Fall back to legacy format
        if let legacy = try? JSONDecoder().decode([MaskLayer].self, from: data) {
            return legacy.map { $0.toAdjustmentLayer() }
        }
        return []
    }

    static func encode(_ layers: [AdjustmentLayer]) -> String? {
        guard let data = try? JSONEncoder().encode(layers) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - RLE Encoding

func rleEncode(_ pixels: [UInt8]) -> Data {
    guard !pixels.isEmpty else { return Data() }
    var result = Data()
    let startValue = pixels[0]
    result.append(startValue)
    var runLength: UInt16 = 1
    for i in 1..<pixels.count {
        if pixels[i] == pixels[i - 1] {
            runLength += 1
            if runLength == UInt16.max {
                var len = runLength
                result.append(Data(bytes: &len, count: 2))
                runLength = 0
            }
        } else {
            var len = runLength
            result.append(Data(bytes: &len, count: 2))
            runLength = 1
        }
    }
    if runLength > 0 {
        var len = runLength
        result.append(Data(bytes: &len, count: 2))
    }
    return result
}

func rleDecode(_ data: Data, count: Int) -> [UInt8] {
    guard data.count >= 3 else { return [UInt8](repeating: 0, count: count) }
    var pixels = [UInt8]()
    pixels.reserveCapacity(count)
    let startValue = data[0]
    var currentValue = startValue
    var offset = 1
    while offset + 1 < data.count && pixels.count < count {
        let len = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        let fill = min(Int(len), count - pixels.count)
        pixels.append(contentsOf: repeatElement(currentValue, count: fill))
        currentValue = currentValue == 0 ? 255 : 0
    }
    while pixels.count < count { pixels.append(0) }
    return pixels
}
