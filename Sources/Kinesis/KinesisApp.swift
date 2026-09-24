import AppKit
import SwiftUI

extension Bundle {
    static let kinesis = Bundle.main.url(forResource: "Kinesis_Kinesis", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BandModel()
    private var cursorKeyMonitors: [Any] = []
    #if KINESIS_DEV
    private var calibrationOverlay: CalibrationOverlay?
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if KINESIS_DEV
        calibrationOverlay = CalibrationOverlay(model: model)
        #endif
        // Local monitors cover Kinesis; global monitors cover whichever app the
        // user is pointing at. Both use the app's existing Accessibility access.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            self?.handleCursorKey(event)
            return event
        }) { cursorKeyMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            self?.handleCursorKey(event)
        }) { cursorKeyMonitors.append(monitor) }
        model.startAutomatically()
    }
    private func handleCursorKey(_ event: NSEvent) {
        // A mapped thumb swipe can send Escape without disabling the cursor.
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != MacShortcuts.shortcutEventTag else { return }
        #if KINESIS_DEV
        // Escape in the practice lab ends a run. It must not turn the cursor off too.
        if event.type == .keyDown, PracticeWindow.shared.owns(event) { return }
        #endif
        if event.type == .keyDown, event.keyCode == 53 { model.setAirCursorEnabled(false) }
        model.setCursorRepositioning(event.modifierFlags.contains(.option))
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if KINESIS_DEV
        // A run in progress saves what it has.
        PracticeWindow.shared.close()
        #endif
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct KinesisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Kinesis", id: "main") {
            MainView(model: delegate.model)
        }
        .defaultSize(width: 980, height: 730)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            BandMenu(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
    }
}

/// The kinesis mark in the menu bar. It is a template image, so macOS tints it
/// for light and dark menu bars. It dims while gestures are not reaching the Mac.
private struct MenuBarLabel: View {
    @ObservedObject var model: BandModel
    var body: some View {
        Image(nsImage: model.live && model.controlsEnabled ? Self.live : Self.idle)
            .accessibilityLabel(model.live && model.controlsEnabled ? "Kinesis, controls live" : "Kinesis")
    }

    // Drawn once each. The model publishes on every gesture, and the mark never changes.
    private static let live = icon(active: true)
    private static let idle = icon(active: false)

    private static func icon(active: Bool) -> NSImage {
        let mark = KinesisMark(size: CGSize(width: 20, height: 17), lineWidth: 5.6)
            .foregroundStyle(.black).opacity(active ? 1 : 0.5)
        let renderer = ImageRenderer(content: mark)
        renderer.scale = 3
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct BandMenu: View {
    @ObservedObject var model: BandModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("\(model.bandName.lowercased()) · \(model.phase.lowercased())")
        if let battery = model.battery {
            Text(model.chargeState.isCharging ? "battery \(battery)% · charging" : "battery \(battery)%")
        }
        Divider()
        // The same next step the band's column offers, so the menu never disagrees with the window.
        switch model.nextAction {
        case .pair:
            Button("pair band…") { open() }
        case .pairing, .connecting, .disconnecting:
            Button(model.nextAction.title) {}.disabled(true)
        case .connect:
            Button("connect") { model.connect() }
        case .enableControls, .pauseControls:
            Button(model.nextAction.title) { model.toggleControls() }.disabled(model.showingSetup)
        }
        if model.live || model.wantsConnection {
            Button("disconnect") { model.disconnect() }
        }
        if model.developerMode {
            Toggle("air cursor", isOn: Binding(get: { model.airCursorEnabled }, set: { model.setAirCursorEnabled($0) }))
                .disabled(!model.airCursorEnabled && !model.canUseAirCursor)
            #if KINESIS_DEV
            Button("open lab") { PracticeWindow.shared.open(model: model) }
            #endif
        }
        Divider()
        Button("open kinesis") { open() }
        Button("quit kinesis") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
