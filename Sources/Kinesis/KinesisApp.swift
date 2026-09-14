import AppKit
import SwiftUI

extension Bundle {
    static let kinesis = Bundle.main.url(forResource: "Kinesis_Kinesis", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BandModel()
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
        MenuBarExtra("Kinesis", systemImage: "waveform") {
            BandMenu(model: delegate.model)
        }
    }
}

private struct BandMenu: View {
    @ObservedObject var model: BandModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.bandName)
        Text(model.phase)
        if let battery = model.battery { Text("Battery \(battery)%") }
        Divider()
        Button(model.controlsEnabled ? "Pause Mac controls" : "Enable Mac controls") { model.toggleControls() }
            .disabled(model.showingSetup || (!model.live && !model.controlsEnabled))
        Button(model.wantsConnection ? "Disconnect band" : "Connect band") {
            if model.wantsConnection { model.disconnect() } else { model.connect() }
        }.disabled(model.selectedAddress.isEmpty || (model.busy && !model.wantsConnection))
        Divider()
        Button("Open Kinesis") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Kinesis") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
