import AppKit
import SwiftUI

struct CursorPage: View {
    @ObservedObject var model: BandModel

    /// Degrees of arm turn that cross the display in front of the wearer, before acceleration.
    private var degreesAcross: Double {
        let width = NSScreen.main?.frame.width ?? 1440
        return width / model.cursorSpeed
    }

    private var leversChanged: Bool {
        model.cursorSpeed != PointerReach.standardSpeed || abs(model.cursorFlickBoost - PointerAcceleration.fastFactor) > 0.01
            || abs(model.cursorSteadiness - BandModel.standardSteadiness) > 0.01
    }

    private var status: String? {
        if model.cursorRepositioning { return "parked · let go of Option" }
        if model.airCursorEnabled { return "pinch to click · hold to drag · middle pinch to right-click · esc to stop" }
        return model.canUseAirCursor ? nil : "connect your band and turn on controls"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("a little room to move.").font(KinesisType.title).tracking(-1.2)
            OpenRow(title: "air cursor", detail: "experimental") {
                Toggle("Air cursor", isOn: Binding(get: { model.airCursorEnabled }, set: { model.setAirCursorEnabled($0) }))
                    .toggleStyle(KinesisToggleStyle())
                    .disabled(!model.airCursorEnabled && !model.canUseAirCursor)
            }
            if let status {
                Text(status).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            }
            ArmMirror(model: model)

            Lever(title: "speed", value: String(format: "%.0f° across this screen", degreesAcross), slower: "slower", faster: "faster",
                  changed: model.cursorSpeed != PointerReach.standardSpeed, reset: { model.cursorSpeed = PointerReach.standardSpeed }) {
                PillSlider(value: $model.cursorSpeed, range: PointerReach.speeds, step: 5, label: "Pointer speed")
            }
            Lever(title: "flick boost", value: String(format: "%.1f×", model.cursorFlickBoost), slower: "even", faster: "more boost",
                  changed: abs(model.cursorFlickBoost - PointerAcceleration.fastFactor) > 0.01,
                  reset: { model.cursorFlickBoost = PointerAcceleration.fastFactor }) {
                PillSlider(value: $model.cursorFlickBoost, range: PointerAcceleration.flickBoosts, step: 0.1, label: "Flick boost")
            }
            HStack(alignment: .top, spacing: 22) {
                Lever(title: "steadiness", value: nil, slower: "more responsive", faster: "more steady",
                      changed: abs(model.cursorSteadiness - BandModel.standardSteadiness) > 0.01,
                      reset: { model.cursorSteadiness = BandModel.standardSteadiness }) {
                    PillSlider(value: $model.cursorSteadiness, range: 0...1, step: 0.1, label: "Cursor steadiness")
                }
                StillnessRing(speed: model.cursorArmSpeed, still: AirPointer.still(steadiness: model.cursorSteadiness),
                              live: model.live)
            }
            TryItRow(done: model.cursorSkills)
            if leversChanged {
                Button("reset all") { model.resetCursorLevers() }
                    .buttonStyle(KinesisButtonStyle())
            }

            #if KINESIS_LAB
            OpenRow(title: "calibrate", detail: model.pointerCalibrated
                        ? String(format: "lab · %.0f pt/°, tilt %.2f", model.cursorSpeed, model.pointerReach.upTilt) : "lab") {
                HStack(spacing: 14) {
                    if model.pointerCalibrated {
                        Button("reset") {
                            model.resetPointerReach()
                            model.cursorSpeed = PointerReach.standardSpeed
                        }
                        .buttonStyle(.plain).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                    }
                    Button(model.pointerCalibrated ? "redo" : "start") { model.beginPointerCalibration() }
                        .buttonStyle(KinesisButtonStyle())
                        .disabled(!model.canUseAirCursor || model.pointerCalibration != nil)
                }
            }
            OpenRow(title: "practice", detail: "lab") {
                Button("open") { PracticeWindow.shared.open(model: model) }
                    .buttonStyle(KinesisButtonStyle())
            }
            #endif

            Text("hold Option to move your arm without moving the pointer.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
        }
        .onAppear { model.setCursorPageVisible(true) }
        .onDisappear { model.setCursorPageVisible(false) }
    }
}

