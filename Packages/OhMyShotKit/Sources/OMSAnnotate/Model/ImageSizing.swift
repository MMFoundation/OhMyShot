import CoreGraphics
import Foundation

/// The size the Image Size sheet is asking for: a width and a height in pixels, which a percent of the
/// picture's current size sets too. Proportions are kept by default, so changing one side moves the other.
nonisolated public struct ImageSizing: Equatable, Sendable {
    /// The picture's size now: the canvas, in pixels.
    public let current: CGSize
    public private(set) var width: Int
    public private(set) var height: Int
    public var keepsProportions = true

    public init(current: CGSize) {
        self.current = CGSize(width: max(current.width.rounded(), 1), height: max(current.height.rounded(), 1))
        width = Int(self.current.width)
        height = Int(self.current.height)
    }

    /// The size asked for, in pixels.
    public var size: CGSize { CGSize(width: width, height: height) }

    /// How large the width is against the current width, as a percent.
    public var percent: Double { Double(width) / Double(current.width) * 100 }

    /// Whether this asks for a different size than the picture has.
    public var changesSize: Bool { size != current }

    public mutating func setWidth(_ value: Int) {
        width = Self.clamped(value)
        if keepsProportions { height = Self.clamped(Double(width) * Double(current.height) / Double(current.width)) }
    }

    public mutating func setHeight(_ value: Int) {
        height = Self.clamped(value)
        if keepsProportions { width = Self.clamped(Double(height) * Double(current.width) / Double(current.height)) }
    }

    /// Both sides at `value` percent of the current size, whatever the proportions setting.
    public mutating func setPercent(_ value: Double) {
        let factor = value.isFinite ? max(value, 0) / 100 : (value > 0 ? Double.infinity : 0)
        width = Self.clamped(Double(current.width) * factor)
        height = Self.clamped(Double(current.height) * factor)
    }

    /// Quick scale presets offered in the Image Size sheet.
    public static let presetPercents: [Double] = [50, 75, 200]

    /// Formats a scale percentage cleanly without grouping separators or trailing decimal zeros.
    public static func formatPercent(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded))"
        }
        var formatted = String(format: "%.2f", rounded)
        while formatted.last == "0" { formatted.removeLast() }
        if formatted.last == "." { formatted.removeLast() }
        return formatted
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, 1), AnnotationDocument.maxPictureSide)
    }

    private static func clamped(_ value: Double) -> Int {
        guard value.isFinite else { return value > 0 ? AnnotationDocument.maxPictureSide : 1 }
        let rounded = value.rounded()
        if rounded <= 1 { return 1 }
        if rounded >= Double(AnnotationDocument.maxPictureSide) { return AnnotationDocument.maxPictureSide }
        return Int(rounded)
    }
}

nonisolated extension AnnotationDocument {
    /// Whether the picture can have a canvas of `size` pixels: the picture it makes stays within what can
    /// be drawn and kept.
    public func allowsCanvas(of size: CGSize) -> Bool {
        resizedPictureSize(forCanvas: size) != nil
    }
}
