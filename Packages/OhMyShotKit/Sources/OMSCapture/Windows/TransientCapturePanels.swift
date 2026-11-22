import AppKit
import CoreGraphics

/// Windows visible at the area hotkey that can close as soon as the selector takes focus.
public struct TransientCapturePanels: Sendable {
    /// Only these windows need exceptions to ScreenCaptureKit's exclusion of OhMyShot.
    let ownWindowIDs: Set<CGWindowID>

    public static func visible(launcher: CGWindowID?) -> Self? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let alfred = NSRunningApplication.runningApplications(withBundleIdentifier: "com.runningwithcrayons.Alfred")
        return visible(in: list, launcher: launcher, ownPID: getpid(), alfredPIDs: Set(alfred.map(\.processIdentifier)))
    }

    static func visible(in list: [[String: Any]], launcher: CGWindowID?, ownPID: pid_t, alfredPIDs: Set<pid_t>) -> Self? {
        func bounds(_ info: [String: Any]) -> CGRect? {
            guard let rect = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: rect)
        }
        let menuBars = list.compactMap { info in
            (info[kCGWindowLayer as String] as? Int) == NSWindow.Level.mainMenu.rawValue ? bounds(info) : nil
        }
        var ownWindows = Set([launcher].compactMap { $0 })
        var found = launcher != nil
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let level = info[kCGWindowLayer as String] as? Int,
                  (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0,
                  let rect = bounds(info), rect.width > 1, rect.height > 1 else { continue }
            // Alfred also owns a persistent menu bar item when its search panel is closed.
            guard level == NSWindow.Level.popUpMenu.rawValue || (alfredPIDs.contains(pid) && !menuBars.contains(where: { $0.contains(rect) })) else { continue }
            found = true
            if pid == ownPID { ownWindows.insert(id) }
        }
        return found ? Self(ownWindowIDs: ownWindows) : nil
    }
}
