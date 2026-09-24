import AppKit
import SwiftUI

struct CursorPage: View {
    @ObservedObject var model: BandModel

    /// Degrees of arm turn that cross the display in front of the wearer, before acceleration.
    private var degreesAcross: Double {
        let width = NSScreen.main?.frame.width ?? 1440
        return width / model.cursorSpeed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("a little room to move.").font(KinesisType.title).tracking(-1.2)
            OpenRow(title: "air cursor", detail: "experimental · move your forearm like a mouse.") {
                Toggle("Air cursor", isOn: Binding(get: { model.airCursorEnabled }, set: { model.setAirCursorEnabled($0) }))
                    .toggleStyle(KinesisToggleStyle())
                    .disabled(!model.airCursorEnabled && !model.canUseAirCursor)
            }
            Text(model.cursorRepositioning ? "pointer parked · release Option when your arm feels comfortable."
                 : model.airCursorEnabled ? "pinch your index to click, or hold the pinch and move to drag. middle pinch to right-click. Escape to stop."
                 : model.canUseAirCursor ? "turn it on, then move your forearm. slow for small moves, a quick flick to cross the screen. rest your elbow if you like."
                 : "connect your band and enable Mac controls to try it.")
                .font(KinesisType.body).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Lever(title: "speed", value: String(format: "%.0f° of turn crosses this screen", degreesAcross),
                  detail: "how far the pointer moves when you turn your arm.", slower: "slower", faster: "faster") {
                PillSlider(value: $model.cursorSpeed, range: PointerReach.speeds, step: 5, label: "Pointer speed")
            }
            Lever(title: "flick boost", value: String(format: "%.1f×", model.cursorFlickBoost),
                  detail: "how much quick moves speed up. less is easier to predict.", slower: "even", faster: "more boost") {
                PillSlider(value: $model.cursorFlickBoost, range: PointerAcceleration.flickBoosts, step: 0.1, label: "Flick boost")
            }
            HStack(alignment: .top, spacing: 22) {
                Lever(title: "steadiness", value: nil, detail: "how much small movement the pointer ignores.",
                      slower: "more responsive", faster: "more steady") {
                    PillSlider(value: $model.cursorSteadiness, range: 0...1, step: 0.1, label: "Cursor steadiness")
                }
                WobbleRing(wobble: model.cursorWobble, still: AirPointer.still(steadiness: model.cursorSteadiness),
                           live: model.live)
            }
            TryItRow(done: model.cursorSkills, active: model.airCursorEnabled)

            #if KINESIS_LAB
            OpenRow(title: "calibrate", detail: model.pointerCalibrated
                        ? String(format: "lab build · fitted to your arm: %.0f points a degree, up tilt %.2f.", model.cursorSpeed, model.pointerReach.upTilt)
                        : "lab build · aim at four dots to measure speed and slant for your arm.") {
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
            OpenRow(title: "lab", detail: "lab build · practice targets full screen. each run is saved for review.") {
                Button("open") { PracticeWindow.shared.open(model: model) }
                    .buttonStyle(KinesisButtonStyle())
            }
            #endif

            Text("hold Option to move your arm without moving the pointer. a click lands where the pointer is.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("thumb swipes keep your gesture shortcuts. cursor mode turns off when you pause or disconnect.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.setCursorPageVisible(true) }
        .onDisappear { model.setCursorPageVisible(false) }
    }
}

/// One setting: its name and value, one sentence on what it does, and its control.
private struct Lever<Control: View>: View {
    let title: String
    let value: String?
    let detail: String
    let slower: String
    let faster: String
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(KinesisType.body)
                Spacer()
                if let value { Text(value).font(KinesisType.label).monospacedDigit().foregroundStyle(KinesisStyle.secondary) }
            }
            Text(detail).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// The arm's live turn rate as a dot, and the stillness threshold as a ring. Inside
/// the ring, the pointer holds still. Moving the steadiness lever grows the ring.
private struct WobbleRing: View {
    let wobble: SIMD2<Double>
    let still: ClosedRange<Double>
    let live: Bool
    /// Degrees a second at the edge of the drawing.
    private let scale = 3.0

    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2 - 3
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                func circle(_ r: Double) -> Path {
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                }
                context.stroke(circle(radius), with: .color(KinesisStyle.line), lineWidth: 1)
                let inner = min(1, still.lowerBound / scale) * radius
                let outer = min(1, still.upperBound / scale) * radius
                context.fill(circle(inner), with: .color(KinesisStyle.accent.opacity(0.14)))
                context.stroke(circle(inner), with: .color(KinesisStyle.accent.opacity(0.7)), lineWidth: 1.5)
                context.stroke(circle(outer), with: .color(KinesisStyle.accent.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                guard live else { return }
                var offset = wobble / scale * radius
                let length = (offset.x * offset.x + offset.y * offset.y).squareRoot()
                if length > radius { offset *= radius / length }
                let moving = (wobble.x * wobble.x + wobble.y * wobble.y).squareRoot() > still.lowerBound
                let dot = CGPoint(x: center.x + offset.x, y: center.y - offset.y)
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)),
                             with: .color(moving ? KinesisStyle.ink : KinesisStyle.accent))
            }
            .frame(width: 96, height: 96)
            Text(live ? "your arm now. inside the ring the pointer holds still." : "connect your band to see your arm.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                .multilineTextAlignment(.center).frame(width: 130)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live arm movement against the steadiness threshold")
    }
}

/// The pointer's actions as words that light up once done with the air cursor.
private struct TryItRow: View {
    let done: Set<BandModel.CursorSkill>
    let active: Bool
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
            Text(active ? "each one lights up when you do it with the air cursor." : "turn on the air cursor, then try each one here.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
        }
    }
}
