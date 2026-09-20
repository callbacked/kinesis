import AppKit
import SwiftUI

/// The pairing surface on the band page and in setup. The model runs one
/// pipeline (find, sign in, claim, settle); this shows where it is, what the
/// person has to do with their hands, and what went wrong.
struct PairBandControl: View {
    @ObservedObject var model: BandModel
    var layout = PairingFlowView.Layout.card
    var idleHeadline: String?
    var body: some View {
        PairingFlowView(state: model.pairing, layout: layout, showsButton: layout == .centered,
                        idleHeadline: idleHeadline,
                        pair: { model.pairBand() }, cancel: { model.cancelPairing() },
                        switchAccount: {
                            // Drop the sign-in that the band refused, then run again: the sheet opens.
                            model.switchMetaAccount()
                            model.pairBand()
                        })
    }
}

/// Draws a `PairingPresentation`. It owns no state beyond animation, so every
/// pairing state can be rendered and checked without a band. The sign-in sheet
/// lives at the window root, so a run can reach it from any page.
struct PairingFlowView: View {
    enum Layout { case card, centered }
    let state: PairingPresentation
    var layout = Layout.card
    /// The band pane carries the pair button in the window. Setup has no pane, so the flow does.
    var showsButton = true
    /// Setup greets a fresh band with its own line instead of "pair your band".
    var idleHeadline: String?
    var pair: () -> Void = {}
    var cancel: () -> Void = {}
    var switchAccount: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var centered: Bool { layout == .centered }
    private var headline: String {
        if let idleHeadline, state.current == nil, state.failed == nil, state.bandName == nil { return idleHeadline }
        return state.headline
    }

    var body: some View {
        // The band itself lives in the pane and on setup's stage, never here.
        VStack(alignment: centered ? .center : .leading, spacing: 0) {
            if let name = state.bandName, !centered {
                Text(name.lowercased()).font(KinesisType.micro)
                    .foregroundStyle(KinesisStyle.secondary).padding(.bottom, 12)
            }
            PairStepper(state: state).padding(.bottom, centered ? 26 : 20)
            Text(headline).font(.system(size: centered ? 36 : 21)).tracking(centered ? -1.4 : -0.5)
                .foregroundStyle(state.needsSystemPairing ? KinesisStyle.blue : KinesisStyle.ink)
                .multilineTextAlignment(centered ? .center : .leading).contentTransition(.opacity)
            Text(state.detail).font(.system(size: centered ? 14 : 12.5))
                .foregroundStyle(state.failed != nil && state.holdHint != .insist ? KinesisStyle.warning : KinesisStyle.secondary)
                .lineSpacing(centered ? 5 : 4).multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: centered ? 460 : nil)
                .padding(.top, centered ? 12 : 8).contentTransition(.opacity)
            if let progress = state.claimProgress, !state.needsSystemPairing {
                ClaimTicks(progress: progress).padding(.top, 14)
            }
            HStack(spacing: 14) {
                if showsButton {
                    Button(action: pair) {
                        HStack(spacing: 9) {
                            if state.working {
                                ProgressView().controlSize(.mini).tint(KinesisStyle.paper)
                            } else {
                                Image(systemName: state.failed == nil ? "dot.radiowaves.left.and.right" : "arrow.clockwise")
                                    .font(.system(size: 11))
                            }
                            Text(state.buttonTitle)
                        }
                    }.buttonStyle(KinesisButtonStyle(prominent: true)).disabled(!state.buttonEnabled)
                    if state.working {
                        Button("cancel", action: cancel).buttonStyle(.plain)
                            .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                    }
                }
                if let help = state.help { GuideLink(title: help.title, url: help.url) }
                if !centered { Spacer(minLength: 0) }
                if state.offersOtherAccount {
                    Button("sign in with another account", action: switchAccount).buttonStyle(.plain)
                        .font(KinesisType.caption).foregroundStyle(KinesisStyle.secondary)
                        .help("signs out, then pairs again so you can use the account that owns this band.")
                }
            }.padding(.top, showsButton || state.help != nil || state.offersOtherAccount ? (centered ? 26 : 20) : 0)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .padding(centered ? 0 : 24)
        .background(centered ? Color.clear : KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state)
        .accessibilityElement(children: .contain)
    }
}

