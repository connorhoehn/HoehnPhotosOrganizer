#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Pipeline building-block API — small, composable OpenCV operations for Swift.
@interface OpenCVBridge : NSObject

// MARK: - Pencil Sketch Pipeline (Photoshop tutorial port)
// Desaturate -> Invert -> Color Dodge Blend -> Gaussian Blur -> Levels -> Noise -> Sharpen
+ (nullable NSImage *)pencilSketch:(NSImage *)source
                        blurRadius:(double)blurRadius
                        brightness:(double)brightness
                          contrast:(double)contrast
                     noiseStrength:(double)noiseStrength
                       sharpAmount:(double)sharpAmount;

// MARK: - Threshold / Chiaroscuro
// Maps grayscale image to colored zones based on threshold boundaries
// thresholds: array of N boundary values (ascending, 0-255)
// colors: array of N+1 RGB triplets [r,g,b] (0-255), one per zone
// bgColor: RGB triplet for background/paper color
+ (nullable NSImage *)thresholdMap:(NSImage *)grayscale
                        thresholds:(NSArray<NSNumber *> *)thresholds
                            colors:(NSArray<NSArray<NSNumber *> *> *)rgbColors
                   backgroundColor:(NSArray<NSNumber *> *)bgRGB;

// Single inRange mask (like cv2.inRange) — white where pixel in [lower,upper], black elsewhere
+ (nullable NSImage *)inRangeMask:(NSImage *)grayscale
                            lower:(int)lower
                            upper:(int)upper;

// MARK: - Color Quantization
// K-means clustering. Returns NSDictionary with:
//   "image": quantized NSImage
//   "palette": NSArray of NSArray<NSNumber*> (RGB triplets)
//   "labels": NSData (int32 label per pixel, row-major)
+ (nullable NSDictionary *)kmeansQuantize:(NSImage *)source
                                numColors:(int)numColors
                                 attempts:(int)attempts;

// Merge small color clusters into their most common spatial neighbor
// Uses Laplacian edge filter to find boundaries, then reassigns small regions
+ (nullable NSImage *)pruneSmallClusters:(NSImage *)quantized
                           minPixelCount:(int)minPixels
                              iterations:(int)iterations;

// MARK: - Filters
+ (nullable NSImage *)bilateralFilter:(NSImage *)source
                             diameter:(int)d
                           sigmaColor:(double)sigmaColor
                           sigmaSpace:(double)sigmaSpace;

+ (nullable NSImage *)gaussianBlur:(NSImage *)source
                             sigma:(double)sigma;

+ (nullable NSImage *)medianBlur:(NSImage *)source
                      kernelSize:(int)ksize;

// MARK: - Color Operations
+ (nullable NSImage *)desaturate:(NSImage *)source;
+ (nullable NSImage *)invert:(NSImage *)source;
+ (nullable NSImage *)colorDodgeBlend:(NSImage *)base top:(NSImage *)top;
+ (nullable NSImage *)adjustBrightnessContrast:(NSImage *)source
                                    brightness:(double)brightness
                                      contrast:(double)contrast;

// MARK: - Edge Detection
+ (nullable NSImage *)cannyEdges:(NSImage *)source
                      threshold1:(double)t1
                      threshold2:(double)t2;

+ (nullable NSImage *)laplacianEdges:(NSImage *)source;

// MARK: - Morphology
+ (nullable NSImage *)posterize:(NSImage *)source levels:(int)levels;

+ (nullable NSImage *)morphClose:(NSImage *)mask kernelSize:(int)ksize;
+ (nullable NSImage *)morphOpen:(NSImage *)mask kernelSize:(int)ksize;
+ (nullable NSImage *)dilate:(NSImage *)mask kernelSize:(int)ksize;
+ (nullable NSImage *)erode:(NSImage *)mask kernelSize:(int)ksize;

// MARK: - Contours
// Returns array of contours. Each contour is an array of CGPoint-wrapped NSValues.
+ (nullable NSArray<NSArray<NSValue *> *> *)findContours:(NSImage *)binaryMask;

// MARK: - Connected Components
// Returns NSDictionary with:
//   "labelMap": NSData (int32 per pixel)
//   "count": NSNumber (number of components)
//   "stats": NSArray of NSDictionary (area, boundingBox, centroid per component)
+ (nullable NSDictionary *)connectedComponents:(NSImage *)binaryMask;

// MARK: - Blending
+ (nullable NSImage *)addWeighted:(NSImage *)src1
                            alpha:(double)alpha
                             src2:(NSImage *)src2
                             beta:(double)beta
                            gamma:(double)gamma;

+ (nullable NSImage *)multiplyBlend:(NSImage *)base top:(NSImage *)top;

// MARK: - Noise & Texture
+ (nullable NSImage *)addGaussianNoise:(NSImage *)source strength:(double)strength;
+ (nullable NSImage *)unsharpMask:(NSImage *)source sigma:(double)sigma amount:(double)amount;

// MARK: - Utility
+ (nullable NSImage *)roundTrip:(NSImage *)image;
+ (NSSize)imageSize:(NSImage *)image;

@end

NS_ASSUME_NONNULL_END
