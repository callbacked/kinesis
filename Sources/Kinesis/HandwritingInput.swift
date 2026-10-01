import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Handwriting as real input. Started by a gesture while a text field has the focus, it
/// types what the band reads into that field, in any app: a browser, a chat, an editor or
/// a terminal. It stops by itself when the keyboard is used, when the focus leaves a text
/// field, or after a pause in writing, so it never has to be switched off.
@MainActor final class HandwritingInput {
    static let shared = HandwritingInput()

    /// Writing that stops for this long ends the session.
    static let idleSeconds = 12.0
    /// Marks the keys this types, so its own keys never count as the keyboard being used.
    private static let tag: Int64 = 0x4B494E_575249
    /// Terminals often don't report their text view to accessibility. Their window is input.
    private static let terminals = ["terminal", "iterm", "ghostty", "warp", "alacritty", "kitty", "wezterm", "hyper"]

    private(set) var active = false
    private weak var recording: BandModelRecording?
    private var typed = ""
    private var lastWriting = 0.0
    private var unfocusedSince: Double?
    private var watchers: Set<AnyCancellable> = []
    private var keyboard: Any?
    private var timer: Timer?
    private var askedForAccess: Set<pid_t> = []
    private let badge = WritingBadge()

    private init() {}

    /// Browsers whose web pages show their fields only when an assistive app asks.
    private static let browsers = ["chrome", "chromium", "edgemac", "brave", "thebrowser", "vivaldi", "opera", "firefox"]
    private var appWatcher: Any?

    /// Asks each app, as it comes to the front, to show its fields to accessibility, so the
    /// check at a gesture finds them. Browsers build that on request, and a fresh request
    /// at the gesture itself comes too late.
    func watchApps() {
        guard appWatcher == nil else { return }
        appWatcher = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.askForFields(app) }
        }
        if let app = NSWorkspace.shared.frontmostApplication { askForFields(app) }
    }

    private func askForFields(_ app: NSRunningApplication) {
        guard app.processIdentifier != getpid(), askedForAccess.insert(app.processIdentifier).inserted else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Electron and Chromium answer to this one. It does nothing in other apps.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Browsers also answer to the one screen readers set. Only browsers get it: some
        // other apps slow their window animations under it.
        let id = app.bundleIdentifier?.lowercased() ?? ""
        if Self.browsers.contains(where: id.contains) {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Whether the front app's focus takes text: a text field or area, anything whose text
    /// can be set or selected, as web editors are, or a terminal. Kinesis itself never
    /// counts: there, the write page shows the writing.
    func focusTakesText() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return false }
        let id = app.bundleIdentifier?.lowercased() ?? ""
        if Self.terminals.contains(where: id.contains) { return true }
        askForFields(app)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let focused = value, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            lastRefusal = "\(id): no focused element"
            return false
        }
        let field = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
        let roleName = role as? String ?? "?"
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(roleName) { return true }
        var editable: CFTypeRef?
        AXUIElementCopyAttributeValue(field, "AXEditable" as CFString, &editable)
        if (editable as? Bool) == true { return true }
        var settable = DarwinBoolean(false)
        for attribute in [kAXValueAttribute, kAXSelectedTextRangeAttribute] {
            if AXUIElementIsAttributeSettable(field, attribute as CFString, &settable) == .success, settable.boolValue { return true }
        }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole)
        lastRefusal = "\(id): focused \(roleName) \(subrole as? String ?? ""), not editable"
        return false
    }

    /// What the last refused check saw, for the log.
    private(set) var lastRefusal = ""

    /// Types into the focused field what `recording` reads, until something ends it.
    func begin(_ recording: BandModelRecording) {
        guard !active else { return }
        active = true
        self.recording = recording
        typed = ""
        unfocusedSince = nil
        lastWriting = ProcessInfo.processInfo.systemUptime
        recording.clearHandwriting()
        recording.$candidateText.dropFirst().sink { [weak self] text in self?.follow(text) }.store(in: &watchers)
        recording.$phase.sink { [weak self] phase in
            if phase == .done || phase == .idle { self?.end() }
            // The clock for a pause starts once the band is ready, not while it switches.
            if phase == .recording { self?.lastWriting = ProcessInfo.processInfo.systemUptime }
        }.store(in: &watchers)
        keyboard = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.tag else { return }
            MainActor.assumeIsolated { self?.stop() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        badge.show()
    }

    /// Shows a short note in the badge for a moment, when writing can't start.
    func flash(_ note: String) {
        guard !active else { return }
        badge.flash(note)
    }

    /// Ends writing. The band goes back to normal, and the typed text stays.
    func stop() {
        guard active else { return }
        if let recording, recording.isRunning, recording.phase != .restoring { recording.finish() }
        end()
    }

    private func end() {
        guard active else { return }
        active = false
        watchers = []
        if let keyboard { NSEvent.removeMonitor(keyboard) }
        keyboard = nil
        timer?.invalidate()
        timer = nil
        badge.hide()
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        if focusTakesText() {
            unfocusedSince = nil
        } else if let since = unfocusedSince {
            if now - since > 1 { stop(); return }
        } else {
            unfocusedSince = now
        }
        if now - lastWriting > Self.idleSeconds { stop() }
    }

    /// Brings the field from what was typed to the band's text: deletes back to where they
    /// differ, then types the rest. That covers letters, spaces, deletes and capitals alike.
    private func follow(_ text: String) {
        guard active, text != typed else { return }
        lastWriting = ProcessInfo.processInfo.systemUptime
        let shared = zip(typed, text).prefix { $0 == $1 }.count
        for _ in 0..<(typed.count - shared) { press(51) }
        for character in text.dropFirst(shared) {
            if character == "\n" { press(36) } else { type(String(character)) }
        }
        typed = text
        badge.update(text)
    }

    private func type(_ string: String) {
        let units = Array(string.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.setIntegerValueField(.eventSourceUserData, value: Self.tag)
            event.post(tap: .cghidEventTap)
        }
    }

    private func press(_ key: CGKeyCode) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: Self.tag)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// A small badge at the top of the screen while the band types: it is listening, and what
/// it read last.
@MainActor private final class WritingBadge {
    private var panel: NSPanel?
    private let state = BadgeState()
    private var hideTask: Task<Void, Never>?

    func show() {
        hideTask?.cancel()
        state.text = ""
        state.listening = true
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: BadgeView(state: state))
            self.panel = panel
        }
        if let screen = NSScreen.main, let panel {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.maxY - 56))
        }
        panel?.orderFrontRegardless()
    }

    func update(_ text: String) { state.text = String(text.suffix(24)) }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    /// A note for a moment, then gone.
    func flash(_ note: String) {
        show()
        state.text = note
        state.listening = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}

@MainActor private final class BadgeState: ObservableObject {
    @Published var text = ""
    /// False while it shows a note instead of listening.
    @Published var listening = true
}

private struct BadgeView: View {
    @ObservedObject var state: BadgeState

    var body: some View {
        HStack(spacing: 9) {
            if state.listening {
                Pulse { beat in
                    Circle().fill(KinesisStyle.accent).frame(width: 7, height: 7).opacity(0.45 + 0.55 * (1 - beat))
                }
            }
            Text(state.text.isEmpty ? "writing" : state.text).font(KinesisType.label).lineLimit(1)
                .foregroundStyle(KinesisStyle.ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(PillSurface(fill: KinesisStyle.paper, raised: true))
        .frame(maxWidth: .infinity)
    }
}
