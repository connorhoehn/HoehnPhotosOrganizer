import Testing
@testable import HoehnPhotosOrganizer

struct ColorGradingLUTBuilderTests {

    private static let dim = ColorGradingLUTBuilder.dimension   // 32
    // 32³ samples × 4 channels (RGBA) × 4 bytes per Float
    private static let expectedByteCount = dim * dim * dim * 4 * MemoryLayout<Float>.size

    // MARK: - isIdentity

    @Test
    func testIsIdentityReturnsTrueForDefaultAdjustments() {
        let adj = PhotoAdjustments()
        #expect(ColorGradingLUTBuilder.isIdentity(adj),
                "Default PhotoAdjustments must be recognised as identity — all sub-systems are at zero")
    }

    @Test
    func testIsIdentityReturnsFalseWhenHSLModified() {
        var adj = PhotoAdjustments()
        adj.hsl.red.hue = 30   // non-zero hue shift on the red channel
        #expect(!ColorGradingLUTBuilder.isIdentity(adj),
                "isIdentity must return false when any HSL channel value is non-zero")
    }

    // MARK: - buildLUT byte count

    @Test
    func testBuildLUTProducesCorrectByteCount() {
        let data = ColorGradingLUTBuilder.buildLUT(from: PhotoAdjustments())
        #expect(data.count == Self.expectedByteCount,
                "buildLUT must produce exactly \(Self.expectedByteCount) bytes for a \(Self.dim)³ LUT")
    }

    // MARK: - Identity passthrough: pure black

    @Test
    func testBuildLUTIdentityPassesThroughPureBlack() {
        let data = ColorGradingLUTBuilder.buildLUT(from: PhotoAdjustments())
        // Sample (ri=0, gi=0, bi=0) occupies float indices 0–3
        let r = readFloat(from: data, floatIndex: 0)
        let g = readFloat(from: data, floatIndex: 1)
        let b = readFloat(from: data, floatIndex: 2)
        let a = readFloat(from: data, floatIndex: 3)
        #expect(abs(r) < 1e-4, "Identity LUT: black R must be ~0")
        #expect(abs(g) < 1e-4, "Identity LUT: black G must be ~0")
        #expect(abs(b) < 1e-4, "Identity LUT: black B must be ~0")
        #expect(abs(a - 1.0) < 1e-4, "Identity LUT: alpha must be 1.0 everywhere")
    }

    // MARK: - Identity passthrough: pure white

    @Test
    func testBuildLUTIdentityPassesThroughPureWhite() {
        let data = ColorGradingLUTBuilder.buildLUT(from: PhotoAdjustments())
        // Sample (ri=dim-1, gi=dim-1, bi=dim-1): idx = (31*32*32 + 31*32 + 31) * 4
        let dim = Self.dim
        let sampleIndex = ((dim - 1) * dim * dim + (dim - 1) * dim + (dim - 1)) * 4
        let r = readFloat(from: data, floatIndex: sampleIndex)
        let g = readFloat(from: data, floatIndex: sampleIndex + 1)
        let b = readFloat(from: data, floatIndex: sampleIndex + 2)
        #expect(abs(r - 1.0) < 1e-4, "Identity LUT: white R must be ~1.0")
        #expect(abs(g - 1.0) < 1e-4, "Identity LUT: white G must be ~1.0")
        #expect(abs(b - 1.0) < 1e-4, "Identity LUT: white B must be ~1.0")
    }

    // MARK: - Helper

    private func readFloat(from data: Data, floatIndex: Int) -> Float {
        let byteOffset = floatIndex * MemoryLayout<Float>.size
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: byteOffset, as: Float.self)
        }
    }
}
