import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - MinimalDNGWriter

/// Writes a processed (linear) DNG from a CGImage without external dependencies.
///
/// The output is a valid TIFF/DNG structure that Photoshop routes through Camera Raw
/// instead of the direct-open TIFF path, giving you full ACR tone / curve controls.
///
/// Format: LinearRaw (PhotometricInterpretation = 34892), 8 or 16-bit RGB, uncompressed.
/// Color matrix: identity (sRGB → sRGB) with D65 calibration illuminant.
enum MinimalDNGWriter {

    enum DNGError: LocalizedError {
        case pixelExtractionFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .pixelExtractionFailed:
                return "Could not extract pixel data from source image."
            case .writeFailed(let detail):
                return "Failed to write DNG: \(detail)"
            }
        }
    }

    // MARK: - Public entry point

    /// Write `image` as a minimal Linear DNG to `url`.
    /// The bit depth of the output matches the source (8 or 16-bit per channel).
    static func write(_ image: CGImage, to url: URL) throws {
        // Always write 8-bit. 16-bit TIFFs without an embedded ICC profile are treated as
        // linearSRGB by macOS Image I/O, causing washed-out proxy rendering. The 8-bit context
        // draw automatically converts linearSRGB → gamma-corrected sRGB, and 8-bit TIFFs without
        // ICC default to sRGB — so proxies, Finder, and Camera Raw all render correctly.
        let bpc = 8
        let pixelData = try extractRGBPixels(from: image, bitsPerComponent: bpc)
        let binary = buildDNG(
            width: image.width, height: image.height,
            bitsPerComponent: bpc,
            pixelData: pixelData
        )
        do {
            try binary.write(to: url, options: .atomic)
        } catch {
            throw DNGError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Pixel extraction

    private static func extractRGBPixels(from image: CGImage, bitsPerComponent: Int) throws -> Data {
        let w = image.width
        let h = image.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!

        if bitsPerComponent == 16 {
            // 16-bit: RGBA→RGB strip alpha (2 bytes/channel × 4 = 8 bytes/pixel input)
            let srcBytesPerRow = w * 8
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 16, bytesPerRow: srcBytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue |
                            CGBitmapInfo.byteOrder16Little.rawValue
            ) else { throw DNGError.pixelExtractionFailed }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let ptr = ctx.data else { throw DNGError.pixelExtractionFailed }

            var rgb = Data(count: w * h * 6)
            rgb.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let src = ptr.assumingMemoryBound(to: UInt16.self)
                var s = 0, d = 0
                for _ in 0 ..< w * h {
                    // src is RGBA-16LE; write R, G, B as little-endian UInt16 (TIFF "II" header)
                    let r = src[s], g = src[s+1], b = src[s+2]
                    dst[d]   = UInt8(r & 0xFF);  dst[d+1] = UInt8(r >> 8)
                    dst[d+2] = UInt8(g & 0xFF);  dst[d+3] = UInt8(g >> 8)
                    dst[d+4] = UInt8(b & 0xFF);  dst[d+5] = UInt8(b >> 8)
                    s += 4; d += 6
                }
            }
            return rgb
        } else {
            // 8-bit: RGBA→RGB strip alpha (1 byte/channel × 4 = 4 bytes/pixel input)
            let srcBytesPerRow = w * 4
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: srcBytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw DNGError.pixelExtractionFailed }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let ptr = ctx.data else { throw DNGError.pixelExtractionFailed }

            var rgb = Data(count: w * h * 3)
            rgb.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let src = ptr.assumingMemoryBound(to: UInt8.self)
                var s = 0, d = 0
                for _ in 0 ..< w * h {
                    dst[d] = src[s]; dst[d+1] = src[s+1]; dst[d+2] = src[s+2]
                    s += 4; d += 3
                }
            }
            return rgb
        }
    }

    // MARK: - TIFF/DNG binary builder

    // TIFF IFD binary layout (little-endian):
    //   0–7    : TIFF header  (8 bytes)
    //   8–9    : IFD entry count  (2 bytes)
    //   10–141 : 11 IFD entries × 12 bytes = 132 bytes
    //   142–145: next-IFD pointer = 0  (4 bytes)
    //   146–151: BitsPerSample overflow  (3 × SHORT = 6 bytes)
    //   152+   : pixel data  (padded to 4-byte boundary if needed)
    //
    // DNG-specific tags (DNGVersion 50706, DNGBackwardVersion 50707, UniqueCameraModel 50708,
    // ColorMatrix1 50721, CalibrationIlluminant1 50778) are intentionally omitted.
    // Those tags force Image I/O to route the file through the RA02 RAW decoder which rejects
    // TIFF-structured pixel data, breaking proxy generation and XMP embedding.
    // Without them the file is a plain RGB TIFF that every decoder handles correctly.

    private static let numIFDEntries: UInt16 = 11
    private static let bpsOffset     = UInt32(146)          // BitsPerSample data (8+2+132+4=146)
    private static let pixelBase     = 152                  // first pixel byte   (146+6)

    private static func buildDNG(width: Int, height: Int,
                                 bitsPerComponent: Int,
                                 pixelData: Data) -> Data {
        let pixelDataOffset = UInt32(pixelBase)
        let pixelDataSize   = UInt32(pixelData.count)
        let bpc             = UInt16(bitsPerComponent)

        var d = Data()
        d.reserveCapacity(pixelBase + pixelData.count)

        // ── TIFF header ────────────────────────────────────────────────
        d += u16(0x4949)   // "II" = little-endian
        d += u16(42)       // TIFF magic
        d += u32(8)        // IFD0 at offset 8

        // ── IFD0 ────────────────────────────────────────────────────────
        d += u16(numIFDEntries)

        //  Tag  Type  Count  Value/Offset
        d += ifd(254,  4, 1, 0)                          // NewSubFileType = 0 (full image)
        d += ifd(256,  4, 1, UInt32(width))              // ImageWidth
        d += ifd(257,  4, 1, UInt32(height))             // ImageLength
        d += ifd(258,  3, 3, bpsOffset)                  // BitsPerSample → overflow
        d += ifd(259,  3, 1, 1)                          // Compression = 1 (none)
        d += ifd(262,  3, 1, 2)                          // PhotometricInterpretation = RGB
        d += ifd(273,  4, 1, pixelDataOffset)            // StripOffsets
        d += ifd(277,  3, 1, 3)                          // SamplesPerPixel
        d += ifd(278,  4, 1, UInt32(height))             // RowsPerStrip
        d += ifd(279,  4, 1, pixelDataSize)              // StripByteCounts
        d += ifd(284,  3, 1, 1)                          // PlanarConfiguration = 1 (chunky)

        d += u32(0)   // next IFD = none

        // ── BitsPerSample overflow (3 × SHORT) ─────────────────────────
        d += u16(bpc); d += u16(bpc); d += u16(bpc)

        // ── Pixel data (padded so offset == pixelBase) ──────────────────
        while d.count < pixelBase { d += Data([0]) }
        d += pixelData

        return d
    }

    // MARK: - Binary helpers

    /// Standard IFD entry: tag / type / count / 4-byte value-or-offset (little-endian).
    private static func ifd(_ tag: UInt16, _ type: UInt16,
                             _ count: UInt32, _ value: UInt32) -> Data {
        u16(tag) + u16(type) + u32(count) + u32(value)
    }

    /// IFD entry where the value field holds 4 raw bytes (e.g. BYTE[4] for DNGVersion).
    private static func ifdBytes(_ tag: UInt16,
                                  _ bytes: (UInt8,UInt8,UInt8,UInt8)) -> Data {
        u16(tag) + u16(1) + u32(4) + Data([bytes.0, bytes.1, bytes.2, bytes.3])
    }

    private static func u16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    }
    private static func u32(_ v: UInt32) -> Data {
        Data([UInt8( v        & 0xFF), UInt8((v >>  8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8( v >> 24        )])
    }
    private static func s32(_ v: Int32) -> Data { u32(UInt32(bitPattern: v)) }
}
