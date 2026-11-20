import CoreGraphics
import CoreText
import Foundation
import Testing
import Vision
@testable import OMSAnnotate

struct RedactionRenderingTests {
    private let scale: CGFloat = 2
    private let markID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    private func context(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    private func fixture(_ text: String, pointSize: CGFloat) throws -> (image: CGImage, rect: CGRect) {
        let font = try #require(CTFontCreateUIFontForLanguage(pointSize >= 36 ? .emphasizedSystem : .system, pointSize * scale, nil))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let pad = (pointSize * scale * 1.5).rounded()
        let width = Int(ceil(bounds.width) + 2 * pad)
        let height = Int(ceil(bounds.height) + 2 * pad)
        let context = try context(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(line, context)
        let rect = CGRect(x: pad, y: CGFloat(height) - pad - bounds.height, width: bounds.width, height: bounds.height)
        return (try #require(context.makeImage()), rect.insetBy(dx: -4 * scale, dy: -4 * scale).integral)
    }

    private func digits(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().filter(\.isNumber)
    }

    @Test func visionReadsNoDigitsInFilteredFixtures() throws {
        for size: CGFloat in [13, 24, 36, 60, 96] {
            for text in ["835 204", "4929 1038 5562 7716", "Hunter2!x"] {
                let (base, rect) = try fixture(text, pointSize: size)
                try #require(digits(in: base) == text.filter(\.isNumber), "Unreadable control: \(text) at \(size) pt")
                for method in [Redaction.Method.blur, .pixelate] {
                    let mark = Annotation(id: markID, shape: .redaction(Redaction(rect: rect, method: method)), style: Style())
                    let document = AnnotationDocument(pixelSize: CGSize(width: base.width, height: base.height), scale: scale, items: [mark])
                    let output = try #require(AnnotationRenderer.flatten(document, base: base))
                    let pixels = Pixels(output)
                    #expect(pixels[Int(rect.midX), Int(rect.midY)].r > 0, "Unexpected solid fallback for \(method) at \(size) pt")
                    #expect(try digits(in: output).isEmpty, "\(method) on \(text) at \(size) pt")
                }
            }
        }
    }

    @Test func aUISizedSelectionKeepsSmallBlocksButAHeadingGetsLargerOnes() {
        #expect(Redactor.blockSize(for: CGRect(x: 0, y: 0, width: 116, height: 47), scale: 2) == 12)
        #expect(Redactor.blockSize(for: CGRect(x: 0, y: 0, width: 785, height: 243), scale: 2) > 100)
    }

    @Test(arguments: [Redaction.Method.blur, .pixelate])
    func failedFilterCoversOnlyTheIntersectionInTheFlattenedExport(method: Redaction.Method) throws {
        let context = try context(width: 40, height: 30)
        context.setFillColor(CGColor(gray: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let base = try #require(context.makeImage())
        var document = AnnotationDocument(pixelSize: CGSize(width: 40, height: 30), scale: scale)
        document.canvas = CGRect(x: -20, y: 0, width: 60, height: 30)
        let plain = Pixels(try #require(AnnotationRenderer.flatten(document, base: base)))
        let style = Style(color: RGBA(red: 1, green: 0, blue: 0, alpha: 0.05))
        document.items = [
            CGRect(x: -8.5, y: 4.5, width: 18, height: 10),
            CGRect(x: -19, y: 2, width: 6, height: 10),
        ].map { Annotation(shape: .redaction(Redaction(rect: $0, method: method)), style: style) }
        var filtered: [CGRect] = []
        let output = try #require(AnnotationRenderer.flatten(document, base: base, redactionFilter: { _, rect, _, _, _ in
            filtered.append(rect)
            return nil
        }))
        #expect(filtered == [CGRect(x: 0, y: 4, width: 10, height: 11)])
        let pixels = Pixels(output)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                if (20..<30).contains(x), (4..<15).contains(y) {
                    #expect(pixels[x, y] == (0, 0, 0, 255))
                } else {
                    #expect(pixels[x, y] == plain[x, y])
                }
            }
        }
    }
}
