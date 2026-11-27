import AppKit
@testable import OMSCore
import Testing
@testable import OMSUI

/// Escape taken as a hot key while something with no window of its own waits on it (Capture Text's reading). The
/// presses are Carbon events sent through the dispatcher's handlers, as the window server's would be; nothing is typed.
@MainActor
struct EscapeHotKeyTests {
    @Test func aPressReachesItOnlyWhileArmed() throws {
        var presses = 0
        let escape = EscapeHotKey { presses += 1 }
        #expect(!escape.simulatePress())
        try #require(escape.arm())
        #expect(escape.isArmed)
        #expect(escape.arm())
        #expect(escape.simulatePress())
        #expect(presses == 1)
        escape.disarm()
        #expect(!escape.isArmed)
        #expect(!escape.simulatePress())
        #expect(presses == 1)
    }

    @Test func eachPressGoesToItsOwnKeyAlone() throws {
        var first = 0
        var second = 0
        let one = EscapeHotKey { first += 1 }
        let other = EscapeHotKey { second += 1 }
        try #require(one.arm())
        // Escape alone can be one app's hot key once: the second registration is refused, and says so.
        let otherArmed = other.arm()
        defer {
            one.disarm()
            other.disarm()
        }
        #expect(one.simulatePress())
        #expect(first == 1)
        #expect(second == 0)
        if otherArmed {
            #expect(other.simulatePress())
            #expect(first == 1)
            #expect(second == 1)
        }
    }

    @Test func goingAwayGivesEscapeBack() throws {
        var escape: EscapeHotKey? = EscapeHotKey {}
        try #require(escape?.arm() == true)
        escape = nil
        let next = EscapeHotKey {}
        // Its registration is gone with it, so Escape can be taken again.
        #expect(next.arm())
        next.disarm()
    }

    @Test func sharedHardwarePressDispatchesLIFOAndFallsBackOnDisarm() throws {
        var first = 0, second = 0
        let bottom = EscapeHotKey { first += 1 }
        let top = EscapeHotKey { second += 1 }
        defer {
            top.disarm()
            bottom.disarm()
        }
        try #require(bottom.arm())
        try #require(top.arm())
        #expect(EscapeHotKey.simulateHardwarePress())
        #expect(second == 1 && first == 0)
        top.disarm()
        #expect(EscapeHotKey.simulateHardwarePress())
        #expect(second == 1 && first == 1)
    }
}
