import AppKit
import OMSCore
import QuartzCore
import Testing
@testable import OMSCapture

@MainActor
struct TransientCapturePanelTests {
    private func window(_ id: CGWindowID, pid: pid_t, level: NSWindow.Level, frame: CGRect, alpha: CGFloat = 1) -> [String: Any] {
        [
            kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: level.rawValue,
            kCGWindowBounds as String: frame.dictionaryRepresentation, kCGWindowAlpha as String: alpha,
        ]
    }

    private let panel = CGRect(x: 140, y: 120, width: 600, height: 400)
    private let menuBar = CGRect(x: -1600, y: 40, width: 1600, height: 32)

    @Test func ordinaryWindowsAndAlfredsMenuExtraLeaveCaptureLive() {
        let list = [
            window(1, pid: 90, level: .mainMenu, frame: menuBar),
            window(2, pid: 20, level: .statusBar, frame: CGRect(x: -80, y: 40, width: 30, height: 32)),
            window(3, pid: 10, level: .floating, frame: panel),
            window(4, pid: 30, level: .normal, frame: panel),
            window(5, pid: 20, level: .floating, frame: panel, alpha: 0),
        ]
        #expect(TransientCapturePanels.visible(in: list, launcher: nil, ownPID: 10, alfredPIDs: [20]) == nil)
    }

    @Test func alfredSearchIsPreservedWithoutIncludingOtherOhMyShotWindows() throws {
        let list = [window(1, pid: 20, level: .floating, frame: panel), window(2, pid: 10, level: .floating, frame: panel)]
        let panels = try #require(TransientCapturePanels.visible(in: list, launcher: nil, ownPID: 10, alfredPIDs: [20]))
        #expect(panels.ownWindowIDs.isEmpty)
    }

    @Test func onlyTheOpenLauncherAndOwnMenuNeedCaptureExceptions() throws {
        let list = [
            window(2, pid: 10, level: .popUpMenu, frame: panel),
            window(3, pid: 30, level: .popUpMenu, frame: panel),
            window(4, pid: 10, level: .screenSaver, frame: panel),
        ]
        let panels = try #require(TransientCapturePanels.visible(in: list, launcher: 1, ownPID: 10, alfredPIDs: []))
        #expect(panels.ownWindowIDs == [1, 2])
        #expect(TransientCapturePanels.visible(in: [list[1]], launcher: nil, ownPID: 10, alfredPIDs: []) != nil)
        #expect(TransientCapturePanels.visible(in: [], launcher: 1, ownPID: 10, alfredPIDs: [])?.ownWindowIDs == [1])
    }

    #if DEBUG
    /// Uses the WindowServer and ScreenCaptureKit. Opt in on a Mac with Screen Recording access.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_TEST_CAPTURE_POPOVER"] == "1"))
    func selectedPixelsSurvivePopoverDismissal() async throws {
        try #require(CGPreflightScreenCaptureAccess())
        let topology = DisplayTopology()
        let display = try #require(topology.layout.primary)
        let cache = ShareableContentCache()
        let capturer = ScreenCapturer(content: cache)
        let overlay = OverlayController(topology: topology, capturer: capturer)
        overlay.prepare()
        _ = try await cache.current()
        let anchor = NSWindow(contentRect: CGRect(x: display.frame.midX, y: display.frame.midY, width: 40, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        anchor.level = .statusBar
        anchor.orderFrontRegardless()
        defer { anchor.orderOut(nil) }
        for freezes in [false, true] {
            let content = NSViewController()
            content.view = Swatch(frame: CGRect(x: 0, y: 0, width: 180, height: 80))
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = content
            let button = try #require(anchor.contentView)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            defer { popover.close() }
            let window = try #require(content.view.window)
            window.displayIfNeeded()
            CATransaction.flush()
            let point = window.convertPoint(toScreen: content.view.convert(CGPoint(x: 90, y: 40), to: nil))
            let area = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
            // The user presses the shortcut after seeing the popover. AppKit can return from show()
            // before WindowServer has presented it, even with animations disabled.
            var visibleColor: String?
            for _ in 0..<15 {
                let screen = try await capturer.captureDisplay(display, includingOwnWindows: true)
                visibleColor = screen.cropped(to: area)?.color(atPixel: 1, 1)?.hex
                if visibleColor == "#FF00FF" { break }
                try await Task.sleep(for: .milliseconds(16))
            }
            try #require(visibleColor == "#FF00FF")
            let panels = try #require(TransientCapturePanels.visible(launcher: CGWindowID(window.windowNumber)))
            overlay.freezesScreen = freezes
            var result: OverlayController.Outcome?
            overlay.begin(options: .init(panels: panels)) { result = $0 }
            defer { overlay.cancel() }
            for _ in 0..<100 where overlay.isActive && !overlay.hasFrames {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(overlay.hasFrames)
            popover.close()
            overlay.simulateSelection(area)
            guard case .region(_, _, _, let frame?) = result else {
                Issue.record("Expected the selected pixels from before dismissal (freeze = \(freezes))")
                return
            }
            #expect(frame.color(atPixel: frame.image.width / 2, frame.image.height / 2)?.hex == "#FF00FF", "freeze = \(freezes)")
        }
    }

    private final class Swatch: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }
    #endif
}
