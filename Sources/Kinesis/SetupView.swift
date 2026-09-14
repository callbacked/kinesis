import SwiftUI
import KinesisCore

struct SetupView: View {
    @ObservedObject var model: BandModel
    @State private var step = 0
    @State private var swipes: Set<SwipeDirection> = []
    @State private var preview: SwipeDirection = .left
    @State private var handHighlight = HandHighlight.index
    @State private var revision = 0
    @State private var received = ""
    @State private var hasReceivedGesture = false
    @State private var feedbackVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var practiceValue = 50.0
    @State private var practiceRouter = DialRouter()
    @State private var hasTurned = false
    @State private var completedTurn = false
    private let names = ["connect", "swipe", "turn", "ready"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) {
                    KinesisMark()
                    Text("kinesis").font(.system(size: 21, weight: .medium, design: .rounded)).tracking(-0.7)
                }
                Spacer()
                AppearanceMenu(compact: true).padding(.trailing, 18)
                Button("set up later") { model.finishSetup() }
                    .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(KinesisStyle.secondary)
            }.padding(.horizontal, 38).padding(.top, 33)
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 23) {
                    HStack(spacing: 12) {
                        ZStack(alignment: .leading) {
                            ForEach(names.indices, id: \.self) { index in
                                Eyebrow(text: "0\(index + 1) / \(names[index])")
                                    .opacity(index == step ? 1 : 0)
                            }
                        }
                        HStack(spacing: 4) {
                            ForEach(names.indices, id: \.self) { index in
                                Capsule().fill(index == step ? KinesisStyle.ink : KinesisStyle.line)
                                    .frame(width: index == step ? 20 : 5, height: 5)
                                    .frame(width: 20)
                            }
                        }
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel("Setup step \(step + 1) of \(names.count): \(names[step])")
                    Text(step == 0 ? "your mac.\nin good hands." : step == 1 ? "small gesture.\nbig move." : step == 2 ? "give it\na little turn." : "take it\nfrom here.")
                        .font(.system(size: 49, weight: .regular)).tracking(-2.2).lineSpacing(-1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(step == 0 ? "your band brings a few new shortcuts.\nlet’s get you connected." : step == 1 ? "slide your thumb across your index finger.\ntry a swipe in any direction." : step == 2 ? "pinch your thumb and index finger.\nturn your wrist, then release." : "move between desktops, turn up your music,\nand keep your hands where they are.")
                        .font(.system(size: 14)).foregroundStyle(KinesisStyle.secondary).lineSpacing(5)
                    Group {
                        if step == 0 {
                            ConnectionControls(model: model)
                            ConnectionBadge(live: model.live, text: model.phase)
                        } else if step == 1 {
                            HStack(spacing: 10) {
                                ForEach(SwipeDirection.allCases) { direction in
                                    Button {
                                        preview = direction
                                        handHighlight = .index
                                        revision += 1
                                        received = ""
                                        feedbackVisible = false
                                    } label: {
                                        Image(systemName: direction.symbol)
                                            .font(.system(size: 15, weight: .medium)).frame(width: 43, height: 43)
                                            .foregroundStyle(swipes.contains(direction) ? KinesisStyle.paper : KinesisStyle.ink)
                                            .background(swipes.contains(direction) ? KinesisStyle.green : KinesisStyle.surface, in: Circle())
                                            .overlay(Circle().strokeBorder(preview == direction ? KinesisStyle.blue : .clear, lineWidth: 1.5).padding(-3))
                                    }.buttonStyle(KinesisPressStyle()).accessibilityLabel("Preview swipe \(direction.rawValue)\(swipes.contains(direction) ? ", received" : "")")
                                }
                            }
                            Text(!model.live ? "preview only. connect your band to try it live." : swipes.isEmpty ? (!hasReceivedGesture ? "controls are paused while you try this." : "taps are coming through too. try a thumb swipe next.") : "got it. that one came from your band.")
                                .font(.system(size: 12)).foregroundStyle(swipes.isEmpty ? KinesisStyle.secondary : KinesisStyle.green)
                        } else if step == 2 {
                            Text(completedTurn ? "got it. you’re getting the hang of this." : !model.live ? "connect your band to try the dial." : model.dialEngaged ? "keep holding the pinch as you turn." : "controls are paused. try the practice dial.")
                                .font(.system(size: 12))
                                .foregroundStyle(completedTurn ? KinesisStyle.green : KinesisStyle.secondary)
                            Text("release and pinch again whenever you need a fresh turn.")
                                .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary).lineSpacing(3)
                        } else {
                            PermissionCard(model: model)
                            Text("you can change every assignment later.")
                                .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                        }
                    }
                    if let error = model.error { ErrorNote(text: error) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                artwork.frame(maxWidth: .infinity).frame(height: 395)
            }.padding(.horizontal, 48).padding(.top, 58)
                .frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 12) {
                if step > 0 {
                    Button { advance(to: step - 1) } label: {
                        Image(systemName: "arrow.left").frame(width: 14)
                    }.buttonStyle(KinesisButtonStyle()).accessibilityLabel("Back")
                }
                Spacer()
                if step == 0 && !model.live {
                    Button("preview gestures") { advance(to: 1) }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary).padding(.trailing, 12)
                }
                if (step == 1 && swipes.isEmpty) || (step == 2 && !completedTurn) {
                    Button("try it later") { advance(to: step + 1) }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary).padding(.trailing, 12)
                }
                if step == 3 {
                    Button("finish with controls paused") { model.finishSetup() }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary).padding(.trailing, 12)
                }
                Button {
                    if step == 3 { model.finishSetup(enableControls: true) } else { advance(to: step + 1) }
                } label: {
                    HStack(spacing: 22) {
                        Text(step == 3 ? "let’s go" : "continue")
                        Image(systemName: "arrow.right")
                    }
                }.buttonStyle(KinesisButtonStyle(prominent: true))
                    .disabled(step == 0 ? !model.live : step == 1 ? swipes.isEmpty : step == 2 ? !completedTurn : !model.live || !model.accessibilityAllowed)
            }.padding(.horizontal, 48).padding(.bottom, 32)
        }
        .onReceive(model.dialTurns) { delta in
            guard step == 2 else { return }
            let ticks = practiceRouter.turn(delta: delta, sensitivity: model.dialSensitivity,
                                            now: ProcessInfo.processInfo.systemUptime)
            guard ticks != 0 else { return }
            hasTurned = true
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.08)) {
                practiceValue = min(100, max(0, practiceValue + Double(ticks) * 6.25))
            }
        }
        .onChange(of: model.dialEngaged) { _, engaged in
            practiceRouter.reset()
            if step == 2 && !engaged && hasTurned && model.live { completedTurn = true }
        }
        .onChange(of: model.gestureCount) { _, _ in
            guard step == 1, let gesture = model.recognizedGesture else { return }
            switch gesture {
            case .swipe(let direction):
                swipes.insert(direction)
                preview = direction
                handHighlight = .index
            case .tap(let tap): handHighlight = tap.finger == "middle" ? .middle : .index
            }
            received = gesture.label.lowercased()
            hasReceivedGesture = true
            revision += 1
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { feedbackVisible = true }
        }
        .task(id: revision) {
            guard feedbackVisible else { return }
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.65)) { feedbackVisible = false }
        }
        .task(id: step) {
            guard step == 1, !reduceMotion else { return }
            while !Task.isCancelled && !hasReceivedGesture {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, !hasReceivedGesture else { return }
                revision += 1
            }
        }
    }

    @ViewBuilder private var artwork: some View {
        if step == 0 {
            VStack(spacing: 20) {
                BandArtwork().frame(height: 275)
                VStack(spacing: 10) {
                    Text("which hand is your band on?").font(.system(size: 13, weight: .medium))
                    Picker("Band hand", selection: Binding(get: { model.pendingHand ?? model.bandHand }, set: { model.selectHand($0) })) {
                        ForEach(BandHand.allCases) { hand in Text(hand.rawValue).tag(hand) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    .disabled(!model.canChangeHand)
                    Text(model.handSettingStatus)
                        .font(.system(size: 11)).foregroundStyle(KinesisStyle.secondary)
                }
            }
        } else if step == 1 {
            ZStack(alignment: .bottom) {
                HandSceneView(hand: model.bandHand, highlight: model.pinchedFinger.map { $0 == "middle" ? .middle : .index } ?? handHighlight,
                              revision: revision, sustained: model.pinchedFinger != nil, viewpoint: .teaching)
                RoundedRectangle(cornerRadius: 20)
                    .stroke(KinesisStyle.blue.opacity(feedbackVisible ? 0.3 : 0), lineWidth: 16)
                    .blur(radius: 18).allowsHitTesting(false)
                HStack(spacing: 8) {
                    Image(systemName: received.isEmpty ? preview.symbol : "checkmark.circle.fill")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    Text(received.isEmpty ? "swipe \(preview.rawValue)" : received)
                        .contentTransition(.opacity)
                }.font(.system(size: 13, weight: .medium))
                    .foregroundStyle(received.isEmpty ? KinesisStyle.secondary : KinesisStyle.blue)
                    .padding(.bottom, 26)
            }.frame(height: 310).clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: KinesisStyle.blue.opacity(feedbackVisible ? 0.24 : 0), radius: 24)
        } else if step == 2 {
            VStack(spacing: 25) {
                PracticeDial(value: practiceValue, engaged: model.dialEngaged && model.live)
                Text(completedTurn ? "pinch. turn. release." : "practice dial")
                    .font(.system(size: 12)).foregroundStyle(completedTurn ? KinesisStyle.green : KinesisStyle.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 28) {
                Text("your shortcuts").font(.system(size: 20)).tracking(-0.4)
                VStack(alignment: .leading, spacing: 25) {
                    readyRow("arrow.up", "swipe up", (model.mappings[.up] ?? .none).title.lowercased())
                    readyRow("playpause", "index double tap", (model.tapMappings[.indexDoubleTap] ?? .none).title.lowercased())
                    readyRow("dial.low", "pinch + turn", model.dialTarget.title.lowercased())
                }
                Text("kinesis lives quietly in your menu bar.")
                    .font(.system(size: 11)).foregroundStyle(KinesisStyle.secondary)
            }.padding(26).background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func readyRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 23).foregroundStyle(KinesisStyle.secondary)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(detail).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
        }.frame(maxWidth: 300)
    }

    private func advance(to next: Int) {
        practiceRouter.reset()
        if next == 2 { hasTurned = false }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { step = next }
    }
}

private struct PracticeDial: View {
    let value: Double
    let engaged: Bool

    var body: some View {
        ZStack {
            Circle().fill(KinesisStyle.surface)
                .shadow(color: KinesisStyle.blue.opacity(engaged ? 0.18 : 0), radius: 28)
            ForEach(0..<41) { tick in
                Capsule().fill(Double(tick) <= value / 2.5 ? KinesisStyle.blue : KinesisStyle.line)
                    .frame(width: 2, height: tick.isMultiple(of: 5) ? 12 : 7)
                    .offset(y: -105)
                    .rotationEffect(.degrees(-135 + Double(tick) * 6.75))
            }
            Circle().fill(KinesisStyle.blue).frame(width: 7, height: 7)
                .offset(y: -82).rotationEffect(.degrees(-135 + value * 2.7))
            Text(value.formatted(.number.precision(.fractionLength(0))))
                .font(.system(size: 54, weight: .light)).monospacedDigit()
        }.frame(width: 250, height: 250)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Practice dial")
            .accessibilityValue("\(Int(value)) percent")
    }
}
