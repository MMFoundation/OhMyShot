import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads an image to recognize text in: upright (a camera photo stores its rotation as metadata), no
/// larger than recognition can use, and with the scale it was made at (a Retina screenshot is 144 dpi,
/// two pixels per point), so it is never shown larger than it appeared.
public enum ImageLoader {
    public struct Loaded: Sendable {
        public let image: CGImage
        /// Pixels per point.
        public let scale: CGFloat
        /// Whether the file said nothing about its resolution (none, or 72 dpi), so `scale` is the fallback that was
        /// asked for and not something known of the picture.
        public let usesFallbackScale: Bool
    }

    /// Larger images are scaled down to this many pixels: recognition reads no more from them, and a
    /// 48-megapixel photo takes 190 MB once decoded.
    public static let maximumPixels = 40_000_000

    /// - Parameter fallbackScale: the scale when the file does not say (no resolution, or 72 dpi).
    public static func load(contentsOf url: URL, fallbackScale: CGFloat = 1) -> Loaded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return load(source, fallbackScale: fallbackScale)
    }

    public static func load(data: Data, fallbackScale: CGFloat = 1) -> Loaded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return load(source, fallbackScale: fallbackScale)
    }

    /// Whether a file is an image this loader can read, judged by its type alone.
    public static func canLoad(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func load(_ source: CGImageSource, fallbackScale: CGFloat) -> Loaded? {
        guard
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        let longest = max(width, height)
        let pixels = Double(width) * Double(height)
        let reduction = pixels > Double(maximumPixels) ? (Double(maximumPixels) / pixels).squareRoot() : 1
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(longest) * reduction)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let stated = pixelsPerPoint(in: properties)
        let scale = stated ?? Double(fallbackScale)
        let decoded = Double(max(image.width, image.height)) / Double(longest)
        return Loaded(image: image, scale: max(1, scale * decoded), usesFallbackScale: stated == nil)
    }

    /// The scale a picture's properties state in its resolution: 144 dpi is 2 pixels per point. Nil when they state
    /// none, or 72 dpi, which is every file's way of saying so.
    public static func pixelsPerPoint(in properties: [CFString: Any]) -> Double? {
        guard let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi > 72.5 else { return nil }
        // PNG stores resolution per meter, so 144 dpi reads back as 143.99: snapped to quarter steps.
        return (dpi / 72 * 4).rounded() / 4
    }

    /// The same, for the first picture in `source`.
    public static func pixelsPerPoint(of source: CGImageSource) -> Double? {
        (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]).flatMap(pixelsPerPoint(in:))
    }

    /// Decodes the first image in `source` upright, applying EXIF orientation only when metadata specifies
    /// a transform other than `.up` (1), so normal screenshots incur no extra transform overhead.
    public static func orientedImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
            ?? ((properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.uint32Value
            ?? CGImagePropertyOrientation.up.rawValue
        if rawOrientation == CGImagePropertyOrientation.up.rawValue {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Upright pixel dimensions from image properties, swapping width and height for 90°/270° EXIF orientations (5–8).
    public static func orientedPixelSize(in properties: [CFString: Any]) -> (width: Int, height: Int)? {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
            ?? ((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.uint32Value
            ?? CGImagePropertyOrientation.up.rawValue
        if rawOrientation >= 5, rawOrientation <= 8 {
            return (width: height, height: width)
        }
        return (width: width, height: height)
    }
}
