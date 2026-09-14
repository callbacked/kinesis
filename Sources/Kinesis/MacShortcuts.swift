import AppKit
import IOKit.hidsystem
import KinesisCore

@MainActor
protocol MacControls {
    var trusted: Bool { get }
    func requestAccess()
    func post(_ action: MacAction) throws
}

@MainActor
struct MacShortcuts: MacControls {
    var trusted: Bool { CGPreflightPostEventAccess() }

    func requestAccess() {
        _ = CGRequestPostEventAccess()
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
        return (down, up)
    }
}
