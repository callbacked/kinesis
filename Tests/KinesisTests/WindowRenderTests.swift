import AppKit
import Metal
import SceneKit
import SwiftUI
import Testing
import KinesisCore
@testable import Kinesis

@MainActor private final class StagedConnection: BandConnection {
    private var onEvent: ((BandEvent) -> Void)?
    private var onEnd: ((Error?) -> Void)?
    func start(_ operation: BandOperation, onEvent: @escaping (BandEvent) -> Void,
               onEnd: @escaping (Error?) -> Void) throws {
        self.onEvent = onEvent
        self.onEnd = onEnd
    }
    func stop() {
        let end = onEnd
        onEnd = nil
        onEvent = nil
        end?(nil)
    }
    func setHandedness(_ hand: BandHand) throws {}
    func resumeCeremony(_ completion: CeremonyCompletion) throws {}
    func send(_ payload: BandEvent.Payload) { onEvent?(BandEvent(payload, at: 100)) }
}

private struct AllowedControls: MacControls {
    var trusted = true
    func requestAccess() {}
    func post(_ action: MacAction) throws {}
}

@MainActor private final class NoSession: MetaSessionStoring {
    func hasSavedSession() -> Bool { false }
    func saveSession(_ session: MetaSession) {}
    func restoreSession() -> MetaSession? { nil }
    func deleteSession() {}
}

/// Draws the whole window in its main states, light and dark. It runs only
/// when KINESIS_RENDER_DIR names a directory. SceneKit and menus draw as
/// placeholders offscreen; everything else is what the app shows.
@Test @MainActor func windowStatesRenderForReview() throws {
    guard let directory = ProcessInfo.processInfo.environment["KINESIS_RENDER_DIR"] else { return }
    let band = "render-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }

    func model(paired: Bool, live: Bool, trusted: Bool = true) throws -> BandModel {
        let suite = "kinesis-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "setupCompleted")
        defaults.set(1284, forKey: "totalGestureCount")
        if paired {
            defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Meta Band 00BC")), forKey: "band")
            if !BandIdentity.exists(for: band) { try BandIdentity.generate(for: band) }
        }
        let connection = StagedConnection()
        let model = BandModel(defaults: defaults, connection: connection, controls: AllowedControls(trusted: trusted),
                              sessionStore: NoSession(), clock: { 100 })
        if live {
            model.connect()
            connection.send(.connected)
            connection.send(.heartbeat)
            connection.send(.battery(86))
            connection.send(.handedness(.right))
            model.toggleControls()
        }
        return model
    }

    func setup(_ model: BandModel, step: Int) -> some View {
        SetupView(model: model, step: step).background(Field()).foregroundStyle(KinesisStyle.ink)
    }

    let windows: [(String, AnyView)] = [
        ("overview-live", AnyView(MainView(model: try model(paired: true, live: true), scrolls: false))),
        ("overview-offline", AnyView(MainView(model: try model(paired: true, live: false), scrolls: false))),
        ("gestures", AnyView(MainView(model: try model(paired: true, live: true), page: .gestures, scrolls: false))),
        ("band-paired", AnyView(MainView(model: try model(paired: true, live: true), page: .band, scrolls: false))),
        ("band-unpaired", AnyView(MainView(model: try model(paired: false, live: false, trusted: false), page: .band, scrolls: false))),
        ("setup-0-fresh", AnyView(setup(try model(paired: false, live: false, trusted: false), step: 0))),
        ("setup-0-connected", AnyView(setup(try model(paired: true, live: true), step: 0))),
        ("setup-1-swipe", AnyView(setup(try model(paired: true, live: true), step: 1))),
        ("setup-2-turn", AnyView(setup(try model(paired: true, live: true), step: 2))),
        ("setup-3-ready", AnyView(setup(try model(paired: true, live: true, trusted: false), step: 3))),
    ]
    // SceneKit does not draw inside ImageRenderer, so the hand is drawn on its own and handed in.
    func hand(dark: Bool, teaching: Bool) throws -> NSImage {
        let coordinator = HandSceneView.Coordinator(viewpoint: teaching ? .teaching : .overview)
        coordinator.setBackground(dark: dark)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = coordinator.scene
        renderer.pointOfView = coordinator.camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: 1050, height: 1050), antialiasingMode: .multisampling4X)
    }
    for (name, window) in windows {
        for (mode, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
            var png: Data?
            let standIn = try hand(dark: scheme == .dark, teaching: name.hasPrefix("setup"))
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: window.frame(width: 980, height: 730).environment(\.colorScheme, scheme)
                    .environment(\.handStandIn, standIn))
                renderer.scale = 1.5
                if let image = renderer.cgImage {
                    png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                }
            }
            try #require(png).write(to: URL(fileURLWithPath: directory).appendingPathComponent("window-\(name)-\(mode).png"))
        }
    }
}
