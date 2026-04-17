#import "OpenCVBridge.h"

#ifdef __cplusplus
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <map>
#include <vector>
#import <OpenCV/core.hpp>
#import <OpenCV/imgproc.hpp>
#import <OpenCV/photo.hpp>
#import <OpenCV/imgcodecs.hpp>
#pragma clang diagnostic pop
#endif

using namespace cv;

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - NSImage ↔ cv::Mat conversion helpers
// ──────────────────────────────────────────────────────────────────────────────

/// NSImage → cv::Mat (BGRA, 8UC4).  Premultiplied alpha is undone.
static cv::Mat nsImageToMat(NSImage *image) {
    CGImageRef cgImage = [image CGImageForProposedRect:nil context:nil hints:nil];
    if (!cgImage) return cv::Mat();

    size_t w = CGImageGetWidth(cgImage);
    size_t h = CGImageGetHeight(cgImage);

    // Allocate BGRA mat
    cv::Mat mat((int)h, (int)w, CV_8UC4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        mat.data, w, h, 8, mat.step[0], cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);  // BGRA layout
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    // Un-premultiply alpha so colour channels are correct
    for (int r = 0; r < mat.rows; r++) {
        uint8_t *row = mat.ptr<uint8_t>(r);
        for (int c = 0; c < mat.cols; c++) {
            uint8_t a = row[3];
            if (a > 0 && a < 255) {
                row[0] = (uint8_t)MIN(255, (int)row[0] * 255 / a);
                row[1] = (uint8_t)MIN(255, (int)row[1] * 255 / a);
                row[2] = (uint8_t)MIN(255, (int)row[2] * 255 / a);
            }
            row += 4;
        }
    }
    return mat;
}

/// cv::Mat → NSImage.  Accepts 1-ch, 3-ch (BGR) or 4-ch (BGRA).
static NSImage *matToNSImage(const cv::Mat &mat) {
    cv::Mat bgra;
    if (mat.channels() == 1) {
        cv::cvtColor(mat, bgra, cv::COLOR_GRAY2BGRA);
    } else if (mat.channels() == 3) {
        cv::cvtColor(mat, bgra, cv::COLOR_BGR2BGRA);
    } else {
        bgra = mat;
    }
    // Make sure the alpha channel is 255
    for (int r = 0; r < bgra.rows; r++) {
        uint8_t *row = bgra.ptr<uint8_t>(r);
        for (int c = 0; c < bgra.cols; c++) {
            row[3] = 255;
            row += 4;
        }
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        bgra.data, bgra.cols, bgra.rows, 8, bgra.step[0], cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);  // BGRA
    CGImageRef cgImage = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    NSImage *result = [[NSImage alloc] initWithCGImage:cgImage
                                                  size:NSMakeSize(bgra.cols, bgra.rows)];
    CGImageRelease(cgImage);
    return result;
}

/// Convenience: convert BGRA mat to single-channel grayscale.
static cv::Mat toGray(const cv::Mat &src) {
    cv::Mat gray;
    if (src.channels() == 1) {
        gray = src;
    } else if (src.channels() == 3) {
        cv::cvtColor(src, gray, cv::COLOR_BGR2GRAY);
    } else {
        cv::cvtColor(src, gray, cv::COLOR_BGRA2GRAY);
    }
    return gray;
}