/// The hand, turning as the forearm turns and pinching as the fingers pinch, so the
/// wearer sees what the band reads: the forearm's direction. A held pose drifts back
/// to the middle over a few seconds, so the hand never sits at an odd angle.
private struct ArmMirror: View {
    @ObservedObject var model: BandModel
    @State private var rest: ForearmAim?
    @Environment(\.colorScheme) private var scheme

    /// Degrees from rest, left and up, within what the picture can show.
    private var turned: SIMD2<Double>? {
        guard let aim = model.cursorAim, let rest else { return nil }
        let left = remainder(aim.azimuth - rest.azimuth, 360)
        return SIMD2(max(-40, min(40, left)), max(-40, min(40, aim.elevation - rest.elevation)))
    }

    var body: some View {
        HandView(scene: HandSceneView(hand: model.bandHand,
                                      highlight: model.pinchedFinger.map { $0 == "middle" ? .middle : .index } ?? .none,
                                      sustained: model.pinchedFinger != nil, aim: turned))
            .frame(width: 220, height: 180)
            .background {
                Circle().fill(RadialGradient(colors: [KinesisStyle.pool, .clear], center: .center, startRadius: 20, endRadius: 110))
                    .opacity(scheme == .dark ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
        .onChange(of: model.cursorAim) { _, aim in
            guard let aim else { rest = nil; return }
            guard var next = rest else { rest = aim; return }
            // 20 updates a second: rest follows the arm over about 2.5 seconds.
            next.azimuth += remainder(aim.azimuth - next.azimuth, 360) * 0.02
            next.elevation += (aim.elevation - next.elevation) * 0.02
            rest = next
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A hand that follows your forearm")
    }
}

/// One setting: its name, its value, and its control.
private struct Lever<Control: View>: View {
    let title: String
    let value: String?
    let slower: String
    let faster: String
    var changed = false
    var reset: () -> Void = {}
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(KinesisType.body)
                if changed {
                    Button("reset", action: reset).buttonStyle(.plain)
                        .font(KinesisType.caption).foregroundStyle(KinesisStyle.accent)
                }
                Spacer()
                if let value { Text(value).font(KinesisType.label).monospacedDigit().foregroundStyle(KinesisStyle.secondary) }
            }
            control
            HStack {
                Text(slower)
                Spacer()
                Text(faster)
            }
            .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
        }
    }
}

/// The arm's live speed as a disk, and the stillness threshold as a ring. While the
/// disk stays inside the ring, the pointer holds still. Steadiness grows the ring.
private struct StillnessRing: View {
    let speed: Double
    let still: ClosedRange<Double>
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Degrees a second at the edge of the drawing.
    private let scale = 3.0
    private let size = 96.0

    private func diameter(_ degrees: Double) -> Double { min(1, degrees / scale) * (size - 6) }

    var body: some View {
        let moving = speed > still.lowerBound
        ZStack {
            Circle().stroke(KinesisStyle.line, lineWidth: 1).frame(width: size - 6, height: size - 6)
            if live {
                Circle().fill(moving ? KinesisStyle.ink.opacity(0.18) : KinesisStyle.accent.opacity(0.22))
                    .frame(width: max(6, diameter(speed)), height: max(6, diameter(speed)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: speed)
            }
            Circle().stroke(KinesisStyle.accent.opacity(0.8), lineWidth: 1.5)
                .frame(width: diameter(still.lowerBound), height: diameter(still.lowerBound))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : KinesisMotion.settle, value: still.lowerBound)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(moving ? "Your arm is moving the pointer" : "Your arm is inside the stillness threshold")
    }
}

/// The pointer's actions as words that light up once done with the air cursor.
private struct TryItRow: View {
    let done: Set<BandModel.CursorSkill>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let skills: [(BandModel.CursorSkill, String)] = [(.click, "click"), (.rightClick, "right-click"),
                                                              (.drag, "drag"), (.doubleClick, "double-click")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("try it").font(KinesisType.body)
            HStack(spacing: 8) {
                ForEach(skills, id: \.1) { skill, word in
                    let isDone = done.contains(skill)
                    HStack(spacing: 5) {
                        if isDone { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                        Text(word)
                    }
                    .font(KinesisType.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(isDone ? Color.white : KinesisStyle.ink)
                    .background(Capsule().fill(isDone ? KinesisStyle.accent : KinesisStyle.tray))
                    .animation(reduceMotion ? nil : KinesisMotion.settle, value: isDone)
                }
            }
        }
    }
}
