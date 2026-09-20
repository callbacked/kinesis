import AppKit
import SwiftUI
import Testing
@testable import Kinesis

/// Draws every pairing state to PNG files for a visual check. It runs only
/// when KINESIS_RENDER_DIR names a directory:
/// `KINESIS_RENDER_DIR=/tmp/kinesis swift test --filter pairingStatesRender`
@Test @MainActor func pairingStatesRenderForReview() throws {
    guard let directory = ProcessInfo.processInfo.environment["KINESIS_RENDER_DIR"] else { return }
    let states: [(String, PairingInput)] = [
        ("new band", PairingInput()),
        ("finding", PairingInput(route: .scanning)),
        ("macOS pairing request", PairingInput(route: .connecting, hasRememberedBand: true, awaitingSystemPairing: true, canPair: false)),
        ("sign in", PairingInput(route: .enrolling, stage: .login, hasRememberedBand: true, canPair: false)),
        ("claiming", PairingInput(route: .enrolling, stage: .working("confirming ownership"), hasRememberedBand: true, hasSavedSession: true, canPair: false)),
        ("settling", PairingInput(route: .connecting, hasRememberedBand: true, claimedThisRun: true, canPair: false)),
        ("no band found", PairingInput(failure: "no band found. put the band in pairing mode and pair again.", failedStep: .find, emptyScans: 2)),
        ("claim refused", PairingInput(failure: "this band belongs to a different meta account. sign in with that account, or factory reset the band (hold its button for about 16 seconds) to claim it with this one.", failedStep: .claim, hasRememberedBand: true)),
        ("setup incomplete, after bailing out of the sign-in", PairingInput(hasRememberedBand: true, bandName: "Meta Band 00BC")),
        ("pair it again", PairingInput(hasRememberedBand: true, bandName: "Meta Band 00BC", identityRejected: true)),
    ]
    let sheet = VStack(alignment: .leading, spacing: 26) {
        ForEach(states, id: \.0) { name, input in
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(KinesisStyle.secondary)
                PairingFlowView(state: PairingPresentation(input))
            }
        }
        Text("centered, as in setup").font(.system(size: 10, weight: .semibold)).foregroundStyle(KinesisStyle.secondary)
        PairingFlowView(state: PairingPresentation(PairingInput(route: .scanning)), layout: .centered).frame(width: 560)
    }.padding(32).frame(width: 760, alignment: .leading).background(KinesisStyle.paper).foregroundStyle(KinesisStyle.ink)
    let signIn = MetaLoginView(onSession: { _ in }, onCancel: {})
    for (name, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
        for (file, view) in [("pairing", AnyView(sheet)), ("sign-in", AnyView(signIn)),
                             ("reset-reminder", AnyView(FactoryResetReminder(done: {})))] {
            var png: Data?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
                renderer.scale = 2
                if let image = renderer.cgImage {
                    png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                }
            }
            let data = try #require(png)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(file)-\(name).png"))
        }
    }
}