/// Convenience: ensure mat is 3-channel BGR.
static cv::Mat toBGR(const cv::Mat &src) {
    cv::Mat bgr;
    if (src.channels() == 1) {
        cv::cvtColor(src, bgr, cv::COLOR_GRAY2BGR);
    } else if (src.channels() == 4) {
        cv::cvtColor(src, bgr, cv::COLOR_BGRA2BGR);
    } else {
        bgr = src;
    }
    return bgr;
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ──────────────────────────────────────────────────────────────────────────────

@implementation OpenCVBridge

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Pencil Sketch Pipeline
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)pencilSketch:(NSImage *)source
               blurRadius:(double)blurRadius
               brightness:(double)brightness
                 contrast:(double)contrast
            noiseStrength:(double)noiseStrength
              sharpAmount:(double)sharpAmount {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    // 1. Desaturate
    cv::Mat gray = toGray(src);

    // 2. Invert
    cv::Mat inverted;
    cv::bitwise_not(gray, inverted);

    // 3. Gaussian blur on inverted
    cv::Mat blurred;
    cv::GaussianBlur(inverted, blurred, cv::Size(0, 0), blurRadius);

    // 4. Color dodge blend: gray / (255 - blurred) * 256
    cv::Mat invertedBlur;
    cv::subtract(cv::Scalar(255), blurred, invertedBlur);
    // Avoid divide-by-zero: clamp floor to 1
    cv::max(invertedBlur, 1, invertedBlur);
    cv::Mat sketch;
    cv::divide(gray, invertedBlur, sketch, 256.0);

    // 5. Brightness / contrast (levels)
    //    result = saturate(alpha * pixel + brightness)
    //    contrast comes in as 50–200 range; normalize to 0.5–2.0 multiplier.
    cv::Mat leveled;
    double alpha = contrast / 100.0;
    sketch.convertTo(leveled, -1, alpha, brightness);

    // 6. Add noise (simulates paper grain)
    if (noiseStrength > 0.001) {
        cv::Mat noise(leveled.size(), CV_8UC1);
        cv::randn(noise, 128, noiseStrength * 60.0);
        cv::Mat noiseF, leveledF;
        leveled.convertTo(leveledF, CV_32F);
        noise.convertTo(noiseF, CV_32F, 1.0, -128.0);
        leveledF += noiseF;
        leveledF.convertTo(leveled, CV_8U);
    }

    // 7. Sharpen (unsharp mask)
    if (sharpAmount > 0.001) {
        cv::Mat blurredSharp;
        cv::GaussianBlur(leveled, blurredSharp, cv::Size(0, 0), 1.5);
        cv::addWeighted(leveled, 1.0 + sharpAmount, blurredSharp, -sharpAmount, 0, leveled);
    }

    return matToNSImage(leveled);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Threshold / Chiaroscuro
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)thresholdMap:(NSImage *)grayscale
               thresholds:(NSArray<NSNumber *> *)thresholds
                   colors:(NSArray<NSArray<NSNumber *> *> *)rgbColors
          backgroundColor:(NSArray<NSNumber *> *)bgRGB {
    cv::Mat src = nsImageToMat(grayscale);
    if (src.empty()) return nil;

    cv::Mat gray = toGray(src);

    int bgB = bgRGB[2].intValue;
    int bgG = bgRGB[1].intValue;
    int bgR = bgRGB[0].intValue;

    cv::Mat canvas(gray.rows, gray.cols, CV_8UC3, cv::Scalar(bgB, bgG, bgR));

    NSInteger N = thresholds.count;
    // N thresholds → N+1 zones
    for (NSInteger i = 0; i <= N; i++) {
        int lower = (i == 0) ? 0 : thresholds[i - 1].intValue;
        int upper = (i == N) ? 255 : thresholds[i].intValue - 1;

        if (i >= (NSInteger)rgbColors.count) break;
        NSArray<NSNumber *> *rgb = rgbColors[i];
        int cr = rgb[0].intValue;
        int cg = rgb[1].intValue;
        int cb = rgb[2].intValue;

        cv::Mat mask;
        cv::inRange(gray, lower, upper, mask);
        canvas.setTo(cv::Scalar(cb, cg, cr), mask);
    }

    return matToNSImage(canvas);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - inRange Mask
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)inRangeMask:(NSImage *)grayscale
                   lower:(int)lower
                   upper:(int)upper {
    cv::Mat src = nsImageToMat(grayscale);
    if (src.empty()) return nil;

    cv::Mat gray = toGray(src);
    cv::Mat mask;
    cv::inRange(gray, lower, upper, mask);
    return matToNSImage(mask);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - K-Means Quantize
// ──────────────────────────────────────────────────────────────────────────────

+ (NSDictionary *)kmeansQuantize:(NSImage *)source
                       numColors:(int)numColors
                        attempts:(int)attempts {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat bgr = toBGR(src);

    // Downsample large images for k-means (run on smaller version, apply centers to full res)
    cv::Mat sampleBGR;
    double scale = 1.0;
    int maxSamplePixels = 500000; // 500K pixels max for k-means sampling
    int totalPixels = bgr.rows * bgr.cols;
    if (totalPixels > maxSamplePixels) {
        scale = std::sqrt((double)maxSamplePixels / totalPixels);
        cv::resize(bgr, sampleBGR, cv::Size(), scale, scale, cv::INTER_AREA);
    } else {
        sampleBGR = bgr;
    }

    // Reshape sample to Nx3 float
    cv::Mat data;
    sampleBGR.reshape(1, sampleBGR.rows * sampleBGR.cols).convertTo(data, CV_32F);

    cv::Mat sampleLabels, centers;
    cv::TermCriteria tc(cv::TermCriteria::EPS + cv::TermCriteria::MAX_ITER, 10, 1.0);
    cv::kmeans(data, numColors, sampleLabels, tc, std::max(1, attempts / 3), cv::KMEANS_PP_CENTERS, centers);
    centers.convertTo(centers, CV_8U);

    // Assign every full-res pixel to the nearest center (fast nearest-neighbor lookup)
    cv::Mat labels(totalPixels, 1, CV_32S);
    cv::Mat fullData;
    bgr.reshape(1, totalPixels).convertTo(fullData, CV_32F);
    for (int i = 0; i < totalPixels; i++) {
        float bestDist = FLT_MAX;
        int bestLabel = 0;
        const float *px = fullData.ptr<float>(i);
        for (int k = 0; k < centers.rows; k++) {
            float db = px[0] - centers.at<uint8_t>(k, 0);
            float dg = px[1] - centers.at<uint8_t>(k, 1);
            float dr = px[2] - centers.at<uint8_t>(k, 2);
            float dist = db*db + dg*dg + dr*dr;
            if (dist < bestDist) { bestDist = dist; bestLabel = k; }
        }
        labels.at<int>(i) = bestLabel;
    }

    // Build quantized image
    cv::Mat quantized(bgr.size(), bgr.type());
    for (int i = 0; i < totalPixels; i++) {
        int label = labels.at<int>(i);
        quantized.at<cv::Vec3b>(i / bgr.cols, i % bgr.cols) =
            cv::Vec3b(centers.at<uint8_t>(label, 0),
                      centers.at<uint8_t>(label, 1),
                      centers.at<uint8_t>(label, 2));
    }

    // Build palette (BGR→RGB for caller)
    NSMutableArray *palette = [NSMutableArray arrayWithCapacity:numColors];
    for (int k = 0; k < centers.rows; k++) {
        int b = centers.at<uint8_t>(k, 0);
        int g = centers.at<uint8_t>(k, 1);
        int r = centers.at<uint8_t>(k, 2);
        [palette addObject:@[@(r), @(g), @(b)]];
    }

    // Labels as NSData (int32, row-major)
    NSData *labelData = [NSData dataWithBytes:labels.data
                                       length:labels.total() * sizeof(int32_t)];

    NSImage *quantizedImage = matToNSImage(quantized);
    if (!quantizedImage) return nil;

    return @{
        @"image": quantizedImage,
        @"palette": [palette copy],
        @"labels": labelData
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Prune Small Clusters
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)pruneSmallClusters:(NSImage *)quantized
                  minPixelCount:(int)minPixels
                     iterations:(int)iterations {
    cv::Mat src = nsImageToMat(quantized);
    if (src.empty()) return nil;

    cv::Mat bgr = toBGR(src);
    cv::Mat current = bgr.clone();

    for (int iter = 0; iter < iterations; iter++) {
        // Detect edges with Laplacian to find region boundaries
        cv::Mat gray;
        cv::cvtColor(current, gray, cv::COLOR_BGR2GRAY);
        cv::Mat laplacian;
        cv::Laplacian(gray, laplacian, CV_16S, 3);
        cv::Mat absLap;
        cv::convertScaleAbs(laplacian, absLap);
        cv::Mat edgeMask;
        cv::threshold(absLap, edgeMask, 10, 255, cv::THRESH_BINARY);

        // Connected components on non-edge regions
        cv::Mat nonEdge;
        cv::bitwise_not(edgeMask, nonEdge);
        cv::Mat labelMap;
        int numComponents = cv::connectedComponents(nonEdge, labelMap, 8, CV_32S);

        // Count pixels per component and compute mean color
        std::vector<int> counts(numComponents, 0);
        std::vector<long long> sumB(numComponents, 0), sumG(numComponents, 0), sumR(numComponents, 0);

        for (int r = 0; r < current.rows; r++) {
            const int *labelRow = labelMap.ptr<int>(r);
            const cv::Vec3b *colorRow = current.ptr<cv::Vec3b>(r);
            for (int c = 0; c < current.cols; c++) {
                int lbl = labelRow[c];
                if (lbl <= 0) continue;  // background (edge pixels)
                counts[lbl]++;
                sumB[lbl] += colorRow[c][0];
                sumG[lbl] += colorRow[c][1];
                sumR[lbl] += colorRow[c][2];
            }
        }

        // For small components, find most common neighbor color
        for (int r = 0; r < current.rows; r++) {
            const int *labelRow = labelMap.ptr<int>(r);
            for (int c = 0; c < current.cols; c++) {
                int lbl = labelRow[c];
                if (lbl <= 0) continue;
                if (counts[lbl] >= minPixels) continue;

                // Sample 4-connected neighbors for their labels
                std::map<int, int> neighborCounts;
                const int dx[] = {-1, 1, 0, 0};
                const int dy[] = {0, 0, -1, 1};
                for (int d = 0; d < 4; d++) {
                    int nr = r + dy[d];
                    int nc = c + dx[d];
                    if (nr < 0 || nr >= current.rows || nc < 0 || nc >= current.cols) continue;
                    int nlbl = labelMap.at<int>(nr, nc);
                    if (nlbl > 0 && nlbl != lbl && counts[nlbl] >= minPixels) {
                        neighborCounts[nlbl]++;
                    }
                }

                if (neighborCounts.empty()) continue;

                // Pick the neighbor with most contact
                int bestNeighbor = -1;
                int bestCount = 0;
                for (auto &pair : neighborCounts) {
                    if (pair.second > bestCount) {
                        bestCount = pair.second;
                        bestNeighbor = pair.first;
                    }
                }

                if (bestNeighbor > 0 && counts[bestNeighbor] > 0) {
                    // Assign mean color of that neighbor
                    current.at<cv::Vec3b>(r, c) = cv::Vec3b(
                        (uint8_t)(sumB[bestNeighbor] / counts[bestNeighbor]),
                        (uint8_t)(sumG[bestNeighbor] / counts[bestNeighbor]),
                        (uint8_t)(sumR[bestNeighbor] / counts[bestNeighbor])
                    );
                }
            }
        }
    }

    return matToNSImage(current);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Filters
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)bilateralFilter:(NSImage *)source
                    diameter:(int)d
                  sigmaColor:(double)sigmaColor
                  sigmaSpace:(double)sigmaSpace {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat bgr = toBGR(src);
    cv::Mat dst;
    cv::bilateralFilter(bgr, dst, d, sigmaColor, sigmaSpace);
    return matToNSImage(dst);
}

+ (NSImage *)gaussianBlur:(NSImage *)source sigma:(double)sigma {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat dst;
    cv::GaussianBlur(src, dst, cv::Size(0, 0), sigma);
    return matToNSImage(dst);
}

+ (NSImage *)medianBlur:(NSImage *)source kernelSize:(int)ksize {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    // medianBlur requires odd kernel >= 1, and for multi-channel must be 3 or 5
    int k = MAX(1, ksize | 1);  // ensure odd
    cv::Mat bgr = toBGR(src);
    cv::Mat dst;
    cv::medianBlur(bgr, dst, k);
    return matToNSImage(dst);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Color Operations
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)desaturate:(NSImage *)source {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat gray = toGray(src);
    return matToNSImage(gray);
}

+ (NSImage *)invert:(NSImage *)source {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat dst;
    cv::bitwise_not(src, dst);
    // Restore alpha to 255 if 4-channel
    if (dst.channels() == 4) {
        std::vector<cv::Mat> channels;
        cv::split(dst, channels);
        channels[3] = cv::Scalar(255);
        cv::merge(channels, dst);
    }
    return matToNSImage(dst);
}

+ (NSImage *)colorDodgeBlend:(NSImage *)base top:(NSImage *)top {
    cv::Mat baseMat = nsImageToMat(base);
    cv::Mat topMat = nsImageToMat(top);
    if (baseMat.empty() || topMat.empty()) return nil;

    cv::Mat baseGray = toGray(baseMat);
    cv::Mat topGray = toGray(topMat);

    // Resize top to match base if needed
    if (topGray.size() != baseGray.size()) {
        cv::resize(topGray, topGray, baseGray.size());
    }

    // Color dodge: base / (255 - top) * 256
    cv::Mat invertedTop;
    cv::subtract(cv::Scalar(255), topGray, invertedTop);
    cv::max(invertedTop, 1, invertedTop);  // avoid /0

    cv::Mat result;
    cv::divide(baseGray, invertedTop, result, 256.0);
    return matToNSImage(result);
}

+ (NSImage *)adjustBrightnessContrast:(NSImage *)source
                           brightness:(double)brightness
                             contrast:(double)contrast {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat dst;
    src.convertTo(dst, -1, contrast, brightness);
    return matToNSImage(dst);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Edge Detection
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)cannyEdges:(NSImage *)source
             threshold1:(double)t1
             threshold2:(double)t2 {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat gray = toGray(src);
    cv::Mat edges;
    cv::Canny(gray, edges, t1, t2);
    return matToNSImage(edges);
}

+ (NSImage *)laplacianEdges:(NSImage *)source {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat gray = toGray(src);
    cv::Mat laplacian;
    cv::Laplacian(gray, laplacian, CV_16S, 3);
    cv::Mat abs;
    cv::convertScaleAbs(laplacian, abs);
    return matToNSImage(abs);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Morphology
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)posterize:(NSImage *)source levels:(int)levels {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    int lvl = MAX(2, levels);
    double divisor = 256.0 / lvl;
    cv::Mat dst;
    // Quantize: floor(pixel / divisor) * divisor
    src.convertTo(dst, CV_32F);
    dst = dst / divisor;
    // Floor
    for (int r = 0; r < dst.rows; r++) {
        float *row = dst.ptr<float>(r);
        for (int c = 0; c < dst.cols * dst.channels(); c++) {
            row[c] = std::floor(row[c]);
        }
    }
    dst = dst * divisor;
    dst.convertTo(dst, CV_8U);
    return matToNSImage(dst);
}

+ (NSImage *)morphClose:(NSImage *)mask kernelSize:(int)ksize {
    cv::Mat src = nsImageToMat(mask);
    if (src.empty()) return nil;

    int k = MAX(1, ksize | 1);
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(k, k));
    cv::Mat dst;
    cv::morphologyEx(src, dst, cv::MORPH_CLOSE, kernel);
    return matToNSImage(dst);
}

+ (NSImage *)morphOpen:(NSImage *)mask kernelSize:(int)ksize {
    cv::Mat src = nsImageToMat(mask);
    if (src.empty()) return nil;

    int k = MAX(1, ksize | 1);
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(k, k));
    cv::Mat dst;
    cv::morphologyEx(src, dst, cv::MORPH_OPEN, kernel);
    return matToNSImage(dst);
}

