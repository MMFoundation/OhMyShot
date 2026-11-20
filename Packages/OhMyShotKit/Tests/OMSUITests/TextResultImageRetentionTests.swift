import CoreGraphics
import Testing
@testable import OMSUI

@MainActor
struct TextResultImageRetentionTests {
    private func image() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    @Test func disabledCardDoesNotKeepAnImageAndTurningItOffDropsTheCurrentOne() throws {
        let hud = TextResultHUD()
        weak var capture: CGImage?
        do {
            let image = try image()
            capture = image
            hud.setPanelAction({ _ = image.width }, showsResult: false)
        }
        #expect(capture == nil)
        do {
            let image = try image()
            capture = image
            hud.setPanelAction({ _ = image.width }, showsResult: true)
        }
        #expect(capture != nil)
        hud.setPanelAction(nil, showsResult: false)
        #expect(capture == nil)
        #expect(hud.onOpenInPanel == nil)
    }

    @Test func replacingAndDismissingReleaseTheMatchingResultImage() throws {
        let hud = TextResultHUD()
        weak var first: CGImage?, second: CGImage?
        do {
            let image = try image()
            first = image
            hud.setPanelAction({ _ = image.width }, showsResult: true)
        }
        do {
            let image = try image()
            second = image
            hud.setPanelAction({ _ = image.width }, showsResult: true)
        }
        #expect(first == nil)
        #expect(second != nil)
        hud.dismiss()
        #expect(second == nil)
    }

    @Test func cancellingAnOlderReadingDoesNotClearAReplacementCard() throws {
        let hud = TextResultHUD()
        let older = hud.resultGeneration
        hud.dismiss()
        weak var capture: CGImage?
        do {
            let image = try image()
            capture = image
            hud.setPanelAction({ _ = image.width }, showsResult: true)
        }
        hud.clearPanelAction(ifCurrent: older)
        #expect(capture != nil)
        hud.clearPanelAction(ifCurrent: hud.resultGeneration)
        #expect(capture == nil)
    }

    @Test func openInPanelTakesTheVisibleImageBeforeDismissalAndOpensOnlyOnce() throws {
        let hud = TextResultHUD()
        var opened = 0
        weak var capture: CGImage?
        do {
            let image = try image()
            capture = image
            hud.setPanelAction({ [weak hud] in
                #expect(hud?.onOpenInPanel == nil)
                #expect(image.width == 2)
                opened += 1
            }, showsResult: true)
        }
        hud.setPanelAction(hud.onOpenInPanel, showsResult: true)
        hud.openResultInPanel()
        #expect(capture == nil)
        hud.openResultInPanel()
        #expect(opened == 1)
    }
}
