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
    var saved: MetaSession?
    func hasSavedSession() -> Bool { saved != nil }
    func saveSession(_ session: MetaSession) { saved = session }
    func restoreSession() -> MetaSession? { saved }
    func deleteSession() { saved = nil }
}

/// Draws the whole window in its main states, light and dark. It runs only
/// when KINESIS_RENDER_DIR names a directory. SceneKit and menus draw as
/// placeholders offscreen; everything else is what the app shows.
@Test @MainActor func windowStatesRenderForReview() throws {
    guard let directory = ProcessInfo.processInfo.environment["KINESIS_RENDER_DIR"] else { return }
    let band = "render-\(UUID().uuidString)"
    defer { BandIdentity.delete(for: band) }

    func model(paired: Bool, live: Bool, trusted: Bool = true, turning: Bool = false) throws -> BandModel {
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
            // A held pinch lights the accent everywhere it lives: the hand, the electrodes, the row.
            if turning { connection.send(.dialState(true)) }
        }
        return model
    }

    // The hard cases: a long name, a low battery, a big count, a long error, and the
    // wait for macOS, all at the smallest size the window allows.
    func strained() throws -> BandModel {
        let suite = "kinesis-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "setupCompleted")
        defaults.set(1_284_302, forKey: "totalGestureCount")
        defaults.set(try JSONEncoder().encode(BandDevice(address: band, name: "Alexander’s Meta Neural Band 00BC-7F3A")), forKey: "band")
        if !BandIdentity.exists(for: band) { try BandIdentity.generate(for: band) }
        let connection = StagedConnection()
        let model = BandModel(defaults: defaults, connection: connection, controls: AllowedControls(trusted: false),
                              sessionStore: NoSession(), clock: { 100 })
        model.connect()
        connection.send(.connected)
        connection.send(.heartbeat)
        connection.send(.battery(9))
        model.error = "the band stopped answering (CBErrorDomain 7, peripheral disconnected). kinesis will try again in a moment. if this keeps happening, restart the band."
        return model
    }
    func waitingForMacOS() throws -> BandModel {
        let suite = "kinesis-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "setupCompleted")
        let unclaimed = "render-unclaimed-\(UUID().uuidString)"
        defaults.set(try JSONEncoder().encode(BandDevice(address: unclaimed, name: "Meta Band 00BC")), forKey: "band")
        let connection = StagedConnection()
        let store = NoSession()
        store.saved = MetaSession(accessToken: "token", userID: "1")
        let model = BandModel(defaults: defaults, connection: connection, controls: AllowedControls(),
                              sessionStore: store, clock: { 100 })
        model.pairBand()
        connection.send(.systemPairingPending)
        return model
    }

    func setup(_ model: BandModel, step: Int) -> some View {
        SetupView(model: model, step: step).background(Field()).foregroundStyle(KinesisStyle.ink)
    }

    let smallest = CGSize(width: 920, height: 660)
    let edges: [(String, AnyView)] = [
        ("edge-strained-overview", AnyView(MainView(model: try strained(), scrolls: false))),
        ("edge-strained-band", AnyView(MainView(model: try strained(), page: .band, scrolls: false))),
        ("edge-waiting-for-macos", AnyView(MainView(model: try waitingForMacOS(), page: .band, scrolls: false))),
    ]
    let windows: [(String, AnyView)] = [
        ("overview-live", AnyView(MainView(model: try model(paired: true, live: true), scrolls: false))),
        ("overview-turning", AnyView(MainView(model: try model(paired: true, live: true, turning: true), scrolls: false))),
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
    func hand(dark: Bool, teaching: Bool, pinching: Bool) throws -> NSImage {
        let coordinator = HandSceneView.Coordinator(viewpoint: teaching ? .teaching : .overview)
        coordinator.setBackground(dark: dark)
        if pinching {
            coordinator.rig?.snap(to: .pinchIndex)
            coordinator.setIllumination(SIMD3(1, 1, 0))
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = coordinator.scene
        renderer.pointOfView = coordinator.camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: 1050, height: 1050), antialiasingMode: .multisampling4X)
    }
    for (name, window) in windows + edges {
        let size = name.hasPrefix("edge") ? smallest : CGSize(width: 980, height: 730)
        for (mode, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
            var png: Data?
            let standIn = try hand(dark: scheme == .dark, teaching: name.hasPrefix("setup"), pinching: name.hasSuffix("turning"))
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: window.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme)
                    .environment(\.handStandIn, standIn).environment(\.motionless, true))
                renderer.scale = 1.5
                if let image = renderer.cgImage {
                    png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                }
            }
            try #require(png).write(to: URL(fileURLWithPath: directory).appendingPathComponent("window-\(name)-\(mode).png"))
        }
    }
}