+ (NSImage *)dilate:(NSImage *)mask kernelSize:(int)ksize {
    cv::Mat src = nsImageToMat(mask);
    if (src.empty()) return nil;

    int k = MAX(1, ksize | 1);
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(k, k));
    cv::Mat dst;
    cv::dilate(src, dst, kernel);
    return matToNSImage(dst);
}

+ (NSImage *)erode:(NSImage *)mask kernelSize:(int)ksize {
    cv::Mat src = nsImageToMat(mask);
    if (src.empty()) return nil;

    int k = MAX(1, ksize | 1);
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(k, k));
    cv::Mat dst;
    cv::erode(src, dst, kernel);
    return matToNSImage(dst);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Contours
// ──────────────────────────────────────────────────────────────────────────────

+ (NSArray<NSArray<NSValue *> *> *)findContours:(NSImage *)binaryMask {
    cv::Mat src = nsImageToMat(binaryMask);
    if (src.empty()) return nil;

    cv::Mat gray = toGray(src);

    // Ensure binary
    cv::Mat binary;
    cv::threshold(gray, binary, 127, 255, cv::THRESH_BINARY);

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(binary, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_TC89_L1);

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:contours.size()];
    for (const auto &contour : contours) {
        NSMutableArray *points = [NSMutableArray arrayWithCapacity:contour.size()];
        for (const auto &pt : contour) {
            [points addObject:[NSValue valueWithPoint:NSMakePoint(pt.x, pt.y)]];
        }
        [result addObject:[points copy]];
    }
    return [result copy];
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Connected Components
// ──────────────────────────────────────────────────────────────────────────────

