import SwiftUI

struct CursorPage: View {
    @ObservedObject var model: BandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("a little room to move.").font(KinesisType.title).tracking(-1.2)
            OpenRow(title: "air cursor", detail: "experimental · move your forearm like a mouse.") {
                Toggle("Air cursor", isOn: Binding(get: { model.airCursorEnabled }, set: { model.setAirCursorEnabled($0) }))
                    .toggleStyle(KinesisToggleStyle())
                    .disabled(!model.airCursorEnabled && !model.canUseAirCursor)
            }
            OpenRow(title: "calibrate",
                    detail: model.pointerCalibrated
                        ? String(format: "fitted to your arm: %.0f° across, %.0f° up and down.", model.pointerReach.degreesAcrossWidth, model.pointerReach.degreesAcrossHeight)
                        : "aim at four dots so the pointer fits how far, and how slanted, your arm likes to move.") {
                HStack(spacing: 14) {
                    if model.pointerCalibrated {
                        Button("reset") { model.resetPointerReach() }.buttonStyle(.plain)
                            .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                    }
                    Button(model.pointerCalibrated ? "redo" : "start") { model.beginPointerCalibration() }
                        .buttonStyle(KinesisButtonStyle(prominent: !model.pointerCalibrated))
                        .disabled(!model.canUseAirCursor || model.pointerCalibration != nil)
                }
            }
            Text(model.cursorRepositioning ? "pointer parked · release Option when your arm feels comfortable."
                 : model.airCursorEnabled ? "pinch your index to click, or hold the pinch and move to drag. middle pinch to right-click. Escape to stop."
                 : model.canUseAirCursor ? "turn it on, then move your forearm. slow for small moves, a quick flick to cross the screen. rest your elbow if you like."
                 : "connect your band and enable Mac controls to try it.")
                .font(KinesisType.body).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("sensitivity").font(KinesisType.body)
                    Spacer()
                    Text(model.cursorSensitivity.formatted(.number.precision(.fractionLength(2))) + "×")
                        .font(KinesisType.label).monospacedDigit()
                }
                PillSlider(value: $model.cursorSensitivity, range: 0.25...4, step: 0.25, label: "Cursor sensitivity")
                HStack {
                    Text("bigger movements")
                    Spacer()
                    Text("smaller movements")
                }.font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("steadiness").font(KinesisType.body)
                PillSlider(value: $model.cursorSteadiness, range: 0...1, step: 0.1, label: "Cursor steadiness")
                HStack {
                    Text("more responsive")
                    Spacer()
                    Text("more steady")
                }.font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            }
            Text("a click lands where you aimed just before the pinch, so the pinch’s nudge doesn’t miss. hold Option to move your arm without moving the pointer.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("thumb swipes keep your gesture shortcuts. cursor mode turns off when you pause or disconnect.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
