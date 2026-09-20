import SwiftUI
import KinesisCore

struct OverviewPage: View {
    @ObservedObject var model: BandModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text(model.controlsEnabled ? "go about your day." : "ready when you are.")
                    .font(KinesisType.title).tracking(-1.2).contentTransition(.opacity)
                Text(model.controlsEnabled ? "a small gesture. your Mac follows." : "your usual Mac, with a little less reaching.")
                    .font(KinesisType.body).foregroundStyle(KinesisStyle.secondary).contentTransition(.opacity)
            }.animation(KinesisMotion.settle, value: model.controlsEnabled)
            ZStack(alignment: .bottomLeading) {
                HandSceneView(hand: model.bandHand, highlight: handHighlight, revision: model.gestureCount,
                              sustained: model.pinchedFinger != nil || model.dialEngaged)
                    .frame(height: 226)
                HStack(alignment: .bottom) {
                    Pairing(label: model.live ? "last gesture" : "neural band",
                            value: model.live ? model.lastGesture.lowercased() : "waiting for your band")
                    Spacer()
                    Image(systemName: model.lastDirection?.symbol ?? (model.dialEngaged ? "arrow.trianglehead.2.clockwise.rotate.90" : "waveform"))
                        .font(.system(size: 20, weight: .light)).foregroundStyle(KinesisStyle.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }.padding(24)
            }
            .background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(alignment: .topLeading) {
                ConnectionBadge(live: model.controlsEnabled && model.live,
                                text: model.controlsEnabled ? "controls live" : "controls paused").padding(24)
            }
            GestureMap(model: model)
            if model.live && !model.accessibilityAllowed {
                PermissionCard(model: model)
            } else {
                Text(model.lastAction.lowercased()).font(KinesisType.caption)
                    .foregroundStyle(KinesisStyle.secondary).lineLimit(2).contentTransition(.opacity)
                    .animation(KinesisMotion.settle, value: model.lastAction)
            }
            Text("close this window. kinesis stays in your menu bar.")
                .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary.opacity(0.8))
        }
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

/// Your mappings at a glance. A row lights up the moment you perform its gesture,
/// so the page answers "did the Mac get that?" without a word.
private struct GestureMap: View {
    @ObservedObject var model: BandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Entry: Identifiable {
        let id: String
        let symbol: String
        let gesture: String
        let action: String
        let active: Bool
    }

    private func entries(lit: RecognizedGesture?) -> [Entry] {
        var rows: [Entry] = []
        for direction in SwipeDirection.allCases {
            let action = model.mappings[direction] ?? .none
            guard action != .none else { continue }
            rows.append(Entry(id: direction.rawValue, symbol: direction.symbol, gesture: direction.label.lowercased(),
                              action: action.title.lowercased(), active: lit == .swipe(direction)))
        }
        for tap in TapGesture.allCases {
            let action = model.tapMappings[tap] ?? .none
            guard action != .none else { continue }
            rows.append(Entry(id: tap.rawValue, symbol: tap.action == "tap" ? "circle" : "circle.circle",
                              gesture: tap.label.lowercased(), action: action.title.lowercased(), active: lit == .tap(tap)))
        }
        if model.dialTarget != .none {
            rows.append(Entry(id: "dial", symbol: "dial.low", gesture: "pinch + turn",
                              action: model.dialTarget.title.lowercased(), active: model.dialEngaged && model.live))
        }
        return rows
    }

    var body: some View {
        GestureLight(model: model) { lit in map(entries(lit: lit)) }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.dialEngaged)
    }

    private func map(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("your gestures").font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary).padding(.leading, 12)
            if entries.isEmpty {
                Text("nothing assigned yet. pick actions under gestures.")
                    .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary).padding(.leading, 12)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 4) {
                ForEach(entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.symbol).font(.system(size: 12)).frame(width: 18)
                            .foregroundStyle(entry.active ? KinesisStyle.blue : KinesisStyle.secondary)
                        Text(entry.gesture).font(KinesisType.body)
                        Spacer(minLength: 8)
                        Text(entry.action).font(KinesisType.caption).lineLimit(1)
                            .foregroundStyle(entry.active ? KinesisStyle.blue : KinesisStyle.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(KinesisStyle.blue.opacity(entry.active ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