+ (NSDictionary *)connectedComponents:(NSImage *)binaryMask {
    cv::Mat src = nsImageToMat(binaryMask);
    if (src.empty()) return nil;

    cv::Mat gray = toGray(src);

    // Ensure binary
    cv::Mat binary;
    cv::threshold(gray, binary, 127, 255, cv::THRESH_BINARY);

    cv::Mat labelMap, stats, centroids;
    int numComponents = cv::connectedComponentsWithStats(binary, labelMap, stats, centroids, 8, CV_32S);

    // labelMap as NSData (int32 per pixel)
    NSData *labelData = [NSData dataWithBytes:labelMap.data
                                       length:labelMap.total() * sizeof(int32_t)];

    // Stats per component
    NSMutableArray *statsArray = [NSMutableArray arrayWithCapacity:numComponents];
    for (int i = 0; i < numComponents; i++) {
        int x = stats.at<int>(i, cv::CC_STAT_LEFT);
        int y = stats.at<int>(i, cv::CC_STAT_TOP);
        int w = stats.at<int>(i, cv::CC_STAT_WIDTH);
        int h = stats.at<int>(i, cv::CC_STAT_HEIGHT);
        int area = stats.at<int>(i, cv::CC_STAT_AREA);
        double cx = centroids.at<double>(i, 0);
        double cy = centroids.at<double>(i, 1);

        [statsArray addObject:@{
            @"area": @(area),
            @"boundingBox": @{@"x": @(x), @"y": @(y), @"width": @(w), @"height": @(h)},
            @"centroid": @{@"x": @(cx), @"y": @(cy)}
        }];
    }

    return @{
        @"labelMap": labelData,
        @"count": @(numComponents),
        @"stats": [statsArray copy]
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Blending
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)addWeighted:(NSImage *)src1
                   alpha:(double)alpha
                    src2:(NSImage *)src2
                    beta:(double)beta
                   gamma:(double)gamma {
    cv::Mat mat1 = nsImageToMat(src1);
    cv::Mat mat2 = nsImageToMat(src2);
    if (mat1.empty() || mat2.empty()) return nil;

    // Match sizes
    if (mat2.size() != mat1.size()) {
        cv::resize(mat2, mat2, mat1.size());
    }
    // Match channel counts
    if (mat1.channels() != mat2.channels()) {
        mat1 = toBGR(mat1);
        mat2 = toBGR(mat2);
    }

    cv::Mat dst;
    cv::addWeighted(mat1, alpha, mat2, beta, gamma, dst);
    return matToNSImage(dst);
}

+ (NSImage *)multiplyBlend:(NSImage *)base top:(NSImage *)top {
    cv::Mat baseMat = nsImageToMat(base);
    cv::Mat topMat = nsImageToMat(top);
    if (baseMat.empty() || topMat.empty()) return nil;

    // Match sizes
    if (topMat.size() != baseMat.size()) {
        cv::resize(topMat, topMat, baseMat.size());
    }

    cv::Mat b = toBGR(baseMat);
    cv::Mat t = toBGR(topMat);

    cv::Mat dst;
    cv::multiply(b, t, dst, 1.0 / 255.0);
    return matToNSImage(dst);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Noise & Texture
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)addGaussianNoise:(NSImage *)source strength:(double)strength {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat working = toBGR(src);

    cv::Mat noise(working.size(), CV_16SC3);
    cv::randn(noise, cv::Scalar(0, 0, 0), cv::Scalar(strength, strength, strength));

    cv::Mat srcS;
    working.convertTo(srcS, CV_16SC3);
    cv::Mat added = srcS + noise;
    cv::Mat dst;
    added.convertTo(dst, CV_8UC3);
    return matToNSImage(dst);
}

+ (NSImage *)unsharpMask:(NSImage *)source sigma:(double)sigma amount:(double)amount {
    cv::Mat src = nsImageToMat(source);
    if (src.empty()) return nil;

    cv::Mat blurred;
    cv::GaussianBlur(src, blurred, cv::Size(0, 0), sigma);
    cv::Mat dst;
    cv::addWeighted(src, 1.0 + amount, blurred, -amount, 0, dst);
    return matToNSImage(dst);
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Utility
// ──────────────────────────────────────────────────────────────────────────────

+ (NSImage *)roundTrip:(NSImage *)image {
    cv::Mat mat = nsImageToMat(image);
    if (mat.empty()) return nil;
    return matToNSImage(mat);
}

+ (NSSize)imageSize:(NSImage *)image {
    CGImageRef cgImage = [image CGImageForProposedRect:nil context:nil hints:nil];
    if (!cgImage) return NSZeroSize;
    return NSMakeSize(CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));
}

@end
