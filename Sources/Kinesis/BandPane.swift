import SwiftUI

/// What the band column's one button does next. It always offers the step that
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

/// The band's column. It shares the window's field: the band is an object on the
/// same ground as everything else, in its own pool of light, with the next thing to do under it.
struct BandPane: View {
    @ObservedObject var model: BandModel
    var openBandPage: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var unpaired: Bool { model.showsPairAction && !model.pairInProgress }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                KinesisMark(size: CGSize(width: 25, height: 23))
                Text("kinesis").font(.system(size: 16, weight: .medium, design: .rounded)).tracking(-0.5)
                Spacer()
            }.foregroundStyle(KinesisStyle.ink.opacity(0.9)).padding(.top, 46)

            Spacer(minLength: 18)
            band
            VStack(spacing: 9) {
                Text(model.bandName.lowercased()).font(.system(size: 19)).tracking(-0.4)
                    .foregroundStyle(KinesisStyle.ink).lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.82)
                state
            }.padding(.top, 18)
            notice.padding(.top, 16)
            Spacer(minLength: 18)

            actions
            Rectangle().fill(KinesisStyle.line).frame(height: 1).padding(.top, 24)
            HStack(alignment: .top) {
                Readout(symbol: batterySymbol, value: model.battery.map { "\($0) %" } ?? "–", label: "battery")
                Spacer()
                Readout(symbol: "hand.draw", value: model.totalGestureCount.formatted(), label: "gestures",
                        alignment: .trailing)
            }.padding(.top, 20).padding(.bottom, 26)
        }
        .padding(.horizontal, 24)
        .frame(width: 264)
    }

    private var band: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [KinesisStyle.pool.opacity(model.live ? 1 : 0.5), .clear],
                                         center: .center, startRadius: 4, endRadius: 128))
                .frame(width: 256, height: 256)
            // The band rests on the field the way a product rests on a table.
            Ellipse().fill(.black.opacity(scheme == .dark ? 0.55 : 0.22))
                .frame(width: 124, height: 10).blur(radius: 11).offset(y: 76)
                .opacity(unpaired ? 0.4 : 1)
            BandArtwork().frame(width: 196, height: 150)
                .saturation(unpaired ? 0 : 1)
                .opacity(unpaired ? 0.42 : model.live ? 1 : 0.8)
        }
        .frame(height: 170)
        .animation(reduceMotion ? nil : KinesisMotion.calm, value: model.live)
        .animation(reduceMotion ? nil : KinesisMotion.calm, value: unpaired)
    }

    private var state: some View {
        HStack(spacing: 7) {
            PulseDot(color: model.live ? KinesisStyle.green
                        : model.inTransit ? KinesisStyle.accent : KinesisStyle.secondary.opacity(0.55),
                     pulsing: model.inTransit)
            Text(stateText).font(KinesisType.micro)
                .foregroundStyle(model.inTransit ? KinesisStyle.accent : KinesisStyle.secondary)
                .contentTransition(.opacity)
        }
        .animation(reduceMotion ? nil : KinesisMotion.settle, value: stateText)
        .accessibilityElement(children: .combine)
    }

    private var stateText: String {
        if model.justPaired { return "paired. you’re all set." }
        if unpaired { return model.selectedAddress.isEmpty ? "no band yet" : "setup incomplete" }
        // The notice under this line already says what to do. The state only says who we wait for.
        if model.awaitingSystemPairing { return "waiting for macOS" }
        return model.phase.lowercased()
    }

    private var notice: some View {
        let lowBattery = model.live && (model.battery ?? 100) <= 15
        return noticeContent
            .animation(reduceMotion ? nil : KinesisMotion.enter, value: model.awaitingSystemPairing)
            .animation(reduceMotion ? nil : KinesisMotion.enter, value: lowBattery)
    }

    @ViewBuilder private var noticeContent: some View {
        if model.awaitingSystemPairing {
            PaneNotice(symbol: "hand.tap", text: "accept the bluetooth request", tint: KinesisStyle.accent)
        } else if model.live, let battery = model.battery, battery <= 15 {
            PaneNotice(symbol: "bolt.fill", text: "low battery", tint: KinesisStyle.warning)
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
                        ProgressView().controlSize(.mini).tint(KinesisStyle.accent)
                    } else if let symbol = action.symbol {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    }
                    Text(action == .pair && model.pairFailure != nil ? "try again" : action.title)
                        .contentTransition(.opacity)
                }
            }
            // Pausing is the quiet choice. Every other step moves the band toward live, so it takes the accent.
            .buttonStyle(KinesisButtonStyle(prominent: action != .pauseControls, wide: true)).disabled(action.waits)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .animation(reduceMotion ? nil : KinesisMotion.settle, value: action)
            Button(model.live ? "disconnect" : "cancel") {
                if model.pairInProgress { model.cancelPairing() } else { model.disconnect() }
            }
            .buttonStyle(.plain).font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
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

/// A short alert in the band's column, such as a pending pairing request.
private struct PaneNotice: View {
    let symbol: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            Text(text).font(KinesisType.micro).foregroundStyle(KinesisStyle.ink.opacity(0.9))
        }
        .padding(.horizontal, 13).frame(height: 30)
        .background(tint.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .transition(.opacity.combined(with: .offset(y: -4)))
        .accessibilityElement(children: .combine)
    }
}

/// A state dot that breathes while something is in progress, on the shared heartbeat.
struct PulseDot: View {
    let color: Color
    let pulsing: Bool
    var body: some View {
        Pulse(active: pulsing) { beat in
            ZStack {
                Circle().fill(color.opacity(0.35)).scaleEffect(1 + 1.6 * beat).opacity(1 - beat)
                Circle().fill(color)
            }
        }
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
    }
}
