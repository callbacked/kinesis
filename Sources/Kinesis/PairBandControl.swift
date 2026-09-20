import SwiftUI

/// The pairing surface on the band page and in setup. The model runs one
/// pipeline (find, sign in, claim, settle); this shows where it is, what the
/// person has to do with their hands, and what went wrong.
struct PairBandControl: View {
    @ObservedObject var model: BandModel
    var compact = false
    var body: some View {
        PairingFlowView(state: model.pairing, compact: compact,
                        pair: { model.pairBand() }, cancel: { model.cancelPairing() },
                        switchAccount: {
                            // Drop the sign-in that the band refused, then run again: the sheet opens.
                            model.switchMetaAccount()
                            model.pairBand()
                        })
            .sheet(isPresented: Binding(get: { model.enrollmentStage == .login },
                                        set: { if !$0 { model.cancelEnrollment() } })) {
                MetaLoginView(onSession: { model.enroll(session: $0) },
                              onCancel: { model.cancelEnrollment() })
            }
    }
}

/// Draws a `PairingPresentation`. It owns no state beyond animation, so every
/// pairing state can be rendered and checked without a band.
struct PairingFlowView: View {
    let state: PairingPresentation
    var compact = false
    var pair: () -> Void = {}
    var cancel: () -> Void = {}
    var switchAccount: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            if !compact {
                HoldArtwork(hint: state.holdHint).frame(width: 150, height: 135)
                    .saturation(state.dimsArtwork ? 0 : 1).opacity(state.dimsArtwork ? 0.45 : 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let name = state.bandName {
                    Text(name.lowercased()).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(KinesisStyle.secondary).padding(.bottom, 12)
                }
                PairStepper(state: state).padding(.bottom, 20)
                Text(state.headline).font(.system(size: compact ? 17 : 21)).tracking(-0.5)
                    .foregroundStyle(state.needsSystemPairing ? KinesisStyle.blue : KinesisStyle.ink)
                    .contentTransition(.opacity)
                Text(state.detail).font(.system(size: 12.5))
                    .foregroundStyle(state.failed != nil && state.holdHint != .insist ? KinesisStyle.warning : KinesisStyle.secondary)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8).contentTransition(.opacity)
                if let progress = state.claimProgress, !state.needsSystemPairing {
                    ClaimTicks(progress: progress).padding(.top, 14)
                }
                HStack(spacing: 14) {
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
                            .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                    }
                    if let help = state.help {
                        Link(destination: help.url) {
                            HStack(spacing: 5) {
                                Text(help.title)
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                            }
                        }.font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                    }
                    Spacer(minLength: 0)
                    if state.offersOtherAccount {
                        Button("sign in with another account", action: switchAccount).buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                            .help("signs out, then pairs again so you can use the account that owns this band.")
                    }
                }.padding(.top, 20)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(compact ? 0 : 22)
        .background(compact ? Color.clear : KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state)
        .accessibilityElement(children: .contain)
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
private struct HoldArtwork: View {
    let hint: PairingPresentation.HoldHint
    @State private var ringing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        BandArtwork()
            .overlay {
                GeometryReader { geometry in
                    // The button sits on the capsule under the top arc of the product image.
                    let center = CGPoint(x: geometry.size.width * 0.5, y: geometry.size.height * 0.23)
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
