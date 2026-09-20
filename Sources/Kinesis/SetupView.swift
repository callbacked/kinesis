import SwiftUI
import KinesisCore

/// First run, and "quick setup" after it. Each step puts one object center
/// stage with one line of instruction under it: the band, the hand, the dial,
/// then what you can do with them.
struct SetupView: View {
    @ObservedObject var model: BandModel
    @State private var step: Int
    @State private var swipes: Set<SwipeDirection> = []
    @State private var preview: SwipeDirection = .left
    @State private var handHighlight = HandHighlight.index
    @State private var revision = 0
    @State private var received = ""
    @State private var hasReceivedGesture = false
    @State private var feedbackVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var practiceValue = 50.0
    @State private var practiceRouter = DialRouter()
    @State private var hasTurned = false
    @State private var completedTurn = false
    private let names = ["pair", "swipe", "turn", "ready"]

    init(model: BandModel, step: Int = 0) {
        self.model = model
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 10)
            stage.frame(height: 292)
                .id(step).transition(.rise(moves: !reduceMotion))
            Group {
                if step == 0 && !model.live {
                    PairBandControl(model: model, layout: .centered, idleHeadline: "your mac. in good hands.")
                } else {
                    VStack(spacing: 12) {
                        Text(headline).font(.system(size: 36)).tracking(-1.4).multilineTextAlignment(.center)
                        Text(detail).font(.system(size: 14)).foregroundStyle(KinesisStyle.secondary)
                            .lineSpacing(5).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 470)
                        controls.padding(.top, 14)
                    }
                }
            }
            .padding(.top, 26)
            .id(step == 0 ? (model.live ? "connected" : "pairing") : "step-\(step)")
            .transition(.opacity)
            if let error = model.error { ErrorNote(text: error).padding(.top, 14) }
            Spacer(minLength: 10)
            footer
        }
        // A wide window must not pull the layout apart or inflate the stage.
        .frame(maxWidth: 1040).frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: step)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: model.live)
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

    // MARK: - frame

    private var header: some View {
        ZStack {
            HStack(spacing: 5) {
                ForEach(names.indices, id: \.self) { index in
                    Capsule().fill(index == step ? KinesisStyle.ink : index < step ? KinesisStyle.green : KinesisStyle.line)
                        .frame(width: index == step ? 22 : 6, height: 6)
                }
            }
            .animation(reduceMotion ? nil : KinesisMotion.select, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup step \(step + 1) of \(names.count): \(names[step])")
            HStack {
                HStack(spacing: 10) {
                    KinesisMark(size: CGSize(width: 30, height: 28))
                    Text("kinesis").font(.system(size: 19, weight: .medium, design: .rounded)).tracking(-0.6)
                }
                Spacer()
                AppearanceMenu(compact: true).foregroundStyle(KinesisStyle.secondary).padding(.trailing, 16)
                Button("set up later") { model.finishSetup() }
                    .font(KinesisType.caption).buttonStyle(.plain).foregroundStyle(KinesisStyle.secondary)
            }
        }.padding(.horizontal, 40).padding(.top, 34)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button { advance(to: step - 1) } label: {
                    Image(systemName: "arrow.left").frame(width: 14)
                }.buttonStyle(KinesisButtonStyle()).accessibilityLabel("Back")
            }
            Spacer()
            if let skip = skipTitle {
                Button(skip) { if step == 3 { model.finishSetup() } else { advance(to: step + 1) } }
                    .buttonStyle(.plain).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                    .padding(.trailing, 12)
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
        }.padding(.horizontal, 40).padding(.bottom, 30)
    }

    private var skipTitle: String? {
        switch step {
        case 0: model.live ? nil : "preview gestures"
        case 1: swipes.isEmpty ? "try it later" : nil
        case 2: completedTurn ? nil : "try it later"
        default: "finish with controls paused"
        }
    }

    // MARK: - words

    private var headline: String {
        switch step {
        case 0: "you’re connected."
        case 1: "small gesture. big move."
        case 2: "give it a little turn."
        default: "take it from here."
        }
    }

    private var detail: String {
        switch step {
        case 0: "which wrist is your band on?"
        case 1: "slide your thumb across your index finger. try a swipe in any direction."
        case 2: "pinch your thumb and index finger. turn your wrist, then release."
        default: "move between desktops, turn up your music, and keep your hands where they are."
        }
    }

    // MARK: - stage

    @ViewBuilder private var stage: some View {
        switch step {
        case 0:
            ZStack {
                Circle().fill(RadialGradient(colors: [KinesisStyle.accent.opacity(model.live ? 0.16 : 0.07), .clear],
                                             center: .center, startRadius: 10, endRadius: 210))
                    .frame(width: 420, height: 420)
                HoldArtwork(hint: model.pairing.holdHint).frame(width: 400, height: 262)
                    .saturation(model.live || model.pairInProgress ? 1 : 0.3)
                    .opacity(model.live || model.pairInProgress ? 1 : 0.75)
            }.animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: model.live || model.pairInProgress)
        case 1:
            ZStack(alignment: .bottom) {
                // The same stage as the overview: a pool of light, the hand, and the band's electrodes.
                Circle().fill(RadialGradient(colors: [KinesisStyle.pool, .clear], center: .center, startRadius: 24, endRadius: 160))
                    .opacity(scheme == .dark ? 1 : 0)
                Circle().fill(RadialGradient(colors: [KinesisStyle.accent.opacity(0.16), .clear], center: .center, startRadius: 10, endRadius: 150))
                    .opacity(feedbackVisible ? 1 : 0)
                // Until the band sends something, the hand acts out the swipe you picked.
                HandView(scene: HandSceneView(hand: model.bandHand, highlight: model.pinchedFinger.map { $0 == "middle" ? .middle : .index } ?? handHighlight,
                                              gesture: received.isEmpty ? .swipe(preview) : model.recognizedGesture,
                                              revision: revision, sustained: model.pinchedFinger != nil, viewpoint: .teaching, demonstrates: true))
                ElectrodeRing(angle: 0, engaged: 0).allowsHitTesting(false)
                HStack(spacing: 8) {
                    Image(systemName: received.isEmpty ? preview.symbol : "checkmark.circle.fill")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    Text(received.isEmpty ? "swipe \(preview.rawValue)" : received).contentTransition(.opacity)
                }.font(KinesisType.label)
                    .foregroundStyle(received.isEmpty ? KinesisStyle.secondary : KinesisStyle.accent)
                    .padding(.bottom, 34)
            }.frame(width: 292, height: 292)
        case 2:
            PracticeDial(value: practiceValue, engaged: model.dialEngaged && model.live)
        default:
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "your shortcuts").padding(.bottom, 8)
                readyRow("arrow.left.arrow.right", "swipe left or right", "switch desktops")
                readyRow("arrow.up", "swipe up", (model.mappings[.up] ?? .none).title.lowercased())
                readyRow("playpause", "index double tap", (model.tapMappings[.indexDoubleTap] ?? .none).title.lowercased())
                readyRow("dial.low", "pinch + turn", model.dialTarget.title.lowercased(), last: true)
                Text("change any of them later under gestures.")
                    .font(KinesisType.micro).foregroundStyle(KinesisStyle.secondary).padding(.top, 14)
            }.frame(width: 460)
        }
    }

    // MARK: - controls

    @ViewBuilder private var controls: some View {
        switch step {
        case 0:
            VStack(spacing: 12) {
                PillTray(options: BandHand.allCases.map { Choice($0, $0.rawValue) },
                         selection: model.pendingHand ?? model.bandHand,
                         select: { model.selectHand($0) }, label: "Band hand")
                    .disabled(!model.canChangeHand)
                Text(model.handSettingStatus).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                    .contentTransition(.opacity)
            }
        case 1:
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(SwipeDirection.allCases) { direction in
                        Button {
                            preview = direction
                            handHighlight = .index
                            revision += 1
                            received = ""
                            feedbackVisible = false
                        } label: {
                            Image(systemName: swipes.contains(direction) ? "checkmark" : direction.symbol)
                                .font(.system(size: 14, weight: .medium)).frame(width: 42, height: 42)
                                .foregroundStyle(swipes.contains(direction) ? KinesisStyle.paper : KinesisStyle.ink)
                                .background(swipes.contains(direction) ? KinesisStyle.green : KinesisStyle.tray, in: Circle())
                                .overlay(Circle().strokeBorder(preview == direction ? KinesisStyle.accent : .clear, lineWidth: 1.5).padding(-3))
                                .contentTransition(.symbolEffect(.replace))
                        }.buttonStyle(KinesisPressStyle())
                            .accessibilityLabel("Preview swipe \(direction.rawValue)\(swipes.contains(direction) ? ", received" : "")")
                    }
                }
                Text(!model.live ? "preview only. pair your band to try it live." : swipes.isEmpty ? (!hasReceivedGesture ? "controls are paused while you try this." : "taps are coming through too. try a thumb swipe next.") : "got it. that one came from your band.")
                    .font(KinesisType.caption).foregroundStyle(swipes.isEmpty ? KinesisStyle.secondary : KinesisStyle.green)
                    .contentTransition(.opacity)
            }
        case 2:
            Text(completedTurn ? "got it. you’re getting the hang of this." : !model.live ? "pair your band to try the dial." : model.dialEngaged ? "keep holding the pinch as you turn." : "controls are paused. try the practice dial.")
                .font(KinesisType.caption).foregroundStyle(completedTurn ? KinesisStyle.green : KinesisStyle.secondary)
                .contentTransition(.opacity)
        default:
            // One blocking item on this step, so it gets one line, not a second card.
            if model.accessibilityAllowed {
                Label("Mac controls are allowed", systemImage: "checkmark.circle.fill")
                    .font(KinesisType.label).foregroundStyle(KinesisStyle.green)
            } else {
                VStack(spacing: 12) {
                    Text("kinesis needs Accessibility access to send your shortcuts.")
                        .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                    HStack(spacing: 10) {
                        Button("allow access") { model.requestAccessibility() }.buttonStyle(KinesisButtonStyle(prominent: true))
                        Button("open settings") { MacShortcuts.openAccessSettings() }.buttonStyle(KinesisButtonStyle())
                    }
                }
            }
        }
    }

    private func readyRow(_ symbol: String, _ title: String, _ detail: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 22).foregroundStyle(KinesisStyle.secondary)
                Text(title).font(.system(size: 15))
                Spacer()
                Text(detail).font(KinesisType.body).foregroundStyle(KinesisStyle.secondary)
            }.padding(.vertical, 14)
            if !last { Rectangle().fill(KinesisStyle.line).frame(height: 1) }
        }
    }

    private func advance(to next: Int) {
        practiceRouter.reset()
        if next == 2 { hasTurned = false }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { step = next }
    }
}

private struct PracticeDial: View {
    let value: Double
    let engaged: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [KinesisStyle.accent.opacity(engaged ? 0.15 : 0), .clear],
                                         center: .center, startRadius: 10, endRadius: 140))
            // The overview's ring, used as a dial: it fills from the lower left as you turn.
            ElectrodeRing(angle: -135 + value * 2.7, engaged: 1, sweep: 135)
            Text(value.formatted(.number.precision(.fractionLength(0))))
                .font(.system(size: 54, weight: .light)).monospacedDigit()
        }.frame(width: 270, height: 270)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: engaged)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Practice dial")
            .accessibilityValue("\(Int(value)) percent")
    }
}
