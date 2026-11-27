import AppKit
import Carbon.HIToolbox
import OSLog

/// Escape, taken from every app while armed, for something of OhMyShot's that Escape stops but that has no window
/// to take the key in, such as a reading behind Capture Text's highlight or a Self-Timer countdown.
///
/// All armed instances share a single Carbon Escape hot key managed as a LIFO stack so concurrent features
/// (e.g. Color Card + Self-Timer) never collide on `RegisterEventHotKey`, and the most recently armed
/// consumer receives Escape first.
///
/// While a modal window, attached sheet, popover, or panel of OhMyShot's holds the keyboard, Escape is
/// forwarded to that window as a normal key event rather than cancelling background state.
@MainActor
public final class EscapeHotKey {
    /// `EventHotKeyID.signature` for these, beside KeyboardShortcuts' own (`SSKS`), which leaves others' hot keys alone.
    private nonisolated static let signature: OSType = 0x4F_4D_53_45 // OMSE
    /// Reserved hot key ID used for the single shared hardware registration; individual instances use 1, 2, ...
    private nonisolated static let sharedHotKeyID: UInt32 = 0
    private static var handler: EventHandlerRef?
    private static var sharedHotKey: EventHotKeyRef?
    private static var stack: [Weak] = []
    private static var armedByID: [UInt32: Weak] = [:]
    private static var lastID: UInt32 = 0

    private struct Weak {
        weak var key: EscapeHotKey?
    }

    private let id: UInt32
    private let pressed: () -> Void
    public private(set) var isArmed = false

    /// `pressed` runs on the main thread when Escape is pressed while armed, unless a modal/sheet/panel holds the keyboard.
    public init(pressed: @escaping () -> Void) {
        Self.lastID += 1
        id = Self.lastID
        self.pressed = pressed
    }

    isolated deinit {
        disarm()
    }

    /// Takes Escape until `disarm`. False when another app already owns Escape as a global hot key.
    @discardableResult
    public func arm() -> Bool {
        guard !isArmed else { return true }
        Self.stack.removeAll { $0.key == nil }
        if Self.sharedHotKey == nil {
            guard Self.installHandler() else { return false }
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: Self.sharedHotKeyID), GetEventDispatcherTarget(), 0, &hotKey
            )
            guard status == noErr, let hotKey else {
                Log.hotkeys.error("Escape couldn't be taken as a hot key: \(status, privacy: .public)")
                return false
            }
            Self.sharedHotKey = hotKey
        }
        isArmed = true
        let weakSelf = Weak(key: self)
        Self.stack.append(weakSelf)
        Self.armedByID[id] = weakSelf
        return true
    }

    /// Gives Escape back to the previous armed owner, or to the app in front when no owner remains.
    public func disarm() {
        guard isArmed else { return }
        isArmed = false
        Self.armedByID[id] = nil
        Self.stack.removeAll { $0.key == nil || $0.key === self }
        if Self.stack.isEmpty, let hotKey = Self.sharedHotKey {
            UnregisterEventHotKey(hotKey)
            Self.sharedHotKey = nil
        }
    }

    /// One handler for every Escape hot key, on the event dispatcher, where KeyboardShortcuts registers its own.
    private static func installHandler() -> Bool {
        guard handler == nil else { return true }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let status = InstallEventHandler(GetEventDispatcherTarget(), escapeHotKeyHandler, types.count, &types, nil, &handler)
        guard status == noErr else {
            Log.hotkeys.error("Escape's hot key handler couldn't be installed: \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// Carbon's call for a hot key: one of these is answered, any other left to the handler after (KeyboardShortcuts').
    fileprivate nonisolated static func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else { return OSStatus(eventNotHandledErr) }
        let id = hotKeyID.id
        MainActor.assumeIsolated {
            stack.removeAll { $0.key == nil }
            let target: EscapeHotKey?
            if id == sharedHotKeyID {
                target = stack.last?.key
            } else {
                target = armedByID[id]?.key
            }
            guard let key = target, key.isArmed else { return }
            if let forwardTarget = escapeForwardTarget() {
                forwardEscape(to: forwardTarget)
            } else {
                Log.hotkeys.notice("hotkey.escape")
                key.pressed()
            }
        }
        return noErr
    }

    /// Returns the frontmost modal window, attached sheet, popover, or panel that should consume Escape
    /// instead of a background Escape hot key handler, or nil when the armed hot key should handle it.
    private static func escapeForwardTarget() -> NSWindow? {
        if let modal = NSApplication.shared.modalWindow {
            return modal
        }
        guard let window = NSApplication.shared.keyWindow else { return nil }
        if let sheet = window.attachedSheet {
            return sheet
        }
        if window.styleMask.contains(.nonactivatingPanel) || window is NSPanel || window.className.contains("Popover") {
            return window
        }
        return nil
    }

    #if DEBUG
    /// A press of this hot key as Carbon delivers one, through the dispatcher's handlers (KeyboardShortcuts' among
    /// them); only the window server's match of the key itself is left out. For scripted checks. False when not armed.
    @discardableResult
    public func simulatePress() -> Bool {
        guard isArmed else { return false }
        return Self.dispatchSimulatedHotKey(id: id)
    }

    /// Simulates a hardware Escape press routed to the topmost armed owner on the shared LIFO stack.
    @discardableResult
    public static func simulateHardwarePress() -> Bool {
        stack.removeAll { $0.key == nil }
        guard !stack.isEmpty else { return false }
        return dispatchSimulatedHotKey(id: sharedHotKeyID)
    }

    private static func dispatchSimulatedHotKey(id: UInt32) -> Bool {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &event) == noErr,
              let event
        else { return false }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        return SendEventToEventTarget(event, GetEventDispatcherTarget()) == noErr
    }
    #endif

    /// Escape, as the key it was, to a modal window, sheet, popover, or panel holding the keyboard.
    private static func forwardEscape(to window: NSWindow) {
        guard let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)
        ) else { return }
        Log.hotkeys.notice("hotkey.escape went to the active window")
        NSApplication.shared.sendEvent(escape)
    }
}

private let escapeHotKeyHandler: EventHandlerUPP = { _, event, _ in
    EscapeHotKey.handle(event)
}
