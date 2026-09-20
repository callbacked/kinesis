import SwiftUI
import KinesisCore

/// One type scale for the whole app. Large and light for what matters, small
/// and grey for what supports it.
enum KinesisType {
    static let display = Font.system(size: 49, weight: .regular)
    static let title = Font.system(size: 32, weight: .regular)
    static let headline = Font.system(size: 21, weight: .regular)
    static let lead = Font.system(size: 15, weight: .regular)
    static let body = Font.system(size: 13, weight: .regular)
    static let label = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12, weight: .regular)
    static let micro = Font.system(size: 11, weight: .medium)
}

enum KinesisMotion {
    /// Selection capsules, tab indicators, and the switch knob share one spring.
    static let select = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let settle = Animation.easeOut(duration: 0.22)
}

/// One option in a tray, a menu, or the tabs.
struct Choice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// A row of choices in one tray. The selection slides between them.
struct PillTray<Value: Hashable>: View {
    let options: [Choice<Value>]
    let selection: Value
    let select: (Value) -> Void
    var label = ""
    @Namespace private var tray
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let chosen = option.value == selection
                Button {
                    guard !chosen else { return }
                    withAnimation(reduceMotion ? nil : KinesisMotion.select) { select(option.value) }
                } label: {
                    Text(option.title).font(KinesisType.label)
                        .foregroundStyle(chosen ? KinesisStyle.ink : KinesisStyle.secondary)
                        .padding(.horizontal, 15).padding(.vertical, 7)
                        .background {
                            if chosen {
                                Capsule().fill(KinesisStyle.chip)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "choice", in: tray)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(KinesisStyle.tray, in: Capsule())
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A menu that wears a pill: the current choice and a small chevron.
struct PillMenu<Value: Hashable>: View {
    let options: [Choice<Value>]
    let selection: Value
    let select: (Value) -> Void
    var label = ""
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    select(option.value)
                } label: {
                    if option.value == selection { Label(option.title, systemImage: "checkmark") }
                    else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.title ?? "")
                    .font(KinesisType.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(KinesisStyle.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(hovered ? KinesisStyle.trayHover : KinesisStyle.tray, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hovered = $0 }
        .animation(KinesisMotion.settle, value: hovered)
        .accessibilityLabel(label)
    }
}

/// A switch drawn in the app's language. It stays a toggle to assistive tools.
struct KinesisToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule().fill(configuration.isOn ? KinesisStyle.accent : KinesisStyle.trayStrong)
                .frame(width: 40, height: 23)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2.5)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                }
                .animation(reduceMotion ? nil : KinesisMotion.select, value: configuration.isOn)
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A stepped slider: one capsule track, a fill, and a knob.
struct PillSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var label = ""
    @State private var dragging = false
    @FocusState private var focused: Bool

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        GeometryReader { geometry in
            let knob = 20.0
            let travel = max(geometry.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(KinesisStyle.tray).frame(height: 8)
                Capsule().fill(KinesisStyle.accent).frame(width: knob / 2 + travel * fraction, height: 8)
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: dragging ? 5 : 2, y: 1)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: travel * fraction)
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                dragging = true
                set(range.lowerBound + (drag.location.x - knob / 2) / travel * (range.upperBound - range.lowerBound))
            }.onEnded { _ in dragging = false })
            .animation(KinesisMotion.settle, value: dragging)
        }
        .frame(height: 20)
        .focusable().focused($focused)
        .onMoveCommand { direction in
            if direction == .left || direction == .down { set(value - step) }
            if direction == .right || direction == .up { set(value + step) }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
        .accessibilityAdjustableAction { direction in
            set(value + (direction == .increment ? step : -step))
        }
    }

    private func set(_ raw: Double) {
        let stepped = (raw / step).rounded() * step
        let next = min(range.upperBound, max(range.lowerBound, stepped))
        if next != value { value = next }
    }
}

