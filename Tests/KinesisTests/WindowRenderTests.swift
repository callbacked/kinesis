import AppKit
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

    let windows: [(String, MainView)] = [
        ("overview-live", MainView(model: try model(paired: true, live: true), scrolls: false)),
        ("overview-offline", MainView(model: try model(paired: true, live: false), scrolls: false)),
        ("gestures", MainView(model: try model(paired: true, live: true), page: .gestures, scrolls: false)),
        ("band-paired", MainView(model: try model(paired: true, live: true), page: .band, scrolls: false)),
        ("band-unpaired", MainView(model: try model(paired: false, live: false, trusted: false), page: .band, scrolls: false)),
    ]
    for (name, window) in windows {
        for (mode, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
            var png: Data?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: window.frame(width: 980, height: 730).environment(\.colorScheme, scheme))
                renderer.scale = 1.5
                if let image = renderer.cgImage {
                    png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                }
            }
            try #require(png).write(to: URL(fileURLWithPath: directory).appendingPathComponent("window-\(name)-\(mode).png"))
        }
    }
}
