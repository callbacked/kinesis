import AppKit
import SwiftUI

extension Bundle {
    static let kinesis = Bundle.main.url(forResource: "Kinesis_Kinesis", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BandModel(forgetSystemPairing: SystemPairing.remove(named:))
    func applicationDidFinishLaunching(_ notification: Notification) { model.startAutomatically() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        if let battery = model.battery { Text("battery \(battery)%") }
        Divider()
        // The same next step the band's column offers, so the menu never disagrees with the window.
        switch model.nextAction {
        case .pair:
            Button("pair band…") { open() }
        case .pairing, .connecting:
            Button(model.nextAction.title) {}.disabled(true)
        case .connect:
            Button("connect") { model.connect() }
        case .enableControls, .pauseControls:
            Button(model.nextAction.title) { model.toggleControls() }.disabled(model.showingSetup)
        }
        if model.live || model.wantsConnection {
            Button("disconnect") { model.disconnect() }
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