/// Text tabs with one indicator that slides under the live tab.
struct TextTabs<Value: Hashable>: View {
    let options: [Choice<Value>]
    @Binding var selection: Value
    @Namespace private var tabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 26) {
            ForEach(options) { option in
                let chosen = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : KinesisMotion.select) { selection = option.value }
                } label: {
                    Text(option.title).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(chosen ? KinesisStyle.ink : KinesisStyle.secondary)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            if chosen {
                                Capsule().fill(KinesisStyle.ink).frame(height: 2)
                                    .matchedGeometryEffect(id: "tab", in: tabs)
                            }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Pages")
    }
}

/// A value over its name, the way the band's column reports battery and gestures.
struct Readout: View {
    let symbol: String
    let value: String
    let label: String
    var alignment = HorizontalAlignment.leading
    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText())
            }.foregroundStyle(KinesisStyle.ink.opacity(0.92))
            Text(label).font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary.opacity(0.85))
        }.accessibilityElement(children: .combine)
    }
}

/// A label over its value on a page: what it is in ink, how it is in grey.
struct Pairing: View {
    let label: String
    let value: String
    var live = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            Text(value).font(KinesisType.headline).tracking(-0.4).monospacedDigit()
                .foregroundStyle(live ? KinesisStyle.accent : KinesisStyle.ink)
                .contentTransition(.numericText()).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}

/// Counts how often each gesture has fired. Rows watch their own count, so a
/// gesture never has to interrupt another row's animation.
struct GestureLight<Content: View>: View {
    @ObservedObject var model: BandModel
    @ViewBuilder var content: ([RecognizedGesture: Int]) -> Content
    @State private var fires: [RecognizedGesture: Int] = [:]

    var body: some View {
        content(fires)
            .onChange(of: model.gestureCount) { _, _ in
                guard model.live, let gesture = model.recognizedGesture else { return }
                fires[gesture, default: 0] += 1
            }
    }
}

/// Flash and decay. A trigger snaps the glow to full at once, then lets it fall
/// away smoothly. A new trigger just restarts the fall, so it stays smooth at any
/// speed, and fast gestures leave soft trails instead of fighting each other.
struct Flash<Content: View>: View {
    let trigger: Int
    var held = false
    @ViewBuilder var content: (Double) -> Content
    @State private var glow = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(held ? 1 : glow)
            .onChange(of: trigger) { _, _ in fire() }
            .onChange(of: held) { _, isHeld in if !isHeld { fire() } }
    }

    private func fire() {
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { glow = 1 }
        withAnimation(.easeOut(duration: reduceMotion ? 0.6 : 1.15)) { glow = 0 }
    }
}

/// A small grey word that names a group of rows, as "information" and "options" do.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One line on open ground: what it is, how it is, and its control at the right
/// edge. No box. The row under the pointer gets a soft band that bleeds past the
/// text, and a row can light in the accent while its gesture is being performed.
struct OpenRow<Control: View>: View {
    var symbol: String?
    let title: String
    var detail: String?
    /// 0 to 1. The row takes the accent by this much, as a gesture flashes and fades.
    var glow = 0.0
    @ViewBuilder var control: Control
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 22)
                    .foregroundStyle(KinesisStyle.secondary)
                    .overlay(Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(KinesisStyle.accent).opacity(glow))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15)).foregroundStyle(KinesisStyle.ink)
                    .overlay(alignment: .leading) { Text(title).font(.system(size: 15)).foregroundStyle(KinesisStyle.accent).opacity(glow) }
                if let detail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(KinesisStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, detail == nil ? 13 : 15).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 13).fill(hovered ? KinesisStyle.tray : .clear))
        .background(RoundedRectangle(cornerRadius: 13).fill(KinesisStyle.accent.opacity(0.13 * glow)))
        // The band bleeds past the text, so titles still line up with the page edge.
        .padding(.horizontal, -14)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
}

extension KinesisCore.TapGesture {
    /// One ring for a tap, two for a double tap, a filled one for a hold.
    var symbol: String {
        switch action {
        case "tap": "circle"
        case "doubletap": "circle.circle"
        default: "circle.inset.filled"
        }
    }
}
