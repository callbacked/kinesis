#if KINESIS_DEV
import AppKit
import Combine
import KinesisCore
import SwiftUI

/// Shows the calibration targets over the whole main display while calibration runs.
/// The window ignores the mouse, so the trackpad keeps working underneath it.
@MainActor final class CalibrationOverlay {
    private let model: BandModel
    private var panel: NSPanel?
    private var watcher: AnyCancellable?

    init(model: BandModel) {
        self.model = model
        watcher = model.$pointerCalibration.map { $0 != nil }.removeDuplicates().sink { [weak self] active in
            active ? self?.show() : self?.hide()
        }
    }

    private func show() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: CalibrationTargets(model: model))
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CalibrationTargets: View {
    @ObservedObject var model: BandModel
    @State private var demo = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: PointerCalibration.Step { model.pointerCalibration?.step ?? .left }

    private var instruction: String {
        switch step {
        case .left: "point your forearm at the dot, then pinch"
        case .right: "now the dot on the right"
        case .top: "now the dot at the top"
        case .bottom: "last one, at the bottom"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let fraction = PointerCalibration.position(of: step)
            let target = CGPoint(x: fraction.x * geometry.size.width, y: fraction.y * geometry.size.height)
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                Target().position(target)
                    .animation(reduceMotion ? nil : KinesisMotion.enter, value: step)
                VStack(spacing: 14) {
                    HandView(scene: HandSceneView(hand: model.bandHand, highlight: .index, gesture: .tap(.indexTap),
                                                  revision: demo, viewpoint: .teaching, demonstrates: true))
                        .frame(width: 180, height: 140)
                    Text("\(step.rawValue + 1) of 4").font(KinesisType.micro).foregroundStyle(.white.opacity(0.6))
                    Text(instruction).font(.system(size: 22)).tracking(-0.5).foregroundStyle(.white)
                        .contentTransition(.opacity)
                    Text(model.pointerCalibrationProblem ?? "use small, comfortable turns, the way you’ll aim later. esc to stop.")
                        .font(KinesisType.caption)
                        .foregroundStyle(model.pointerCalibrationProblem == nil ? .white.opacity(0.6) : Color(red: 1, green: 0.62, blue: 0.5))
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .padding(28)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
                // Keep the panel away from whichever target is showing.
                .position(x: geometry.size.width / 2, y: step == .bottom ? geometry.size.height * 0.33 : geometry.size.height * 0.66)
            }
        }
        .task {
            // The hand pinches every few seconds, as a reminder of what to do.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                demo += 1
            }
        }
    }
}

private struct Target: View {
    var body: some View {
        ZStack {
            Pulse { beat in
                Circle().stroke(KinesisStyle.accent.opacity(0.7), lineWidth: 2)
                    .frame(width: 44, height: 44).scaleEffect(1 + beat).opacity(1 - beat)
            }
            Circle().stroke(.white, lineWidth: 2).frame(width: 30, height: 30)
            Circle().fill(KinesisStyle.accent).frame(width: 10, height: 10)
        }
        .accessibilityHidden(true)
    }
}
#endif
