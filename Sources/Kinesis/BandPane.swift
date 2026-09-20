import SwiftUI

/// What the band pane's one button does next. It always offers the step that
/// moves the band toward useful: pair it, connect it, then hand it the Mac.
enum BandAction: Equatable {
    case pair, pairing, connect, connecting, enableControls, pauseControls

    var title: String {
        switch self {
        case .pair: "pair band"
        case .pairing: "pairing…"
        case .connect: "connect"
        case .connecting: "connecting…"
        case .enableControls: "enable controls"
        case .pauseControls: "pause controls"
        }
    }

    var symbol: String? {
        switch self {
        case .pair: "dot.radiowaves.left.and.right"
        case .connect: "arrow.right"
        case .enableControls: "play.fill"
        case .pauseControls: "pause.fill"
        case .pairing, .connecting: nil
        }
    }

    var waits: Bool { self == .pairing || self == .connecting }
}

extension BandModel {
    var nextAction: BandAction {
        if pairInProgress || enrollmentStage != .idle { return .pairing }
        if showsPairAction { return .pair }
        if live { return controlsEnabled ? .pauseControls : .enableControls }
        if wantsConnection || busy { return .connecting }
        return .connect
    }

    /// True while the band is on its way somewhere: finding, connecting, claiming.
    var inTransit: Bool { !live && (busy || wantsConnection || pairInProgress) }
}

