import SwiftUI
import KinesisCore

struct GesturesPage: View {
    @ObservedObject var model: BandModel
    @State private var family = "swipe"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let actions = MacAction.allCases.map { Choice($0, $0.title.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("little moves. your rules.").font(KinesisType.title).tracking(-1.2)
            PillTray(options: ["swipe", "tap", "turn"].map { Choice($0, $0) }, selection: family,
                     select: { family = $0 }, label: "Gesture family")
            VStack(alignment: .leading, spacing: 7) {
                Text(family == "swipe" ? "a shortcut at your fingertips." : family == "tap" ? "taps, and one hold." : "turn it just a little.")
                    .font(KinesisType.headline).tracking(-0.4)
                Text(family == "swipe" ? "slide your thumb across your index finger in any direction." : family == "tap" ? "tap your thumb to your index or middle finger, or hold it on the middle one." : "pinch thumb and index, then turn your wrist. release to reset.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            }
            GestureLight(model: model) { fires in
            VStack(spacing: 2) {
                if family == "swipe" {
                    ForEach(SwipeDirection.allCases) { direction in
                        assignment(direction.label, symbol: direction.symbol, last: direction == SwipeDirection.allCases.last,
                                   trigger: fires[.swipe(direction)] ?? 0,
                                   selection: model.mappings[direction] ?? .none) { model.mappings[direction] = $0 }
                    }
                } else if family == "tap" {
                    ForEach(TapGesture.allCases) { tap in
                        assignment(tap.label, symbol: tap.symbol, last: tap == TapGesture.allCases.last,
                                   trigger: fires[.tap(tap)] ?? 0,
                                   selection: model.tapMappings[tap] ?? .none) { model.tapMappings[tap] = $0 }
                    }
                } else {
                    row(symbol: "dial.low", title: "pinch + turn", held: model.dialEngaged && model.live) {
                        PillMenu(options: DialTarget.allCases.map { Choice($0, $0.title.lowercased()) },
                                 selection: model.dialTarget, select: { model.dialTarget = $0 }, label: "Dial controls")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("sensitivity").font(KinesisType.body)
                            Spacer()
                            Text(model.dialSensitivity.formatted(.number.precision(.fractionLength(2))) + "×")
                                .font(KinesisType.label).monospacedDigit().contentTransition(.numericText())
                                .animation(KinesisMotion.settle, value: model.dialSensitivity)
                        }
                        PillSlider(value: $model.dialSensitivity, range: 0.5...4, step: 0.25, label: "Dial sensitivity")
                        HStack {
                            Text("more precise")
                            Spacer()
                            Text("less movement")
                        }.font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
                    }.padding(.top, 18)
                }
            }
            }
            .id(family).transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            Text(model.live ? "perform a gesture and its row lights up." : "connect your band to try them as you edit.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary).padding(.top, -10)
            Text(family == "swipe" ? "desktop actions use the Mac’s Control + arrow shortcuts. window and tab actions stay in the current app." : family == "tap" ? "single taps and the hold start unassigned. holding the index finger is the dial, so only the middle finger has a hold." : "volume follows your audio output, including AirPods. brightness controls your Mac’s display; external displays may not respond. pinch again after changing settings.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary).lineSpacing(4)
        }
        .animation(reduceMotion ? nil : KinesisMotion.settle, value: family)
    }

    private func assignment(_ label: String, symbol: String, last: Bool, trigger: Int, selection: MacAction,
                            select: @escaping (MacAction) -> Void) -> some View {
        row(symbol: symbol, title: label.lowercased(), trigger: trigger) {
            PillMenu(options: actions, selection: selection, select: select, label: label)
        }
    }

    private func row<Control: View>(symbol: String, title: String, trigger: Int = 0, held: Bool = false,
                                    @ViewBuilder control: @escaping () -> Control) -> some View {
        Flash(trigger: trigger, held: held) { glow in
            OpenRow(symbol: symbol, title: title, glow: glow) { control() }
        }
    }
}
