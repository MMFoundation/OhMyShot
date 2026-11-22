import AppKit
import CoreGraphics
import OMSCore
import Testing
@testable import OMSCapture

@MainActor
struct OverlayTransientCaptureTests {
    @Test func transientPrecaptureIsLimitedToLiveAreaScreenshotsWithWindowsToPreserve() {
        #expect(OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .screenshot, holdsStill: false, allInOne: false, windowCount: 1
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .screenshot, holdsStill: true, allInOne: false, windowCount: 1
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .screenshot, holdsStill: false, allInOne: false, windowCount: 0
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .window, purpose: .screenshot, holdsStill: false, allInOne: false, windowCount: 1
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .text, holdsStill: false, allInOne: false, windowCount: 1
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .screenshot, holdsStill: false, allInOne: true, windowCount: 1
        ))
    }

    @Test func ownWindowExceptionIsLimitedToAreaScreenshots() {
        let requested: CGWindowID = 42
        #expect(OverlayController.scopedOwnWindowID(mode: .area, purpose: .screenshot, requested: requested) == requested)
        #expect(OverlayController.scopedOwnWindowID(mode: .window, purpose: .screenshot, requested: requested) == nil)
        #expect(OverlayController.scopedOwnWindowID(mode: .area, purpose: .record, requested: requested) == nil)
        #expect(OverlayController.scopedOwnWindowID(mode: .area, purpose: .text, requested: requested) == nil)
    }

    @Test func pendingTransientComparisonAllowsOnlyEscapeInput() {
        #expect(OverlayPanel.dispatches(.keyDown, keyCode: 53, whileComparisonPending: true))
        #expect(!OverlayPanel.dispatches(.keyDown, keyCode: 0, whileComparisonPending: true))
        #expect(!OverlayPanel.dispatches(.leftMouseDown, keyCode: 0, whileComparisonPending: true))
        #expect(OverlayPanel.dispatches(.leftMouseDown, keyCode: 0, whileComparisonPending: false))
    }

    @Test func pendingTransientComparisonSafelyConsumesSyntheticMouseEvent() throws {
        let panel = OverlayPanel(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        panel.suppressesInputUntilTransientComparison = true
        let mouseEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        panel.sendEvent(mouseEvent)

        #expect(panel.suppressesInputUntilTransientComparison)
    }

    @Test func liveTransientPreviewIsBelowDimmingAndSelectionAndClearedOnResetAndCancel() throws {
        let display = DisplayInfo(
            id: 1, name: "Synthetic", frame: CGRect(x: -100, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 200, height: 200), backingScale: 2, maximumPotentialEDR: 1
        )
        let context = try #require(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let frame = CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: display.id, frame: display.frame)
        let snapshot = TransientCaptureSnapshot(frame: frame, regions: [CGRect(x: -80, y: 20, width: 30, height: 40)])
        let view = OverlayView(display: display)
        defer { view.clear() }

        view.reset(pointer: .zero, mode: .area, windows: [], showsToolbar: false)
        view.showTransientContent(from: [])
        #expect(view.debugTransientPatchCount == 0)
        view.showTransientContent(from: [TransientCaptureSnapshot(frame: frame, regions: [CGRect(x: 20, y: 20, width: 10, height: 10)])])
        #expect(view.debugTransientPatchCount == 0)
        view.showTransientContent(from: [snapshot])
        #expect(view.debugTransientPatchCount == 1)
        #expect(view.debugTransientPatchFrames == [CGRect(x: 20, y: 20, width: 30, height: 40)])
        #expect(view.debugTransientContentIsBelowDimmingAndSelection)

        view.reset(pointer: .zero, mode: .area, windows: [], showsToolbar: false)
        #expect(view.debugTransientPatchCount == 0)
        view.showTransientContent(from: [snapshot])
        view.clear()
        #expect(view.debugTransientPatchCount == 0)
    }
}