/// The dark pane is the band: what it is, how it is, and the next thing to do with it.
struct BandPane: View {
    @ObservedObject var model: BandModel
    var openBandPage: () -> Void
    @State private var bloom = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var unpaired: Bool { model.showsPairAction && !model.pairInProgress }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                KinesisMark(size: CGSize(width: 25, height: 23))
                Text("kinesis").font(.system(size: 16, weight: .medium, design: .rounded)).tracking(-0.5)
                Spacer()
            }.foregroundStyle(.white.opacity(0.92)).padding(.top, 46)

            Spacer(minLength: 18)
            band
            VStack(spacing: 9) {
                Text(model.bandName.lowercased()).font(.system(size: 19)).tracking(-0.4)
                    .foregroundStyle(.white.opacity(0.95)).lineLimit(1).truncationMode(.middle)
                state
            }.padding(.top, 18)
            notice.padding(.top, 16)
            Spacer(minLength: 18)

            actions
            Rectangle().fill(.white.opacity(0.09)).frame(height: 1).padding(.top, 24)
            HStack(alignment: .top) {
                Readout(symbol: batterySymbol, value: model.battery.map { "\($0) %" } ?? "–", label: "battery")
                Spacer()
                Readout(symbol: "hand.draw", value: model.totalGestureCount.formatted(), label: "gestures",
                        alignment: .trailing)
            }.padding(.top, 20).padding(.bottom, 26)
        }
        .padding(.horizontal, 24)
        .frame(width: 264)
        .background {
            LinearGradient(colors: [KinesisStyle.paneTop, KinesisStyle.paneBottom], startPoint: .top, endPoint: .bottom)
        }
        .onChange(of: model.gestureCount) { _, _ in
            // The band felt that: a short bloom for every recognized gesture.
            guard model.live, !reduceMotion else { return }
            bloom = true
            withAnimation(.easeOut(duration: 0.7)) { bloom = false }
        }
    }

    private var band: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [KinesisStyle.blue.opacity(0.55), .clear],
                                         center: .center, startRadius: 4, endRadius: 120))
                .frame(width: 240, height: 240).opacity(bloom ? 0.9 : 0).blur(radius: 6)
            Circle().fill(RadialGradient(colors: [.white.opacity(model.live ? 0.1 : 0.05), .clear],
                                         center: .center, startRadius: 4, endRadius: 115))
                .frame(width: 230, height: 230)
            HoldArtwork(hint: model.pairing.holdHint).frame(width: 196, height: 150)
                .saturation(unpaired ? 0 : 1)
                .opacity(unpaired ? 0.42 : model.live ? 1 : 0.78)
                .scaleEffect(bloom ? 1.025 : 1)
        }
        .frame(height: 170)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: model.live)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: unpaired)
    }

    private var state: some View {
        HStack(spacing: 7) {
            PulseDot(color: model.live ? Color(red: 0.62, green: 0.84, blue: 0.7)
                        : model.inTransit ? KinesisStyle.paneAccent : .white.opacity(0.32),
                     pulsing: model.inTransit)
            Text(stateText).font(KinesisType.micro)
                .foregroundStyle(model.inTransit ? KinesisStyle.paneAccent : .white.opacity(0.7))
                .contentTransition(.opacity)
        }
        .animation(reduceMotion ? nil : KinesisMotion.settle, value: stateText)
        .accessibilityElement(children: .combine)
    }

    private var stateText: String {
        if model.justPaired { return "paired. you’re all set." }
        if unpaired { return model.selectedAddress.isEmpty ? "no band yet" : "setup incomplete" }
        return model.phase.lowercased()
    }

    @ViewBuilder private var notice: some View {
        if model.awaitingSystemPairing {
            PaneNotice(symbol: "hand.tap", text: "accept the bluetooth request", tint: KinesisStyle.paneAccent)
        } else if model.live, let battery = model.battery, battery <= 15 {
            PaneNotice(symbol: "bolt.fill", text: "low battery", tint: Color(red: 0.96, green: 0.66, blue: 0.32))
        } else {
            Color.clear.frame(height: 30)
        }
    }

    private var actions: some View {
        let action = model.nextAction
        return VStack(spacing: 12) {
            Button { perform(action) } label: {
                HStack(spacing: 9) {
                    if action.waits {
                        ProgressView().controlSize(.mini).tint(.black)
                    } else if let symbol = action.symbol {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    }
                    Text(action == .pair && model.pairFailure != nil ? "try again" : action.title)
                        .contentTransition(.opacity)
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(PaneButtonStyle()).disabled(action.waits)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .animation(reduceMotion ? nil : KinesisMotion.settle, value: action)
            Button(model.live ? "disconnect" : "cancel") {
                if model.pairInProgress { model.cancelPairing() } else { model.disconnect() }
            }
            .buttonStyle(.plain).font(KinesisType.caption).foregroundStyle(.white.opacity(0.5))
            .opacity(model.live || action.waits ? 1 : 0)
            .disabled(!(model.live || action.waits))
            .accessibilityHidden(!(model.live || action.waits))
        }
    }

    private func perform(_ action: BandAction) {
        switch action {
        case .pair:
            openBandPage()
            model.pairBand()
        case .connect: model.connect()
        case .enableControls, .pauseControls: model.toggleControls()
        case .pairing, .connecting: break
        }
    }

    private var batterySymbol: String {
        switch model.battery ?? -1 {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

extension KinesisStyle {
    /// The live-state blue, fixed for the dark pane in both modes.
    static let paneAccent = Color(red: 0.49, green: 0.75, blue: 0.98)
}

/// The pane's button is light in both modes, because the pane is always dark.
struct PaneButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 12)
            .foregroundStyle(Color(white: 0.1))
            .background(Color(white: hovered && enabled ? 1 : 0.93), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .contentShape(Capsule())
            .scaleEffect(reduceMotion || !enabled ? 1 : configuration.isPressed ? 0.975 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// A short alert inside the pane, such as a pending pairing request.
private struct PaneNotice: View {
    let symbol: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            Text(text).font(KinesisType.micro).foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 13).frame(height: 30)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .accessibilityElement(children: .combine)
    }
}

/// A state dot that breathes while something is in progress.
struct PulseDot: View {
    let color: Color
    let pulsing: Bool
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).scaleEffect(out ? 2.6 : 1).opacity(out ? 0 : 1)
            Circle().fill(color)
        }
        .frame(width: 6, height: 6)
        .onAppear { animate() }
        .onChange(of: pulsing) { _, _ in animate() }
        .accessibilityHidden(true)
    }

    private func animate() {
        out = false
        guard pulsing, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { out = true }
    }
}
