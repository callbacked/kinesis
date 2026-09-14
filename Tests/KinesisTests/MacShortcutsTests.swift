import AppKit
import Testing
import KinesisCore
@testable import Kinesis

@Test @MainActor func systemShortcutsRetainArrowKeyIdentity() throws {
    for action in [MacAction.previousDesktop, .nextDesktop, .missionControl] {
        let (down, up) = try MacShortcuts.events(for: action)
        for event in [down, up] {
            let key = try #require(NSEvent(cgEvent: event))
            #expect(key.modifierFlags.contains([.control, .function, .numericPad]))
            #expect(!key.modifierFlags.contains(.command))
        }
        #expect(down.type == .keyDown)
        #expect(up.type == .keyUp)
    }
}

@Test @MainActor func dismissSendsUnmodifiedEscape() throws {
    let (down, up) = try MacShortcuts.events(for: .dismiss)
    for event in [down, up] {
        let key = try #require(NSEvent(cgEvent: event))
        #expect(key.keyCode == 53)
        #expect(key.modifierFlags.intersection([.control, .command, .shift, .option, .function]).isEmpty)
    }
}

@Test @MainActor func mediaControlsEncodeBothPressAndRelease() throws {
    for (action, keyCode) in [(MacAction.playPause, 16), (.mute, 7), (.volumeUp, 0), (.volumeDown, 1), (.brightnessUp, 2), (.brightnessDown, 3)] {
        let (down, up) = try MacShortcuts.events(for: action)
        let press = try #require(NSEvent(cgEvent: down))
        let release = try #require(NSEvent(cgEvent: up))
        #expect(press.type == .systemDefined)
        #expect(press.subtype.rawValue == 8)
        #expect(press.data1 == (keyCode << 16) | 0xA00)
        #expect(release.data1 == (keyCode << 16) | 0xB00)
    }
}
