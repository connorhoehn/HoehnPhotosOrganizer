import Accelerate
import CoreImage
import CoreML
import Foundation

// MARK: - MobileCLIPError

enum MobileCLIPError: Error, LocalizedError {
    case modelNotFound(String)
    case preprocessingFailed
    case unexpectedOutputShape(String)
    case missingOutputFeature(String)
    case tokenizerNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):      return "CoreML model not found in bundle: \(name)"
        case .preprocessingFailed:          return "Image preprocessing failed (resize or pixel extraction)"
        case .unexpectedOutputShape(let s): return "Unexpected model output shape: \(s)"
        case .missingOutputFeature(let n):  return "Model output missing feature: \(n)"
        case .tokenizerNotReady:            return "CLIP tokenizer not ready — bundle vocab.json + bpe_merges.txt"
        }
    }
}

// MARK: - MobileCLIPService

/// On-device semantic embedding using Apple's MobileCLIP CoreML models.
///
/// Both image and text embeddings land in the same 512-dimensional CLIP space,
/// enabling text-to-image similarity search without any network requests.
///
/// Model files expected in the app bundle (added via Xcode target membership):
///   - `MobileCLIPImageEncoder.mlpackage`  → image → 512-d embedding
///   - `MobileCLIPTextEncoder.mlpackage`   → token IDs → 512-d embedding
///
/// Optional tokenizer data files (enables text encoding):
///   - `clip_vocab.json`     — CLIP BPE vocabulary (~49k entries)
///   - `clip_bpe_merges.txt` — BPE merge rules
actor MobileCLIPService {

    // MARK: - Constants

    static let embeddingDimensions = 512
    static let clipContextLength   = 77      // max tokens including SOT + EOT
    static let clipSOT: Int32      = 49406   // start-of-text token
    static let clipEOT: Int32      = 49407   // end-of-text token

    // CLIP image normalisation (ImageNet-derived, same as openai/clip)
    private static let normMean: [Float] = [0.48145466, 0.4578275,  0.40821073]
    private static let normStd:  [Float] = [0.26862954, 0.26130258, 0.27577711]

    // MARK: - Lazy-loaded models

    private var imageEncoderModel: MLModel?
    private var textEncoderModel: MLModel?

    // Tokenizer state (populated when vocab files are found in bundle)
    private var tokenizer: CLIPTokenizer?
    private var tokenizerLoaded = false

    // MARK: - Public API

    /// Encode a CGImage into a 512-dimensional CLIP embedding.
    ///
    /// The image is resized to 256×256 and passed to the CoreML image encoder.
    /// Automatically handles both image-typed inputs (CVPixelBuffer) and
    /// multiarray-typed inputs (CHW float32 NCHW tensor).
    func encodeImage(_ cgImage: CGImage) async throws -> [Float] {
        let model = try loadImageEncoder()
        let inputName = imageEncoderInputName(for: model)

        let featureValue: MLFeatureValue
        let inputType = model.modelDescription.inputDescriptionsByName[inputName]?.type
        if inputType == .image {
            featureValue = try preprocessImageAsPixelBuffer(cgImage)
        } else {
            featureValue = try MLFeatureValue(multiArray: preprocessImage(cgImage))
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: featureValue])
        let output = try await model.prediction(from: provider)

        return try extractVector(from: output, expectedDim: Self.embeddingDimensions)
    }

    /// Encode a text query into a 512-dimensional CLIP embedding.
    ///
    /// Requires `clip_vocab.json` and `clip_bpe_merges.txt` to be present in the
    /// main bundle (add via Xcode → target membership). Returns `nil` and logs a
    /// warning when the tokenizer files are unavailable.
    func encodeText(_ query: String) async throws -> [Float]? {
        guard let tok = loadedTokenizer() else {
            print("[MobileCLIP] Text encoding skipped — tokenizer files not bundled yet.")
            return nil
        }

        let model = try loadTextEncoder()
        let tokenIds = tok.tokenize(query, contextLength: Self.clipContextLength)
        let multiArray = try tokenIdsToMLMultiArray(tokenIds)

        let inputName = textEncoderInputName(for: model)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: multiArray])
        let output = try await model.prediction(from: provider)

        return try extractVector(from: output, expectedDim: Self.embeddingDimensions)
    }

    /// L2-normalise a vector so cosine similarity equals dot product.
    nonisolated func normalise(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        var result = [Float](repeating: 0, count: v.count)
        var scalar = 1.0 / norm
        vDSP_vsmul(v, 1, &scalar, &result, 1, vDSP_Length(v.count))
        return result
    }

    // MARK: - Model loading

    private func loadImageEncoder() throws -> MLModel {
        if let m = imageEncoderModel { return m }
        let m = try loadModel(named: "MobileCLIPImageEncoder")
        imageEncoderModel = m
        return m
    }

    private func loadTextEncoder() throws -> MLModel {
        if let m = textEncoderModel { return m }
        let m = try loadModel(named: "MobileCLIPTextEncoder")
        textEncoderModel = m
        return m
    }

    private func loadModel(named name: String) throws -> MLModel {
        // Xcode compiles .mlpackage → .mlmodelc at build time
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw MobileCLIPError.modelNotFound(name)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // prefer Neural Engine
        return try MLModel(contentsOf: url, configuration: config)
    }

    // MARK: - Image preprocessing

    private func preprocessImage(_ cgImage: CGImage) throws -> MLMultiArray {
        // Resize to 256×256 in sRGB
        guard let resized = resizeCGImage(cgImage, to: CGSize(width: 256, height: 256)),
              let pixelData = extractRGBPixels(resized) else {
            throw MobileCLIPError.preprocessingFailed
        }

        // Output shape: [1, 3, 256, 256] — NCHW
        let array = try MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * 256 * 256)

        let mean = Self.normMean
        let std  = Self.normStd

        for y in 0..<256 {
            for x in 0..<256 {
                let base = (y * 256 + x) * 4   // RGBA
                for c in 0..<3 {
                    let raw = Float(pixelData[base + c]) / 255.0
                    let normalised = (raw - mean[c]) / std[c]
                    ptr[c * 256 * 256 + y * 256 + x] = normalised
                }
            }
        }

        return array
    }

    /// Build a CVPixelBuffer for models whose input feature type is `.image`.
    private func preprocessImageAsPixelBuffer(_ cgImage: CGImage) throws -> MLFeatureValue {
        guard let resized = resizeCGImage(cgImage, to: CGSize(width: 256, height: 256)) else {
            throw MobileCLIPError.preprocessingFailed
        }
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 256, 256,
            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw MobileCLIPError.preprocessingFailed
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: 256, height: 256,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { throw MobileCLIPError.preprocessingFailed }
        ctx.draw(resized, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        return MLFeatureValue(pixelBuffer: buffer)
    }

    private func resizeCGImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        context?.draw(image, in: CGRect(origin: .zero, size: size))
        return context?.makeImage()
    }

    private func extractRGBPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    // MARK: - Text preprocessing

    private func tokenIdsToMLMultiArray(_ ids: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: Self.clipContextLength)], dataType: .int32)
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: Self.clipContextLength)
        for i in 0..<Self.clipContextLength {
            ptr[i] = i < ids.count ? ids[i] : 0
        }
        return array
    }

    // MARK: - Output extraction

    private func extractVector(from output: MLFeatureProvider, expectedDim: Int) throws -> [Float] {
        // Try common output feature names used by CLIP-family models
        let candidateNames = ["embedding", "image_features", "text_features",
                              "output", "pooled_output", "var_955", "linear_0"]

        for name in candidateNames {
            guard let feature = output.featureValue(for: name) else { continue }
            if let array = feature.multiArrayValue {
                return try flattenToFloatVector(array, expectedDim: expectedDim)
            }
        }

        // Fall back to first available feature
        let firstName = output.featureNames.first ?? "<none>"
        guard let feature = output.featureValue(for: firstName),
              let array = feature.multiArrayValue else {
            throw MobileCLIPError.missingOutputFeature("No MLMultiArray output found. Available: \(output.featureNames)")
        }
        return try flattenToFloatVector(array, expectedDim: expectedDim)
    }

    private func flattenToFloatVector(_ array: MLMultiArray, expectedDim: Int) throws -> [Float] {
        let count = array.count
        guard count >= expectedDim else {
            throw MobileCLIPError.unexpectedOutputShape("count=\(count), expected ≥\(expectedDim)")
        }
        let ptr = array.dataPointer
        switch array.dataType {
        case .float32, .float16:
            let f32 = ptr.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: f32, count: expectedDim))
        case .double:
            let f64 = ptr.bindMemory(to: Double.self, capacity: count)
            return (0..<expectedDim).map { Float(f64[$0]) }
        default:
            throw MobileCLIPError.unexpectedOutputShape("Unsupported dataType: \(array.dataType)")
        }
    }

    // MARK: - Input name discovery

    private func imageEncoderInputName(for model: MLModel) -> String {
        let candidates = ["image", "pixel_values", "input"]
        return firstMatchingInput(model, candidates: candidates) ?? "image"
    }

    private func textEncoderInputName(for model: MLModel) -> String {
        let candidates = ["input_ids", "tokens", "text", "input"]
        return firstMatchingInput(model, candidates: candidates) ?? "input_ids"
    }

    private func firstMatchingInput(_ model: MLModel, candidates: [String]) -> String? {
        let desc = model.modelDescription.inputDescriptionsByName
        return candidates.first { desc[$0] != nil }
    }

    // MARK: - Tokenizer

    private func loadedTokenizer() -> CLIPTokenizer? {
        if tokenizerLoaded { return tokenizer }
        tokenizerLoaded = true
        tokenizer = CLIPTokenizer(bundle: .main)
        return tokenizer
    }
}

