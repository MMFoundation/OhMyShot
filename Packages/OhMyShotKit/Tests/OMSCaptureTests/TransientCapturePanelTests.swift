import AppKit
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
}
