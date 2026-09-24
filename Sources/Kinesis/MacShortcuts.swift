import AppKit
import IOKit.hidsystem
import KinesisCore

@MainActor
protocol MacControls {
    var trusted: Bool { get }
    func requestAccess()
    func post(_ action: MacAction) throws
    /// Where the pointer is now, in global display points with y growing downward.
    var cursorLocation: CGPoint? { get }
    /// The size of the main display in points.
    var displaySize: CGSize { get }
    /// Moves the pointer as close to this point as a real display allows, and returns where it went.
    /// While a button is held down the move is a drag with that button.
    func moveCursor(to point: CGPoint, dragging button: CGMouseButton?) throws -> CGPoint
    /// Presses or releases a mouse button at a point, or where the pointer is when the point is nil.
    /// `clicks` is 1 for a click and 2 for the second press of a double-click.
    func mouseButton(_ button: CGMouseButton, down: Bool, clicks: Int, at point: CGPoint?) throws
}

@MainActor
struct MacShortcuts: MacControls {
    static let shortcutEventTag: Int64 = 0x4B494E45534953
    var trusted: Bool { CGPreflightPostEventAccess() }

    func requestAccess() {
        _ = CGRequestPostEventAccess()
    }

    var cursorLocation: CGPoint? { CGEvent(source: nil)?.location }

    var displaySize: CGSize { NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900) }

    func moveCursor(to point: CGPoint, dragging button: CGMouseButton?) throws -> CGPoint {
        guard trusted else { throw KinesisError(message: "Allow Kinesis in Accessibility to move the cursor.") }
        guard point.x.isFinite, point.y.isFinite else { return cursorLocation ?? point }
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
        let target = Self.cursorPosition(from: point, delta: .zero, displays: displays)
        let type: CGEventType = switch button {
        case .left?: .leftMouseDragged
        case .right?: .rightMouseDragged
        default: .mouseMoved
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: button ?? .left) else {
            throw KinesisError(message: "macOS couldn't create the cursor movement")
        }
        event.post(tap: .cghidEventTap)
        return target
    }

    static func cursorPosition(from origin: CGPoint, delta: SIMD2<Double>, displays: [CGRect]) -> CGPoint {
        let proposed = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        // Clamp to a real display, including monitors above or left of the primary.
        // Clamping only to the union would leave the cursor in gaps between screens.
        let candidates = displays.filter { $0.width >= 1 && $0.height >= 1 }.map {
            CGPoint(x: min(max(proposed.x, $0.minX), $0.maxX - 1),
                    y: min(max(proposed.y, $0.minY), $0.maxY - 1))
        }
        return candidates.min {
            hypot($0.x - proposed.x, $0.y - proposed.y) < hypot($1.x - proposed.x, $1.y - proposed.y)
        } ?? origin
    }

    func mouseButton(_ button: CGMouseButton, down: Bool, clicks: Int, at point: CGPoint?) throws {
        guard trusted else { throw KinesisError(message: "Allow Kinesis in Accessibility to click.") }
        guard let location = point ?? CGEvent(source: nil)?.location else { return }
        try Self.buttonEvent(button, down: down, clicks: clicks, at: location).post(tap: .cghidEventTap)
    }

    static func buttonEvent(_ button: CGMouseButton, down: Bool, clicks: Int, at location: CGPoint) throws -> CGEvent {
        let type: CGEventType = button == .right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
            throw KinesisError(message: "macOS couldn't create the mouse click")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, min(clicks, 3))))
        return event
    }



    static func openAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ action: MacAction) throws {
        guard action != .none else { return }
        guard trusted else { throw KinesisError(message: "Allow Kinesis in Accessibility to use Mac controls.") }
        let (down, up) = try Self.events(for: action)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func events(for action: MacAction) throws -> (CGEvent, CGEvent) {
        let mediaKey: Int?
        switch action {
        case .volumeUp: mediaKey = Int(NX_KEYTYPE_SOUND_UP)
        case .volumeDown: mediaKey = Int(NX_KEYTYPE_SOUND_DOWN)
        case .brightnessUp: mediaKey = Int(NX_KEYTYPE_BRIGHTNESS_UP)
        case .brightnessDown: mediaKey = Int(NX_KEYTYPE_BRIGHTNESS_DOWN)
        case .mute: mediaKey = Int(NX_KEYTYPE_MUTE)
        case .playPause: mediaKey = Int(NX_KEYTYPE_PLAY)
        default: mediaKey = nil
        }
        if let mediaKey {
            func event(down: Bool) throws -> CGEvent {
                // NX_SUBTYPE_AUX_CONTROL_BUTTONS encodes the media key and its up/down state.
                guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                    data1: (mediaKey << 16) | ((down ? 0xA : 0xB) << 8), data2: -1)?.cgEvent else {
                    throw KinesisError(message: "macOS couldn't create the media control")
                }
                return event
            }
            return try (event(down: true), event(down: false))
        }
        guard let key = action.keyCode,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw KinesisError(message: "macOS couldn't create the keyboard shortcut")
        }
        var flags: CGEventFlags = []
        if action.usesCommand { flags.insert(.maskCommand) }
        if action.usesControl { flags.insert(.maskControl) }
        if action.usesShift { flags.insert(.maskShift) }
        // Arrow events carry function/numeric-pad flags that macOS needs for its system shortcuts.
        down.flags.formUnion(flags)
        up.flags.formUnion(flags)
        down.setIntegerValueField(.eventSourceUserData, value: shortcutEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: shortcutEventTag)
        return (down, up)
    }
}