// MARK: - CLIPTokenizer

/// Minimal CLIP BPE tokenizer.
///
/// Loads `clip_vocab.json` and `clip_bpe_merges.txt` from the app bundle.
/// Both files are standard OpenAI CLIP artefacts available on HuggingFace
/// (openai/clip-vit-base-patch32, files: `vocab.json` + `merges.txt`).
///
/// Add them to the Xcode target with the names:
///   - `clip_vocab.json`
///   - `clip_bpe_merges.txt`
final class CLIPTokenizer: @unchecked Sendable {

    private let encoder: [String: Int32]     // token → id
    private let bpeRanks: [BPEPair: Int]     // merge pair → rank
    private let byteEncoder: [UInt8: String] // byte → unicode char

    struct BPEPair: Hashable { let first: String; let second: String }

    init?(bundle: Bundle) {
        guard
            let vocabURL  = bundle.url(forResource: "clip_vocab",      withExtension: "json"),
            let mergesURL = bundle.url(forResource: "clip_bpe_merges",  withExtension: "txt"),
            let vocabData = try? Data(contentsOf: vocabURL),
            let mergesData = try? Data(contentsOf: mergesURL),
            let vocab = try? JSONDecoder().decode([String: Int32].self, from: vocabData)
        else {
            return nil
        }

        self.encoder = vocab

        // Build BPE merge ranks from the merges file (one pair per line, skip header)
        let mergesText = String(data: mergesData, encoding: .utf8) ?? ""
        var ranks: [BPEPair: Int] = [:]
        let lines = mergesText.components(separatedBy: "\n")
        for (idx, line) in lines.dropFirst().enumerated() {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            ranks[BPEPair(first: String(parts[0]), second: String(parts[1]))] = idx
        }
        self.bpeRanks = ranks

        // Standard CLIP byte-to-unicode mapping
        self.byteEncoder = CLIPTokenizer.buildByteEncoder()
    }

