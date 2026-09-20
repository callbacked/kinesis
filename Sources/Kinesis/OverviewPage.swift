import SwiftUI
import KinesisCore

/// The overview is a mirror. The hand shows what the band just felt, the words
/// beside it say what that was and what it did, and the map underneath shows
/// what every gesture will do.
struct OverviewPage: View {
    @ObservedObject var model: BandModel
    @State private var dialRouter = DialRouter()
    @State private var dialAngle = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stage
            GestureMap(model: model)
            if model.live && !model.accessibilityAllowed { PermissionRow(model: model) }
            Text("close this window. kinesis stays in your menu bar.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary.opacity(0.8))
        }
        .onReceive(model.dialTurns) { delta in
            let ticks = dialRouter.turn(delta: delta, sensitivity: model.dialSensitivity,
                                        now: ProcessInfo.processInfo.systemUptime)
            guard ticks != 0 else { return }
            withAnimation(.easeOut(duration: 0.1)) { dialAngle = max(-150, min(150, dialAngle + Double(ticks) * 7.5)) }
        }
        .onChange(of: model.dialEngaged) { _, engaged in
            dialRouter.reset()
            if engaged { dialAngle = 0 }
        }
    }

    /// The hand floats on the page, with no box: its ring and its caption sit around it.
    private var stage: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    DialRing(angle: dialAngle, engaged: model.dialEngaged && model.live)
                    HandSceneView(hand: model.bandHand, highlight: handHighlight, revision: model.gestureCount,
                                  sustained: model.pinchedFinger != nil || model.dialEngaged)
                        .frame(width: 330, height: 330)
                }.frame(width: 350, height: 350)
            }
            VStack(alignment: .leading, spacing: 0) {
                ConnectionBadge(live: model.controlsEnabled && model.live,
                                text: model.controlsEnabled ? "controls live" : "controls paused")
                Spacer()
                GestureCaption(model: model)
                Spacer()
                Spacer().frame(height: 16)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 350)
    }

    private var handHighlight: HandHighlight {
        guard model.live else { return .none }
        if let finger = model.pinchedFinger { return finger == "middle" ? .middle : .index }
        if model.dialEngaged { return .index }
        switch model.recognizedGesture {
        case .swipe: return .index
        case .tap(let tap): return tap.finger == "middle" ? .middle : .index
        case nil: return .none
        }
    }
}

/// What the band just felt, in three words, and what that did. Most of it is
/// quiet; the one word that names the motion carries the weight.
private struct GestureCaption: View {
    @ObservedObject var model: BandModel

    private var words: (before: String, strong: String, after: String) {
        guard model.live else { return ("waiting for your ", "band", "") }
        if model.dialEngaged { return ("index pinch + ", "turn", "") }
        switch model.recognizedGesture {
        case .swipe(let direction): return ("thumb ", "swipe", " " + direction.rawValue)
        case .tap(let tap): return (tap.finger + " ", tap.action == "tap" ? "tap" : "double tap", "")
        case nil: return ("waiting for a ", "gesture", "")
        }
    }

    private var action: String? {
        guard model.live else { return nil }
        let mapped: MacAction?
        if model.dialEngaged {
            return model.dialTarget == .none ? "unassigned" : model.dialTarget.title.lowercased()
        }
        switch model.recognizedGesture {
        case .swipe(let direction): mapped = model.mappings[direction]
        case .tap(let tap): mapped = model.tapMappings[tap]
        case nil: return nil
        }
        return (mapped ?? MacAction.none) == .none ? "unassigned" : mapped?.title.lowercased()
    }

    var body: some View {
        Flash(trigger: model.gestureCount, held: model.dialEngaged && model.live) { glow in
            VStack(alignment: .leading, spacing: 9) {
                // The words swap at once. The glow carries the feedback, so a fast
                // second gesture never has a half-finished transition to interrupt.
                (Text(words.before).foregroundStyle(KinesisStyle.secondary)
                    + Text(words.strong).foregroundStyle(KinesisStyle.ink).fontWeight(.medium)
                    + Text(words.after).foregroundStyle(KinesisStyle.secondary))
                    .font(.system(size: 25)).tracking(-0.6)
                if let action {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .semibold))
                        Text(model.controlsEnabled ? action : "paused · " + action)
                    }
                    .font(KinesisType.label)
                    .foregroundStyle(model.controlsEnabled && action != "unassigned" ? KinesisStyle.blue : KinesisStyle.secondary)
                    .opacity(0.5 + 0.5 * glow)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thin ring around the hand. While you hold a pinch and turn, a short arc
/// rides it to show how far you have turned.
private struct DialRing: View {
    let angle: Double
    let engaged: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(KinesisStyle.line, lineWidth: 1)
            Circle().trim(from: 0, to: 0.07)
                .stroke(KinesisStyle.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90 - 12.6 + angle))
                .opacity(engaged ? 1 : 0)
        }
        .padding(8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: engaged)
        .accessibilityHidden(true)
    }
}

/// Your mappings at a glance. A row flashes the moment you perform its gesture,
/// so the page answers "did the Mac get that?" without a word.
private struct GestureMap: View {
    @ObservedObject var model: BandModel

    private struct Entry: Identifiable {
        let id: String
        let symbol: String
        let gesture: String
        let action: String
        var fired: RecognizedGesture?
        var held = false
    }

    private var entries: [Entry] {
        var rows: [Entry] = []
        for direction in SwipeDirection.allCases {
            let action = model.mappings[direction] ?? .none
            guard action != .none else { continue }
            rows.append(Entry(id: direction.rawValue, symbol: direction.symbol, gesture: direction.label.lowercased(),
                              action: action.title.lowercased(), fired: .swipe(direction)))
        }
        for tap in TapGesture.allCases {
            let action = model.tapMappings[tap] ?? .none
            guard action != .none else { continue }
            rows.append(Entry(id: tap.rawValue, symbol: tap.action == "tap" ? "circle" : "circle.circle",
                              gesture: tap.label.lowercased(), action: action.title.lowercased(), fired: .tap(tap)))
        }
        if model.dialTarget != .none {
            rows.append(Entry(id: "dial", symbol: "dial.low", gesture: "pinch + turn",
                              action: model.dialTarget.title.lowercased(), held: model.dialEngaged && model.live))
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "your gestures").padding(.leading, 12)
            if entries.isEmpty {
                Text("nothing assigned yet. pick actions under gestures.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary).padding(.leading, 12)
            }
            GestureLight(model: model) { fires in
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 4) {
                    ForEach(entries) { entry in
                        Flash(trigger: entry.fired.map { fires[$0] ?? 0 } ?? 0, held: entry.held) { glow in
                            HStack(spacing: 10) {
                                Image(systemName: entry.symbol).font(.system(size: 12)).frame(width: 18)
                                    .foregroundStyle(KinesisStyle.secondary)
                                    .overlay(Image(systemName: entry.symbol).font(.system(size: 12))
                                        .foregroundStyle(KinesisStyle.blue).opacity(glow))
                                Text(entry.gesture).font(KinesisType.body)
                                Spacer(minLength: 8)
                                Text(entry.action).font(KinesisType.caption).lineLimit(1)
                                    .foregroundStyle(KinesisStyle.secondary)
                                    .overlay(alignment: .trailing) {
                                        Text(entry.action).font(KinesisType.caption).lineLimit(1)
                                            .foregroundStyle(KinesisStyle.blue).opacity(glow)
                                    }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(KinesisStyle.blue.opacity(0.13 * glow), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}
