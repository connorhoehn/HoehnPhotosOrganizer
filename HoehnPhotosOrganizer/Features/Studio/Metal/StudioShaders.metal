#include <metal_stdlib>
using namespace metal;

// MARK: - K-Means Quantization

/// Assignment step: for each pixel, find the nearest center by squared Euclidean distance.
kernel void kmeans_assign(
    texture2d<float, access::read> input [[texture(0)]],
    device int *labels [[buffer(0)]],
    device float3 *centers [[buffer(1)]],
    constant int &numColors [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float4 pixel = input.read(gid);
    float3 color = pixel.rgb;

    int bestLabel = 0;
    float bestDist = MAXFLOAT;
    for (int c = 0; c < numColors; c++) {
        float3 diff = color - centers[c];
        float dist = dot(diff, diff);
        if (dist < bestDist) {
            bestDist = dist;
            bestLabel = c;
        }
    }
    labels[gid.y * input.get_width() + gid.x] = bestLabel;
}

/// Accumulation step: atomically sum per-label color components and pixel counts.
/// sums layout: numColors * 4 floats — [r, g, b, count] per cluster.
kernel void kmeans_accumulate(
    texture2d<float, access::read> input [[texture(0)]],
    device int *labels [[buffer(0)]],
    device atomic_float *sums [[buffer(1)]],
    constant int &numColors [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    int idx = gid.y * input.get_width() + gid.x;
    int label = labels[idx];
    float4 pixel = input.read(gid);

    int base = label * 4;
    atomic_fetch_add_explicit(&sums[base + 0], pixel.r, memory_order_relaxed);
    atomic_fetch_add_explicit(&sums[base + 1], pixel.g, memory_order_relaxed);
    atomic_fetch_add_explicit(&sums[base + 2], pixel.b, memory_order_relaxed);
    atomic_fetch_add_explicit(&sums[base + 3], 1.0, memory_order_relaxed);
}

/// Update centers from accumulated sums, then zero the accumulators for the next iteration.
kernel void kmeans_update_centers(
    device float3 *centers [[buffer(0)]],
    device float *sums [[buffer(1)]],
    constant int &numColors [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= uint(numColors)) return;

    int base = gid * 4;
    float count = sums[base + 3];
    if (count > 0) {
        centers[gid] = float3(sums[base] / count,
                              sums[base + 1] / count,
                              sums[base + 2] / count);
    }
    // Reset accumulators for next iteration
    sums[base + 0] = 0.0;
    sums[base + 1] = 0.0;
    sums[base + 2] = 0.0;
    sums[base + 3] = 0.0;
}

/// Apply quantized colors: replace each pixel with its assigned center color.
kernel void kmeans_apply(
    device int *labels [[buffer(0)]],
    device float3 *centers [[buffer(1)]],
    texture2d<float, access::write> output [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    int label = labels[gid.y * output.get_width() + gid.x];
    float3 color = centers[label];
    output.write(float4(color, 1.0), gid);
}

// MARK: - Bilateral Filter

kernel void bilateral_filter(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant int &radius [[buffer(0)]],
    constant float &sigmaColor [[buffer(1)]],
    constant float &sigmaSpace [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width();
    int h = input.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;

    float4 center = input.read(gid);
    float3 centerRGB = center.rgb;

    float3 sum = float3(0.0);
    float wsum = 0.0;

    float invSigmaColor2 = -0.5 / (sigmaColor * sigmaColor);
    float invSigmaSpace2 = -0.5 / (sigmaSpace * sigmaSpace);

    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 pos = int2(gid) + int2(dx, dy);
            if (pos.x < 0 || pos.x >= w || pos.y < 0 || pos.y >= h) continue;

            float4 neighbor = input.read(uint2(pos));
            float3 nRGB = neighbor.rgb;

            float spaceDist2 = float(dx * dx + dy * dy);
            float3 colorDiff = nRGB - centerRGB;
            float colorDist2 = dot(colorDiff, colorDiff);

            float weight = exp(spaceDist2 * invSigmaSpace2 + colorDist2 * invSigmaColor2);
            sum += nRGB * weight;
            wsum += weight;
        }
    }

    output.write(float4(sum / wsum, center.a), gid);
}

// MARK: - Gaussian Blur (Separable)

kernel void gaussian_blur_h(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float *kernel_weights [[buffer(0)]],
    constant int &radius [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    int w = input.get_width();
    float4 sum = float4(0.0);
    float wsum = 0.0;
    for (int dx = -radius; dx <= radius; dx++) {
        int x = clamp(int(gid.x) + dx, 0, w - 1);
        float wt = kernel_weights[dx + radius];
        sum += input.read(uint2(x, gid.y)) * wt;
        wsum += wt;
    }
    output.write(sum / wsum, gid);
}

kernel void gaussian_blur_v(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float *kernel_weights [[buffer(0)]],
    constant int &radius [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    int h = input.get_height();
    float4 sum = float4(0.0);
    float wsum = 0.0;
    for (int dy = -radius; dy <= radius; dy++) {
        int y = clamp(int(gid.y) + dy, 0, h - 1);
        float wt = kernel_weights[dy + radius];
        sum += input.read(uint2(gid.x, y)) * wt;
        wsum += wt;
    }
    output.write(sum / wsum, gid);
}

// MARK: - Desaturate (Luminance)

kernel void desaturate(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float4 p = input.read(gid);
    float gray = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    output.write(float4(gray, gray, gray, p.a), gid);
}

// MARK: - Brightness + Contrast

kernel void brightness_contrast(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float &brightness [[buffer(0)]],
    constant float &contrast [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float4 p = input.read(gid);
    // brightness is in [-255, 255] range, contrast is a multiplier (e.g. 1.15)
    float3 adjusted = clamp(p.rgb * contrast + brightness / 255.0, 0.0, 1.0);
    output.write(float4(adjusted, p.a), gid);
}

// MARK: - Posterize

kernel void posterize(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant int &levels [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float4 p = input.read(gid);
    float f = float(levels - 1);
    float3 q = floor(p.rgb * f + 0.5) / f;
    output.write(float4(q, p.a), gid);
}

// MARK: - Threshold Map

/// Map a grayscale image to palette colors based on brightness thresholds.
/// thresholds: numThresholds ascending values in [0, 255].
/// palette: numThresholds + 1 colors (one per region).
kernel void threshold_map(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant int *thresholds [[buffer(0)]],
    constant float3 *palette [[buffer(1)]],
    constant int &numThresholds [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float4 p = input.read(gid);
    float gray = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    int grayInt = int(gray * 255.0);

    int region = numThresholds; // default to last region
    for (int i = 0; i < numThresholds; i++) {
        if (grayInt < thresholds[i]) {
            region = i;
            break;
        }
    }
    output.write(float4(palette[region], 1.0), gid);
}

// MARK: - Gaussian Noise

kernel void add_noise(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float &strength [[buffer(0)]],
    constant uint &seed [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float4 p = input.read(gid);
    // Hash-based pseudo-random per pixel
    uint h = (gid.x * 1664525u + gid.y * 1013904223u + seed) ^ 0xDEADBEEFu;
    h = h * 2654435761u;
    float noise = (float(h & 0xFFFFu) / 65535.0 - 0.5) * 2.0 * strength / 255.0;
    output.write(float4(clamp(p.rgb + noise, 0.0, 1.0), p.a), gid);
}

// MARK: - Invert

kernel void invert_image(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float4 p = input.read(gid);
    output.write(float4(1.0 - p.rgb, p.a), gid);
}

// MARK: - Blend Modes

kernel void multiply_blend(
    texture2d<float, access::read> base [[texture(0)]],
    texture2d<float, access::read> top [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float4 b = base.read(gid);
    float4 t = top.read(gid);
    output.write(float4(b.rgb * t.rgb, b.a), gid);
}

// MARK: - Color Dodge Blend (Pencil Sketch)

/// Color dodge / divide blend for pencil sketch technique.
/// original: grayscale source, blurred: blurred inverted version.
/// Result = original / (1.0 - blurred), clamped to [0, 1].
kernel void color_dodge_blend(
    texture2d<float, access::read> original [[texture(0)]],
    texture2d<float, access::read> blurred [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float4 orig = original.read(gid);
    float4 blur = blurred.read(gid);
    // Color dodge: original / (1.0 - blurred)
    float denom = max(1.0 - blur.r, 0.004); // avoid div by zero
    float sketch = min(orig.r / denom, 1.0);
    output.write(float4(sketch, sketch, sketch, 1.0), gid);
}

// MARK: - Additive Weighted Blend

kernel void add_weighted(
    texture2d<float, access::read> src1 [[texture(0)]],
    texture2d<float, access::read> src2 [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant float &alpha [[buffer(0)]],
    constant float &beta [[buffer(1)]],
    constant float &gamma [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float4 a = src1.read(gid);
    float4 b = src2.read(gid);
    float3 result = clamp(a.rgb * alpha + b.rgb * beta + gamma / 255.0, 0.0, 1.0);
    output.write(float4(result, a.a), gid);
}

// MARK: - Paint-By-Numbers Kernels

/// Classify each pixel into a region index based on grayscale brightness thresholds.
/// Reads the .r channel of a desaturated RGBA texture (0-1 range).
/// Writes a region index (0..regionCount-1) to an R8Uint texture.
kernel void pbn_classify_regions(
    texture2d<float, access::read> grayscale [[texture(0)]],
    texture2d<uint, access::write> regionMap [[texture(1)]],
    constant uint *thresholds [[buffer(0)]],
    constant uint &regionCount [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= grayscale.get_width() || gid.y >= grayscale.get_height()) return;

    float4 p = grayscale.read(gid);
    uint grayVal = uint(p.r * 255.0);

    // Linear scan thresholds to find region index.
    // Region i spans [threshold[i-1], threshold[i]).
    // Region 0 spans [0, threshold[0]).
    // Last region spans [threshold[N-1], 255].
    uint numThresholds = regionCount - 1;
    uint region = numThresholds; // default to last region
    for (uint i = 0; i < numThresholds; i++) {
        if (grayVal < thresholds[i]) {
            region = i;
            break;
        }
    }

    regionMap.write(uint4(region, 0, 0, 0), gid);
}

/// Produce a tinted image with boundary lines from a region map.
/// Reads region indices from R8Uint texture, checks 4-neighbors for boundaries.
/// Writes pre-blended tint color or line color to RGBA output.
kernel void pbn_tint_and_boundary(
    texture2d<uint, access::read> regionMap [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float4 *paletteColors [[buffer(0)]],
    constant float4 &lineColor [[buffer(1)]],
    constant uint &lineWeight [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = int(regionMap.get_width());
    int h = int(regionMap.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;

    uint centerRegion = regionMap.read(gid).r;

    // Check if this pixel or any neighbor within lineWeight/2 is a boundary.
    // A boundary pixel is one whose 4-connected neighbor has a different region.
    int halfW = int(lineWeight) / 2;
    // First check: is this pixel itself on a boundary edge?
    bool isBoundary = false;

    // Scan a (2*halfW+1) square; if any pixel in that square has a boundary neighbor, mark it.
    for (int dy = -halfW; dy <= halfW && !isBoundary; dy++) {
        for (int dx = -halfW; dx <= halfW && !isBoundary; dx++) {
            int sx = int(gid.x) + dx;
            int sy = int(gid.y) + dy;
            if (sx < 0 || sx >= w || sy < 0 || sy >= h) continue;

            uint sRegion = regionMap.read(uint2(sx, sy)).r;

            // Check 4 neighbors of (sx, sy)
            if (sx > 0 && regionMap.read(uint2(sx - 1, sy)).r != sRegion) { isBoundary = true; break; }
            if (sx < w - 1 && regionMap.read(uint2(sx + 1, sy)).r != sRegion) { isBoundary = true; break; }
            if (sy > 0 && regionMap.read(uint2(sx, sy - 1)).r != sRegion) { isBoundary = true; break; }
            if (sy < h - 1 && regionMap.read(uint2(sx, sy + 1)).r != sRegion) { isBoundary = true; break; }
        }
    }

    if (isBoundary) {
        output.write(lineColor, gid);
    } else {
        output.write(paletteColors[centerRegion], gid);
    }
}

/// Highlight a single region at full brightness, dimming all others.
/// Reads region indices and a base (tinted/colored) image.
/// Highlighted region passes through; others are blended toward gray.
kernel void pbn_hover_highlight(
    texture2d<uint, access::read> regionMap [[texture(0)]],
    texture2d<float, access::read> baseImage [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant uint &highlightedRegion [[buffer(0)]],
    constant float &dimAlpha [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= baseImage.get_width() || gid.y >= baseImage.get_height()) return;

    uint region = regionMap.read(gid).r;
    float4 base = baseImage.read(gid);

    if (region == highlightedRegion) {
        output.write(base, gid);
    } else {
        // Dim: mix with gray (0.6, 0.6, 0.6) at dimAlpha blend
        float3 gray = float3(0.6, 0.6, 0.6);
        float3 dimmed = mix(gray, base.rgb, dimAlpha);
        output.write(float4(dimmed, base.a), gid);
    }
}

// MARK: - PBN Narrow Strip Cleanup

/// Remove 1-pixel-wide strips by snapping them to the nearest-color neighbor.
/// Checks vertical then horizontal neighbors; if the pixel is sandwiched between
/// two different labels, it adopts the closer one in RGB space.
kernel void pbn_narrow_strip_cleanup(
    device int *labels      [[buffer(0)]],
    device int *output      [[buffer(1)]],
    device float3 *centers  [[buffer(2)]],
    constant int &width     [[buffer(3)]],
    constant int &height    [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(width) || gid.y >= uint(height)) return;
    int idx = gid.y * width + gid.x;
    int myLabel = labels[idx];
    int outLabel = myLabel;

    if (gid.y > 0 && gid.y < uint(height) - 1) {
        int top = labels[(gid.y - 1) * width + gid.x];
        int bot = labels[(gid.y + 1) * width + gid.x];
        if (top != myLabel && bot != myLabel) {
            float3 me = centers[myLabel];
            float3 td = me - centers[top];
            float3 bd = me - centers[bot];
            outLabel = (dot(td, td) < dot(bd, bd)) ? top : bot;
        }
    }
    if (outLabel == myLabel && gid.x > 0 && gid.x < uint(width) - 1) {
        int left  = labels[idx - 1];
        int right = labels[idx + 1];
        if (left != myLabel && right != myLabel) {
            float3 me = centers[myLabel];
            float3 ld = me - centers[left];
            float3 rd = me - centers[right];
            outLabel = (dot(ld, ld) < dot(rd, rd)) ? left : right;
        }
    }
    output[idx] = outLabel;
}

// MARK: - PBN Labels to Region Map

/// Convert an Int32 labels buffer to an R8Uint region map texture.
kernel void pbn_labels_to_regionmap(
    device int *labels          [[buffer(0)]],
    texture2d<uint, access::write> regionMap [[texture(0)]],
    constant int &width         [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= regionMap.get_width() || gid.y >= regionMap.get_height()) return;
    int label = labels[gid.y * width + gid.x];
    regionMap.write(uint4(uint(label), 0, 0, 0), gid);
}
