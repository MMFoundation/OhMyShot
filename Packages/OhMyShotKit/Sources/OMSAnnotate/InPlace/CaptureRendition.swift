import CoreGraphics
import Foundation
import OMSCore

nonisolated public enum CaptureRendition {
    @concurrent public static func render(
        marks: AnnotationDocument, adding backdrop: Backdrop?, to base: CGImage
    ) async throws -> (image: CGImage, document: Data)? {
        func render(_ document: AnnotationDocument) throws -> (image: CGImage, document: Data) {
            guard let image = AnnotationRenderer.flatten(document, base: base) else { throw ImageExporter.ExportError.cannotEncode }
            return (image, try JSONEncoder().encode(document))
        }

        if marks.backdrop == nil, let backdrop {
            var decorated = marks
            decorated.backdrop = backdrop
            if let rendered = try? render(decorated) { return rendered }
        }
        guard !marks.isEmpty else { return nil }
        return try render(marks)
    }

    /// The capture with its marks drawn in and no background, as a pin over the area it was taken from shows it: the
    /// same size as the capture, so the pin lies there at 1:1, and a redaction drawn in place stays over what it hides.
    /// Nil when it can't be made, where the capture without its marks must not stand in.
    @concurrent public static func pinned(_ marks: AnnotationDocument, on base: CGImage) async -> CGImage? {
        var plain = marks
        plain.backdrop = nil
        return AnnotationRenderer.flatten(plain, base: base)
    }

    /// What such a pin hands over once its capture's file no longer holds its picture: the picture it shows (`pinned`'s),
    /// at its scale, on the background its capture was put on, as the capture was. Nil when that can't be drawn, where the
    /// picture without its background must not stand in.
    public static func handedOver(_ pinned: CGImage, scale: CGFloat, on backdrop: Backdrop) -> CGImage? {
        var document = AnnotationDocument(pixelSize: CGSize(width: pinned.width, height: pinned.height), scale: scale)
        document.backdrop = backdrop
        return AnnotationRenderer.flatten(document, base: pinned)
    }
}