    // MARK: - Public

    func tokenize(_ text: String, contextLength: Int) -> [Int32] {
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespaces)
        var tokens: [Int32] = [MobileCLIPService.clipSOT]

        for word in cleaned.components(separatedBy: .whitespaces) where !word.isEmpty {
            let bpeTokens = bpe(word + "</w>")
            for tok in bpeTokens {
                if let id = encoder[tok] {
                    tokens.append(id)
                }
            }
        }

        tokens.append(MobileCLIPService.clipEOT)

        // Truncate or pad to contextLength
        if tokens.count > contextLength {
            tokens = Array(tokens.prefix(contextLength - 1)) + [MobileCLIPService.clipEOT]
        }
        while tokens.count < contextLength { tokens.append(0) }
        return tokens
    }

    // MARK: - BPE

    private func bpe(_ word: String) -> [String] {
        var symbols = word.map { byteEncoder[UInt8($0.asciiValue ?? 0)] ?? String($0) }

        while symbols.count > 1 {
            // Find the merge pair with the lowest rank
            var bestRank = Int.max
            var bestIdx = -1
            for i in 0..<symbols.count - 1 {
                let pair = BPEPair(first: symbols[i], second: symbols[i + 1])
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestIdx = i
                }
            }
            guard bestIdx >= 0 else { break }

            // Merge the best pair
            var merged: [String] = []
            var i = 0
            while i < symbols.count {
                if i == bestIdx {
                    merged.append(symbols[i] + symbols[i + 1])
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }

        return symbols
    }

    // MARK: - Byte encoder

    private static func buildByteEncoder() -> [UInt8: String] {
        // Ranges that map directly to printable Unicode
        var bs: [UInt8] = []
        bs += (UInt8(ascii: "!") ... UInt8(ascii: "~")).map { $0 }
        bs += (UInt8(0xA1) ... UInt8(0xFF)).map { $0 }

        var cs = bs.map { Character(UnicodeScalar($0)) }

        // Remaining bytes get mapped to Unicode code points starting at 256
        var n = 0
        for b in UInt8(0)...UInt8(255) where !bs.contains(b) {
            bs.append(b)
            cs.append(Character(UnicodeScalar(UInt32(256 + n))!))
            n += 1
        }

        var result: [UInt8: String] = [:]
        for (byte, char) in zip(bs, cs) { result[byte] = String(char) }
        return result
    }
}
