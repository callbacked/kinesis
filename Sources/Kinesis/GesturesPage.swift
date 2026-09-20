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
                Text(family == "swipe" ? "a shortcut at your fingertips." : family == "tap" ? "one finger. two taps." : "turn it just a little.")
                    .font(KinesisType.headline).tracking(-0.4)
                Text(family == "swipe" ? "slide your thumb across your index finger in any direction." : family == "tap" ? "touch your thumb to your index or middle finger." : "pinch thumb and index, then turn your wrist. release to reset.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
            }
            GestureLight(model: model) { lit in
            VStack(spacing: 0) {
                if family == "swipe" {
                    ForEach(SwipeDirection.allCases) { direction in
                        assignment(direction.label, symbol: direction.symbol, last: direction == SwipeDirection.allCases.last,
                                   lit: lit == .swipe(direction),
                                   selection: model.mappings[direction] ?? .none) { model.mappings[direction] = $0 }
                    }
                } else if family == "tap" {
                    ForEach(TapGesture.allCases) { tap in
                        assignment(tap.label, symbol: tap.action == "tap" ? "circle" : "circle.circle", last: tap == TapGesture.allCases.last,
                                   lit: lit == .tap(tap),
                                   selection: model.tapMappings[tap] ?? .none) { model.tapMappings[tap] = $0 }
                    }
                } else {
                    row(symbol: "dial.low", title: "pinch + turn", lit: model.dialEngaged && model.live) {
                        PillMenu(options: DialTarget.allCases.map { Choice($0, $0.title.lowercased()) },
                                 selection: model.dialTarget, select: { model.dialTarget = $0 }, label: "Dial controls")
                    }
                    Rectangle().fill(KinesisStyle.line).frame(height: 1).padding(.horizontal, 20)
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
                    }.padding(20)
                }
            }
            .background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .id(family).transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            Text(model.live ? "perform a gesture and its row lights up." : "connect your band to try them as you edit.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary).padding(.top, -10)
            Text(family == "swipe" ? "desktop actions use the Mac’s Control + arrow shortcuts. window and tab actions stay in the current app." : family == "tap" ? "single taps start unassigned, leaving room for double taps and the dial." : "volume follows your audio output, including AirPods. brightness controls your Mac’s display; external displays may not respond. pinch again after changing settings.")
                .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary).lineSpacing(4)
        }
        .animation(reduceMotion ? nil : KinesisMotion.settle, value: family)
    }

    private func assignment(_ label: String, symbol: String, last: Bool, lit: Bool, selection: MacAction,
                            select: @escaping (MacAction) -> Void) -> some View {
        VStack(spacing: 0) {
            row(symbol: symbol, title: label.lowercased(), lit: lit) {
                PillMenu(options: actions, selection: selection, select: select, label: label)
            }
            if !last { Rectangle().fill(KinesisStyle.line).frame(height: 1).padding(.horizontal, 20) }
        }
    }

    private func row<Control: View>(symbol: String, title: String, lit: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 21).foregroundStyle(lit ? KinesisStyle.blue : KinesisStyle.secondary)
            Text(title).font(KinesisType.body).foregroundStyle(lit ? KinesisStyle.blue : KinesisStyle.ink)
            Spacer()
            control()
        }.padding(.horizontal, 20).padding(.vertical, 14)
            .background(KinesisStyle.blue.opacity(lit ? 0.1 : 0))
    }
}
