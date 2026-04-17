import Metal
import MetalKit
import AppKit

/// GPU-accelerated image processing via Metal compute shaders.
/// Drop-in replacement for CVImageProcessor operations that benefit from GPU parallelism.
/// All public methods accept NSImage and return NSImage for API compatibility.
@MainActor
final class MetalImageProcessor {

    static let shared: MetalImageProcessor? = MetalImageProcessor()

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    // Pipeline states
    private let kmeansAssignPSO: MTLComputePipelineState
    private let kmeansAccumulatePSO: MTLComputePipelineState
    private let kmeansUpdateCentersPSO: MTLComputePipelineState
    private let kmeansApplyPSO: MTLComputePipelineState
    private let bilateralPSO: MTLComputePipelineState
    private let gaussianBlurHPSO: MTLComputePipelineState
    private let gaussianBlurVPSO: MTLComputePipelineState
    private let desaturatePSO: MTLComputePipelineState
    private let brightnessContrastPSO: MTLComputePipelineState
    private let posterizePSO: MTLComputePipelineState
    private let thresholdMapPSO: MTLComputePipelineState
    private let addNoisePSO: MTLComputePipelineState
    private let invertPSO: MTLComputePipelineState
    private let multiplyBlendPSO: MTLComputePipelineState
    private let addWeightedPSO: MTLComputePipelineState
    private let colorDodgeBlendPSO: MTLComputePipelineState
    private let pbnClassifyPSO: MTLComputePipelineState
    private let pbnTintBoundaryPSO: MTLComputePipelineState
    private let pbnHoverHighlightPSO: MTLComputePipelineState
    private let pbnNarrowStripPSO: MTLComputePipelineState
    private let pbnLabelsToRegionMapPSO: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[MetalImageProcessor] No Metal device available")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            print("[MetalImageProcessor] Failed to create command queue")
            return nil
        }
        guard let library = device.makeDefaultLibrary() else {
            print("[MetalImageProcessor] Failed to load default Metal library")
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.library = library

        // Build all pipeline states up front
        do {
            kmeansAssignPSO = try Self.makePSO(device: device, library: library, name: "kmeans_assign")
            kmeansAccumulatePSO = try Self.makePSO(device: device, library: library, name: "kmeans_accumulate")
            kmeansUpdateCentersPSO = try Self.makePSO(device: device, library: library, name: "kmeans_update_centers")
            kmeansApplyPSO = try Self.makePSO(device: device, library: library, name: "kmeans_apply")
            bilateralPSO = try Self.makePSO(device: device, library: library, name: "bilateral_filter")
            gaussianBlurHPSO = try Self.makePSO(device: device, library: library, name: "gaussian_blur_h")
            gaussianBlurVPSO = try Self.makePSO(device: device, library: library, name: "gaussian_blur_v")
            desaturatePSO = try Self.makePSO(device: device, library: library, name: "desaturate")
            brightnessContrastPSO = try Self.makePSO(device: device, library: library, name: "brightness_contrast")
            posterizePSO = try Self.makePSO(device: device, library: library, name: "posterize")
            thresholdMapPSO = try Self.makePSO(device: device, library: library, name: "threshold_map")
            addNoisePSO = try Self.makePSO(device: device, library: library, name: "add_noise")
            invertPSO = try Self.makePSO(device: device, library: library, name: "invert_image")
            multiplyBlendPSO = try Self.makePSO(device: device, library: library, name: "multiply_blend")
            addWeightedPSO = try Self.makePSO(device: device, library: library, name: "add_weighted")
            colorDodgeBlendPSO = try Self.makePSO(device: device, library: library, name: "color_dodge_blend")
            pbnClassifyPSO = try Self.makePSO(device: device, library: library, name: "pbn_classify_regions")
            pbnTintBoundaryPSO = try Self.makePSO(device: device, library: library, name: "pbn_tint_and_boundary")
            pbnHoverHighlightPSO = try Self.makePSO(device: device, library: library, name: "pbn_hover_highlight")
            pbnNarrowStripPSO = try Self.makePSO(device: device, library: library, name: "pbn_narrow_strip_cleanup")
            pbnLabelsToRegionMapPSO = try Self.makePSO(device: device, library: library, name: "pbn_labels_to_regionmap")
        } catch {
            print("[MetalImageProcessor] Failed to create pipeline states: \(error)")
            return nil
        }

        print("[MetalImageProcessor] Initialized on \(device.name)")
    }

    private static func makePSO(
        device: MTLDevice,
        library: MTLLibrary,
        name: String
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw MetalError.functionNotFound(name)
        }
        return try device.makeComputePipelineState(function: function)
    }

    // MARK: - Texture Utilities

    func textureFromImage(_ image: NSImage) -> MTLTexture? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("[Metal] textureFromImage: failed to get CGImage")
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        print("[Metal] textureFromImage: \(width)x\(height), bpc=\(cgImage.bitsPerComponent), bpp=\(cgImage.bitsPerPixel), cs=\(cgImage.colorSpace?.name ?? "nil" as CFString)")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // Render CGImage into RGBA8 byte buffer, then upload
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height
        var pixelData = [UInt8](repeating: 0, count: dataSize)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    func imageFromTexture(_ texture: MTLTexture) -> NSImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height
        var pixelData = [UInt8](repeating: 0, count: dataSize)

        texture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    /// Compute optimal thread group and grid sizes for a 2D texture dispatch.
    private func threadGroups(for texture: MTLTexture, pso: MTLComputePipelineState) -> (MTLSize, MTLSize) {
        let w = pso.threadExecutionWidth
        let h = pso.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let gridSize = MTLSize(width: texture.width, height: texture.height, depth: 1)
        return (gridSize, threadsPerGroup)
    }

    // MARK: - K-Means Quantization

    /// GPU-accelerated k-means color quantization with k-means++ initialization.
    /// Returns the quantized image, or nil on failure.
    func kmeansQuantize(_ source: NSImage, numColors: Int, iterations: Int = 12) -> NSImage? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        let width = inputTexture.width
        let height = inputTexture.height
        let pixelCount = width * height

        // Read all pixels for CPU-side k-means++ initialization
        var initialPixels = [UInt8](repeating: 0, count: pixelCount * 4)
        inputTexture.getBytes(
            &initialPixels,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        // K-means++ initialization (CPU) — picks centers spread across color space
        var centerData = [Float](repeating: 0, count: numColors * 3)
        let sampleCount = min(pixelCount, 4096) // subsample for speed
        let sampleStride = max(1, pixelCount / sampleCount)

        // First center: random pixel
        let firstIdx = Int.random(in: 0..<pixelCount)
        centerData[0] = Float(initialPixels[firstIdx * 4 + 0]) / 255.0
        centerData[1] = Float(initialPixels[firstIdx * 4 + 1]) / 255.0
        centerData[2] = Float(initialPixels[firstIdx * 4 + 2]) / 255.0

        // Subsequent centers: weighted by distance to nearest existing center
        for c in 1..<numColors {
            var bestDist: Float = -1
            var bestIdx = 0

            for s in 0..<sampleCount {
                let pIdx = s * sampleStride
                let r = Float(initialPixels[pIdx * 4 + 0]) / 255.0
                let g = Float(initialPixels[pIdx * 4 + 1]) / 255.0
                let b = Float(initialPixels[pIdx * 4 + 2]) / 255.0

                // Find min distance to all existing centers
                var minDist: Float = .greatestFiniteMagnitude
                for j in 0..<c {
                    let dr = r - centerData[j * 3 + 0]
                    let dg = g - centerData[j * 3 + 1]
                    let db = b - centerData[j * 3 + 2]
                    let dist = dr * dr + dg * dg + db * db
                    if dist < minDist { minDist = dist }
                }

                if minDist > bestDist {
                    bestDist = minDist
                    bestIdx = pIdx
                }
            }

            centerData[c * 3 + 0] = Float(initialPixels[bestIdx * 4 + 0]) / 255.0
            centerData[c * 3 + 1] = Float(initialPixels[bestIdx * 4 + 1]) / 255.0
            centerData[c * 3 + 2] = Float(initialPixels[bestIdx * 4 + 2]) / 255.0
        }

        guard let centersBuffer = device.makeBuffer(
            bytes: &centerData,
            length: numColors * 3 * MemoryLayout<Float>.stride,
            options: .storageModeManaged
        ) else { return nil }

        guard let labelsBuffer = device.makeBuffer(
            length: pixelCount * MemoryLayout<Int32>.stride,
            options: .storageModeManaged
        ) else { return nil }

        let sumsLength = numColors * 4 * MemoryLayout<Float>.stride
        guard let sumsBuffer = device.makeBuffer(
            length: sumsLength,
            options: .storageModeManaged
        ) else { return nil }
        // Zero the sums buffer
        memset(sumsBuffer.contents(), 0, sumsLength)
        sumsBuffer.didModifyRange(0..<sumsLength)

        var numColorsVar = Int32(numColors)

        guard let outputTexture = makeTexture(width: width, height: height) else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: kmeansAssignPSO)

        for _ in 0..<iterations {
            // Assign step
            guard let assignEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            assignEncoder.setComputePipelineState(kmeansAssignPSO)
            assignEncoder.setTexture(inputTexture, index: 0)
            assignEncoder.setBuffer(labelsBuffer, offset: 0, index: 0)
            assignEncoder.setBuffer(centersBuffer, offset: 0, index: 1)
            assignEncoder.setBytes(&numColorsVar, length: MemoryLayout<Int32>.stride, index: 2)
            assignEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            assignEncoder.endEncoding()

            // Accumulate step
            guard let accumEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            accumEncoder.setComputePipelineState(kmeansAccumulatePSO)
            accumEncoder.setTexture(inputTexture, index: 0)
            accumEncoder.setBuffer(labelsBuffer, offset: 0, index: 0)
            accumEncoder.setBuffer(sumsBuffer, offset: 0, index: 1)
            accumEncoder.setBytes(&numColorsVar, length: MemoryLayout<Int32>.stride, index: 2)
            accumEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            accumEncoder.endEncoding()

            // Update centers step
            guard let updateEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            updateEncoder.setComputePipelineState(kmeansUpdateCentersPSO)
            updateEncoder.setBuffer(centersBuffer, offset: 0, index: 0)
            updateEncoder.setBuffer(sumsBuffer, offset: 0, index: 1)
            updateEncoder.setBytes(&numColorsVar, length: MemoryLayout<Int32>.stride, index: 2)
            let updateGrid = MTLSize(width: numColors, height: 1, depth: 1)
            let updateGroup = MTLSize(width: min(numColors, 64), height: 1, depth: 1)
            updateEncoder.dispatchThreads(updateGrid, threadsPerThreadgroup: updateGroup)
            updateEncoder.endEncoding()
        }

        // Apply final labels
        guard let applyEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        applyEncoder.setComputePipelineState(kmeansApplyPSO)
        applyEncoder.setBuffer(labelsBuffer, offset: 0, index: 0)
        applyEncoder.setBuffer(centersBuffer, offset: 0, index: 1)
        applyEncoder.setTexture(outputTexture, index: 0)
        applyEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        applyEncoder.endEncoding()

        // Synchronize managed textures for CPU readback
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalImageProcessor] K-means command buffer error: \(error)")
            return nil
        }

        return imageFromTexture(outputTexture)
    }

    // MARK: - K-Means Quantization with Labels

    /// Result of GPU k-means quantization with full pipeline data.
    struct KMeansResult {
        let image: NSImage
        let labelsBuffer: MTLBuffer
        let centersBuffer: MTLBuffer
        let width: Int
        let height: Int
        let numColors: Int
    }

    /// GPU-accelerated k-means color quantization returning the labels buffer, centers buffer,
    /// and quantized image for downstream PBN pipeline use.
    /// If `restrictPalette` is provided, after the k-means loop each center is snapped
    /// to the nearest palette color (Euclidean distance in RGB) before applying.
    func kmeansQuantizeWithLabels(
        _ source: NSImage,
        numColors: Int,
        iterations: Int = 12,
        restrictPalette: [SIMD3<Float>]? = nil
    ) -> KMeansResult? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        let width = inputTexture.width
        let height = inputTexture.height
        let pixelCount = width * height

        // Read all pixels for CPU-side k-means++ initialization
        var initialPixels = [UInt8](repeating: 0, count: pixelCount * 4)
        inputTexture.getBytes(
            &initialPixels,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        // K-means++ initialization (CPU) — picks centers spread across color space
        var centerData = [Float](repeating: 0, count: numColors * 3)
        let sampleCount = min(pixelCount, 4096)
        let sampleStride = max(1, pixelCount / sampleCount)

        // First center: random pixel
        let firstIdx = Int.random(in: 0..<pixelCount)
        centerData[0] = Float(initialPixels[firstIdx * 4 + 0]) / 255.0
        centerData[1] = Float(initialPixels[firstIdx * 4 + 1]) / 255.0
        centerData[2] = Float(initialPixels[firstIdx * 4 + 2]) / 255.0

        // Subsequent centers: weighted by distance to nearest existing center
        for c in 1..<numColors {
            var bestDist: Float = -1
            var bestIdx = 0

            for s in 0..<sampleCount {
                let pIdx = s * sampleStride
                let r = Float(initialPixels[pIdx * 4 + 0]) / 255.0
                let g = Float(initialPixels[pIdx * 4 + 1]) / 255.0
                let b = Float(initialPixels[pIdx * 4 + 2]) / 255.0

                var minDist: Float = .greatestFiniteMagnitude
                for j in 0..<c {
                    let dr = r - centerData[j * 3 + 0]
                    let dg = g - centerData[j * 3 + 1]
                    let db = b - centerData[j * 3 + 2]
                    let dist = dr * dr + dg * dg + db * db
                    if dist < minDist { minDist = dist }
                }

                if minDist > bestDist {
                    bestDist = minDist
                    bestIdx = pIdx
                }
            }

            centerData[c * 3 + 0] = Float(initialPixels[bestIdx * 4 + 0]) / 255.0
            centerData[c * 3 + 1] = Float(initialPixels[bestIdx * 4 + 1]) / 255.0
            centerData[c * 3 + 2] = Float(initialPixels[bestIdx * 4 + 2]) / 255.0
        }

        guard let centersBuffer = device.makeBuffer(
            bytes: &centerData,
            length: numColors * 3 * MemoryLayout<Float>.stride,
            options: .storageModeManaged
        ) else { return nil }

        guard let labelsBuffer = device.makeBuffer(
            length: pixelCount * MemoryLayout<Int32>.stride,
            options: .storageModeManaged
        ) else { return nil }

        let sumsLength = numColors * 4 * MemoryLayout<Float>.stride
        guard let sumsBuffer = device.makeBuffer(
            length: sumsLength,
            options: .storageModeManaged
        ) else { return nil }
        memset(sumsBuffer.contents(), 0, sumsLength)
        sumsBuffer.didModifyRange(0..<sumsLength)

        var numColorsVar = Int32(numColors)

        guard let outputTexture = makeTexture(width: width, height: height) else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: kmeansAssignPSO)

        for _ in 0..<iterations {
            // Assign step
            guard let assignEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            assignEncoder.setComputePipelineState(kmeansAssignPSO)
            assignEncoder.setTexture(inputTexture, index: 0)
            assignEncoder.setBuffer(labelsBuffer, offset: 0, index: 0)
            assignEncoder.setBuffer(centersBuffer, offset: 0, index: 1)
            assignEncoder.setBytes(&numColorsVar, length: MemoryLayout<Int32>.stride, index: 2)
            assignEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            assignEncoder.endEncoding()

            // Accumulate step
            guard let accumEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            accumEncoder.setComputePipelineState(kmeansAccumulatePSO)
            accumEncoder.setTexture(inputTexture, index: 0)
            accumEncoder.setBuffer(labelsBuffer, offset: 0, index: 0)
            accumEncoder.setBuffer(sumsBuffer, offset: 0, index: 1)
            accumEncoder.setBytes(&numColorsVar, length: MemoryLayout<Int32>.stride, index: 2)
            accumEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            accumEncoder.endEncoding()

            // Update centers step
            guard let updateEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            updateEncoder.setComputePipelineState(kmeansUpdateCentersPSO)
            updateEncoder.setBuffer(centersBuffer, offset: 0, index: 0)
            updateEncoder.setBuffer(sumsBuffer, offset: 0, index: 1)
            updateEncoder.setBytes(&numColorsVar, length: MemoryLayout<Int32>.stride, index: 2)
            let updateGrid = MTLSize(width: numColors, height: 1, depth: 1)
            let updateGroup = MTLSize(width: min(numColors, 64), height: 1, depth: 1)
            updateEncoder.dispatchThreads(updateGrid, threadsPerThreadgroup: updateGroup)
            updateEncoder.endEncoding()
        }

        // Synchronize centers buffer for CPU readback before palette restriction
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: centersBuffer)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalImageProcessor] K-means iterations error: \(error)")
            return nil
        }

        // If restrictPalette is provided, snap each center to the nearest palette color
        if let palette = restrictPalette, !palette.isEmpty {
            let centersPtr = centersBuffer.contents().bindMemory(to: Float.self, capacity: numColors * 3)
            for c in 0..<numColors {
                let r = centersPtr[c * 3 + 0]
                let g = centersPtr[c * 3 + 1]
                let b = centersPtr[c * 3 + 2]

                var bestDist: Float = .greatestFiniteMagnitude
                var bestPalette = palette[0]
                for p in palette {
                    let dr = r - p.x
                    let dg = g - p.y
                    let db = b - p.z
                    let dist = dr * dr + dg * dg + db * db
                    if dist < bestDist {
                        bestDist = dist
                        bestPalette = p
                    }
                }
                centersPtr[c * 3 + 0] = bestPalette.x
                centersPtr[c * 3 + 1] = bestPalette.y
                centersPtr[c * 3 + 2] = bestPalette.z
            }
            centersBuffer.didModifyRange(0..<numColors * 3 * MemoryLayout<Float>.stride)

            // Reassign labels with snapped centers so pixels map to correct palette colors
            guard let reassignBuffer = commandQueue.makeCommandBuffer(),
                  let reassignEncoder = reassignBuffer.makeComputeCommandEncoder() else { return nil }
            reassignEncoder.setComputePipelineState(kmeansAssignPSO)
            reassignEncoder.setTexture(inputTexture, index: 0)
            reassignEncoder.setBuffer(labelsBuffer, offset: 0, index: 0)
            reassignEncoder.setBuffer(centersBuffer, offset: 0, index: 1)
            reassignEncoder.setBytes(&numColorsVar, length: MemoryLayout<Int32>.stride, index: 2)
            reassignEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            reassignEncoder.endEncoding()
            if let blit = reassignBuffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: labelsBuffer)
                blit.endEncoding()
            }
            reassignBuffer.commit()
            reassignBuffer.waitUntilCompleted()
        }

        // Apply final labels + synchronize labels and output for CPU readback
        guard let applyBuffer = commandQueue.makeCommandBuffer() else { return nil }

        guard let applyEncoder = applyBuffer.makeComputeCommandEncoder() else { return nil }
        applyEncoder.setComputePipelineState(kmeansApplyPSO)
        applyEncoder.setBuffer(labelsBuffer, offset: 0, index: 0)
        applyEncoder.setBuffer(centersBuffer, offset: 0, index: 1)
        applyEncoder.setTexture(outputTexture, index: 0)
        applyEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        applyEncoder.endEncoding()

        // Synchronize managed resources for CPU readback
        if let blitEncoder = applyBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.synchronize(resource: labelsBuffer)
            blitEncoder.synchronize(resource: centersBuffer)
            blitEncoder.endEncoding()
        }

        applyBuffer.commit()
        applyBuffer.waitUntilCompleted()

        if let error = applyBuffer.error {
            print("[MetalImageProcessor] K-means apply error: \(error)")
            return nil
        }

        guard let image = imageFromTexture(outputTexture) else { return nil }

        return KMeansResult(
            image: image,
            labelsBuffer: labelsBuffer,
            centersBuffer: centersBuffer,
            width: width,
            height: height,
            numColors: numColors
        )
    }

    // MARK: - Narrow Strip Cleanup

    /// Run narrow strip cleanup on a labels buffer. Ping-pongs between two buffers
    /// for `passes` iterations, removing 1-pixel-wide strips.
    func narrowStripCleanup(
        labels: MTLBuffer,
        centers: MTLBuffer,
        width: Int,
        height: Int,
        numColors: Int,
        passes: Int = 3
    ) -> MTLBuffer? {
        let pixelCount = width * height
        let bufferLength = pixelCount * MemoryLayout<Int32>.stride

        guard let tempBuffer = device.makeBuffer(
            length: bufferLength,
            options: .storageModeManaged
        ) else { return nil }

        var widthVar = Int32(width)
        var heightVar = Int32(height)

        // Ping-pong between labels<->temp
        var src = labels
        var dst = tempBuffer

        for _ in 0..<passes {
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

            encoder.setComputePipelineState(pbnNarrowStripPSO)
            encoder.setBuffer(src, offset: 0, index: 0)
            encoder.setBuffer(dst, offset: 0, index: 1)
            encoder.setBuffer(centers, offset: 0, index: 2)
            encoder.setBytes(&widthVar, length: MemoryLayout<Int32>.stride, index: 3)
            encoder.setBytes(&heightVar, length: MemoryLayout<Int32>.stride, index: 4)

            let w = pbnNarrowStripPSO.threadExecutionWidth
            let h = pbnNarrowStripPSO.maxTotalThreadsPerThreadgroup / w
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let gridSize = MTLSize(width: width, height: height, depth: 1)
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()

            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: dst)
                blit.endEncoding()
            }

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if let error = commandBuffer.error {
                print("[MetalImageProcessor] narrowStripCleanup error: \(error)")
                return nil
            }

            // Swap for next pass
            let tmp = src
            src = dst
            dst = tmp
        }

        // src now points to the final result
        return src
    }

    // MARK: - Labels to Region Map

    /// Convert an Int32 labels buffer to an R8Uint region map texture.
    func labelsToRegionMap(labels: MTLBuffer, width: Int, height: Int) -> MTLTexture? {
        guard let regionMap = makeR8UintTexture(width: width, height: height) else { return nil }

        var widthVar = Int32(width)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pbnLabelsToRegionMapPSO)
        encoder.setBuffer(labels, offset: 0, index: 0)
        encoder.setTexture(regionMap, index: 0)
        encoder.setBytes(&widthVar, length: MemoryLayout<Int32>.stride, index: 1)

        let w = pbnLabelsToRegionMapPSO.threadExecutionWidth
        let h = pbnLabelsToRegionMapPSO.maxTotalThreadsPerThreadgroup / w
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let gridSize = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: regionMap)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalImageProcessor] labelsToRegionMap error: \(error)")
            return nil
        }

        return regionMap
    }

    // MARK: - Bilateral Filter

    func bilateralFilter(
        _ source: NSImage,
        diameter: Int = 21,
        sigmaColor: Double = 21,
        sigmaSpace: Double = 14
    ) -> NSImage? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        guard let outputTexture = makeTexture(width: inputTexture.width, height: inputTexture.height) else { return nil }

        var radius = Int32(diameter / 2)
        // OpenCV uses 0-255 pixel space for sigmaColor; Metal textures are 0-1 float range
        var sigC = Float(sigmaColor / 255.0)
        var sigS = Float(sigmaSpace)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(bilateralPSO)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&radius, length: MemoryLayout<Int32>.stride, index: 0)
        encoder.setBytes(&sigC, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setBytes(&sigS, length: MemoryLayout<Float>.stride, index: 2)

        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: bilateralPSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalImageProcessor] Bilateral filter error: \(error)")
            return nil
        }

        return imageFromTexture(outputTexture)
    }

    // MARK: - Gaussian Blur

    func gaussianBlur(_ source: NSImage, sigma: Double = 3) -> NSImage? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        let width = inputTexture.width
        let height = inputTexture.height

        // Compute kernel weights
        let radius = Int(ceil(sigma * 3))
        let kernelSize = radius * 2 + 1
        var weights = [Float](repeating: 0, count: kernelSize)
        let sigmaF = Float(sigma)
        let norm = -0.5 / (sigmaF * sigmaF)
        for i in 0..<kernelSize {
            let x = Float(i - radius)
            weights[i] = exp(x * x * norm)
        }

        var radiusVar = Int32(radius)

        // Intermediate texture for horizontal pass
        guard let tempTexture = makeTexture(width: width, height: height),
              let outputTexture = makeTexture(width: width, height: height) else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Horizontal pass
        guard let hEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        hEncoder.setComputePipelineState(gaussianBlurHPSO)
        hEncoder.setTexture(inputTexture, index: 0)
        hEncoder.setTexture(tempTexture, index: 1)
        hEncoder.setBytes(weights, length: kernelSize * MemoryLayout<Float>.stride, index: 0)
        hEncoder.setBytes(&radiusVar, length: MemoryLayout<Int32>.stride, index: 1)
        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: gaussianBlurHPSO)
        hEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        hEncoder.endEncoding()

        // Vertical pass
        guard let vEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        vEncoder.setComputePipelineState(gaussianBlurVPSO)
        vEncoder.setTexture(tempTexture, index: 0)
        vEncoder.setTexture(outputTexture, index: 1)
        vEncoder.setBytes(weights, length: kernelSize * MemoryLayout<Float>.stride, index: 0)
        vEncoder.setBytes(&radiusVar, length: MemoryLayout<Int32>.stride, index: 1)
        vEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        vEncoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalImageProcessor] Gaussian blur error: \(error)")
            return nil
        }

        return imageFromTexture(outputTexture)
    }

    // MARK: - Desaturate

    func desaturate(_ source: NSImage) -> NSImage? {
        return dispatchSimple(source: source, pso: desaturatePSO)
    }

    // MARK: - Brightness + Contrast

    func adjustBrightnessContrast(
        _ source: NSImage,
        brightness: Double,
        contrast: Double
    ) -> NSImage? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        guard let outputTexture = makeTexture(width: inputTexture.width, height: inputTexture.height) else { return nil }

        var brightnessF = Float(brightness)
        var contrastF = Float(contrast)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(brightnessContrastPSO)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&brightnessF, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setBytes(&contrastF, length: MemoryLayout<Float>.stride, index: 1)

        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: brightnessContrastPSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return imageFromTexture(outputTexture)
    }

    // MARK: - Posterize

    func posterize(_ source: NSImage, levels: Int) -> NSImage? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        guard let outputTexture = makeTexture(width: inputTexture.width, height: inputTexture.height) else { return nil }

        var levelsVar = Int32(levels)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(posterizePSO)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&levelsVar, length: MemoryLayout<Int32>.stride, index: 0)

        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: posterizePSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return imageFromTexture(outputTexture)
    }

    // MARK: - Threshold Map

    /// Map a grayscale image to palette colors based on brightness thresholds.
    /// - Parameters:
    ///   - source: Input image (will be converted to grayscale luminance internally by the shader).
    ///   - thresholds: Ascending brightness boundary values in [0, 255].
    ///   - colors: Array of RGB triplets (each [r, g, b] in 0-255). Must have thresholds.count + 1 entries.
    func thresholdMap(_ source: NSImage, thresholds: [Int], colors: [[Double]]) -> NSImage? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        guard let outputTexture = makeTexture(width: inputTexture.width, height: inputTexture.height) else { return nil }

        var thresholdValues = thresholds.map { Int32($0) }
        var numThresholds = Int32(thresholds.count)

        // Pack colors as float3 array (SIMD-aligned: 16 bytes each)
        var paletteData = [SIMD3<Float>](repeating: .zero, count: colors.count)
        for (i, c) in colors.enumerated() {
            let r = Float(c.count > 0 ? c[0] / 255.0 : 0)
            let g = Float(c.count > 1 ? c[1] / 255.0 : 0)
            let b = Float(c.count > 2 ? c[2] / 255.0 : 0)
            paletteData[i] = SIMD3<Float>(r, g, b)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(thresholdMapPSO)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&thresholdValues, length: thresholdValues.count * MemoryLayout<Int32>.stride, index: 0)
        encoder.setBytes(&paletteData, length: paletteData.count * MemoryLayout<SIMD3<Float>>.stride, index: 1)
        encoder.setBytes(&numThresholds, length: MemoryLayout<Int32>.stride, index: 2)

        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: thresholdMapPSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return imageFromTexture(outputTexture)
    }

    // MARK: - Gaussian Noise

    func addGaussianNoise(_ source: NSImage, strength: Double = 8) -> NSImage? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        guard let outputTexture = makeTexture(width: inputTexture.width, height: inputTexture.height) else { return nil }

        var strengthF = Float(strength)
        var seed = UInt32.random(in: 0...UInt32.max)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(addNoisePSO)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&strengthF, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setBytes(&seed, length: MemoryLayout<UInt32>.stride, index: 1)

        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: addNoisePSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return imageFromTexture(outputTexture)
    }

    // MARK: - Invert

    func invert(_ source: NSImage) -> NSImage? {
        return dispatchSimple(source: source, pso: invertPSO)
    }

    // MARK: - Multiply Blend

    func multiplyBlend(base: NSImage, top: NSImage) -> NSImage? {
        guard let baseTexture = textureFromImage(base),
              let topTexture = textureFromImage(top) else { return nil }

        let width = baseTexture.width
        let height = baseTexture.height
        guard let outputTexture = makeTexture(width: width, height: height) else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(multiplyBlendPSO)
        encoder.setTexture(baseTexture, index: 0)
        encoder.setTexture(topTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)

        let (gridSize, threadsPerGroup) = threadGroups(for: baseTexture, pso: multiplyBlendPSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return imageFromTexture(outputTexture)
    }

    // MARK: - Additive Weighted Blend

    func addWeighted(
        _ src1: NSImage,
        alpha: Double,
        _ src2: NSImage,
        beta: Double,
        gamma: Double = 0
    ) -> NSImage? {
        guard let tex1 = textureFromImage(src1),
              let tex2 = textureFromImage(src2) else { return nil }

        let width = tex1.width
        let height = tex1.height
        guard let outputTexture = makeTexture(width: width, height: height) else { return nil }

        var alphaF = Float(alpha)
        var betaF = Float(beta)
        var gammaF = Float(gamma)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(addWeightedPSO)
        encoder.setTexture(tex1, index: 0)
        encoder.setTexture(tex2, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&alphaF, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setBytes(&betaF, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setBytes(&gammaF, length: MemoryLayout<Float>.stride, index: 2)

        let (gridSize, threadsPerGroup) = threadGroups(for: tex1, pso: addWeightedPSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return imageFromTexture(outputTexture)
    }

    // MARK: - Chained Dry-Media Pipeline

    /// Chained dry-media pipeline: desaturate -> threshold map -> blur -> noise -> brightness/contrast.
    /// All operations stay on GPU in a SINGLE command buffer -- no NSImage conversion between steps.
    /// Returns the final NSImage.
    func renderDryMedia(
        source: NSImage,
        thresholds: [Int],
        paletteColors: [[Double]],
        blurSigma: Double,
        noiseStrength: Double,
        brightness: Double,
        contrast: Double
    ) -> NSImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let inputTexture = textureFromImage(source) else { return nil }
        let w = inputTexture.width
        let h = inputTexture.height

        // Create intermediate textures (reusable ping-pong pair)
        guard let texA = makeTexture(width: w, height: h),
              let texB = makeTexture(width: w, height: h) else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Step 1: Desaturate (input -> texA)
        encodeDesaturate(commandBuffer, input: inputTexture, output: texA)

        // Step 2: Threshold map (texA -> texB)
        encodeThresholdMap(commandBuffer, input: texA, output: texB,
                           thresholds: thresholds, colors: paletteColors)

        // Step 3: Gaussian blur (texB -> texA, optional)
        if blurSigma > 0.5 {
            guard let texC = makeTexture(width: w, height: h) else { return nil }
            encodeGaussianBlurH(commandBuffer, input: texB, output: texC, sigma: blurSigma)
            encodeGaussianBlurV(commandBuffer, input: texC, output: texA, sigma: blurSigma)
        } else {
            encodeCopy(commandBuffer, from: texB, to: texA)
        }

        // Step 4: Add noise (texA -> texB)
        encodeNoise(commandBuffer, input: texA, output: texB, strength: noiseStrength)

        // Step 5: Brightness/contrast (texB -> texA)
        encodeBrightnessContrast(commandBuffer, input: texB, output: texA,
                                  brightness: brightness, contrast: contrast)

        // Synchronize for CPU readback
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texA)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalChain] renderDryMedia error: \(error)")
            return nil
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        print("[MetalChain] renderDryMedia: \(String(format: "%.3f", elapsed))s for \(w)x\(h)")
        return imageFromTexture(texA)
    }

    // MARK: - Chained Pencil Sketch Pipeline

    /// Chained pencil sketch: grayscale -> invert -> blur -> color dodge divide -> contrast -> noise.
    /// All operations stay on GPU in a SINGLE command buffer.
    func renderPencilSketch(
        source: NSImage,
        blurRadius: Double,
        brightness: Double,
        contrast: Double,
        noiseStrength: Double
    ) -> NSImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let inputTexture = textureFromImage(source) else { return nil }
        let w = inputTexture.width
        let h = inputTexture.height

        guard let texA = makeTexture(width: w, height: h),
              let texB = makeTexture(width: w, height: h),
              let texC = makeTexture(width: w, height: h) else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Step 1: Desaturate (input -> texA) -- this is the grayscale original
        encodeDesaturate(commandBuffer, input: inputTexture, output: texA)

        // Step 2: Invert (texA -> texB)
        encodeInvert(commandBuffer, input: texA, output: texB)

        // Step 3: Gaussian blur on inverted (texB -> texC -> texB via separable)
        // Use texC as temp for horizontal pass
        let sigma = max(blurRadius, 1.0)
        encodeGaussianBlurH(commandBuffer, input: texB, output: texC, sigma: sigma)
        encodeGaussianBlurV(commandBuffer, input: texC, output: texB, sigma: sigma)

        // Step 4: Color dodge blend (texA=grayscale, texB=blurred inverted -> texC)
        encodeColorDodge(commandBuffer, original: texA, blurred: texB, output: texC)

        // Step 5: Brightness/contrast (texC -> texA)
        encodeBrightnessContrast(commandBuffer, input: texC, output: texA,
                                  brightness: brightness, contrast: contrast)

        // Step 6: Noise (texA -> texB)
        if noiseStrength > 0.1 {
            encodeNoise(commandBuffer, input: texA, output: texB, strength: noiseStrength)
            // Synchronize texB for readback
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: texB)
                blit.endEncoding()
            }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                print("[MetalChain] renderPencilSketch error: \(error)")
                return nil
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            print("[MetalChain] renderPencilSketch: \(String(format: "%.3f", elapsed))s for \(w)x\(h)")
            return imageFromTexture(texB)
        } else {
            // No noise -- read from texA
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: texA)
                blit.endEncoding()
            }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                print("[MetalChain] renderPencilSketch error: \(error)")
                return nil
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            print("[MetalChain] renderPencilSketch: \(String(format: "%.3f", elapsed))s for \(w)x\(h)")
            return imageFromTexture(texA)
        }
    }

    // MARK: - Private Encode Helpers (Chained Pipeline)

    private func encodeDesaturate(_ cb: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(desaturatePSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        let (grid, group) = threadGroups(for: input, pso: desaturatePSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    private func encodeInvert(_ cb: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(invertPSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        let (grid, group) = threadGroups(for: input, pso: invertPSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    private func encodeThresholdMap(
        _ cb: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        thresholds: [Int],
        colors: [[Double]]
    ) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(thresholdMapPSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)

        var thresholdValues = thresholds.map { Int32($0) }
        var numThresholds = Int32(thresholds.count)

        // Pack colors as SIMD3<Float> (colors are already in 0-1 range for chained pipeline)
        var paletteData = [SIMD3<Float>](repeating: .zero, count: colors.count)
        for (i, c) in colors.enumerated() {
            let r = Float(c.count > 0 ? c[0] : 0)
            let g = Float(c.count > 1 ? c[1] : 0)
            let b = Float(c.count > 2 ? c[2] : 0)
            paletteData[i] = SIMD3<Float>(r, g, b)
        }

        enc.setBytes(&thresholdValues, length: thresholdValues.count * MemoryLayout<Int32>.stride, index: 0)
        enc.setBytes(&paletteData, length: paletteData.count * MemoryLayout<SIMD3<Float>>.stride, index: 1)
        enc.setBytes(&numThresholds, length: MemoryLayout<Int32>.stride, index: 2)

        let (grid, group) = threadGroups(for: input, pso: thresholdMapPSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    private func encodeGaussianBlurH(_ cb: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, sigma: Double) {
        let radius = Int(ceil(sigma * 3))
        let kernelSize = radius * 2 + 1
        var weights = [Float](repeating: 0, count: kernelSize)
        let sigmaF = Float(sigma)
        let norm = -0.5 / (sigmaF * sigmaF)
        for i in 0..<kernelSize {
            let x = Float(i - radius)
            weights[i] = exp(x * x * norm)
        }
        var radiusVar = Int32(radius)

        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(gaussianBlurHPSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        enc.setBytes(weights, length: kernelSize * MemoryLayout<Float>.stride, index: 0)
        enc.setBytes(&radiusVar, length: MemoryLayout<Int32>.stride, index: 1)
        let (grid, group) = threadGroups(for: input, pso: gaussianBlurHPSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    private func encodeGaussianBlurV(_ cb: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, sigma: Double) {
        let radius = Int(ceil(sigma * 3))
        let kernelSize = radius * 2 + 1
        var weights = [Float](repeating: 0, count: kernelSize)
        let sigmaF = Float(sigma)
        let norm = -0.5 / (sigmaF * sigmaF)
        for i in 0..<kernelSize {
            let x = Float(i - radius)
            weights[i] = exp(x * x * norm)
        }
        var radiusVar = Int32(radius)

        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(gaussianBlurVPSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        enc.setBytes(weights, length: kernelSize * MemoryLayout<Float>.stride, index: 0)
        enc.setBytes(&radiusVar, length: MemoryLayout<Int32>.stride, index: 1)
        let (grid, group) = threadGroups(for: input, pso: gaussianBlurVPSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    private func encodeNoise(_ cb: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, strength: Double) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(addNoisePSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        var strengthF = Float(strength)
        var seed = UInt32.random(in: 0...UInt32.max)
        enc.setBytes(&strengthF, length: MemoryLayout<Float>.stride, index: 0)
        enc.setBytes(&seed, length: MemoryLayout<UInt32>.stride, index: 1)
        let (grid, group) = threadGroups(for: input, pso: addNoisePSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    private func encodeBrightnessContrast(
        _ cb: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        brightness: Double,
        contrast: Double
    ) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(brightnessContrastPSO)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        var brightnessF = Float(brightness)
        var contrastF = Float(contrast)
        enc.setBytes(&brightnessF, length: MemoryLayout<Float>.stride, index: 0)
        enc.setBytes(&contrastF, length: MemoryLayout<Float>.stride, index: 1)
        let (grid, group) = threadGroups(for: input, pso: brightnessContrastPSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    private func encodeColorDodge(
        _ cb: MTLCommandBuffer,
        original: MTLTexture,
        blurred: MTLTexture,
        output: MTLTexture
    ) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(colorDodgeBlendPSO)
        enc.setTexture(original, index: 0)
        enc.setTexture(blurred, index: 1)
        enc.setTexture(output, index: 2)
        let (grid, group) = threadGroups(for: original, pso: colorDodgeBlendPSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    // MARK: - Paint-By-Numbers Dispatch Methods

    /// Create an R8Uint texture for region map storage.
    func makeR8UintTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    /// Classify each grayscale pixel into a region index based on brightness thresholds.
    /// - Parameters:
    ///   - grayscale: Desaturated RGBA texture (reads .r channel).
    ///   - thresholds: Ascending threshold values in 0-255 range (regionCount - 1 values).
    ///   - regionCount: Total number of regions (thresholds.count + 1).
    /// - Returns: R8Uint texture with region indices, or nil on failure.
    func pbnClassifyRegions(grayscale: MTLTexture, thresholds: [UInt32], regionCount: UInt32) -> MTLTexture? {
        guard let outputTexture = makeR8UintTexture(width: grayscale.width, height: grayscale.height) else { return nil }

        var thresholdData = thresholds
        var regionCountVar = regionCount

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pbnClassifyPSO)
        encoder.setTexture(grayscale, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&thresholdData, length: thresholdData.count * MemoryLayout<UInt32>.stride, index: 0)
        encoder.setBytes(&regionCountVar, length: MemoryLayout<UInt32>.stride, index: 1)

        let (gridSize, threadsPerGroup) = threadGroups(for: grayscale, pso: pbnClassifyPSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalImageProcessor] pbnClassifyRegions error: \(error)")
            return nil
        }

        return outputTexture
    }

    /// Generate tinted regions with boundary lines from a region map.
    /// - Parameters:
    ///   - regionMap: R8Uint texture with region indices.
    ///   - paletteColors: Pre-blended tint RGBA colors (one per region, 20% tint over white).
    ///   - lineColor: RGBA color for boundary lines.
    ///   - lineWeight: Thickness of boundary lines in pixels.
    ///   - width: Output width.
    ///   - height: Output height.
    /// - Returns: RGBA8 texture with tinted regions and boundary lines, or nil on failure.
    func pbnTintAndBoundary(
        regionMap: MTLTexture,
        paletteColors: [SIMD4<Float>],
        lineColor: SIMD4<Float>,
        lineWeight: UInt32,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        guard let outputTexture = makeTexture(width: width, height: height) else { return nil }

        var paletteData = paletteColors
        var lineColorVar = lineColor
        var lineWeightVar = lineWeight

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pbnTintBoundaryPSO)
        encoder.setTexture(regionMap, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&paletteData, length: paletteData.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setBytes(&lineColorVar, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setBytes(&lineWeightVar, length: MemoryLayout<UInt32>.stride, index: 2)

        let (gridSize, threadsPerGroup) = threadGroups(for: outputTexture, pso: pbnTintBoundaryPSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalImageProcessor] pbnTintAndBoundary error: \(error)")
            return nil
        }

        return outputTexture
    }

    /// Highlight a single region at full brightness, dimming all others.
    /// - Parameters:
    ///   - regionMap: R8Uint texture with region indices.
    ///   - baseImage: RGBA8 texture (the tinted/colored base).
    ///   - highlightedRegion: Index of the region to highlight.
    ///   - dimAlpha: Blend factor for non-highlighted regions (0 = fully gray, 1 = no dimming).
    /// - Returns: RGBA8 texture with highlighted region, or nil on failure.
    func pbnHoverHighlight(
        regionMap: MTLTexture,
        baseImage: MTLTexture,
        highlightedRegion: UInt32,
        dimAlpha: Float
    ) -> MTLTexture? {
        guard let outputTexture = makeTexture(width: baseImage.width, height: baseImage.height) else { return nil }

        var highlightVar = highlightedRegion
        var dimAlphaVar = dimAlpha

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pbnHoverHighlightPSO)
        encoder.setTexture(regionMap, index: 0)
        encoder.setTexture(baseImage, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&highlightVar, length: MemoryLayout<UInt32>.stride, index: 0)
        encoder.setBytes(&dimAlphaVar, length: MemoryLayout<Float>.stride, index: 1)

        let (gridSize, threadsPerGroup) = threadGroups(for: baseImage, pso: pbnHoverHighlightPSO)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            print("[MetalImageProcessor] pbnHoverHighlight error: \(error)")
            return nil
        }

        return outputTexture
    }

    // MARK: - Paint-By-Numbers Chained Pipeline Encode Helpers

    /// Encode the classify regions step into an existing command buffer.
    func encodePbnClassifyRegions(
        _ cb: MTLCommandBuffer,
        grayscale: MTLTexture,
        regionMap: MTLTexture,
        thresholds: [UInt32],
        regionCount: UInt32
    ) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pbnClassifyPSO)
        enc.setTexture(grayscale, index: 0)
        enc.setTexture(regionMap, index: 1)
        var thresholdData = thresholds
        var regionCountVar = regionCount
        enc.setBytes(&thresholdData, length: thresholdData.count * MemoryLayout<UInt32>.stride, index: 0)
        enc.setBytes(&regionCountVar, length: MemoryLayout<UInt32>.stride, index: 1)
        let (grid, group) = threadGroups(for: grayscale, pso: pbnClassifyPSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    /// Encode the tint-and-boundary step into an existing command buffer.
    func encodePbnTintAndBoundary(
        _ cb: MTLCommandBuffer,
        regionMap: MTLTexture,
        output: MTLTexture,
        paletteColors: [SIMD4<Float>],
        lineColor: SIMD4<Float>,
        lineWeight: UInt32
    ) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pbnTintBoundaryPSO)
        enc.setTexture(regionMap, index: 0)
        enc.setTexture(output, index: 1)
        var paletteData = paletteColors
        var lineColorVar = lineColor
        var lineWeightVar = lineWeight
        enc.setBytes(&paletteData, length: paletteData.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setBytes(&lineColorVar, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.setBytes(&lineWeightVar, length: MemoryLayout<UInt32>.stride, index: 2)
        let (grid, group) = threadGroups(for: output, pso: pbnTintBoundaryPSO)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    private func encodeCopy(_ cb: MTLCommandBuffer, from src: MTLTexture, to dst: MTLTexture) {
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    // MARK: - Private Helpers

    /// Dispatch a simple input -> output shader with no additional buffers.
    // MARK: - Texture-to-Texture Helpers (no NSImage round-trip)

    /// Desaturate a texture in-place on the GPU. Returns output texture (never leaves GPU).
    func desaturateTexture(_ input: MTLTexture) -> MTLTexture? {
        guard let output = makeTexture(width: input.width, height: input.height) else { return nil }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(desaturatePSO)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        let (grid, group) = threadGroups(for: input, pso: desaturatePSO)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        if let blit = commandBuffer.makeBlitCommandEncoder() { blit.synchronize(resource: output); blit.endEncoding() }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }

    /// Gaussian blur a texture on the GPU (separable: horizontal then vertical).
    func gaussianBlurTexture(_ input: MTLTexture, sigma: Double = 3) -> MTLTexture? {
        let radius = Int(ceil(sigma * 3))
        let kernelSize = radius * 2 + 1
        var weights = [Float](repeating: 0, count: kernelSize)
        let sigma2 = Float(sigma * sigma)
        var sum: Float = 0
        for i in 0..<kernelSize {
            let x = Float(i - radius)
            weights[i] = exp(-x * x / (2 * sigma2))
            sum += weights[i]
        }
        for i in 0..<kernelSize { weights[i] /= sum }

        guard let intermediate = makeTexture(width: input.width, height: input.height),
              let output = makeTexture(width: input.width, height: input.height) else { return nil }

        var kernelSizeU: UInt32 = UInt32(kernelSize)

        // Horizontal pass
        guard let cb1 = commandQueue.makeCommandBuffer(),
              let enc1 = cb1.makeComputeCommandEncoder() else { return nil }
        enc1.setComputePipelineState(gaussianBlurHPSO)
        enc1.setTexture(input, index: 0)
        enc1.setTexture(intermediate, index: 1)
        enc1.setBytes(&weights, length: weights.count * MemoryLayout<Float>.stride, index: 0)
        enc1.setBytes(&kernelSizeU, length: MemoryLayout<UInt32>.stride, index: 1)
        let (grid1, group1) = threadGroups(for: input, pso: gaussianBlurHPSO)
        enc1.dispatchThreads(grid1, threadsPerThreadgroup: group1)
        enc1.endEncoding()
        cb1.commit()
        cb1.waitUntilCompleted()

        // Vertical pass
        guard let cb2 = commandQueue.makeCommandBuffer(),
              let enc2 = cb2.makeComputeCommandEncoder() else { return nil }
        enc2.setComputePipelineState(gaussianBlurVPSO)
        enc2.setTexture(intermediate, index: 0)
        enc2.setTexture(output, index: 1)
        enc2.setBytes(&weights, length: weights.count * MemoryLayout<Float>.stride, index: 0)
        enc2.setBytes(&kernelSizeU, length: MemoryLayout<UInt32>.stride, index: 1)
        let (grid2, group2) = threadGroups(for: intermediate, pso: gaussianBlurVPSO)
        enc2.dispatchThreads(grid2, threadsPerThreadgroup: group2)
        enc2.endEncoding()
        if let blit = cb2.makeBlitCommandEncoder() { blit.synchronize(resource: output); blit.endEncoding() }
        cb2.commit()
        cb2.waitUntilCompleted()

        return output
    }

    private func dispatchSimple(source: NSImage, pso: MTLComputePipelineState) -> NSImage? {
        guard let inputTexture = textureFromImage(source) else { return nil }
        guard let outputTexture = makeTexture(width: inputTexture.width, height: inputTexture.height) else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pso)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)

        let (gridSize, threadsPerGroup) = threadGroups(for: inputTexture, pso: pso)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: outputTexture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return imageFromTexture(outputTexture)
    }
}

// MARK: - Error Types

enum MetalError: Error, LocalizedError {
    case functionNotFound(String)
    case deviceNotAvailable

    var errorDescription: String? {
        switch self {
        case .functionNotFound(let name):
            return "Metal function '\(name)' not found in default library"
        case .deviceNotAvailable:
            return "No Metal device available"
        }
    }
}