/// A quiet link out to a guide, such as Meta's factory reset steps.
struct GuideLink: View {
    let title: String
    let url: URL
    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
            }
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
            .help(url.host ?? "")
    }
}

/// find · sign in · claim · ready, with the live stage marked.
private struct PairStepper: View {
    let state: PairingPresentation
    var body: some View {
        HStack(spacing: 8) {
            ForEach(PairStep.allCases) { step in
                HStack(spacing: 7) {
                    StepDot(mark: mark(step))
                    Text(step.title).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(mark(step) == .upcoming ? KinesisStyle.secondary.opacity(0.7) : KinesisStyle.ink)
                }
                if step != PairStep.allCases.last {
                    Rectangle().fill(state.completed.contains(step) ? KinesisStyle.green.opacity(0.6) : KinesisStyle.line)
                        .frame(height: 1).frame(minWidth: 10, maxWidth: 34)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.current.map { "Pairing step: \($0.title)" } ?? "Pairing steps: find, sign in, claim, ready")
    }

    private func mark(_ step: PairStep) -> StepDot.Mark {
        if state.failed == step { return .failed }
        if state.current == step { return .current }
        return state.completed.contains(step) ? .done : .upcoming
    }
}

private struct StepDot: View {
    enum Mark { case upcoming, current, done, failed }
    let mark: Mark
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            switch mark {
            case .upcoming:
                Circle().strokeBorder(KinesisStyle.line, lineWidth: 1.5)
            case .current:
                Circle().fill(KinesisStyle.blue.opacity(0.22)).scaleEffect(pulsing ? 1.9 : 1).opacity(pulsing ? 0 : 1)
                Circle().fill(KinesisStyle.blue).padding(3)
            case .done:
                Circle().fill(KinesisStyle.green)
                Image(systemName: "checkmark").font(.system(size: 6.5, weight: .heavy)).foregroundStyle(KinesisStyle.paper)
            case .failed:
                Circle().fill(KinesisStyle.warning)
                Image(systemName: "exclamationmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(KinesisStyle.paper)
            }
        }
        .frame(width: 13, height: 13)
        .onAppear { animate() }
        .onChange(of: mark) { _, _ in animate() }
    }

    private func animate() {
        pulsing = false
        guard mark == .current, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulsing = true }
    }
}

/// Four quiet ticks for the claim: identity, ownership, confirmation, keys.
private struct ClaimTicks: View {
    let progress: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...4, id: \.self) { index in
                Capsule().fill(index <= progress ? KinesisStyle.blue : KinesisStyle.line)
                    .frame(width: index == progress ? 22 : 12, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claim step \(max(progress, 1)) of 4")
    }
}

/// The band, with its button called out while the person has to hold it.
struct HoldArtwork: View {
    let hint: PairingPresentation.HoldHint
    @State private var ringing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        BandArtwork()
            .overlay {
                GeometryReader { geometry in
                    // The button sits on the capsule under the top arc of the product image.
                    let center = CGPoint(x: geometry.size.width * 0.5, y: geometry.size.height * 0.25)
                    ZStack {
                        Circle().stroke(KinesisStyle.blue.opacity(0.85), lineWidth: 1.5)
                            .frame(width: 26, height: 26)
                            .scaleEffect(ringing ? 2.1 : 0.7).opacity(ringing ? 0 : 1)
                        Circle().fill(KinesisStyle.blue).frame(width: 7, height: 7)
                            .shadow(color: KinesisStyle.blue.opacity(0.9), radius: 6)
                    }
                    .position(center)
                    .opacity(hint == .none ? 0 : 1)
                }
            }
            .onAppear { animate() }
            .onChange(of: hint) { _, _ in animate() }
            .accessibilityLabel(hint == .none ? "Meta Neural Band" : "Hold the button on the band")
    }

    private func animate() {
        ringing = false
        guard hint != .none, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ringing = true }
    }
}
